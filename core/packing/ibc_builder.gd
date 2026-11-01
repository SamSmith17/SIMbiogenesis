class_name IbcBuilder
extends RefCounted
## An IBC tote: a steel pallet base, a translucent white HDPE bottle and the
## galvanised cage round it (vertical and horizontal tubes), a fill cap on
## top and a valve at the front (+Z). Length along Z, floor at y = 0.

const BOTTLE := Color(0.92, 0.93, 0.90)
const CAGE := Color(0.70, 0.72, 0.74)
const BASE := Color(0.28, 0.30, 0.32)
const VALVE := Color(0.15, 0.15, 0.16)


static func emit(mesh: ArrayMesh, entry: Dictionary) -> void:
	var ex: Dictionary = entry.get("exterior", {})
	var l := float(ex.get("l_m", 1.2))
	var w := float(ex.get("w_m", 1.0))
	var h := float(ex.get("h_m", 1.16))
	var p: Dictionary = entry.get("params", {})
	var deck := float(p.get("deck_h_m", 0.15))
	var base := IntermodalMeshKit.new()
	var bottle := IntermodalMeshKit.new()
	var cage := IntermodalMeshKit.new()
	var valve := IntermodalMeshKit.new()
	# Base: a deck plate on four corner feet and a centre runner.
	base.box(Vector3(0, deck - 0.02, 0), Vector3(w, 0.04, l))
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			base.box(Vector3(sx * (w * 0.5 - 0.06), (deck - 0.04) * 0.5,
				sz * (l * 0.5 - 0.06)), Vector3(0.12, deck - 0.04, 0.12))
	base.box(Vector3(0, (deck - 0.04) * 0.5, 0), Vector3(0.12, deck - 0.04, l * 0.6))
	# Bottle, inset a little inside the cage.
	var bh := h - deck - 0.04
	bottle.box(Vector3(0, deck + bh * 0.5, 0), Vector3(w - 0.06, bh, l - 0.06))
	bottle.cylinder(Vector3(0, h - 0.01, 0), 0.075, 0.04)
	# Cage: tubes on all four sides.
	var tube := 0.022
	var ct := h - deck
	for sx in [-1.0, 1.0]:
		var n_v := maxi(3, int(round(l / 0.2)))
		for i in n_v + 1:
			var z := -l * 0.5 + l * float(i) / float(n_v)
			cage.box(Vector3(sx * w * 0.5, deck + ct * 0.5, z), Vector3(tube, ct, tube))
	for sz in [-1.0, 1.0]:
		var n_v2 := maxi(3, int(round(w / 0.2)))
		for i in n_v2 + 1:
			var x := -w * 0.5 + w * float(i) / float(n_v2)
			cage.box(Vector3(x, deck + ct * 0.5, sz * l * 0.5), Vector3(tube, ct, tube))
	var rings := maxi(3, int(round(ct / 0.2)))
	for i in rings + 1:
		var y := deck + ct * float(i) / float(rings)
		for sx in [-1.0, 1.0]:
			cage.box(Vector3(sx * w * 0.5, y, 0), Vector3(tube, tube, l))
		for sz in [-1.0, 1.0]:
			cage.box(Vector3(0, y, sz * l * 0.5), Vector3(w, tube, tube))
	# Valve at the front, near the bottom.
	valve.cylinder(Vector3(0, deck + 0.09, l * 0.5 + 0.05), 0.05, 0.10,
		Vector3.BACK, 14)
	base.commit(mesh, BASE, 0.4, 0.6)
	bottle.commit(mesh, BOTTLE, 0.0, 0.45, 0.85)
	cage.commit(mesh, CAGE, 0.75, 0.4)
	valve.commit(mesh, VALVE, 0.0, 0.7)
