#!/usr/bin/env raku
use lib 'lib';
use MCP::Server::DSL;

mcp EchoServer:ver<1.0> {
	#| Echo back the input message
	method echo(
		Str :$message! #= Message to echo
	) {
		$message
	}

	#| Reverse a string
	method reverse(
		Str :$text! #= Text to reverse
	) {
		$text.flip
	}
}


EchoServer.new.run
