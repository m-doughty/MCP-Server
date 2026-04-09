#!/usr/bin/env raku
use lib 'lib';
use MCP::Server;

my $server = MCP::Server.new(
	:name<weather-server>,
	:version<1.0>,
	:instructions('Provides weather information via wttr.in'),
);

$server.tool: 'get_weather',
	description => 'Get current weather for a location',
	params => {
		location => { type => 'string', description => 'City name or location', required => True },
		format   => { type => 'string', description => 'Output format: full, oneline, or json (default: oneline)' },
	},
	handler => -> :%args {
		my $location = %args<location>;
		my $format = %args<format> // 'oneline';

		my $url = do given $format {
			when 'json'    { "https://wttr.in/{$location}?format=j1" }
			when 'full'    { "https://wttr.in/{$location}" }
			default        { "https://wttr.in/{$location}?format=3" }
		};

		my $proc = run 'curl', '-s', '--max-time', '5', $url, :out, :err;
		my $out = $proc.out.slurp(:close);
		my $err = $proc.err.slurp(:close);

		die "Failed to fetch weather: $err" if $proc.exitcode != 0;
		$out.trim;
	};

$server.tool: 'get_temperature',
	description => 'Get just the temperature for a location',
	params => {
		location => { type => 'string', description => 'City name or location', required => True },
	},
	handler => -> :%args {
		my $location = %args<location>;
		my $proc = run 'curl', '-s', '--max-time', '5',
			"https://wttr.in/{$location}?format=%t", :out, :err;
		my $out = $proc.out.slurp(:close);
		die "Failed to fetch temperature" if $proc.exitcode != 0;
		"Temperature in {$location}: {$out.trim}";
	};

$server.run;
