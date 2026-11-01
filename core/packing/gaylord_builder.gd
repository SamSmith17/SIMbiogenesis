class_name GaylordBuilder
extends RefCounted
## A gaylord (bulk corrugated box): four walls as thick as their ply count,
## a bottom, an optional lid; the octagonal template draws eight walls.
## Length along Z, floor at y = 0. Gaylords ride on a pallet, which is a
## separate unit in the load (entry `needs_pallet`).

const BOARD := Color(0.70, 0.56, 0.38)
const LID := Color(0.62, 0.49, 0.32)


static func emit(mesh: ArrayMesh, entry: Dictionary) -> void:
	var ex: Dictionary = entry.get("exterior", {})
	var l := float(ex.get("l_m", 1.2))
	var w := float(ex.get("w_m", 1.0))
	var p: Dictionary = entry.get("params", {})
	var walls := int(entry.get("walls", 3))
	var lid := bool(p.get("lid", false))
	var h := float(p.get("ext_h_m", ex.get("h_m", 1.0)))
	var t := maxf(0.006, walls * IntermodalUnits.GAYLORD_WALL_MM * 0.001)
	var octo := str(entry.get("template", "")).contains("octo")
	var board := IntermodalMeshKit.new()
	var lid_k := IntermodalMeshKit.new()
	board.box(Vector3(0, t * 0.5, 0), Vector3(w, t, l))
	if octo:
		# Eight walls round an ellipse-ish octagon fitted to l x w.
		for i in 8:
			var a0 := TAU * (float(i) + 0.5) / 8.0
			var a1 := TAU * (float(i) + 1.5) / 8.0
			var p0 := Vector3(cos(a0) * w * 0.5 / cos(PI / 8.0), 0, sin(a0) * l * 0.5 / cos(PI / 8.0))
			var p1 := Vector3(cos(a1) * w * 0.5 / cos(PI / 8.0), 0, sin(a1) * l * 0.5 / cos(PI / 8.0))
			p0.x = clampf(p0.x, -w * 0.5, w * 0.5)
			p0.z = clampf(p0.z, -l * 0.5, l * 0.5)
			p1.x = clampf(p1.x, -w * 0.5, w * 0.5)
			p1.z = clampf(p1.z, -l * 0.5, l * 0.5)
			var mid := (p0 + p1) * 0.5
			var along := (p1 - p0) * 0.5
			var out := Vector3(mid.x, 0, mid.z).normalized() * t * 0.5
			board.obox(mid - out + Vector3(0, h * 0.5, 0), along,
				Vector3(0, h * 0.5, 0), out)
	else:
		for sx in [-1.0, 1.0]:
			board.box(Vector3(sx * (w - t) * 0.5, h * 0.5, 0), Vector3(t, h, l))
		for sz in [-1.0, 1.0]:
			board.box(Vector3(0, h * 0.5, sz * (l - t) * 0.5), Vector3(w - 2.0 * t, h, t))
	if lid:
		lid_k.box(Vector3(0, h + 0.015, 0), Vector3(w + 0.01, 0.03, l + 0.01))
	board.commit(mesh, BOARD, 0.0, 0.95)
	lid_k.commit(mesh, LID, 0.0, 0.95)
