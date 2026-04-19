#!/usr/bin/env raku
use lib 'lib';
use MCP::Server::DSL;

# The tool that LLMs wish they had.

#| Counts letters in words. Yes, really.
mcp StrawberryServer:ver<1.0> {

	#| Count occurrences of a letter in a word
	method count-letter(
		Str :$letter! is copy, #= The letter to count
		Str :$word!,           #= The word to search in
	) {
		$letter  .= lc;
		my $count = $word.lc.comb.grep(* eq $letter).elems;
		"The letter '$letter' appears $count time{ $count == 1 ?? '' !! 's' } in '$word'.";
	}
}

StrawberryServer.new.run;
