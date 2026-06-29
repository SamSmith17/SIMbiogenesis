class_name GraphPortResolverV2
extends RefCounted

## Shared port and educational message helpers for GraphCanvasV2.


func format_soc_protection(specs: Dictionary) -> String:
	var shut := float(specs.get("soc_shutdown_pct", 10.0))
	var resume := float(specs.get("soc_resume_pct", 20.0))
	return "SOC protect: OFF <= %.0f%%, ON >= %.0f%%" % [shut, resume]


func format_overload_protection(specs: Dictionary) -> String:
	var watts := float(specs.get("overload_watts", 3500.0))
	var delay_s := float(specs.get("overload_duration_s", 10.0))
	var lockout_s := float(specs.get("overload_lockout_s", 30.0))
	return "Overload: %.0fW for %.0fs => %.0fs lockout" % [watts, delay_s, lockout_s]
