#!/usr/bin/env raku
use lib 'lib';
use MCP::Server;

my $server = MCP::Server.new(:name<echo-server>, :version<1.0>);

$server.tool: 'echo',
	description => 'Echo back the input message',
	params => { message => { type => 'string', description => 'Message to echo', required => True } },
	handler => -> :%args { %args<message> };

$server.tool: 'reverse',
	description => 'Reverse a string',
	params => { text => { type => 'string', description => 'Text to reverse', required => True } },
	handler => -> :%args { %args<text>.flip };

$server.run;
