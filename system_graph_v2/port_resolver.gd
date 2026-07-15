class_name GraphPortResolverV2
extends RefCounted

## Thin compatibility shim — port/education helpers live on GraphPortService.


func format_soc_protection(specs: Dictionary) -> String:
	return GraphPortService.format_soc_protection(specs)


func format_overload_protection(specs: Dictionary) -> String:
	return GraphPortService.format_overload_protection(specs)
