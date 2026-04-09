#!/usr/bin/env raku
use lib 'lib';
use MCP::Server;

# The tool that LLMs wish they had.

my $server = MCP::Server.new(
	:name<strawberry-server>,
	:version<1.0>,
	:instructions('Counts letters in words. Yes, really.'),
);

$server.tool: 'count_letter',
	description => 'Count occurrences of a letter in a word',
	params => {
		letter => { type => 'string', description => 'The letter to count', required => True },
		word   => { type => 'string', description => 'The word to search in', required => True },
	},
	handler => -> :%args {
		my $letter = %args<letter>.lc;
		my $word = %args<word>;
		my $count = $word.lc.comb.grep(* eq $letter).elems;
		"The letter '$letter' appears $count time{ $count == 1 ?? '' !! 's' } in '$word'.";
	};

$server.run;
