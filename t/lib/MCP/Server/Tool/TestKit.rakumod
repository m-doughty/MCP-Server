use MCP::Server::Toolkit;

# Test fixture: a toolkit with only optional settings that registers one of
# everything (tool, prompt, resource) so prefixing can be checked end to end.
unit class MCP::Server::Tool::TestKit does MCP::Server::Toolkit;

has Str $.greeting = 'Hello';
has IO::Path() $.root = '.'.IO;

method register($registrar) {
	$registrar.tool: 'greet',
		description => 'Greet somebody by name',
		params => {
			name => { type => 'string', description => 'Who to greet', required => True },
		},
		handler => -> :%args { "{$!greeting}, {%args<name>}" };

	$registrar.prompt: 'greeting',
		description => 'A greeting prompt',
		arguments => [
			{ name => 'name', description => 'Who to greet', required => True },
		],
		handler => -> :%args { "{$!greeting}, {%args<name> // 'world'}!" };

	$registrar.resource: 'test://info',
		name => 'TestKit info',
		description => 'Information about this kit',
		mime-type => 'text/plain',
		handler => -> :%args { "greeting={$!greeting} root={$!root}" };
}
