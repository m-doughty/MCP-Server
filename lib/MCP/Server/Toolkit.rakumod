unit role MCP::Server::Toolkit;

# A toolkit is a self-contained bundle of tools / prompts / resources that can
# be plugged into any MCP::Server via $server.plug($kit).  Deliberately does NOT
# use MCP::Server: the dependency points the other way, so packs can be written
# against this role alone.

#| Register everything this toolkit provides on the supplied registrar.
#| The registrar quacks like MCP::Server — .tool, .prompt and .resource — but
#| applies the plug-time prefix to every name it is given.
method register($registrar) { ... }

#| Prefix applied when .plug is called without an explicit :prefix.
#| An undefined value means "no prefix by default".
method default-prefix(--> Str) { Str }

#| Build an instance from a plain (JSON-shaped) config hash, validating the
#| keys against the toolkit's public attributes so typos and missing required
#| settings fail loudly instead of silently doing nothing.
method from-config(::?CLASS:U: %config) {
	die "Config key 'prefix' is reserved; pass :prefix to .plug or put it beside the tool entry"
		if %config<prefix>:exists;

	my %valid = self.^attributes(:all).grep(*.has_accessor)
		.map({ .name.substr(2) => $_ });

	if %config.keys.grep({ %valid{$_}:!exists }).sort -> @unknown {
		die "Unknown config key(s) for {self.^name}: {@unknown.join(', ')}. "
		  ~ "Valid keys: {%valid.keys.sort.join(', ') || '(none)'}";
	}

	if %valid.pairs.grep({ .value.required && (%config{.key}:!exists) })».key.sort -> @missing {
		die "Missing required config key(s) for {self.^name}: {@missing.join(', ')}";
	}

	self.new(|%config.Map)
}
