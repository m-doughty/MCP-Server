#!/usr/bin/env raku
# Invoke with:
#   raku -I lib -I ../MCP-Server-Tool-FileSystem/lib -I ../MCP-Server-Tool-Shell/lib \
#     examples/toolkit-server.raku
use lib 'lib';
use MCP::Server;

my $server = MCP::Server.new(
	:name<toolkit-server>,
	:version<1.0>,
	:instructions('Combines installed tool packs with one inline tool'),
	:tools[
		FileSystem => { root => '.'.IO.absolute, prefix => 'fs' },
		Shell      => { allow => <git>, prefix => 'sh' },
	],
);

# Mixing plugged-in packs with a tool registered directly on the server.
$server.tool: 'ping',
	description => 'Health check',
	handler => -> :%args { 'pong' };

$server.run;
