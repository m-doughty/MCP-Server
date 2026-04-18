#!/usr/bin/env raku
use lib 'lib';
use MCP::Server::DSL;

#| Provides weather information via wttr.in
mcp WheatherServer:ver<1.0> {

	#| Get current weather for a location
	method get-weather(
		Str :$location!,          #= City name or location
		Str :$format = 'oneline', #= Output format: full, oneline, or json (default: oneline)
	) {
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
	}

	#| Get just the temperature for a location
	method get-temperature(
		Str :$location! #= City name or location
	) {
		my $proc = run 'curl', '-s', '--max-time', '5',
			"https://wttr.in/{$location}?format=%t", :out, :err;
		my $out = $proc.out.slurp(:close);
		die "Failed to fetch temperature" if $proc.exitcode != 0;
		"Temperature in {$location}: {$out.trim}";
	}
}

WheatherServer.new.run;
