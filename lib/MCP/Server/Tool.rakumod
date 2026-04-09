unit class MCP::Server::Tool;

has Str:D $.name is required;
has Str $.description;
has %.params;
has &.handler is required;

method input-schema(--> Hash) {
	my %properties;
	my @required;
	for %!params.kv -> $name, %spec {
		my %prop;
		%prop<type> = %spec<type> // 'string';
		%prop<description> = %spec<description> if %spec<description>.defined;
		%properties{$name} = %prop;
		@required.push($name) if %spec<required>;
	}
	my %schema = type => 'object', properties => %properties;
	%schema<required> = @required if @required.elems > 0;
	%schema;
}

method to-hash(--> Hash) {
	my %h = name => $!name, inputSchema => self.input-schema;
	%h<description> = $!description if $!description.defined;
	%h;
}

method call(%arguments --> Any) {
	&!handler(args => %arguments);
}
