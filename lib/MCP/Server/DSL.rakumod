my package EXPORTHOW {
	package DECLARE {
		use Metamodel::McpHOW;
		constant mcp = Metamodel::McpHOW;
	}
}

multi trait_mod:<is>(Parameter $attr, Str :$mcp-type!) is export {
	my role HasMCPType { has Str $.mcp-type is required }
	$attr does HasMCPType($mcp-type)
}
