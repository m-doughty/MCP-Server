use MCP::Server::Protocol;

unit class MCP::Server::Resource;

has Str:D $.uri is required;
has Str:D $.name is required;
has Str $.description;
has Str $.mime-type;
has &.handler is required;

#| Cacheability of this resource's contents, reported on modern (2026-07-28)
#| resources/read results.  Undefined means "unknown", which the server reports
#| as uncacheable (ttlMs 0) and private — the safe reading for a handler whose
#| freshness only its author knows.
has Int $.ttl-ms;
has CacheScope $.cache-scope;

method to-hash(--> Hash) {
	my %h = uri => $!uri, name => $!name;
	%h<description> = $!description if $!description.defined;
	%h<mimeType> = $!mime-type if $!mime-type.defined;
	%h;
}

method read(--> Hash) {
	my $content = &!handler(args => { uri => $!uri });
	{
		contents => [{
			uri => $!uri,
			|($!mime-type.defined ?? (mimeType => $!mime-type) !! ()),
			text => ~$content,
		},],
	};
}
