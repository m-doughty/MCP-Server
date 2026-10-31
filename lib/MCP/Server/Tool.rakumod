unit class MCP::Server::Tool;

has Str:D $.name is required;
has Str $.description;
has %.params;
has &.handler is required;

#| The MCP C<Tool.annotations> object: the hints a pack author declares about
#| what calling this tool does — C<readOnlyHint>, C<idempotentHint>,
#| C<destructiveHint>, C<openWorldHint>, and a human-facing C<title>.  Empty
#| unless the registration set them, and absent from the wire when empty: an
#| annotations object saying nothing is noise in every catalog that carries it.
#|
#| They are B<hints>.  Nothing here enforces them; the server that publishes
#| them and the client that reads them both treat them as the pack author's
#| word about their own tool.  See MCP::Server's "Annotations" section for the
#| one decision the server itself makes on the strength of them (batching).
has %.annotations;

#| Publish parameter types, descriptions, defaults, item schemas, enums and bounds.
#| Required parameters appear in the schema's top-level C<required> array.
#|
#| C<type> defaults to C<string>; undefined descriptions are omitted.
#| C<default>, C<items>, C<enum>, C<minimum>, C<maximum>, C<minItems> and
#| C<maxItems> are copied when present, including zero bounds and empty enums.
#| Nested item schemas are unchanged. Other parameter-spec keys are ignored.
#| These declarations do not apply defaults or validate arguments.
method input-schema(--> Hash) {
	my %properties;
	my @required;
	for %!params.kv -> $name, %spec {
		my %prop;
		%prop<type> = %spec<type> // 'string';
		%prop<description> = %spec<description> if %spec<description>.defined;
		%prop<default> = %spec<default> if %spec<default>:exists;
		for <items enum minimum maximum minItems maxItems> -> $key {
			%prop{$key} = %spec{$key} if %spec{$key}:exists;
		}
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
	# Copied, not shared: a catalog hash is handed to transports, caches and
	# clients, and none of them should be able to reach back into the
	# registration through it.
	%h<annotations> = %!annotations.Hash if %!annotations.elems;
	%h;
}

method call(%arguments --> Any) {
	&!handler(args => %arguments);
}
