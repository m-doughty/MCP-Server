use JSON::Fast;

unit module MCP::Server::Protocol;

# JSON-RPC 2.0 error codes
constant PARSE_ERROR      is export = -32700;
constant INVALID_REQUEST  is export = -32600;
constant METHOD_NOT_FOUND is export = -32601;
constant INVALID_PARAMS   is export = -32602;
constant INTERNAL_ERROR   is export = -32603;

# MCP protocol version registry (dual-era: 2025-11-25 "legacy" + 2026-07-28 "modern")
constant LEGACY-PROTOCOL-VERSION is export = '2025-11-25';
constant MODERN-PROTOCOL-VERSION is export = '2026-07-28';
constant MODERN-PROTOCOL-VERSIONS is export = (MODERN-PROTOCOL-VERSION,);
constant SUPPORTED-PROTOCOL-VERSIONS is export = (LEGACY-PROTOCOL-VERSION, MODERN-PROTOCOL-VERSION);

# MCP 2026-07-28 error codes
constant HEADER_MISMATCH                    is export = -32020;
constant MISSING_REQUIRED_CLIENT_CAPABILITY is export = -32021;
constant UNSUPPORTED_PROTOCOL_VERSION       is export = -32022;

# _meta keys defined by the 2026-07-28 protocol
constant META-PROTOCOL-VERSION    is export = 'io.modelcontextprotocol/protocolVersion';
constant META-CLIENT-CAPABILITIES is export = 'io.modelcontextprotocol/clientCapabilities';
constant META-CLIENT-INFO         is export = 'io.modelcontextprotocol/clientInfo';
constant META-SERVER-INFO         is export = 'io.modelcontextprotocol/serverInfo';
constant META-LOG-LEVEL           is export = 'io.modelcontextprotocol/logLevel';

# The one request _meta key with no reverse-DNS prefix on it: progressToken
# predates the 2026-07-28 namespacing and both eras spell it the same way
# (RequestMetaObject.progressToken in the 2026-07-28 schema, params._meta.
# progressToken since 2024-11-05).  Its value is opaque to us and may be a
# string or a number.
constant META-PROGRESS-TOKEN      is export = 'progressToken';

# RFC 5424 severity levels, least to most severe. Note: use Map.new rather than a
# Hash literal here -- a `constant %h = { ... }` only freezes the container, not the
# Hash object it points at, so the "constant" could still be mutated in place at
# runtime. Map is an immutable Associative, so it closes that hole outright.
constant %LOG-LEVELS is export = Map.new(
	'debug'     => 0,
	'info'      => 1,
	'notice'    => 2,
	'warning'   => 3,
	'error'     => 4,
	'critical'  => 5,
	'alert'     => 6,
	'emergency' => 7,
);

# Cache scope for modern-era list/read results.
subset CacheScope is export of Str where 'public' | 'private';

sub parse-message(Str:D $line --> Hash) is export {
	my %msg;
	try {
		%msg = from-json($line);
		CATCH {
			default {
				return error-response(Any, PARSE_ERROR, 'Parse error');
			}
		}
	}
	unless %msg<jsonrpc>:exists && %msg<jsonrpc> eq '2.0' {
		return error-response(%msg<id>, INVALID_REQUEST, 'Invalid Request: missing jsonrpc 2.0');
	}
	unless %msg<method>:exists {
		return error-response(%msg<id>, INVALID_REQUEST, 'Invalid Request: missing method');
	}
	%msg;
}

sub success-response($id, %result --> Hash) is export {
	{ jsonrpc => '2.0', id => $id, result => %result };
}

sub error-response($id, Int:D $code, Str:D $message, $data? --> Hash) is export {
	my %err = code => $code, message => $message;
	%err<data> = $data if $data.defined;
	{ jsonrpc => '2.0', id => $id, error => %err };
}

sub notification(Str:D $method, %params? --> Hash) is export {
	my %msg = jsonrpc => '2.0', method => $method;
	%msg<params> = %params if %params.defined && %params.elems > 0;
	%msg;
}

sub format-message(%msg --> Str:D) is export {
	to-json(%msg, :!pretty) ~ "\n";
}

sub tool-result(Str:D $text, Bool:D :$is-error = False --> Hash) is export {
	{
		content => [{ type => 'text', text => $text },],
		|($is-error ?? (isError => True) !! ()),
	};
}

sub tool-result-from-content(@content, Bool:D :$is-error = False --> Hash) is export {
	{
		content => @content,
		|($is-error ?? (isError => True) !! ()),
	};
}

sub request-meta(%msg --> Hash) is export {
	return {} unless %msg<params>:exists && %msg<params> ~~ Hash;
	my %params = %msg<params>;
	return {} unless %params<_meta>:exists && %params<_meta> ~~ Hash;
	%params<_meta>;
}

sub detect-era(%msg --> Str) is export {
	return 'legacy' if %msg<method>:exists && %msg<method> eq 'initialize';
	return 'modern' if %msg<method>:exists && %msg<method> eq 'server/discover';
	my %meta = request-meta(%msg);
	return 'modern' if %meta{META-PROTOCOL-VERSION}:exists;
	'legacy';
}

sub modern-envelope(%response, :%server-info! --> Hash) is export {
	return %response if %response<error>:exists;
	my %result = %response<result> // {};
	my %meta = %result<_meta> // {};
	%meta{META-SERVER-INFO} = %server-info;
	%result<_meta> = %meta;
	%result<resultType> = 'complete' unless %result<resultType>:exists;
	{ jsonrpc => %response<jsonrpc>, id => %response<id>, result => %result };
}

sub with-cacheability(%result, Int:D :$ttl-ms!, CacheScope:D :$cache-scope! --> Hash) is export {
	my %out = %result;
	%out<ttlMs> = $ttl-ms unless %out<ttlMs>:exists;
	%out<cacheScope> = $cache-scope unless %out<cacheScope>:exists;
	%out;
}

sub unsupported-protocol-version-error($id, :$requested!, :@supported! --> Hash) is export {
	error-response(
		$id,
		UNSUPPORTED_PROTOCOL_VERSION,
		'Unsupported protocol version',
		{ supported => @supported, requested => $requested },
	);
}

sub header-mismatch-error($id, :$header-version!, :$meta-version! --> Hash) is export {
	error-response(
		$id,
		HEADER_MISMATCH,
		'MCP-Protocol-Version header does not match request _meta',
		{ headerVersion => $header-version, metaVersion => $meta-version },
	);
}

sub log-level-at-least($level, $threshold --> Bool) is export {
	return False unless (%LOG-LEVELS{$level}:exists) && (%LOG-LEVELS{$threshold}:exists);
	%LOG-LEVELS{$level} >= %LOG-LEVELS{$threshold};
}
