my package EXPORTHOW {
	package DECLARE {
		use Metamodel::McpHOW;
		constant mcp = Metamodel::McpHOW;
	}
}

multi trait_mod:<is>(Attribute $attr, Str :$mcp-type!) is export {
	my role HasMCPType {
		has Str $.mcp-type is required;
	}
	$attr does HasMCPType($mcp-type)
}

# my role IsPrefixedBy {
# 	has Str $.mcp-prefixed-by is required;
# }
#
# multi trait_mod:<is>(Mu:U $mcp, Str :$prefixed-by!) is export {
# 	$mcp does IsPrefixedBy($prefixed-by)
# }
#
# multi trait_mod:<is>(Method $method, Str :$prefixed-by!) is export {
# 	$method does IsPrefixedBy($prefixed-by)
# }
