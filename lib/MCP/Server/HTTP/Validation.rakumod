use JSON::Fast;
use MIME::Base64;
use MCP::Server::Protocol;

unit module MCP::Server::HTTP::Validation;

# The `=?base64?...?=` sentinel used to smuggle non-header-safe values (non-ASCII,
# leading/trailing whitespace, embedded control characters) through HTTP headers.
# Markers are case-sensitive and lowercase-only -- `=?BASE64?...?=` is not a sentinel.
my regex sentinel { ^ '=?base64?' $<payload>=(.*) '?=' $ }

# Strict base64 alphabet check. MIME::Base64's decoder silently *skips* characters
# outside its lookup table instead of failing, so a well-formed-looking sentinel with
# a garbled payload would otherwise decode "successfully" into garbage. We validate
# the payload shape ourselves before ever handing it to the decoder.
my regex strict-base64 {
	^
	[<[A..Za..z0..9+/]> ** 4]*
	[
		<[A..Za..z0..9+/]> ** 2 '=='
		| <[A..Za..z0..9+/]> ** 3 '='
		| <[A..Za..z0..9+/]> ** 4
	]?
	$
}

#| Method => the params field that must match a `Mcp-Name` header for that method.
my constant %NAME-FIELD-FOR-METHOD = Map.new(
	'tools/call'     => 'name',
	'resources/read' => 'uri',
	'prompts/get'    => 'name',
);

#| True when $value is header-safe plain ASCII: visible ASCII (0x21-0x7E) plus space
#| and tab, with no leading or trailing whitespace.
sub header-safe(Str:D $value --> Bool:D) {
	return False if $value.chars > 0 && $value.substr(0, 1) eq (' ' | "\t");
	return False if $value.chars > 0 && $value.substr(*- 1) eq (' ' | "\t");
	for $value.ords -> $ord {
		return False unless (0x21 <= $ord <= 0x7E) || $ord == 0x20 || $ord == 0x09;
	}
	True;
}

sub encode-header-value(Str:D $value --> Str:D) is export {
	return $value if header-safe($value) && $value !~~ &sentinel;
	my $payload = MIME::Base64.encode-str($value, :oneline);
	"=?base64?{$payload}?=";
}

sub decode-header-value(Str:D $value --> Str) is export {
	my $match = $value ~~ &sentinel;
	return $value unless $match;

	my Str $payload = ~$match<payload>;
	return fail("Malformed base64 payload in header sentinel: {$value}")
		unless $payload ~~ &strict-base64;

	my $decoded = MIME::Base64.decode($payload).decode('utf-8');
	return $decoded;

	CATCH {
		default {
			return fail("Malformed UTF-8 inside header sentinel: {$value}");
		}
	}
}

#| $body-value's stringified form for comparison against a decoded header value.
#| Booleans compare as 'true'/'false'; other scalars compare on their .Str form (numeric
#| comparison for Numeric values happens separately in the caller, since string-form
#| numeric comparison would reject e.g. '42' vs 42.0).
sub scalar-matches(Str:D $decoded-header, $body-value --> Bool:D) {
	given $body-value {
		when Bool    { return $decoded-header eq ($body-value ?? 'true' !! 'false') }
		when Numeric {
			my $header-num = try $decoded-header.Numeric;
			return $header-num.defined && $header-num == $body-value;
		}
		default { return $decoded-header eq $body-value.Str }
	}
}

sub header-checks(%headers, %msg --> Any) is export {
	sub mismatch(Str:D $message --> Hash) {
		{ status => 400, code => HEADER_MISMATCH, message => $message };
	}

	my $method = %msg<method> // '';

	# 1. Mcp-Method must be present and match the body's method.
	return mismatch('Missing required Mcp-Method header')
		unless %headers<mcp-method>:exists;
	my $decoded-method = decode-header-value(%headers<mcp-method>);
	return mismatch("Malformed Mcp-Method header: {%headers<mcp-method>}")
		unless $decoded-method.defined;
	return mismatch('Mcp-Method header does not match request method')
		unless $decoded-method eq $method;

	# 2. MCP-Protocol-Version must be present and, when the body carries a _meta
	# protocol version, the two must match.  server/discover is exempt from
	# needing that _meta version at all: it is the mandatory bootstrap probe,
	# MCP::Server's core dispatch deliberately answers it without gating on a
	# version, and a client probing an unknown server cannot know what version
	# to claim in the body before it has heard back.  Every other method still
	# requires _meta's protocol version to be present and matching.
	return mismatch('Missing required MCP-Protocol-Version header')
		unless %headers<mcp-protocol-version>:exists;
	my %meta = request-meta(%msg);
	my $meta-version = %meta{META-PROTOCOL-VERSION};
	unless $meta-version.defined {
		return mismatch('MCP-Protocol-Version header does not match request _meta')
			unless $method eq 'server/discover';
	}
	return mismatch('MCP-Protocol-Version header does not match request _meta')
		if $meta-version.defined && %headers<mcp-protocol-version> ne $meta-version;

	# 3. Mcp-Name is required for tools/call, resources/read, and prompts/get; ignored
	# for every other method (even when present).
	if %NAME-FIELD-FOR-METHOD{$method}:exists {
		my $field = %NAME-FIELD-FOR-METHOD{$method};
		my %params = (%msg<params> // {}) ~~ Hash ?? %msg<params> !! {};
		my $expected = %params{$field};

		return mismatch("Missing required Mcp-Name header for method $method")
			unless %headers<mcp-name>:exists;
		my $decoded-name = decode-header-value(%headers<mcp-name>);
		return mismatch("Malformed Mcp-Name header: {%headers<mcp-name>}")
			unless $decoded-name.defined;
		return mismatch('Mcp-Name header does not match request params')
			unless $expected.defined && $decoded-name eq $expected;
	}

	# 4. Mcp-Param-* is validated (defense-in-depth) for tools/call only, and only for
	# headers whose suffix (case-insensitive) matches a scalar tools/call argument.
	if $method eq 'tools/call' {
		my %params = (%msg<params> // {}) ~~ Hash ?? %msg<params> !! {};
		my %arguments = (%params<arguments> // {}) ~~ Hash ?? %params<arguments> !! {};
		my %lc-arguments;
		for %arguments.kv -> $key, $value {
			%lc-arguments{$key.lc} = $value unless %lc-arguments{$key.lc}:exists;
		}

		for %headers.kv -> $header-name, $header-value {
			next unless $header-name.starts-with('mcp-param-');
			my $suffix = $header-name.substr('mcp-param-'.chars).lc;
			next unless %lc-arguments{$suffix}:exists;
			my $body-value = %lc-arguments{$suffix};
			next unless $body-value ~~ Str || $body-value ~~ Numeric || $body-value ~~ Bool;

			my $decoded-param = decode-header-value($header-value);
			return mismatch("Malformed Mcp-Param-{$suffix} header: {$header-value}")
				unless $decoded-param.defined;
			return mismatch("Mcp-Param-{$suffix} header does not match request arguments")
				unless scalar-matches($decoded-param, $body-value);
		}
	}

	# 5. Mcp-Session-Id / Last-Event-ID are stray Streamable-HTTP-session artifacts we
	# never emit -- ignored entirely.

	Nil;
}

sub origin-allowed(Str $origin, :@allowed, Bool:D :$allow-no-origin = True --> Bool:D) is export {
	return $allow-no-origin unless $origin.defined;
	return True if $origin ~~ / ^ 'http' 's'? '://' [ 'localhost' | '127.0.0.1' | '[::1]' ] [ ':' \d+ ]? $ /;

	for @allowed -> $entry {
		return True if $entry ~~ Regex ?? ($origin ~~ $entry) !! ($origin eq $entry);
	}
	False;
}

sub sse-event(%msg --> Str:D) is export {
	my $json = to-json(%msg, :!pretty);
	$json.split("\n").map({ "data: {$_}" }).join("\n") ~ "\n\n";
}

sub sse-comment(--> Str:D) is export {
	":\n\n";
}
