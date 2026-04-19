#!/usr/bin/env raku
use lib 'lib';
use MCP::Server::DSL;

#| Provides file system tools for reading and listing files
unit mcp FileServer:ver<1.0>;

#| Read the contents of a file
method read(
	IO(Str) :$path! #= Absolute path to the file
) {
	die "File not found: {$path}" unless $path.e;
	die "Not a file: {$path}" unless $path.f;
	$path.slurp;
}

#| List files and directories in a path
method list(
	IO(Str) :$path! #= Absolute path to the directory
) {
	die "Directory not found: {$path}" unless $path.d;
	$path.dir.map(-> $entry {
		"{$entry.basename}{$entry.d ?? '/' !! ''}"
	}).sort.join("\n");
}

#| Search for files matching a pattern
method search(
	IO(Str) :$directory, #= Directory to search in
	Str     :$pattern,   #= Glob pattern (e.g. *.raku)
) {
	die "Directory not found: {$directory}" unless $directory.d;
	my @matches;
	for $directory.dir(:test(*.Str.contains($pattern.subst('*', '', :g)))) -> $f {
		@matches.push: $f.Str;
	}
	@matches.elems > 0 ?? @matches.join("\n") !! "No files matching '$pattern'";
}

FileServer.new.run;
