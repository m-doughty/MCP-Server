use JSON::Fast;
use MCP::Server::Protocol;
use MCP::Server::Context;
use MCP::Server::Tool;
use MCP::Server::Resource;
use MCP::Server::Prompt;

use MCP::Server::Transport;
use MCP::Server::Transport::Stdio;

#| Facade over an MCP::Server that namespaces everything registered through it.
#| Tools and prompts become "{prefix}{sep}{name}" (underscore by default, which
#| keeps generated names inside the MCP tool-name charset); resource URIs get
#| the prefix injected as the first path segment.
class MCP::Server::Registrar {
	has $.server is required;
	has Str $.prefix;
	has Str:D $.sep = '_';

	method prefixing(--> Bool:D) {
		$!prefix.defined && $!prefix ne '';
	}

	method prefixed(Str:D $name --> Str:D) {
		self.prefixing ?? "{$!prefix}{$!sep}{$name}" !! $name;
	}

	method prefixed-uri(Str:D $uri --> Str:D) {
		return $uri unless self.prefixing;
		if $uri ~~ /^ $<scheme> = (<-[:/]>+) '://' $<rest> = (.*) $/ {
			my $scheme = ~$<scheme>;
			# Trim leading slashes off the path so we never emit an empty path
			# segment for authority-less URIs such as file:///etc/hosts.
			my $rest = ~$<rest>;
			$rest ~~ s/ ^ '/'+ //;
			return "{$scheme}://{$!prefix}/{$rest}";
		}
		"{$!prefix}/{$uri}";
	}

	method tool(Str:D $name, Str :$description, :%params, :&handler!) {
		$!server.tool: self.prefixed($name), :$description, :%params, :&handler;
	}

	method prompt(Str:D $name, Str :$description, :@arguments, :&handler!) {
		$!server.prompt: self.prefixed($name), :$description, :@arguments, :&handler;
	}

	method resource(
		Str:D $uri, Str:D :$name!, Str :$description, Str :$mime-type,
		Int :$ttl-ms, Str :$cache-scope, :&handler!,
	) {
		# The cacheability hints are passed only when set so the server keeps its
		# own "unset" defaults (see MCP::Server.resource) rather than having them
		# overwritten with undefined values.
		$!server.resource: self.prefixed-uri($uri), :$name, :$description, :$mime-type, :&handler,
			|($ttl-ms.defined ?? (:$ttl-ms) !! ()),
			|($cache-scope.defined ?? (:$cache-scope) !! ());
	}
}

# Back-compat alias for the pre-toolkit name of the facade.
our constant ToolGroup = MCP::Server::Registrar;

# MCP requires tool names to be 1..128 characters of [A-Za-z0-9_-].
my regex mcp-tool-name { ^ <[A..Za..z0..9_\-]> ** 1..128 $ }

# Methods the 2026-07-28 era removed: the handshake (every modern request is
# self-describing via _meta), ping (liveness belongs to the transport) and
# logging/setLevel (the level travels per-request in _meta).  They stay available
# to legacy clients and answer METHOD_NOT_FOUND to modern ones.
my constant MODERN-REMOVED-METHODS = Set.new(<initialize ping logging/setLevel>);

# $*ERR is process-wide, so concurrent handlers (an HTTP transport's thread pool,
# for instance) would otherwise shear each other's log lines.
my $log-lock = Lock.new;

class MCP::Server is export {

has Str:D $.name is required;
has Str:D $.version = '1.0.0';
has Str $.instructions;
has MCP::Server::Tool %!tools;
has MCP::Server::Resource %!resources;
has MCP::Server::Prompt %!prompts;
has MCP::Server::Transport $!transport;
has Bool:D $!initialized = False;

#| Protocol eras this server will answer for.  Both by default: the era of every
#| message is detected from the message itself, so one instance can serve a
#| legacy and a modern client at the same time.
has Str:D @.protocol-versions = SUPPORTED-PROTOCOL-VERSIONS;

#| Cache metadata for modern catalog listings.  Every registration happens before
#| run(), so the catalogs really are frozen for the life of the process and an
#| hour is an honest TTL; 'private' is the conservative scope for a server whose
#| catalog may be user-specific.
has Int:D $.discovery-ttl-ms = 3_600_000;
has CacheScope:D $.cache-scope = 'private';

# Threshold set by a legacy client through logging/setLevel.  'debug' lets
# everything through, which is what the server did before setLevel existed.
has Str:D $!min-log-level = 'debug';

#| Transport settings carried through from the config file's optional "http"
#| section (port/host/path/allowedOrigins), for whoever starts a transport with
#| this server — the CLI, normally.  The server itself never reads it: it is
#| deliberately transport-agnostic, and from-config has to keep returning an
#| MCP::Server rather than a config-plus-server pair.  Empty unless the config
#| asked for HTTP.
has %.http-config;

submethod TWEAK(:@tools) {
	die "MCP server '$!name' must support at least one protocol version"
		unless @!protocol-versions.elems > 0;

	my $known = SUPPORTED-PROTOCOL-VERSIONS.Set;
	if @!protocol-versions.grep({ $_ !(elem) $known }).sort.squish -> @unsupported {
		die "Unknown protocol version(s) for MCP server '$!name': {@unsupported.join(', ')}. "
		  ~ "Supported: {SUPPORTED-PROTOCOL-VERSIONS.join(', ')}";
	}

	die "discovery-ttl-ms for MCP server '$!name' must be zero or more, got $!discovery-ttl-ms"
		if $!discovery-ttl-ms < 0;

	self!load-tool-entry($_) for @tools;
}

# === Registration API ===

method tool(Str:D $name, Str :$description, :%params, :&handler!) {
	die "Invalid tool name '$name': MCP tool names must be 1 to 128 characters of [A-Za-z0-9_-]"
		unless $name ~~ &mcp-tool-name;
	die "Duplicate tool '$name' on MCP server '$!name'; register one of the providers "
	  ~ "under a prefix, e.g. \$server.plug(\$kit, :prefix<other>)"
		if %!tools{$name}:exists;
	%!tools{$name} = MCP::Server::Tool.new(:$name, :$description, :%params, :&handler);
}

method tool-group(Str:D $prefix, &registrar) {
	my $group = MCP::Server::Registrar.new(:server(self), :$prefix);
	registrar($group);
}

#| :ttl-ms and :cache-scope are the per-resource cacheability hints reported on
#| modern resources/read results.  Both are optional: a resource that says
#| nothing is treated as uncacheable and private, since a read runs arbitrary
#| handler code whose freshness only the author knows.
method resource(
	Str:D $uri, Str:D :$name!, Str :$description, Str :$mime-type,
	Int :$ttl-ms, Str :$cache-scope, :&handler!,
) {
	die "Duplicate resource URI '$uri' on MCP server '$!name'; register one of the providers "
	  ~ "under a prefix, e.g. \$server.plug(\$kit, :prefix<other>)"
		if %!resources{$uri}:exists;
	die "Invalid ttl-ms for resource '$uri' on MCP server '$!name': must be zero or more, got $ttl-ms"
		if $ttl-ms.defined && $ttl-ms < 0;
	die "Invalid cache-scope for resource '$uri' on MCP server '$!name': "
	  ~ "expected 'public' or 'private', got '$cache-scope'"
		if $cache-scope.defined && $cache-scope !~~ CacheScope;
	%!resources{$uri} = MCP::Server::Resource.new(
		:$uri, :$name, :$description, :$mime-type, :&handler,
		|($ttl-ms.defined ?? (:$ttl-ms) !! ()),
		|($cache-scope.defined ?? (:$cache-scope) !! ()),
	);
}

method prompt(Str:D $name, Str :$description, :@arguments, :&handler!) {
	die "Duplicate prompt '$name' on MCP server '$!name'; register one of the providers "
	  ~ "under a prefix, e.g. \$server.plug(\$kit, :prefix<other>)"
		if %!prompts{$name}:exists;
	%!prompts{$name} = MCP::Server::Prompt.new(:$name, :$description, :@arguments, :&handler);
}

# === Toolkits ===

#| Register a toolkit (anything with a .register method) on this server,
#| optionally namespacing everything it registers behind $prefix.  Returns the
#| server so plugs can be chained.
method plug($kit, Str :$prefix is copy, Str:D :$sep = '_') {
	die "plug() expects a toolkit object with a .register method, got "
	  ~ ($kit.defined ?? "a {$kit.^name}" !! 'an undefined value')
		unless $kit.defined && $kit.^can('register');

	$prefix //= $kit.?default-prefix;

	my $registrar = MCP::Server::Registrar.new(:server(self), :$prefix, :$sep);
	$kit.register($registrar);
	self;
}

#| Resolve a toolkit name to its type object.  Bare names are looked up under
#| MCP::Server::Tool::, qualified names are used verbatim.
our sub load-toolkit-class(Str:D $name) {
	my $module = $name.contains('::') ?? $name !! "MCP::Server::Tool::$name";
	CATCH {
		default {
			die "Could not load toolkit '$name' (module $module): {.message}\n"
			  ~ "If the distribution is not installed, try: zef install $module";
		}
	}
	# NB: require's return value MUST be bound here — a later ::($module)
	# lookup can resolve to a stale/absent GLOBAL slot when the caller has
	# already `use`d a sibling module from the same distribution.
	my \type = (require ::($module));
	type;
}

method !instantiate-toolkit(Str:D $name, %config) {
	my \type = load-toolkit-class($name);
	type.^can('from-config') ?? type.from-config(%config) !! type.new(|%config.Map);
}

method !load-tool-entry($entry) {
	my $kit;
	my $prefix;

	if $entry ~~ Pair {
		my $key = $entry.key;
		my %config = $entry.value.defined ?? $entry.value.Hash !! {};
		$prefix = %config<prefix>:delete;

		if $key ~~ Str:D {
			$kit = self!instantiate-toolkit($key, %config);
		} else {
			die "Toolkit instance entries accept only the reserved 'prefix' key; "
			  ~ "got: {%config.keys.sort.join(', ')}"
				if %config.elems > 0;
			$kit = $key;
		}
	} elsif $entry ~~ Str:D {
		$kit = self!instantiate-toolkit($entry, {});
	} else {
		$kit = $entry;
	}

	die "Invalid :tools entry ({$entry.^name}): expected a toolkit name, a toolkit "
	  ~ "instance, or a Pair of either => config hash"
		unless $kit.defined && $kit.^can('register');

	die "Toolkit prefix must be a string, got {$prefix.^name}"
		if $prefix.defined && $prefix !~~ Str:D;

	self.plug($kit, |($prefix.defined ?? (:$prefix) !! ()));
}

#| Build a server from a JSON config file:
#|   { "name": "...", "version": "...", "instructions": "...",
#|     "tools": { "FileSystem#docs": { "root": "/docs", "prefix": "docs" } },
#|     "http": { "port": 8080, "host": "127.0.0.1", "path": "mcp",
#|               "allowedOrigins": ["https://app.example"] } }
#| Toolkit keys may carry a "#alias" suffix so the same toolkit can be loaded
#| more than once with different settings.  The optional "http" section is not
#| used by the server itself — it is validated here and handed on through
#| .http-config to whoever starts the Streamable HTTP transport.
method from-config(MCP::Server:U: IO() $path --> MCP::Server:D) {
	die "Config file not found: $path" unless $path.f;

	my $text = $path.slurp;
	my $parsed;
	{
		CATCH { default { die "Invalid JSON in {$path}: {.message}" } }
		$parsed = from-json($text);
	}
	die "Invalid JSON in {$path}: top level must be an object"
		unless $parsed ~~ Associative;
	my %config = $parsed.Hash;

	my @known = <name version instructions tools http>;
	my %known = @known.Set;
	if %config.keys.grep({ !%known{$_} }).sort -> @unknown {
		die "Unknown key(s) in {$path}: {@unknown.join(', ')}. "
		  ~ "Valid keys: {@known.join(', ')}";
	}

	die "Config in {$path} must set a string 'name'"
		unless %config<name> ~~ Str:D && %config<name>.chars > 0;

	my @entries;
	with %config<tools> {
		die "'tools' in {$path} must be an object mapping toolkit names to config objects"
			unless $_ ~~ Associative;
		for .kv -> $key, $value {
			die "Config for toolkit '$key' in {$path} must be an object"
				unless !$value.defined || $value ~~ Associative;
			my $name = $key.subst(/ '#' .* $ /, '');
			die "Toolkit name is empty in key '$key' of {$path}" unless $name.chars > 0;
			@entries.push: $name => ($value.defined ?? $value.Hash !! {});
		}
	}

	self.new(
		name => %config<name>,
		|(version      => %config<version>      if %config<version>.defined),
		|(instructions => %config<instructions> if %config<instructions>.defined),
		tools => @entries,
		http-config => http-config-from(%config<http>, $path),
	);
}

# Validated here rather than where the transport is started so that a typo in the
# config file is caught the moment the file is read, with the path to blame in
# the message.
my sub http-config-from($section, $path --> Hash) {
	return {} unless $section.defined;
	die "'http' in {$path} must be an object" unless $section ~~ Associative;
	my %http = $section.Hash;

	my @known = <port host path allowedOrigins>;
	my %known = @known.Set;
	if %http.keys.grep({ !%known{$_} }).sort -> @unknown {
		die "Unknown key(s) in the 'http' section of {$path}: {@unknown.join(', ')}. "
		  ~ "Valid keys: {@known.join(', ')}";
	}

	with %http<port> {
		die "'http.port' in {$path} must be an integer from 1 to 65535"
			unless $_ ~~ Int:D && 1 <= $_ <= 65535;
	}
	for <host path> -> $key {
		with %http{$key} {
			die "'http.$key' in {$path} must be a non-empty string"
				unless $_ ~~ Str:D && .chars > 0;
		}
	}
	with %http<allowedOrigins> {
		die "'http.allowedOrigins' in {$path} must be an array of strings"
			unless $_ ~~ Positional && .list.all ~~ Str:D;
		%http<allowedOrigins> = .list.Array;
	}

	%http;
}

# === LLM tool bridge ===

method tools-for-llm(--> List) {
	%!tools.values.map(-> $tool {
		{
			type => 'function',
			function => {
				name => $tool.name,
				|($tool.description.defined ?? (description => $tool.description) !! ()),
				parameters => $tool.input-schema,
			},
		}
	}).list;
}

method execute-tool-calls(@tool-calls --> List) {
	@tool-calls.map(-> %tc {
		my $fn-name = %tc<function><name>;
		my $args = %tc<function><arguments> // {};
		my $call-id = %tc<id> // '';

		my %arguments;
		my $result;
		my $is-error = False;

		if $args ~~ Associative {
			%arguments = $args.Hash;
		} else {
			try {
				my $parsed = from-json($args.Str);
				if $parsed ~~ Associative {
					%arguments = $parsed.Hash;
				} else {
					$result = 'Tool arguments must be a JSON object';
					$is-error = True;
				}
				CATCH {
					default {
						$result = "Invalid tool arguments JSON: {.message}";
						$is-error = True;
					}
				}
			}
		}

		if !$is-error {
			if %!tools{$fn-name}:exists {
				try {
					$result = %!tools{$fn-name}.call(%arguments);
					CATCH {
						default {
							$result = .message;
							$is-error = True;
						}
					}
				}
			} else {
				$result = "Unknown tool: '$fn-name'";
				$is-error = True;
			}
		}

		{
			role => 'tool',
			tool_call_id => $call-id,
			content => ~($result // ''),
			is_error => $is-error,
		};
	}).list;
}

# === Run loop ===

method run(MCP::Server::Transport :$transport) {
	$!transport = $transport // MCP::Server::Transport::Stdio.new;
	self.log('info', "Starting MCP server: $!name v$!version");

	# Notifications raised while a request is in flight go straight out on the
	# transport, so a modern request's notifications/message interleave ahead of
	# the response they belong to instead of being dropped.
	my &notify = -> %notif { $!transport.write-message(format-message(%notif)) };

	loop {
		my $line = $!transport.read-message;
		last unless $line.defined;
		last if $line.trim eq '';

		my %msg = parse-message($line);

		# If parse-message returned an error response directly
		if %msg<error>:exists {
			$!transport.write-message(format-message(%msg));
			next;
		}

		# Notifications have no id — don't send a response
		if !(%msg<id>:exists) {
			self!handle-notification(%msg);
			next;
		}

		my %response = self!dispatch(%msg, self!context-for(%msg, :&notify));
		$!transport.write-message(format-message(%response));
	}

	self.log('info', 'MCP server shutting down');
}

# === Request dispatch (public for testing) ===

#| Handle one parsed request message and return its response.  The protocol era
#| is detected from the message itself, so legacy and modern clients can be
#| served from the same instance without a mode flag.
method handle-request(%msg --> Hash) {
	self!dispatch(%msg, self!context-for(%msg));
}

#| Transport-free entry point for request/response transports (Streamable HTTP,
#| say), which are modern-only: the era is forced rather than detected, so a
#| legacy-shaped message gets a modern answer (METHOD_NOT_FOUND for the removed
#| methods, -32022 for a missing or unsupported _meta version).
#|
#| Notification bodies — those without an id — are dispatched for their side
#| effects and answered with an empty Hash, since JSON-RPC forbids a response.
#|
#| :&notify is called synchronously on the calling thread, zero or more times,
#| before this method returns; leaving it out drops the request's notifications.
#| :$cancelled is surfaced to handlers through $*MCP-REQUEST-CONTEXT.cancelled.
#|
#| Touches no server state, so concurrent calls are safe as far as this class is
#| concerned — user handlers still have to be thread-safe themselves.
method handle-modern-request(%msg, :&notify, Promise :$cancelled --> Hash) {
	my $ctx = self!context-for(%msg, :force-era<modern>, :&notify, :$cancelled);
	my %response = self!dispatch(%msg, $ctx);
	return {} unless %msg<id>:exists;
	%response;
}

#| Server identity, as reported in modern results' _meta.
method server-info(--> Hash) {
	{ name => $!name, version => $!version };
}

#| The body of a server/discover result, minus JSON-RPC framing and the envelope
#| the dispatcher adds.  Static for the life of the process, so transports may
#| cache it (see the ttlMs/cacheScope it carries).
method discovery-document(--> Hash) {
	my %capabilities;
	%capabilities<tools> = {} if %!tools.elems > 0;
	%capabilities<resources> = {} if %!resources.elems > 0;
	%capabilities<prompts> = {} if %!prompts.elems > 0;
	# No 'logging' — 2026-07-28 deprecated the capability in favour of the
	# per-request _meta logLevel — and no 'extensions', which we do not offer.

	{
		supportedVersions => self.modern-protocol-versions,
		capabilities => %capabilities,
		|($!instructions.defined ?? (instructions => $!instructions) !! ()),
		ttlMs => $!discovery-ttl-ms,
		cacheScope => $!cache-scope,
	};
}

#| The configured protocol versions that belong to the modern era, in
#| configuration order.  Transports validate MCP-Protocol-Version against this.
method modern-protocol-versions(--> List) {
	my $modern = MODERN-PROTOCOL-VERSIONS.Set;
	@!protocol-versions.grep({ $modern{$_} }).list;
}

# === Internal dispatch ===

method !context-for(
	%msg, Str :$force-era, :&notify, Promise :$cancelled --> MCP::Server::Context:D
) {
	my $era = $force-era // detect-era(%msg);
	my %meta = request-meta(%msg);

	my $protocol-version = %meta{META-PROTOCOL-VERSION} ~~ Str:D
		?? %meta{META-PROTOCOL-VERSION}
		# A legacy message never carries a version marker but its era is fixed;
		# a modern one without a marker is left undefined for the version gate.
		!! ($era eq 'legacy' ?? LEGACY-PROTOCOL-VERSION !! Str);

	# An unusable logLevel is treated as absent rather than as an error: it is a
	# hint attached to a request that is otherwise perfectly well formed.
	my $log-level = %meta{META-LOG-LEVEL};
	$log-level = Str unless ($log-level ~~ Str:D) && (%LOG-LEVELS{$log-level}:exists);

	MCP::Server::Context.new(
		:$era,
		:$protocol-version,
		:$log-level,
		client-info => (%meta{META-CLIENT-INFO} ~~ Associative ?? %meta{META-CLIENT-INFO}.Hash !! {}),
		client-capabilities => (%meta{META-CLIENT-CAPABILITIES} ~~ Associative
			?? %meta{META-CLIENT-CAPABILITIES}.Hash !! {}),
		emit => &notify,
		|($cancelled.defined ?? (:$cancelled) !! ()),
	);
}

method !dispatch(%msg, MCP::Server::Context:D $ctx --> Hash) {
	my $id = %msg<id>;
	my $method = %msg<method> // '';
	my Bool:D $modern = $ctx.era eq 'modern';

	# JSON-RPC lets params be omitted, but every MCP method that takes them takes
	# an object.  Anything else is rejected here rather than left to explode
	# somewhere inside a handler — transports hand us whatever the client sent.
	my $raw-params = %msg<params>;
	return error-response($id, INVALID_PARAMS, 'Invalid params: expected an object')
		if $raw-params.defined && $raw-params !~~ Associative;
	my %params = $raw-params // {};

	# Era guards run before the version gate: a method that does not exist in the
	# requested era is "not found" whichever version was asked for.
	if $modern {
		return error-response($id, METHOD_NOT_FOUND, "Method not found: $method")
			if MODERN-REMOVED-METHODS{$method};
	} elsif $method eq 'initialize' {
		# detect-era pins initialize to the legacy era, so a server that no longer
		# speaks it owes the client the version list rather than a bare
		# method-not-found.
		return unsupported-protocol-version-error(
			$id, requested => LEGACY-PROTOCOL-VERSION, supported => @!protocol-versions,
		) unless self!speaks(LEGACY-PROTOCOL-VERSION);
	}

	# Version gate.  server/discover is the bootstrap probe — it is answerable
	# without _meta and its whole job is to report which versions we speak — so it
	# is the one modern method exempt from it.  The supported list names every
	# configured version, including legacy ones, so a client that guessed wrong
	# can fall back.
	if $modern && $method ne 'server/discover' {
		my $requested = $ctx.protocol-version;
		return unsupported-protocol-version-error($id, :$requested, supported => @!protocol-versions)
			unless $requested.defined && self.modern-protocol-versions.grep({ $_ eq $requested }).elems > 0;
	}

	my %response = do {
		my $*MCP-REQUEST-CONTEXT = $ctx;
		given $method {
			when 'initialize'         { self!handle-initialize($id, %params) }
			when 'server/discover'    { self!handle-discover($id) }
			when 'ping'               { success-response($id, {}) }
			when 'logging/setLevel'   { self!handle-set-level($id, %params) }
			when 'tools/list'         { self!handle-tools-list($id, %params) }
			when 'tools/call'         { self!handle-tools-call($id, %params) }
			when 'resources/list'     { self!handle-resources-list($id, %params) }
			when 'resources/read'     { self!handle-resources-read($id, %params) }
			when 'prompts/list'       { self!handle-prompts-list($id, %params) }
			when 'prompts/get'        { self!handle-prompts-get($id, %params) }
			# Includes subscriptions/listen: this server emits no change
			# notifications and advertises no listChanged, so it does not exist here.
			default                   { error-response($id, METHOD_NOT_FOUND, "Method not found: $method") }
		}
	};

	return %response unless $modern;

	# Single choke point for the modern result decorations: cache metadata first,
	# then resultType and serverInfo.  MRTR is not implemented — this server never
	# turns round and asks the client anything — so every result is 'complete'.
	%response = self!cacheable-result($method, %params, %response);
	modern-envelope(%response, server-info => self.server-info);
}

method !speaks(Str:D $version --> Bool:D) {
	@!protocol-versions.grep({ $_ eq $version }).elems > 0;
}

#| 2026-07-28 requires cache metadata on the catalog listings and on resource
#| reads.  Listings come out of registries frozen before run(), so they carry the
#| server-wide TTL; a read runs arbitrary handler code, so it is uncacheable
#| unless the resource that owns it says otherwise.
method !cacheable-result(Str:D $method, %params, %response --> Hash) {
	return %response if %response<error>:exists;

	my Int $ttl-ms;
	my Str $cache-scope;
	given $method {
		when 'tools/list' | 'resources/list' | 'prompts/list' {
			$ttl-ms = $!discovery-ttl-ms;
			$cache-scope = $!cache-scope;
		}
		when 'resources/read' {
			my $resource = %!resources{%params<uri> // ''};
			$ttl-ms = ($resource.defined ?? $resource.ttl-ms !! Int) // 0;
			$cache-scope = ($resource.defined ?? $resource.cache-scope !! Str) // 'private';
		}
		default { return %response }
	}

	my %out = %response;
	%out<result> = with-cacheability(%response<result> // {}, :$ttl-ms, :$cache-scope);
	%out;
}

# === Logging ===

#| Log a message at an RFC 5424 level.  It always reaches $*ERR; whether it also
#| reaches the client depends on the era of the request in flight (if any).
method log(Str:D $level, Str:D $message) {
	$log-lock.protect: { $*ERR.say("[MCP/$level] $message") };

	my %notif = notification('notifications/message', {
		level => $level, logger => $!name, message => $message,
	});

	my $ctx = $*MCP-REQUEST-CONTEXT;

	if $ctx.defined && $ctx.era eq 'modern' {
		# A 2026-07-28 server MUST NOT send notifications/message for a request that
		# did not opt in through _meta logLevel, and the emission is scoped to that
		# request's channel, so it can never leak into another one.
		$ctx.emit-notification(%notif) if $ctx.wants-log($level);
		return;
	}

	# Legacy rules, in a request or out of one: nothing before the client says it
	# is initialized, nothing below the level it asked for.
	return unless $!initialized && log-level-at-least($level, $!min-log-level);
	return if $ctx.defined && $ctx.emit-notification(%notif);

	# Out of a request (or in one whose context has no sink of its own) legacy
	# notifications go to the shared transport, which is where they belong: a
	# legacy session only ever has one client on it.
	$!transport.write-message(format-message(%notif)) if $!transport.defined;
}

# === Internal handlers ===

method !handle-notification(%msg) {
	given %msg<method> {
		when 'notifications/initialized' {
			$!initialized = True;
			self.log('info', 'Client initialized');
		}
		when 'notifications/cancelled' {
			# Acknowledge but no action needed for sync server
		}
	}
}

method !handle-initialize($id, %params --> Hash) {
	my %capabilities;
	%capabilities<tools> = {} if %!tools.elems > 0;
	%capabilities<resources> = {} if %!resources.elems > 0;
	%capabilities<prompts> = {} if %!prompts.elems > 0;
	# Legacy clients get the logging capability, and since logging/setLevel is
	# implemented for them the advertisement is truthful.
	%capabilities<logging> = {};

	success-response($id, {
		protocolVersion => LEGACY-PROTOCOL-VERSION,
		capabilities => %capabilities,
		serverInfo => {
			name => $!name,
			version => $!version,
		},
		|($!instructions.defined ?? (instructions => $!instructions) !! ()),
	});
}

method !handle-discover($id --> Hash) {
	success-response($id, self.discovery-document);
}

#| Legacy-only: the modern era carries the level per request instead.  Rejecting
#| an unknown level is what makes the advertised logging capability honest.
method !handle-set-level($id, %params --> Hash) {
	my $level = %params<level>;
	unless ($level ~~ Str:D) && (%LOG-LEVELS{$level}:exists) {
		my $levels = %LOG-LEVELS.keys.sort({ %LOG-LEVELS{$^a} <=> %LOG-LEVELS{$^b} }).join(', ');
		return error-response(
			$id, INVALID_PARAMS,
			"Invalid log level: '{$level // ''}'. Expected one of: $levels",
		);
	}

	$!min-log-level = $level;
	success-response($id, {});
}

# Catalog listings are sorted so a client (or a cache keyed on the response) sees
# a stable order: hash iteration order is not stable in Raku.
method !handle-tools-list($id, %params --> Hash) {
	success-response($id, {
		tools => %!tools.values.sort(*.name).map(*.to-hash).list,
	});
}

method !handle-tools-call($id, %params --> Hash) {
	# Coerced rather than assumed: a transport hands us whatever JSON the client
	# sent, and a non-string name should be a "no such tool" answer, not a crash.
	my Str $name = (%params<name> // '').Str;
	unless %!tools{$name}:exists {
		return error-response($id, INVALID_PARAMS, "Unknown tool: '$name'");
	}

	return error-response(
		$id, INVALID_PARAMS, "Invalid arguments for tool '$name': expected an object",
	) if %params<arguments>.defined && %params<arguments> !~~ Associative;

	my %arguments = %params<arguments> // {};
	my $tool = %!tools{$name};

	try {
		my $result = $tool.call(%arguments);
		if $result ~~ Str {
			return success-response($id, tool-result($result));
		} elsif $result ~~ List {
			return success-response($id, tool-result-from-content($result));
		} elsif $result ~~ Hash {
			return success-response($id, $result);
		}
		return success-response($id, tool-result(~$result));
		CATCH {
			default {
				return success-response($id, tool-result(.message, :is-error));
			}
		}
	}
}

method !handle-resources-list($id, %params --> Hash) {
	success-response($id, {
		resources => %!resources.values.sort(*.uri).map(*.to-hash).list,
	});
}

method !handle-resources-read($id, %params --> Hash) {
	my Str $uri = (%params<uri> // '').Str;
	unless %!resources{$uri}:exists {
		# INVALID_PARAMS (-32602), not the legacy -32002: 2026-07-28 aligned
		# resource-not-found onto the standard JSON-RPC code, and the legacy era
		# accepts it too, so one code serves both.
		return error-response($id, INVALID_PARAMS, "Unknown resource: '$uri'");
	}

	try {
		my %result = %!resources{$uri}.read;
		return success-response($id, %result);
		CATCH {
			default {
				return error-response($id, INTERNAL_ERROR, .message);
			}
		}
	}
}

method !handle-prompts-list($id, %params --> Hash) {
	success-response($id, {
		prompts => %!prompts.values.sort(*.name).map(*.to-hash).list,
	});
}

method !handle-prompts-get($id, %params --> Hash) {
	my Str $name = (%params<name> // '').Str;
	unless %!prompts{$name}:exists {
		return error-response($id, INVALID_PARAMS, "Unknown prompt: '$name'");
	}

	return error-response(
		$id, INVALID_PARAMS, "Invalid arguments for prompt '$name': expected an object",
	) if %params<arguments>.defined && %params<arguments> !~~ Associative;

	my %arguments = %params<arguments> // {};

	try {
		my %result = %!prompts{$name}.get(%arguments);
		return success-response($id, %result);
		CATCH {
			default {
				return error-response($id, INTERNAL_ERROR, .message);
			}
		}
	}
}
}
