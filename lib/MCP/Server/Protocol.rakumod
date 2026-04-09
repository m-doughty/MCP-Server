use JSON::Fast;

unit module MCP::Server::Protocol;

# JSON-RPC 2.0 error codes
constant PARSE_ERROR      is export = -32700;
constant INVALID_REQUEST  is export = -32600;
constant METHOD_NOT_FOUND is export = -32601;
constant INVALID_PARAMS   is export = -32602;
constant INTERNAL_ERROR   is export = -32603;

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
