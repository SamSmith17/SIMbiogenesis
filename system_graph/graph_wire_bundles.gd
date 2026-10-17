class_name GraphWireBundles
extends RefCounted

## Parallel-wire bundling for the freeform canvas. When several wires share
## ONE port (the six 3S2P string leads into a controller's PV +, a bank's
## parallel jumpers on one terminal), each used to leave the port on its own
## bezier from the same pixel, and they read as a knot. Here they leave as a
## short shared TRUNK straight out of the port, then fan into evenly spaced
## lanes (a comb) before each one curves away to its far end — the bus a real
## installer would land on a busbar.
##
## Lanes are ORDERED by where each wire's far end sits across the port's edge,
## so neighbouring lanes never cross each other in the fan. Pure: positions in,
## geometry out, deterministic (ties break on the connection id).
##
## Input `wires`: Array of {
##   id: String, src_key: String, tgt_key: String ("<item>|<handle>"),
##   src_pos, tgt_pos: Vector2, src_tan, tgt_tan: Vector2 (OUTWARD unit normals),
##   src_skip, tgt_skip: bool (hub ports, physical views: no comb),
## }
## Output: {conn_id: {"src": {trunk, tooth, index, count}, "tgt": {...}}}, a side
## present only when that end is bundled (its port carries ≥ 2 wires).

## Graph-space design sizes (× zoom on screen).
const TRUNK_PX := 9.0
const FAN_PX := 18.0
const LANE_PX := 9.0
const LANE_MIN_PX := 4.5
const LANE_MAX_PX := 12.0
## The whole comb never gets wider than this (graph px) however many wires.
const MAX_SPREAD_PX := 64.0


static func endpoint_key(item_id: String, handle_id: String) -> String:
	return "%s|%s" % [item_id, handle_id]


## Lane spacing on screen for a comb of `count` wires at zoom `z`.
static func lane_px(count: int, z: float) -> float:
	var lane := clampf(LANE_PX * z, LANE_MIN_PX, LANE_MAX_PX)
	if count > 1:
		lane = minf(lane, MAX_SPREAD_PX * z / float(count - 1))
	return maxf(lane, 1.0)


static func plan(wires: Array, z: float) -> Dictionary:
	# Group the ends by port.
	var groups := {}
	for w: Dictionary in wires:
		for side: String in ["src", "tgt"]:
			if bool(w.get(side + "_skip", false)):
				continue
			var key := str(w.get(side + "_key", ""))
			if key.is_empty():
				continue
			if not groups.has(key):
				groups[key] = []
			(groups[key] as Array).append({"w": w, "side": side})
	var out := {}
	var keys := groups.keys()
	keys.sort()
	for key: Variant in keys:
		var ends: Array = groups[key]
		if ends.size() < 2:
			continue
		var first: Dictionary = ends[0]
		var fside: String = first["side"]
		var port: Vector2 = (first["w"] as Dictionary).get(fside + "_pos", Vector2.ZERO)
		var tan: Vector2 = ((first["w"] as Dictionary).get(fside + "_tan", Vector2.DOWN) as Vector2)
		if tan.length_squared() < 1e-6:
			continue
		tan = tan.normalized()
		var perp := Vector2(-tan.y, tan.x)
		# Order by the far end's position across the edge.
		var rows: Array = []
		for e: Dictionary in ends:
			var w: Dictionary = e["w"]
			var far_side := "tgt" if str(e["side"]) == "src" else "src"
			var far: Vector2 = w.get(far_side + "_pos", port)
			rows.append({"id": str(w.get("id", "")), "side": str(e["side"]),
				"k": (far - port).dot(perp)})
		rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			if not is_equal_approx(float(a["k"]), float(b["k"])):
				return float(a["k"]) < float(b["k"])
			if str(a["id"]) != str(b["id"]):
				return str(a["id"]) < str(b["id"])
			return str(a["side"]) < str(b["side"]))
		var n := rows.size()
		var lane := lane_px(n, z)
		var trunk := port + tan * TRUNK_PX * z
		var reach := (TRUNK_PX + FAN_PX) * z
		for i: int in n:
			var r: Dictionary = rows[i]
			var off := (float(i) - float(n - 1) * 0.5) * lane
			var tooth := port + tan * reach + perp * off
			var cid := str(r["id"])
			if not out.has(cid):
				out[cid] = {}
			(out[cid] as Dictionary)[str(r["side"])] = {
				"port": port, "trunk": trunk, "tooth": tooth,
				"tangent": tan, "index": i, "count": n,
			}
	return out


## The stub a bundled end draws: port → trunk → tooth (the fan leg). The wire's
## curve then starts at the tooth with the port's own outward tangent.
static func stub_points(end: Dictionary) -> PackedVector2Array:
	return PackedVector2Array([end["port"], end["trunk"], end["tooth"]])
