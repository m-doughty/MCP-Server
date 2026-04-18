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
	Any         => "string",
	Str         => "string",
	Int         => "integer",
	Bool        => "boolean",
	Num         => "number",
	Rat         => "number",
	Positional  => "array",
	Associative => "object",
);

multi type-map(Parameter $_ where *.?mcp-type) {
	.mcp-type
}

multi type-map(Parameter $par) {
	CATCH {
		default {
			die "Type `{$par.type.^name}` for `{$par.gist}` can not be auto converted to json type. Please, use `is mcp-type` for that type."
		}
	}
	type-map $par.type
}

multi type-map(Mu $_ where { .HOW ~~ Metamodel::CoercionHOW }) {
	type-map .^constraint_type
}

multi type-map(Mu $_ where { %type-map{.^name}:!exists }) {
	die "Type {.^name} can not be auto converted to json type. Please, use `is mcp-type` for that type."
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

	my @tools = do for .^methods: :local -> &method {
		my $name  = &method.name;
		next if $name eq "POPULATE";
		my $description = &method.WHY;
		my %params     := Map.new: &method.signature.params.skip.map: {
			next if .name eq '%_';
			die "MCP::Server::DSL does not accept slurp parameters ({&method.name} -> {.gist})." if .slurpy;
			die "MCP::Server::DSL does not accept positional parameters ({&method.name} -> {.gist})." unless .named;
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
			:handler(-> :%args { $obj.&method(|%args) })
		}
	}

	&!build-server = -> $obj {
		my $server = MCP::Server.new: |%server-data;
		for @tools -> &tool { tool $server, :$obj }
		$server
	}
}
