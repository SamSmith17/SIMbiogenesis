class_name MimicWorldSource
extends RefCounted

## The Process lens's "As built" picture: the same things and lines as the
## schematic, drawn where they really are. Each machine stands at its 3D
## position seen in a true 30° isometric; each pipe or cable follows the
## corners of its run in the world (ConduitManager.run_corners), so bends,
## heights and lanes read as built. A line with no run in 3D is drawn as a
## dashed straight line between its two ends; a thing with no place in the
## world waits in a "Not placed" row under the picture.
##
## Pure static. It takes the schematic doc (MimicGraphSource.build) so every
## id, label, kind and state key is the same in both pictures.

## Picture units per metre.
const SCALE := 46.0
## The "Not placed" row: this far under the picture.
const LOOSE_DROP := 90.0
## Pipe widths in As built (thinner than the schematic's).
const PIPE_W_BUILT := 7.0
const WIRE_W_BUILT := 3.5


## A true isometric view of the site: x (east) and z (south) at 30° to the
## horizontal, y straight up. `origin` is the world point drawn at (0, 0).
class Iso:
	extends RefCounted
	const C30 := 0.8660254037844386
	const S30 := 0.5
	var origin := Vector3.ZERO
	var scale := MimicWorldSource.SCALE

	func to_2d(v: Vector3) -> Vector2:
		var p := v - origin
		return Vector2((p.x - p.z) * C30, (p.x + p.z) * S30 - p.y) * scale

	## The world point on the horizontal plane at height `y` drawn at `q`.
	func from_2d(q: Vector2, y: float) -> Vector3:
		var a := q / scale
		var yy := y - origin.y
		var s := (a.y + yy) / S30          # x + z
		var d := a.x / C30                 # x - z
		return origin + Vector3((s + d) * 0.5, yy, (s - d) * 0.5)

	## The world point at `q` on the vertical line through `at` (a height drag).
	func height_at(q: Vector2, at: Vector3) -> float:
		var base := to_2d(Vector3(at.x, origin.y, at.z))
		return origin.y + (base.y - q.y) / scale

	## How far back a point is, in picture units (the P&ID's convention:
	## bigger = further back, drawn first).
	func depth_of(v: Vector3) -> float:
		var p := v - origin
		return -(p.x + p.z) * scale


## The As built doc from the schematic one. `positions` = {item id: Vector3},
## `runs` = {connection id: PackedVector3Array of sharp corners}.
## `editable` = {connection id: true} for runs whose bends can be dragged
## (the solver's runs); null = every run.
static func build(schematic: Dictionary, positions: Dictionary, runs: Dictionary,
		editable: Variant = null) -> Dictionary:
	var iso := Iso.new()
	var pts3 := PackedVector3Array()
	for id: Variant in positions:
		pts3.append(positions[id] as Vector3)
	if not pts3.is_empty():
		var c := Vector3.ZERO
		for p: Vector3 in pts3:
			c += p
		iso.origin = c / float(pts3.size())
	var elements: Array = []
	var placed := {}
	var bottom := -INF
	for e0: Variant in schematic.get("elements", []):
		var e: Dictionary = (e0 as Dictionary).duplicate(true)
		var id := str(e["id"])
		if positions.has(id):
			var w := positions[id] as Vector3
			var s: Vector2 = e["size"]
			# The picture stands on its world point (its foot at the ground).
			var at := iso.to_2d(w)
			e["pos"] = at - Vector2(0.0, s.y * 0.5)
			e["depth"] = iso.depth_of(w)
			e["world"] = w
			placed[id] = true
			bottom = maxf(bottom, at.y)
		elements.append(e)
	# Instruments ride on what they read.
	for e: Dictionary in elements:
		if str(e["kind"]) == "instr" and placed.has(str(e.get("reads", ""))):
			var host: Dictionary = {}
			for h: Dictionary in elements:
				if str(h["id"]) == str(e["reads"]):
					host = h
					break
			if not host.is_empty():
				var hp: Vector2 = host["pos"]
				var hs: Vector2 = host["size"]
				e["pos"] = hp + Vector2(-hs.x * 0.5 + 22.0, -hs.y * 0.5 - 30.0)
				placed[str(e["id"])] = true
	# What has no place in the world: a row under the picture.
	if bottom == -INF:
		bottom = 0.0
	var lx := 0.0
	for e: Dictionary in elements:
		if placed.has(str(e["id"])) or str(e["kind"]) == "widget":
			continue
		var s2: Vector2 = e["size"]
		e["pos"] = Vector2(lx + s2.x * 0.5, bottom + LOOSE_DROP + s2.y * 0.5)
		e["loose"] = true
		e["unplaced"] = true
		lx += s2.x + 24.0
	# Lines: the run's own corners, else a dashed straight line.
	var pos_of := {}
	for e: Dictionary in elements:
		pos_of[str(e["id"])] = e["pos"]
	var pipes: Array = []
	for p0: Variant in schematic.get("pipes", []):
		var p: Dictionary = (p0 as Dictionary).duplicate(true)
		var pid := str(p["id"])
		var is_pipe := str(p.get("style", "pipes")) == "pipes"
		p["w"] = PIPE_W_BUILT if is_pipe else WIRE_W_BUILT
		if runs.has(pid) and (runs[pid] as PackedVector3Array).size() >= 2:
			var c3: PackedVector3Array = runs[pid]
			var pts := PackedVector2Array()
			for v: Vector3 in c3:
				pts.append(iso.to_2d(v))
			p["corners"] = pts
			p["pts"] = MimicLayout.round_corners(pts, 6.0)
			p["corner_r"] = 6.0
			p["world"] = c3
			if editable == null or (editable as Dictionary).has(pid):
				p["bends"] = _bend_points(pts)
			p["depth"] = iso.depth_of(c3[c3.size() / 2])
		else:
			var a: Variant = pos_of.get(str(p.get("from", "")))
			var b: Variant = pos_of.get(str(p.get("to", "")))
			if a == null or b == null:
				continue
			p["pts"] = PackedVector2Array([a as Vector2, b as Vector2])
			p["corners"] = p["pts"]
			p["dashed"] = true
			p["not_built"] = true
		pipes.append(p)
	# Far first, so nearer things stand in front.
	var by_depth := func(x: Dictionary, y: Dictionary) -> bool:
		return float(x.get("depth", 0.0)) > float(y.get("depth", 0.0))
	elements.sort_custom(by_depth)
	pipes.sort_custom(by_depth)
	var doc := {"pipes": pipes, "elements": elements, "layers": schematic.get("layers", 0),
		"built": true, "iso_origin": iso.origin, "iso_scale": iso.scale}
	doc["bounds"] = MimicLayout.bounds_of(doc)
	return doc


## The interior corners of a run's picture (what can be dragged): not the
## two ends at the ports, not the stub ends next to them.
static func _bend_points(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i: int in range(2, pts.size() - 2):
		out.append(pts[i])
	return out


## The Iso of a doc built here (to turn a dragged point back into the world).
static func iso_of(doc: Dictionary) -> Iso:
	var iso := Iso.new()
	iso.origin = doc.get("iso_origin", Vector3.ZERO)
	iso.scale = float(doc.get("iso_scale", SCALE))
	return iso
