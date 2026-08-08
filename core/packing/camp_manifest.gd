class_name CampManifest
extends RefCounted
## Camp packing manifest — PACKING_PLAN.md Phase 2. Sweeps everything
## physical the player has (graph components at any nesting depth + placed
## 3D props), resolves each through PackedSpec, and answers "will my camp
## fit that truck" via PackSolver.
##
## The collectors are PURE (arrays in, manifest lines out) so the whole
## sweep selftests offline; live callers pass `GraphNesting.walk_items(model,
## "root")` and `TerrainLoader.placed_prop_records()`.
##
## A manifest line: {label, spec (PackedSpec dict), qty}.

## Resource containers above this are site infrastructure (ponds, the ∞
## culvert outlet), not cargo — nobody U-Hauls a pond.
const MAX_PORTABLE_TANK_L := 20000.0

## Vehicles worth testing in the fleet report, smallest first.
const FLEET_IDS := ["cargo_van", "uhaul_10", "trailer_6x12", "uhaul_15",
	"uhaul_20", "uhaul_26", "container_20"]


## Graph items (already nesting-walked) → manifest lines. Skips virtual
## mirrors, compounds (their children are walked as items), abstract types,
## and non-portable tanks.
static func from_graph_items(items: Array) -> Array:
	var out: Array = []
	for item in items:
		if not (item is Dictionary):
			continue
		var d := item as Dictionary
		if bool(d.get("is_virtual", false)):
			continue
		var itype := str(d.get("type", ""))
		if itype == "compound":
			continue
		var specs: Dictionary = d.get("specs", {})
		if itype == "resource":
			var unit := str(specs.get("capacity_unit", "L")).to_lower()
			if unit == "l" and float(specs.get("capacity_qty", 0.0)) > MAX_PORTABLE_TANK_L:
				continue
		var spec := PackedSpec.for_preset_specs(itype, specs)
		if spec.is_empty():
			continue
		out.append({"label": str(specs.get("name", itype.capitalize())),
			"spec": spec, "qty": 1})
	return out


## Placed prop records → manifest lines. Linkage props compute their honest
## folded envelope from the live design; containers resolve their variant.
static func from_prop_records(props: Array) -> Array:
	var out: Array = []
	for rec in props:
		if not (rec is Dictionary):
			continue
		var d := rec as Dictionary
		var model_id := str(d.get("model_id", ""))
		var spec: Dictionary = {}
		if d.get("linkage_spec") is Dictionary:
			var p := LinkageParams.new()
			p.from_config(d.get("linkage_spec") as Dictionary)
			spec = LinkageStructureBuilder.packed_spec_for(p)
		elif d.get("container_spec") is Dictionary:
			spec = ContainerCatalog.packed_spec_for(
				str((d.get("container_spec") as Dictionary).get("container_id", "")))
		if spec.is_empty():
			spec = PackedSpec.for_model(model_id)
		if spec.is_empty():
			continue
		var entry := ModelCatalog.find(model_id)
		out.append({"label": str(entry.get("label", model_id)), "spec": spec,
			"qty": 1})
	return out


## Group identical lines (same label + packed dims) with a qty.
static func merge(lines: Array) -> Array:
	var by_key: Dictionary = {}
	var order: Array = []
	for line in lines:
		var d := line as Dictionary
		var s: Dictionary = d.get("spec", {})
		var key := "%s|%.3f|%.3f|%.3f" % [str(d.get("label", "")),
			float(s.get("w_m", 0.0)), float(s.get("d_m", 0.0)), float(s.get("h_m", 0.0))]
		if by_key.has(key):
			(by_key[key] as Dictionary)["qty"] = int((by_key[key] as Dictionary)["qty"]) \
				+ int(d.get("qty", 1))
		else:
			var copy := d.duplicate()
			copy["qty"] = int(d.get("qty", 1))
			by_key[key] = copy
			order.append(key)
	var out: Array = []
	for key in order:
		out.append(by_key[key])
	return out


## Flatten manifest lines into per-unit solver items (qty × spec.count).
static func expand_for_solver(manifest: Array) -> Array:
	var out: Array = []
	for line in manifest:
		var d := line as Dictionary
		var spec: Dictionary = d.get("spec", {})
		var units := int(d.get("qty", 1)) * maxi(int(spec.get("count", 1)), 1)
		for _i in units:
			var item := spec.duplicate()
			item["label"] = str(d.get("label", "?"))
			out.append(item)
	return out


static func total_volume_m3(manifest: Array) -> float:
	var v := 0.0
	for line in manifest:
		var d := line as Dictionary
		var spec: Dictionary = d.get("spec", {})
		v += PackedSpec.volume_m3(spec) * int(d.get("qty", 1)) \
			* maxi(int(spec.get("count", 1)), 1)
	return v


## Known mass total + how many lines carry no mass estimate.
static func total_mass_kg(manifest: Array) -> Dictionary:
	var m := 0.0
	var unknown := 0
	for line in manifest:
		var d := line as Dictionary
		var spec: Dictionary = d.get("spec", {})
		var units := int(d.get("qty", 1)) * maxi(int(spec.get("count", 1)), 1)
		if PackedSpec.has_mass(spec):
			m += float(spec.get("mass_kg", 0.0)) * units
		else:
			unknown += units
	return {"mass_kg": m, "unknown_count": unknown}


## Solve the manifest against the standard fleet, smallest first. Returns
## [{id, label, result}] — the first fitting entry is "the truck you need".
static func fleet_report(manifest: Array) -> Array:
	var units := expand_for_solver(manifest)
	var out: Array = []
	for cid in FLEET_IDS:
		var entry := ContainerCatalog.find(cid)
		if entry.is_empty():
			continue
		out.append({"id": cid, "label": str(entry.get("label", cid)),
			"result": PackSolver.solve(entry, units)})
	return out
