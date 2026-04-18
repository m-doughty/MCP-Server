use MCP::Server;

unit class Metamodel::McpHOW is Metamodel::ClassHOW;

has &.build-server;

class MCP::Base {
	has MCP::Server $.server handles <run tools-for-llm execute-tool-calls handle-request>;
	submethod TWEAK(|) {
		$!server = self.HOW.build-server.(self);
	}
}

my %type-map = %(
	Any  => "string",
	Str  => "string",
	Int  => "integer",
	Bool => "boolean",
);

multi type-map(Parameter $_ where *.?mcp-type) {
	.mcp-type
}

multi type-map(Parameter $_) {
	type-map .type
}

multi type-map(Mu $_ where *.HOW ~~ Metamodel::CoercionHOW) {
	nextwith .^constraint_type
}

multi type-map(Mu $_) {
	%type-map{.^name}
}

method compose(Mu $_) {
	.^add_parent: MCP::Base;

	callsame;

	my %server-data = (
		name           => .^name,
		|(version      => ~.^ver if .^ver),
		|(instructions => ~.WHY  if .WHY ),
	);

	my @tools = do for .^methods -> &method {
		my $name  = &method.name;
		next if $name eq (
			| "POPULATE"
			| "TWEAK"
			| "server"
			| "run"
			| "tools-for-llm"
			| "execute-tool-calls"
			| "handle-request"
		);
		my $description = &method.WHY;
		my %params     := Map.new: &method.signature.params.skip.grep(*.named).map: {
			last if .slurpy;
			my $name = .named_names.head;

			$name => %(
				type          => type-map($_),
				required      => !.optional,
				|(description => ~.WHY if .WHY),
			),
		}

		-> $_, :$obj! {
			.tool: $name,
			|(:description(.Str) with $description),
			:%params,
			:handler(-> :%args { $obj."$name"(|%args) })
		}
	}

	&!build-server = -> $obj {
		my $server = MCP::Server.new: |%server-data;
		for @tools -> &tool { tool $server, :$obj }
		$server
	}
}
