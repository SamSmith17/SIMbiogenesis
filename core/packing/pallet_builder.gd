class_name PalletBuilder
extends RefCounted
## A pallet from an IntermodalUnits entry: top deck boards, blocks (4-way)
## or stringers (2-way), bottom boards. Length along Z, width along X, floor
## at y = 0. Wood, or plastic for a "plastic" material param.

const WOOD := Color(0.62, 0.48, 0.30)
const WOOD_DARK := Color(0.50, 0.38, 0.23)
const PLASTIC := Color(0.18, 0.30, 0.55)


static func emit(mesh: ArrayMesh, entry: Dictionary) -> void:
	var ex: Dictionary = entry.get("exterior", {})
	var l := float(ex.get("l_m", 1.2))
	var w := float(ex.get("w_m", 0.8))
	var h := float(entry.get("deck_h_m", ex.get("h_m", 0.144)))
	var p: Dictionary = entry.get("params", {})
	var plastic := str(p.get("material", "wood")) == "plastic"
	var four_way := str(entry.get("fork_entry", "4-way")).begins_with("4")
	var board_t := clampf(h * 0.15, 0.018, 0.025)
	var top := IntermodalMeshKit.new()
	var under := IntermodalMeshKit.new()
	# Top deck: boards across the width (along X), spread along Z.
	var n_top := maxi(5, int(round(l / 0.17)))
	var bw := minf(0.145, l / float(n_top) * 0.78)
	for i in n_top:
		var z := -l * 0.5 + bw * 0.5 + (l - bw) * float(i) / float(n_top - 1)
		top.box(Vector3(0, h - board_t * 0.5, z), Vector3(w, board_t, bw))
	var mid_h := h - 2.0 * board_t
	if four_way:
		# Nine blocks under three stringer boards.
		for sx in [-1.0, 0.0, 1.0]:
			var x: float = float(sx) * (w * 0.5 - 0.05)
			under.box(Vector3(x, h - board_t * 1.5, 0), Vector3(0.10, board_t, l))
			for sz in [-1.0, 0.0, 1.0]:
				var z: float = float(sz) * (l * 0.5 - 0.07)
				under.box(Vector3(x, board_t + mid_h * 0.5 - board_t * 0.5, z),
					Vector3(0.10, maxf(mid_h - board_t, 0.02), 0.14))
	else:
		# Three stringers running the length (forks enter at the ends).
		for sx in [-1.0, 0.0, 1.0]:
			under.box(Vector3(sx * (w * 0.5 - 0.035), board_t + mid_h * 0.5, 0),
				Vector3(0.07, mid_h, l))
	# Bottom boards.
	for sz in [-1.0, 0.0, 1.0]:
		under.box(Vector3(0, board_t * 0.5, sz * (l * 0.5 - 0.07)),
			Vector3(w, board_t, 0.14))
	if plastic:
		top.commit(mesh, PLASTIC, 0.0, 0.55)
		under.commit(mesh, PLASTIC.darkened(0.2), 0.0, 0.6)
	else:
		top.commit(mesh, WOOD, 0.0, 0.85)
		under.commit(mesh, WOOD_DARK, 0.0, 0.9)
