unit class MCP::Server::Prompt;

has Str:D $.name is required;
has Str $.description;
has @.arguments;  # list of { name, description, required? }
has &.handler is required;

method to-hash(--> Hash) {
	my %h = name => $!name;
	%h<description> = $!description if $!description.defined;
	%h<arguments> = @!arguments if @!arguments.elems > 0;
	%h;
}

method get(%arguments --> Hash) {
	my $result = &!handler(args => %arguments);
	if $result ~~ Str {
		# Simple string → wrap as user message
		return {
			messages => [{
				role => 'user',
				content => { type => 'text', text => $result },
			},],
		};
	}
	# Assume result is already a proper messages structure
	$result;
}
