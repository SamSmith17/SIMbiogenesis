class_name GraphPortService
extends RefCounted

## Single place for dynamic port lists (hub angles, processor I/O, catchment).
## Canvas keeps static HANDLES tables; this resolves per-item overrides.


## Power is AC-only for now (inverter-supplied, SolarUI-gated). `thermal`/
## `mechanical` were dropped; `""`/none = passive (no power port). A processor
## that consumes/produces DC power instead uses a `dc_electricity`-kind
## input/output entry (see the pos/neg port split below), not this AC port.
static func processor_energy_port(specs: Dictionary) -> Dictionary:
	var src: String = str(specs.get("energy_source", "ac"))
	if src.is_empty() and float(specs.get("watts", 0.0)) > 0.0:
		src = "ac"
	if src == "ac":
		return {"id": "power_in", "polarity": "ac", "rx": 0.5, "ry": 0.0}
	return {}


## Dynamic port list from item specs. `static_handles` is the canvas HANDLES table.
static func resolved_handles(item: Dictionary, static_handles: Dictionary) -> Array:
	var custom: Array = item.get("handles", []) as Array
	if not custom.is_empty():
		if GraphHubPorts.is_hub_type(str(item.get("type", ""))):
			GraphHubPorts.migrate_handles_array(custom)
			# Older catchments may only have output — ensure input exists for PBI wiring.
			if str(item.get("type", "")) == "catchment":
				var specs_mig: Dictionary = item.get("specs", {}) as Dictionary
				var kind_mig := PbiBiomass.catchment_output_kind(specs_mig)
				GraphHubPorts.ensure_hub_handles(item, kind_mig)
				custom = item.get("handles", []) as Array
		return custom
	var itype: String = str(item.get("type", ""))
	var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
	if itype == "processor":
		ResourceKinds.new().migrate_processor_specs(specs)
		var handles: Array = []
		var energy_port := processor_energy_port(specs)
		var inputs: Array = specs.get("inputs", []) as Array
		var outputs: Array = specs.get("outputs", []) as Array
		
		if energy_port.is_empty() and inputs.is_empty() and outputs.is_empty():
			var fallback = static_handles.get("processor", []) as Array
			if fallback.is_empty():
				fallback = [
					{"id": "power_in", "polarity": "ac", "rx": 0.5, "ry": 0.0},
					{"id": "output", "polarity": "resource", "rx": 0.5, "ry": 1.0},
				]
			return fallback
			
		var top_count := inputs.size()
		if not energy_port.is_empty():
			top_count += 1
		
		var top_idx := 0
		if not energy_port.is_empty():
			energy_port["rx"] = float(top_idx + 1) / float(top_count + 1)
			energy_port["ry"] = 0.0
			handles.append(energy_port)
			top_idx += 1
			
		for i: int in inputs.size():
			var inp: Dictionary = inputs[i] as Dictionary
			var kind_i := str(inp.get("kind", ""))
			var rx: float = float(top_idx + 1) / float(top_count + 1)
			if kind_i == "dc_electricity":
				handles.append({
					"id": "res_in_%d_pos" % i,
					"polarity": "positive",
					"resource_kind": kind_i,
					"rx": rx - 0.035, "ry": 0.0,
				})
				handles.append({
					"id": "res_in_%d_neg" % i,
					"polarity": "negative",
					"resource_kind": kind_i,
					"rx": rx + 0.035, "ry": 0.0,
				})
			else:
				handles.append({
					"id": "res_in_%d" % i,
					"polarity": "resource",
					"resource_kind": kind_i,
					"rx": rx, "ry": 0.0,
				})
			top_idx += 1

		for i: int in outputs.size():
			var outp: Dictionary = outputs[i] as Dictionary
			var kind_o := str(outp.get("kind", ""))
			var n: int = maxi(outputs.size(), 1)
			var rx: float = float(i + 1) / float(n + 1)
			if kind_o == "dc_electricity":
				handles.append({
					"id": "res_out_%d_pos" % i,
					"polarity": "positive",
					"resource_kind": kind_o,
					"rx": rx - 0.035, "ry": 1.0,
				})
				handles.append({
					"id": "res_out_%d_neg" % i,
					"polarity": "negative",
					"resource_kind": kind_o,
					"rx": rx + 0.035, "ry": 1.0,
				})
			else:
				handles.append({
					"id": "res_out_%d" % i,
					"polarity": "resource",
					"resource_kind": kind_o,
					"rx": rx, "ry": 1.0,
				})

		return handles

	if itype == "resource":
		ResourceKinds.new().migrate_resource_specs(specs)
		var kind: String = str(specs.get("resource_kind", "water"))
		return GraphHubPorts.default_resource_handles(kind)
	if itype == "catchment":
		var out_kind := PbiBiomass.catchment_output_kind(specs)
		return GraphHubPorts.default_catchment_handles(out_kind)
	if itype == "pbi":
		var kind: String = str(specs.get("resource_kind", "water"))
		return GraphHubPorts.default_pbi_handles(kind)
	return static_handles.get(itype, []) as Array


static func format_soc_protection(specs: Dictionary) -> String:
	var shut := float(specs.get("soc_shutdown_pct", 10.0))
	var resume := float(specs.get("soc_resume_pct", 20.0))
	return "SOC protect: OFF <= %.0f%%, ON >= %.0f%%" % [shut, resume]


static func format_overload_protection(specs: Dictionary) -> String:
	var watts := float(specs.get("overload_watts", 3500.0))
	var delay_s := float(specs.get("overload_duration_s", 10.0))
	var lockout_s := float(specs.get("overload_lockout_s", 30.0))
	return "Overload: %.0fW for %.0fs => %.0fs lockout" % [watts, delay_s, lockout_s]
