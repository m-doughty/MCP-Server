unit class MCP::Server::Resource;

has Str:D $.uri is required;
has Str:D $.name is required;
has Str $.description;
has Str $.mime-type;
has &.handler is required;

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
