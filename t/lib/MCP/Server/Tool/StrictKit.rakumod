use MCP::Server::Toolkit;

# Test fixture: a toolkit with a required setting and a default prefix.
unit class MCP::Server::Tool::StrictKit does MCP::Server::Toolkit;

has Str $.token is required;
has Int $.limit = 10;

method default-prefix(--> Str) { 'strict' }

method register($registrar) {
	$registrar.tool: 'peek',
		description => 'Report the configured settings',
		handler => -> :%args { "token={$!token} limit={$!limit}" };
}
