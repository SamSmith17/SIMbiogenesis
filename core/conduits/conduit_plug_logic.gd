class_name ConduitPlugLogic
extends RefCounted

## Pure logic for the in-world "grab a plug and connect it" interaction: pick the
## port under the crosshair, decide whether two ports may join, and build the graph
## connection spec. No scene/physics deps → fully headless-testable. The controller
## (conduit_route_controller) supplies world positions and commits the spec via
## GraphModel.add_connection.
##
## Port dict shape = ConnectionPortDefs.make_port():
##   {id, label, handle_id, polarity, resource_kind, node_path, x,y,z, nx,ny,nz}
## A "port hit" wraps a port with its live world position + owning graph item:
##   {port: Dictionary, world_pos: Vector3, item_id: String}

## polarity / handle tokens that read as an output (source) vs input (sink).
const OUTPUT_TOKENS: Array = ["output", "out", "source", "positive", "pos",
	"pvpositive", "batterypositive", "hot", "supply", "male"]
const INPUT_TOKENS: Array = ["input", "in", "sink", "negative", "neg",
	"pvnegative", "batterynegative", "load", "return", "female", "inlet"]


static func port_is_output(port: Dictionary) -> bool:
	return _matches_tokens(port, OUTPUT_TOKENS)


static func port_is_input(port: Dictionary) -> bool:
	return _matches_tokens(port, INPUT_TOKENS)


static func _matches_tokens(port: Dictionary, tokens: Array) -> bool:
	var hay := (str(port.get("polarity", "")) + "|" + str(port.get("handle_id", ""))
		+ "|" + str(port.get("id", ""))).to_lower()
	for t: String in tokens:
		if hay.contains(t):
			return true
	return false


## Two ports may be plugged together when: different owning items, and (when both
## declare a resource_kind) those kinds are compatible, and they aren't both the
## same polarity (two outputs / two inputs). Empty fields stay permissive so the
## many ports that don't declare polarity/kind still connect (practice sandbox).
static func ports_compatible(a_hit: Dictionary, b_hit: Dictionary) -> bool:
	var a: Dictionary = a_hit.get("port", {})
	var b: Dictionary = b_hit.get("port", {})
	if a.is_empty() or b.is_empty():
		return false
	var a_item := str(a_hit.get("item_id", ""))
	var b_item := str(b_hit.get("item_id", ""))
	# Same port on the same item is never a valid plug (self-loop).
	if a_item == b_item and str(a.get("id", "")) == str(b.get("id", "")):
		return false
	# Resource-kind gate (only when BOTH declare one).
	var ka := str(a.get("resource_kind", ""))
	var kb := str(b.get("resource_kind", ""))
	if not ka.is_empty() and not kb.is_empty() and not _kinds_compatible(ka, kb):
		return false
	# Polarity gate (only when BOTH resolve to a direction).
	var a_out := port_is_output(a)
	var a_in := port_is_input(a)
	var b_out := port_is_output(b)
	var b_in := port_is_input(b)
	if (a_out and b_out and not a_in and not b_in) \
			or (a_in and b_in and not a_out and not b_out):
		return false
	return true


static func _kinds_compatible(ka: String, kb: String) -> bool:
	if ka == kb:
		return true
	# Group loosely by domain so e.g. water/greywater or electric/dc still join.
	return _kind_domain(ka) == _kind_domain(kb)


static func _kind_domain(kind: String) -> String:
	var k := kind.to_lower()
	if k.contains("electric") or k in ["dc", "ac", "power", "dc_electricity"]:
		return "electric"
	if k.contains("water") or k in ["hot_water", "greywater", "blackwater", "potable"]:
		return "fluid"
	return k


## Orient a compatible pair so the OUTPUT side is the connection source, and build
## a GraphModel.add_connection() spec with a locked 3D route. `route_3d` is the
## committed world polyline (Array of Vector3 or waypoint dicts).
static func build_connection_spec(a_hit: Dictionary, b_hit: Dictionary,
		type_id: String, route_3d: Array = []) -> Dictionary:
	var src := a_hit
	var tgt := b_hit
	# If A is clearly an input and B an output, swap so source = output.
	if port_is_input(a_hit.get("port", {})) and port_is_output(b_hit.get("port", {})):
		src = b_hit
		tgt = a_hit
	var src_port: Dictionary = src.get("port", {})
	var tgt_port: Dictionary = tgt.get("port", {})
	var kind := str(src_port.get("resource_kind", tgt_port.get("resource_kind", "")))
	var route_wp: Array = []
	for p: Variant in route_3d:
		if p is Vector3:
			route_wp.append({"x": p.x, "y": p.y, "z": p.z})
		elif p is Dictionary:
			route_wp.append(p)
	var style: Dictionary = {}
	# Prefer the output port's saved style, then the input's, so port-modal
	# "preferred conduit" survives grab-and-plug into the connection.
	if src_port.get("preferred_conduit_style", null) is Dictionary:
		style = (src_port.get("preferred_conduit_style", {}) as Dictionary).duplicate(true)
	elif tgt_port.get("preferred_conduit_style", null) is Dictionary:
		style = (tgt_port.get("preferred_conduit_style", {}) as Dictionary).duplicate(true)
	var out := {
		"source_item_id": str(src.get("item_id", "")),
		"source_handle_id": _handle_of(src_port),
		"target_item_id": str(tgt.get("item_id", "")),
		"target_handle_id": _handle_of(tgt_port),
		"polarity": "resource" if not kind.is_empty() else "positive",
		"resource_type": kind,
		"conduit_type": type_id,
		"route_3d": route_wp,
		# Lock only when explicit mid-waypoints were supplied; otherwise let the
		# manager auto-route A→B (avoids persisting a dense sampled polyline).
		"route_locked": not route_wp.is_empty(),
		"line_style": "bezier",
	}
	if not style.is_empty():
		out["conduit_style"] = style
	return out


static func _handle_of(port: Dictionary) -> String:
	var h := str(port.get("handle_id", ""))
	return h if not h.is_empty() else str(port.get("id", ""))


## Nearest port to a crosshair ray. `hits` = Array of port-hit dicts (must carry
## world_pos). Returns the closest hit whose perpendicular distance to the ray is
## within `max_perp_m` and which sits in front of the camera, else {}.
static func nearest_port_along_ray(origin: Vector3, direction: Vector3,
		hits: Array, max_perp_m: float = 0.6) -> Dictionary:
	var dir := direction
	if dir.length_squared() < 1e-9:
		return {}
	dir = dir.normalized()
	var best: Dictionary = {}
	var best_score := INF
	for h: Variant in hits:
		if not (h is Dictionary):
			continue
		var hd: Dictionary = h
		var wp: Vector3 = hd.get("world_pos", Vector3.INF)
		if not is_finite(wp.x):
			continue
		var to := wp - origin
		var along := to.dot(dir)
		if along <= 0.05:
			continue  # behind the camera / at the eye
		var perp := (to - dir * along).length()
		if perp > max_perp_m:
			continue
		# Prefer small perpendicular offset, tie-break by nearer along-ray.
		var score := perp + along * 0.01
		if score < best_score:
			best_score = score
			best = hd
	return best
