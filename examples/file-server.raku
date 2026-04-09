#!/usr/bin/env raku
use lib 'lib';
use MCP::Server;

my $server = MCP::Server.new(
	:name<file-server>,
	:version<1.0>,
	:instructions('Provides file system tools for reading and listing files'),
);

$server.tool-group: 'file', -> $g {
	$g.tool: 'read',
		description => 'Read the contents of a file',
		params => {
			path => { type => 'string', description => 'Absolute path to the file', required => True },
		},
		handler => -> :%args {
			my $path = %args<path>.IO;
			die "File not found: {%args<path>}" unless $path.e;
			die "Not a file: {%args<path>}" unless $path.f;
			$path.slurp;
		};

	$g.tool: 'list',
		description => 'List files and directories in a path',
		params => {
			path => { type => 'string', description => 'Absolute path to the directory', required => True },
		},
		handler => -> :%args {
			my $path = %args<path>.IO;
			die "Directory not found: {%args<path>}" unless $path.d;
			$path.dir.map(-> $entry {
				"{$entry.basename}{$entry.d ?? '/' !! ''}"
			}).sort.join("\n");
		};

	$g.tool: 'search',
		description => 'Search for files matching a pattern',
		params => {
			directory => { type => 'string', description => 'Directory to search in', required => True },
			pattern   => { type => 'string', description => 'Glob pattern (e.g. *.raku)', required => True },
		},
		handler => -> :%args {
			my $dir = %args<directory>.IO;
			die "Directory not found: {%args<directory>}" unless $dir.d;
			my $pattern = %args<pattern>;
			my @matches;
			for $dir.dir(:test(*.Str.contains($pattern.subst('*', '', :g)))) -> $f {
				@matches.push: $f.Str;
			}
			@matches.elems > 0 ?? @matches.join("\n") !! "No files matching '$pattern'";
		};
};

$server.run;
