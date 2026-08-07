use JSON::Fast;
use MCP::Server;

unit module MCP::Server::CLI;

# Command-line front end for MCP::Server.  Arguments are parsed by hand rather
# than via `sub MAIN` so that parse-args stays a pure, testable function and so
# every diagnostic can be routed to $*ERR — stdout belongs to the MCP transport.

sub usage(--> Str:D) {
	q:to/END/;
	raku-mcp - run an MCP server assembled from toolkit packs.

	Usage:
	  raku-mcp --config=PATH
	  raku-mcp --tool=SPEC [--tool=SPEC ...] [--name=STR] [--version=STR] [--instructions=STR]
	  raku-mcp --tool=SPEC --http=PORT [--host=ADDR] [--http-path=PATH] [--allow-origin=ORIGIN ...]
	  raku-mcp --describe=SPEC
	  raku-mcp --help

	Options:
	  --config=PATH       JSON config file describing the server and its toolkits.
	  --tool=SPEC         Toolkit to load; repeatable.  SPEC is either a toolkit
	                      name or Name={"json":"config"}.  Bare names resolve
	                      under MCP::Server::Tool::, qualified names are used
	                      verbatim.  A "prefix" key in the config namespaces
	                      everything the toolkit registers.
	  --name=STR          Server name reported to clients (default: raku-mcp).
	  --version=STR       Server version reported to clients.
	  --instructions=STR  Server instructions reported to clients.
	  --http=PORT         Serve the Streamable HTTP transport on PORT instead of
	                      stdio.  HTTP is 2026-07-28 only; stdio serves both eras.
	  --host=ADDR         Address the HTTP transport binds (default: 127.0.0.1).
	  --http-path=PATH    Path the HTTP endpoint answers on (default: mcp).
	  --allow-origin=ORIGIN
	                      Extra browser Origin to accept; repeatable.  Loopback
	                      origins are always accepted.
	  --describe=SPEC     Print a toolkit's config schema (plus its tools, when
	                      SPEC carries inline config) and exit.
	  --help              Print this help and exit.

	--config and --tool are mutually exclusive, as is --describe with either.
	The HTTP options may also come from the config file's "http" section; a flag
	given on the command line wins over the file.
	END
}

#| Parse an argument list into an options hash.  Pure: never prints, never
#| exits.  Returns a hash whose <action> is one of serve/help/describe/error.
our sub parse-args(@args --> Hash) is export {
	my %opts =
		action          => 'serve',
		name            => 'raku-mcp',
		version         => Str,
		instructions    => Str,
		config          => Str,
		tools           => [],
		describe        => Str,
		describe-config => Any,
		http            => Int,
		host            => Str,
		http-path       => Str,
		allow-origins   => [],
		error           => Str;

	my Str $error;

	for @args -> $arg {
		last if $error.defined;

		if $arg eq '--help' | '-h' {
			%opts<action> = 'help';
			return %opts;
		}

		unless $arg ~~ /^ '--' $<flag> = (<-[=]>+) [ '=' $<value> = (.*) ]? $/ {
			$error = "Unrecognised argument '$arg'";
			next;
		}

		my Str $flag  = ~$<flag>;
		my Str $value = $<value>.defined ?? ~$<value> !! Str;

		unless $flag eq any(<config name version instructions tool describe
		                     http host http-path allow-origin>) {
			$error = "Unknown option '--$flag'";
			next;
		}

		unless $value.defined {
			$error = "Option '--$flag' requires a value (use --$flag=VALUE)";
			next;
		}

		if $flag eq 'config' | 'name' | 'version' | 'instructions' | 'host' | 'http-path' {
			if $value eq '' {
				$error = "Option '--$flag' requires a non-empty value";
				next;
			}
			%opts{$flag} = $value;
			next;
		}

		if $flag eq 'http' {
			unless $value ~~ /^ \d+ $/ && 1 <= $value.Int <= 65535 {
				$error = "Option '--http' requires a port from 1 to 65535, got '$value'";
				next;
			}
			%opts<http> = $value.Int;
			next;
		}

		if $flag eq 'allow-origin' {
			if $value eq '' {
				$error = "Option '--allow-origin' requires a non-empty value";
				next;
			}
			%opts<allow-origins>.push: $value;
			next;
		}

		# --tool / --describe: SPEC is Name or Name={json object}
		my ($spec-name, $json) = $value.split('=', 2);
		if !$spec-name.defined || $spec-name eq '' {
			$error = "Option '--$flag' requires a toolkit name";
			next;
		}

		my %cfg;
		if $json.defined {
			my $parsed = try from-json($json);
			if $! {
				$error = "Invalid JSON config for '--$flag={$spec-name}': {$!.message.lines.head}";
				next;
			}
			unless $parsed ~~ Associative {
				$error = "Config for '--$flag={$spec-name}' must be a JSON object";
				next;
			}
			%cfg = $parsed.Hash;
		}

		if $flag eq 'tool' {
			%opts<tools>.push: $spec-name => %cfg;
		} else {
			%opts<action>          = 'describe';
			%opts<describe>        = $spec-name;
			%opts<describe-config> = $json.defined ?? %cfg !! Any;
		}
	}

	if !$error.defined && %opts<config>.defined && %opts<tools>.elems > 0 {
		$error = '--config and --tool are mutually exclusive';
	}

	if !$error.defined && %opts<describe>.defined
	&& (%opts<config>.defined || %opts<tools>.elems > 0) {
		$error = '--describe cannot be combined with --config or --tool';
	}

	# The HTTP settings would otherwise be silently ignored.  They are allowed
	# alongside --config without --http, since the config file's "http" section
	# may be what turns the transport on.
	if !$error.defined && !%opts<http>.defined && !%opts<config>.defined {
		my @stray = <host http-path>.grep({ %opts{$_}.defined });
		@stray.push: 'allow-origin' if %opts<allow-origins>.elems > 0;
		if @stray.elems > 0 {
			my $flags = @stray.map({ '--' ~ $_ }).join(', ');
			$error = "$flags only configures the HTTP transport; pass --http=PORT too";
		}
	}

	if !$error.defined && %opts<action> eq 'serve'
	&& !%opts<config>.defined && %opts<tools>.elems == 0 {
		$error = 'Nothing to serve: pass --config=PATH or at least one --tool=SPEC';
	}

	if $error.defined {
		%opts<action> = 'error';
		%opts<error>  = $error;
	}

	%opts;
}

#| Entry point: returns the process exit code.
our sub run(@args --> Int) is export {
	my %opts = parse-args(@args);

	given %opts<action> {
		when 'help' {
			$*OUT.print(usage());
			$*OUT.flush;
			return 0;
		}
		when 'error' {
			note %opts<error>;
			note '';
			note usage().chomp;
			return 2;
		}
		when 'describe' {
			return describe(%opts);
		}
		default {
			return serve(%opts);
		}
	}
}

sub serve(%opts --> Int) {
	CATCH {
		default {
			note .message;
			return 2;
		}
	}

	my $server = do with %opts<config> {
		MCP::Server.from-config($_);
	} else {
		MCP::Server.new(
			name => %opts<name>,
			|(version      => %opts<version>      if %opts<version>.defined),
			|(instructions => %opts<instructions> if %opts<instructions>.defined),
			tools => %opts<tools>,
		);
	}

	# Command line beats config file; either can ask for HTTP, and neither asking
	# means stdio, which is still the default transport.
	my %http = $server.http-config;
	my $port = %opts<http> // %http<port>;
	if $port.defined || %http.elems > 0 {
		serve-http($server, $port // 8080, %opts, %http);
		return 0;
	}

	$server.run;
	0;
}

#| Merge command-line HTTP options with the config file's http section into the
#| constructor args MCP::Server::HTTP needs.  Command-line flags win over the
#| config file for scalar options; allowed origins accumulate from both.  Pure
#| and independently testable so config-driven allowedOrigins can be verified
#| without standing up a listener.
our sub merge-http-options(%opts, %http --> Hash) is export {
	# %http<allowedOrigins> comes back from a Hash lookup itemized, so a bare
	# `flat` treats it as a single element rather than descending into it;
	# .list decontainerizes it first.
	my @allowed-origins = flat((%http<allowedOrigins> // ()).list, %opts<allow-origins>.list);

	{
		host            => %opts<host>      // %http<host> // '127.0.0.1',
		path            => %opts<http-path> // %http<path> // 'mcp',
		allowed-origins => @allowed-origins,
	};
}

#| Start the Streamable HTTP transport.  MCP::Server::HTTP is required at this
#| point rather than used at the top of the file purely to keep stdio startup
#| out of Cro's load time — it is a hard dependency, not an optional feature.
sub serve-http($server, Int:D $port, %opts, %http) {
	my %http-args = merge-http-options(%opts, %http);

	# NB: require's return value MUST be bound (see MCP::Server::load-toolkit-class).
	my \http-class = (require ::('MCP::Server::HTTP'));
	my $http = http-class.new(
		:$server,
		:$port,
		host             => %http-args<host>,
		path             => %http-args<path>,
		# .list decontainerizes: a Hash element access itemizes even an Array
		# value, and the same nesting bug fixed in merge-http-options would
		# otherwise reappear one hop later, right here.
		allowed-origins  => %http-args<allowed-origins>.list,
	);
	$http.run;
}

sub describe(%opts --> Int) {
	CATCH {
		default {
			note .message;
			return 2;
		}
	}

	my $name = %opts<describe>;
	my \type = MCP::Server::load-toolkit-class($name);

	$*OUT.say("Toolkit: {type.^name}");
	$*OUT.say('');
	$*OUT.say('Config:');

	my @attrs = type.^attributes(:all).grep(*.has_accessor);
	if @attrs.elems > 0 {
		my $width = @attrs.map({ .name.chars - 2 }).max;
		for @attrs.sort({ .name }) -> $attr {
			$*OUT.say(
				'  ' ~ $attr.name.substr(2).fmt("%-{$width}s")
				~ '  ' ~ $attr.type.^name.fmt('%-16s')
				~ '  ' ~ ($attr.required ?? 'required' !! 'optional')
			);
		}
	} else {
		$*OUT.say('  (no configurable settings)');
	}

	with %opts<describe-config> {
		my %cfg    = .Hash;
		my $prefix = %cfg<prefix>:delete;
		my $kit    = type.^can('from-config')
			?? type.from-config(%cfg)
			!! type.new(|%cfg.Map);

		my $scratch = MCP::Server.new(:name<describe>);
		$scratch.plug($kit, |($prefix.defined ?? (:$prefix) !! ()));

		my %resp = $scratch.handle-request({
			jsonrpc => '2.0', id => 1, method => 'tools/list',
		});
		describe-listing('Tools', %resp<result><tools>, 'name');

		%resp = $scratch.handle-request({
			jsonrpc => '2.0', id => 2, method => 'prompts/list',
		});
		describe-listing('Prompts', %resp<result><prompts>, 'name');

		%resp = $scratch.handle-request({
			jsonrpc => '2.0', id => 3, method => 'resources/list',
		});
		describe-listing('Resources', %resp<result><resources>, 'uri');
	} else {
		$*OUT.say('');
		$*OUT.say('Pass inline config to list what this toolkit registers, e.g.');
		$*OUT.say("  --describe={$name}=\{\"key\":\"value\"\}");
	}

	$*OUT.flush;
	0;
}

sub describe-listing(Str:D $heading, @entries, Str:D $key) {
	return unless @entries.elems > 0;
	$*OUT.say('');
	$*OUT.say("$heading:");
	for @entries.sort({ .{$key} }) -> %entry {
		$*OUT.say(
			"  {%entry{$key}}"
			~ (%entry<description>.defined ?? " - {%entry<description>}" !! '')
		);
	}
}
