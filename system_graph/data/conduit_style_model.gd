class_name ConduitStyleModel
extends RefCounted

## What the conduit style window shows and writes, for one kind of run.
## Pure static: the window asks which rows apply, what sizes a kind comes in,
## and how to write a choice; it never decides that itself.
##
##  - Kind & size: catalog sizes only (ConduitSpecs). A real kind's thickness
##    is its size; a free thickness is only for drawn-only kinds (conceptual
##    flow lines, a player's own kind with no table).
##  - Route: runs the solver takes get its rows (router, bend radius, height,
##    along walls, 45° where the kind allows it); the rest keep the legacy
##    route mode / elbow rows.
##  - Writes go through `clean()`: only ConduitStylePresets.STYLE_KEYS, so a
##    key the window does not know is never written and pipe_sdr survives.

const ROW_KEYS := ["size", "conductors", "sdr", "thickness", "roughness", "glow",
	"route_mode", "fitting", "elbow", "slack", "solver", "allow_45"]


## Which rows the window shows for this kind (and whether the solver routes it).
static func rows(type_id: String, style: Dictionary, on_solver: bool) -> Dictionary:
	var conceptual := ConduitKinds.is_conceptual_type(type_id)
	var light := ConduitKinds.is_light_type(type_id)
	var kit := ConduitKinds.uses_pipe_kit(type_id)
	var sized := ConduitSpecs.has_sizes(type_id) or kit
	var meta := ConduitKinds.type_meta(type_id)
	var drape := meta.has("end_slack_m") or bool(meta.get("ground_drape", false))
	var rm := ConduitKinds.normalize_route_mode(str(style.get("route_mode", meta.get("route_mode", ""))))
	var out := {
		"size": sized,
		"conductors": type_id == "emt_conduit",
		"sdr": type_id == "poly_penstock",
		"thickness": not sized,
		"roughness": not (conceptual or light),
		"glow": conceptual or light,
		"route_mode": not on_solver,
		"fitting": not on_solver and not kit and (rm == "pipes" or ConduitKinds.is_pipes_type(type_id)),
		"elbow": not on_solver and not kit and (rm == "ortho" or rm == "pipes"),
		"slack": not on_solver and not kit and (drape or rm in ["catenary", "direct", ""]),
		"solver": on_solver,
		"allow_45": on_solver and ConduitSpecs.allowed_angles(type_id).has(45.0),
	}
	return out


## [[label, value], …] a kind comes in, and the style key the value goes to.
static func size_choices(type_id: String) -> Dictionary:
	var t := ConduitSpecs.table(type_id)
	var out: Array = []
	for r: Variant in t.get("rows", []) as Array:
		var rd: Dictionary = r
		out.append([str(rd["label"]), float(rd["value"])])
	var key := str(t.get("key", ""))
	if out.is_empty() and ConduitKinds.uses_pipe_kit(type_id):
		key = "pipe_size_in"
		for sz: Variant in ConduitKinds.pipe_kit_sizes_in(type_id):
			out.append([PipeKit.size_label(float(sz)), float(sz)])
	return {"key": key, "choices": out}


## The value the style currently selects (the row nearest its stored value).
static func size_value(type_id: String, style: Dictionary) -> float:
	var r := ConduitSpecs.row(type_id, style)
	if not r.is_empty():
		return float(r["value"])
	return ConduitKinds.pipe_size_in(type_id, style)


## The style with a size picked: the kind's key set, a free radius dropped
## (the size IS the thickness).
static func set_size(style: Dictionary, type_id: String, value: float) -> Dictionary:
	var out := style.duplicate(true)
	var key := str(size_choices(type_id).get("key", ""))
	if not key.is_empty():
		out[key] = value
	out.erase("radius_m")
	return out


## Conductors inside EMT: [[label, awg], …].
static func conductor_choices() -> Array:
	var out: Array = []
	for r: Variant in ConduitSpecs.conductor_rows():
		var rd: Dictionary = r
		out.append([str(rd["label"]), float(rd["value"])])
	return out


## Only the keys a style may carry; a real (sized) kind never keeps a free
## radius.
static func clean(style: Dictionary, type_id: String) -> Dictionary:
	var out := {}
	for k: String in ConduitStylePresets.STYLE_KEYS:
		if style.has(k) and style[k] != null:
			out[k] = style[k]
	if ConduitSpecs.has_sizes(type_id) or ConduitKinds.uses_pipe_kit(type_id):
		out.erase("radius_m")
	return out


## The bend radius in words: "120 mm · 6 × OD (PPI)".
static func bend_text(type_id: String, style: Dictionary) -> String:
	var r := ConduitSpecs.bend_radius_m(type_id, style)
	var src := ConduitSpecs.bend_source(type_id)
	var own := float(style.get("bend_radius_m", 0.0)) > 0.0
	return "%s%s" % [_mm(r), (" · " + src) if not src.is_empty() and not own else " · yours"]


## The run in numbers, for the window's strip: [[label, value], …].
static func spec_lines(conn: Dictionary, length_m: float = -1.0) -> Array:
	var sp := ConduitSpecs.for_run(conn, length_m)
	var out: Array = []
	var od := float(sp["od_m"])
	var idm := float(sp["id_m"])
	if od > 0.0:
		out.append(["Outside", _mm(od)])
	if idm > 0.0:
		out.append(["Bore", _mm(idm)])
	out.append(["Bends at", _mm(float(sp["bend_radius_m"]))])
	var psi := float(sp["pressure_psi"])
	if psi > 0.0:
		out.append(["Rated", "%d psi" % int(round(psi))])
	var amps := float(sp["ampacity_a"])
	if amps > 0.0:
		out.append(["Carries", "%s A" % UiText.num(amps, "", 3)])
	if sp.has("conductors"):
		out.append(["Wire", str(sp["conductors"])])
	var len_m := float(sp["length_m"])
	if len_m > 0.0:
		out.append(["Length", ConduitLength.format(len_m)])
		if float(sp["kg"]) > 0.0:
			out.append(["Weighs", UiText.num(float(sp["kg"]) * 1000.0, "g", 3)])
		if int(sp["supports"]) > 0:
			out.append(["Supports", UiText.count(int(sp["supports"]), "clip")])
		if float(sp["usd"]) > 0.0:
			out.append(["Costs", "$%s" % UiText.num(float(sp["usd"]), "", 3)])
	return out


## What is wrong with the run as built: [{level warn|error, text}].
## `info` = ConduitManager.run_info; `live` = {amps, flow_lpm, psi} if known.
static func warnings(conn: Dictionary, info: Dictionary, live: Dictionary = {}) -> Array:
	var out: Array = []
	var flags: Dictionary = info.get("flags", {}) as Dictionary
	if int(flags.get("tight", 0)) > 0:
		out.append({"level": "warn", "text": "%s tighter than this %s should bend" % [
			UiText.count(int(flags["tight"]), "bend"), "cable" if _is_cable(
				ConduitKinds.derive_type_for_connection(conn)) else "pipe"]})
	if bool(flags.get("stub_extended", false)):
		out.append({"level": "warn", "text": "A port faces into its machine: the run leaves further out"})
	if bool(flags.get("stub_blocked", false)) or bool(flags.get("end_jammed", false)):
		out.append({"level": "warn", "text": "An end is hard up against something: check the port"})
	if bool(flags.get("budget", false)):
		out.append({"level": "warn", "text": "No clear way found: drawn as a simple route (add a bend point)"})
	if bool(flags.get("unbundled", false)):
		out.append({"level": "warn", "text": "Kept out of its bundle: its lane would hit something"})
	var sp := ConduitSpecs.for_run(conn)
	var amps := float(live.get("amps", 0.0))
	if amps > 0.0 and float(sp["ampacity_a"]) > 0.0 and amps > float(sp["ampacity_a"]):
		out.append({"level": "error", "text": "Carrying %s A on wire rated %s A" % [
			UiText.num(amps, "", 3), UiText.num(float(sp["ampacity_a"]), "", 3)]})
	var psi := float(live.get("psi", 0.0))
	if psi > 0.0 and float(sp["pressure_psi"]) > 0.0 and psi > float(sp["pressure_psi"]):
		out.append({"level": "error", "text": "%d psi in pipe rated %d psi" % [int(psi), int(sp["pressure_psi"])]})
	return out


static func _is_cable(type_id: String) -> bool:
	return float(ConduitKinds.type_meta(type_id).get("resistance_ohm_per_m", 0.0)) > 0.0 \
		or type_id == "ethernet"


static func _mm(m: float) -> String:
	if m >= 0.1:
		return "%d mm" % int(round(m * 1000.0))
	return "%.1f mm" % (m * 1000.0)
