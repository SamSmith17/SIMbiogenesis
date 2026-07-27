class_name PalletRackBuilder
extends RefCounted

## Parametric Mars-College-style structure built from standard warehouse pallet
## racking: upright frames (depth 36/42/48", height 4-20') carrying beams
## (span 4/8/9/10/12'), rack rows locked into columns by 2x4 lumber joists and
## tiled with 4'x8' 3/4" plywood decks. Supports multi-level + rooftop decks,
## plywood walls, a stepped-platform module, and a U-shaped open-bay variant.
##
## Used by the pallet-rack builder modal and as the procedural PlacedProp model
## "pallet_rack". The whole structure is emitted as ONE MeshInstance3D with a few
## merged surfaces (one per material) so large multi-column builds stay cheap and
## the trimesh collision bake (see placed_prop.gd) yields walkable decks.

const MODEL_ID := "pallet_rack"

const FT := 0.3048
const IN := 0.0254

# Catalog option sets (imperial, snapped in resolve_spec).
const DEPTH_OPTIONS_IN := [36, 42, 48]
const HEIGHT_OPTIONS_FT := [4, 6, 8, 10, 12, 16, 20]
const BEAM_OPTIONS_FT := [4, 8, 9, 10, 12]
const LUMBER_OPTIONS_FT := [10, 12, 16]
const JOIST_SPACING_OPTIONS_IN := [16, 24]

# Member cross-sections (metres).
const POST_W := 3.0 * IN          # upright post face
const BEAM_H := 0.10              # steel beam vertical face
const BEAM_T := 0.05              # steel beam thickness (depth)
const JOIST_W := 1.5 * IN         # 2x4 on edge width
const JOIST_H := 3.5 * IN         # 2x4 on edge height
const PLY_T := 0.75 * IN          # 3/4" plywood
const BEARING := 0.04            # joist rest on each beam
const SHEET_LONG := 8.0 * FT      # 4x8 plywood long edge
const SHEET_SHORT := 4.0 * FT     # 4x8 plywood short edge
const HALF_PANEL_FT := 4.0        # 4x4 half-sheet — deck spacing snaps to this
const SEAM := 0.005              # gap between sheets so they read individually
const STAIR_STEPS := 6


static func default_spec() -> Dictionary:
	# The Mars College standard: 42" x 16' uprights, 12' beams, 3 bays, 2 columns,
	# decks at 6" + 8', rooftop deck on.
	return {
		"upright_depth_in": 42,
		"upright_height_ft": 16,
		"beam_span_ft": 12,
		"bay_count": 3,
		"column_count": 2,
		"row_gap_ft": 12.0,
		"decked": true,
		"lumber_len_ft": 12,
		"joist_spacing_in": 24,
		"deck_levels": 2,
		"level_heights_ft": [0.5, 8.0],
		"roof_deck": true,
		"walls": {"front": false, "back": false, "left": false, "right": false},
		"stepped_module": 0,
		"u_shape": false,
		"u_open_bays": 1,
		"u_open_cols": 1,
		# Per-component editor overrides (empty = every cell/beam uses defaults).
		# cell_overrides: "bay,col,level" -> {height_ft, kind: deck|step|none, depth_units}
		# beam_overrides: "level,row,bay,side" -> {deleted, dy_in}
		# wall_sheet_deleted: ["face,ia,iv", ...]
		"cell_overrides": {},
		"beam_overrides": {},
		"wall_sheet_deleted": [],
	}


static func resolve_spec(overrides: Dictionary = {}) -> Dictionary:
	var s := default_spec()
	# Legacy metric spec (width_m/depth_m/levels) → map onto the catalog so old
	# saved pallet_rack props still rebuild.
	if overrides.has("width_m") and not overrides.has("beam_span_ft"):
		overrides = _map_legacy_spec(overrides)
	for k in s.keys():
		if overrides.has(k):
			s[k] = overrides[k]

	s["upright_depth_in"] = _snap(int(s["upright_depth_in"]), DEPTH_OPTIONS_IN)
	s["upright_height_ft"] = _snap(int(s["upright_height_ft"]), HEIGHT_OPTIONS_FT)
	s["beam_span_ft"] = _snap(int(s["beam_span_ft"]), BEAM_OPTIONS_FT)
	s["lumber_len_ft"] = _snap(int(s["lumber_len_ft"]), LUMBER_OPTIONS_FT)
	s["joist_spacing_in"] = _snap(int(s["joist_spacing_in"]), JOIST_SPACING_OPTIONS_IN)
	s["bay_count"] = clampi(int(s["bay_count"]), 1, 10)
	s["column_count"] = clampi(int(s["column_count"]), 1, 10)
	# Assembly spacing (deck depth between rack rows). Legacy specs (no row_gap_ft)
	# derive it from the joist/lumber length. Snap to the nearest half-panel (4 ft)
	# so plywood always tiles with full + half sheets — no slivers.
	if not overrides.has("row_gap_ft"):
		s["row_gap_ft"] = float(s["lumber_len_ft"])
	s["row_gap_ft"] = clampf(_snap_half_panel(float(s["row_gap_ft"])), 4.0, 20.0)
	s["deck_levels"] = clampi(int(s["deck_levels"]), 1, 3)
	s["decked"] = bool(s["decked"])
	s["roof_deck"] = bool(s["roof_deck"])

	# Normalise level heights to deck_levels, filling defaults / clamping below top.
	var top_ft := float(s["upright_height_ft"])
	var heights: Array = []
	var src: Array = s["level_heights_ft"] if s["level_heights_ft"] is Array else []
	for i in int(s["deck_levels"]):
		var v := _default_level_height_ft(i)
		if i < src.size():
			v = float(src[i])
		heights.append(clampf(v, 0.25, maxf(top_ft - 0.5, 0.25)))
	heights.sort()
	s["level_heights_ft"] = heights

	# Walls dict normalisation.
	var w: Dictionary = s["walls"] if s["walls"] is Dictionary else {}
	s["walls"] = {
		"front": bool(w.get("front", false)),
		"back": bool(w.get("back", false)),
		"left": bool(w.get("left", false)),
		"right": bool(w.get("right", false)),
	}

	s["stepped_module"] = clampi(int(s["stepped_module"]), 0, int(s["column_count"]))
	s["u_shape"] = bool(s["u_shape"])
	s["u_open_bays"] = clampi(int(s["u_open_bays"]), 1, int(s["bay_count"]))
	s["u_open_cols"] = clampi(int(s["u_open_cols"]), 1, int(s["column_count"]))

	# Per-component override containers (typed, string-keyed) so old saved racks
	# without them still load and every editor write round-trips through JSON.
	var cov := {}
	if s.get("cell_overrides") is Dictionary:
		for k in (s["cell_overrides"] as Dictionary).keys():
			var v: Variant = s["cell_overrides"][k]
			cov[str(k)] = (v as Dictionary).duplicate() if v is Dictionary else {}
	s["cell_overrides"] = cov
	var bov := {}
	if s.get("beam_overrides") is Dictionary:
		for k in (s["beam_overrides"] as Dictionary).keys():
			var v: Variant = s["beam_overrides"][k]
			bov[str(k)] = (v as Dictionary).duplicate() if v is Dictionary else {}
	s["beam_overrides"] = bov
	var wdel: Array = []
	if s.get("wall_sheet_deleted") is Array:
		for k in (s["wall_sheet_deleted"] as Array):
			wdel.append(str(k))
	s["wall_sheet_deleted"] = wdel

	# Migrate the legacy stepped_module flag into per-cell "step" overrides so the
	# new editor sees one uniform model. Only when there are no explicit cell edits
	# yet (an edited rack already carries the cells it wants).
	if int(s["stepped_module"]) > 0 and cov.is_empty():
		var lv_list := _levels(s)
		var top_decked := -1
		for li in lv_list.size():
			if bool(s["decked"]) or bool(lv_list[li]["roof"]):
				top_decked = li
		if top_decked > 0:
			var cc := int(s["stepped_module"]) - 1
			for b in int(s["bay_count"]):
				cov["%d,%d,%d" % [b, cc, top_decked]] = {"kind": "step"}
	return s


static func _map_legacy_spec(o: Dictionary) -> Dictionary:
	var width_m := float(o.get("width_m", 2.4))
	var depth_m := float(o.get("depth_m", 1.1))
	var levels := int(o.get("levels", 3))
	return {
		"beam_span_ft": _snap(int(round(width_m / FT)), BEAM_OPTIONS_FT),
		"upright_depth_in": _snap(int(round(depth_m / IN)), DEPTH_OPTIONS_IN),
		"bay_count": clampi(int(o.get("bay_count", 3)), 1, 10),
		"column_count": 1,
		"decked": false,
		"deck_levels": clampi(levels, 1, 3),
		"upright_height_ft": 8,
		"roof_deck": false,
	}


static func _snap(value: int, options: Array) -> int:
	var best: int = int(options[0])
	var best_d := absi(value - best)
	for o in options:
		var d := absi(value - int(o))
		if d < best_d:
			best_d = d
			best = int(o)
	return best


## Round a spacing (ft) to the nearest 4x4 half-panel so plywood tiles cleanly.
static func _snap_half_panel(value_ft: float) -> float:
	return roundf(value_ft / HALF_PANEL_FT) * HALF_PANEL_FT


static func _default_level_height_ft(i: int) -> float:
	var defaults := [0.5, 8.0, 16.0]
	if i < defaults.size():
		return defaults[i]
	return 0.5 + float(i) * 7.5


# ---------------------------------------------------------------------------
# Geometry model
# ---------------------------------------------------------------------------

class _Geom:
	extends RefCounted
	var frame := SurfaceTool.new()
	var beam := SurfaceTool.new()
	var lumber := SurfaceTool.new()
	var ply := SurfaceTool.new()
	var counts := {"uprights": 0, "beams": 0, "lumber": 0, "plywood": 0}

	func _init() -> void:
		frame.begin(Mesh.PRIMITIVE_TRIANGLES)
		beam.begin(Mesh.PRIMITIVE_TRIANGLES)
		lumber.begin(Mesh.PRIMITIVE_TRIANGLES)
		ply.begin(Mesh.PRIMITIVE_TRIANGLES)


static func footprint_xz(spec: Dictionary = {}) -> Vector2:
	var s := resolve_spec(spec)
	var m := _metrics(s)
	return Vector2(m.total_x, m.total_z)


static func _metrics(s: Dictionary) -> Dictionary:
	var module_x := float(s["beam_span_ft"]) * FT + POST_W
	var frame_depth := float(s["upright_depth_in"]) * IN
	# Clear spacing between adjacent rack rows (assemblies); joists span it below.
	var gap_z := float(s["row_gap_ft"]) * FT
	var rows := int(s["column_count"]) + 1
	var total_x := float(s["bay_count"]) * module_x
	var total_z := float(rows) * frame_depth + float(s["column_count"]) * gap_z
	return {
		"module_x": module_x, "frame_depth": frame_depth, "gap_z": gap_z,
		"rows": rows, "total_x": total_x, "total_z": total_z,
		"height": float(s["upright_height_ft"]) * FT,
	}


## Ordered list of deck levels: {y: beam-top height, roof: bool}.
static func _levels(s: Dictionary, _m: Dictionary = {}) -> Array:
	var out: Array = []
	var top: float = float(s["upright_height_ft"]) * FT
	for h in s["level_heights_ft"]:
		var y := float(h) * FT
		if y < top - 0.15:
			out.append({"y": y, "roof": false})
	if bool(s["roof_deck"]):
		out.append({"y": top, "roof": true})
	out.sort_custom(func(a, b): return float(a["y"]) < float(b["y"]))
	return out


static func build_node(spec: Dictionary = {}, node_name: String = "PalletRack") -> Node3D:
	var s := resolve_spec(spec)
	var m := _metrics(s)
	var root := Node3D.new()
	root.name = node_name
	root.set_meta("rack_spec", s.duplicate(true))

	var g := _Geom.new()
	_emit_structure(g, s, m)

	var mesh := ArrayMesh.new()
	var mats: Array = []
	for pair in [[g.frame, _steel_frame_material()], [g.beam, _steel_beam_material()],
			[g.lumber, _lumber_material()], [g.ply, _plywood_material()]]:
		var st: SurfaceTool = pair[0]
		var arr := st.commit_to_arrays()
		# An empty SurfaceTool returns a full-size array with a null vertex slot
		# (e.g. no plywood when decking + roof are both off) — skip it rather than
		# casting null to PackedVector3Array (which throws "Invalid cast").
		if arr.size() <= Mesh.ARRAY_VERTEX:
			continue
		var verts: Variant = arr[Mesh.ARRAY_VERTEX]
		if not (verts is PackedVector3Array) or (verts as PackedVector3Array).is_empty():
			continue
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		mats.append(pair[1])
	for i in mats.size():
		mesh.surface_set_material(i, mats[i])

	var mi := MeshInstance3D.new()
	mi.name = "RackMesh"
	mi.mesh = mesh

	# Shadow proxy (perf): the decks (plywood surface) are the solar-meaningful
	# solid shadow; the many thin steel members (posts, braces, beams, joists)
	# cast negligible ground shadow but multiply the shadow-pass triangle count
	# across all splits. Emit the deck surface alone as a SHADOWS_ONLY caster and
	# drop the detailed mesh from the shadow pass. PropRenderTuning's per-prop
	# "Shadows: All parts" override (meta _shadow_full) swaps back to full detail;
	# "Off" / global disable turns both off. Falls back to full-mesh shadows when
	# there is no deck geometry.
	var ply_arr := g.ply.commit_to_arrays()
	var has_ply: bool = ply_arr.size() > Mesh.ARRAY_VERTEX \
		and ply_arr[Mesh.ARRAY_VERTEX] is PackedVector3Array \
		and not (ply_arr[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty()
	if has_ply:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.set_meta("_shadow_full", true)
	else:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	# Add the visible mesh FIRST so it stays the focus/outline + collision source.
	root.add_child(mi)
	if has_ply:
		var pmesh := ArrayMesh.new()
		pmesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, ply_arr)
		pmesh.surface_set_material(0, _plywood_material())
		var pmi := MeshInstance3D.new()
		pmi.name = "RackShadowProxy"
		pmi.mesh = pmesh
		pmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		pmi.set_meta("_shadow_proxy", true)
		# Invisible depth-only caster — not a physics wall (decks already collide
		# via RackMesh) and not a focus/pick target.
		pmi.set_meta("skip_prop_collision", true)
		root.add_child(pmi)

	root.set_meta("bom", g.counts.duplicate())
	# Foot origin on ground centre so PlacedProp footing works (local Y=0).
	return root


static func build_default_node() -> Node3D:
	return build_node(default_spec())


static func bom(spec: Dictionary = {}) -> Dictionary:
	var s := resolve_spec(spec)
	var m := _metrics(s)
	var g := _Geom.new()
	_emit_structure(g, s, m)
	return g.counts.duplicate()


# ---------------------------------------------------------------------------
# Structure emission (drives both geometry and the bill of materials)
# ---------------------------------------------------------------------------

## Shared spatial layout (frame X lines, row Z lines, levels, notch) so geometry
## emission and the pick registry can never drift apart.
static func _layout(s: Dictionary, m: Dictionary) -> Dictionary:
	var bays := int(s["bay_count"])
	var rows: int = m.rows
	var module_x: float = m.module_x
	var frame_depth: float = m.frame_depth
	var gap_z: float = m.gap_z
	var total_x: float = m.total_x
	var total_z: float = m.total_z
	var height: float = m.height
	var x0 := -total_x * 0.5
	var z0 := -total_z * 0.5
	var row_pitch := frame_depth + gap_z
	var fx: Array = []
	for bx in range(bays + 1):
		fx.append(x0 + float(bx) * module_x)
	var rz: Array = []
	for r in range(rows):
		rz.append(z0 + float(r) * row_pitch)
	var notch := {}
	if bool(s["u_shape"]):
		var ow := float(s["u_open_bays"]) * module_x
		var od := float(s["u_open_cols"]) * row_pitch
		notch = {"x0": -ow * 0.5, "x1": ow * 0.5, "z0": z0, "z1": z0 + od}
	return {
		"bays": bays, "rows": rows, "cols": int(s["column_count"]),
		"module_x": module_x, "frame_depth": frame_depth, "gap_z": gap_z,
		"row_pitch": row_pitch, "total_x": total_x, "total_z": total_z,
		"height": height, "x0": x0, "z0": z0, "fx": fx, "rz": rz,
		"levels": _levels(s, m), "notch": notch,
	}


static func _cell_key(b: int, c: int, li: int) -> String:
	return "%d,%d,%d" % [b, c, li]


static func _beam_key(li: int, r: int, b: int, side: int) -> String:
	return "%d,%d,%d,%d" % [li, r, b, side]


## Z bounds of a deck cell in column gap c. Cells share the frame row between
## them at its midpoint so adjacent same-height cells read as one unbroken deck
## (co-planar bridging) while differing heights show a real step.
static func _cell_z_bounds(rz: Array, frame_depth: float, c: int, cols: int) -> Vector2:
	var z_start: float = float(rz[c]) if c == 0 else float(rz[c]) + frame_depth * 0.5
	var z_end: float
	if c == cols - 1:
		z_end = float(rz[c + 1]) + frame_depth
	else:
		z_end = float(rz[c + 1]) + frame_depth * 0.5
	return Vector2(z_start, z_end)


## Resolve one deck cell against the level template + per-cell overrides.
static func _resolve_cell(s: Dictionary, b: int, c: int, li: int,
		level: Dictionary, default_decked: bool) -> Dictionary:
	var kind := "deck" if (default_decked or bool(level["roof"])) else "none"
	var height_ft := float(level["y"]) / FT
	var depth_units := -1
	var ov: Dictionary = (s.get("cell_overrides", {}) as Dictionary).get(_cell_key(b, c, li), {})
	if ov.has("kind"):
		kind = str(ov["kind"])
	if ov.has("height_ft"):
		height_ft = float(ov["height_ft"])
	if ov.has("depth_units"):
		depth_units = int(ov["depth_units"])
	return {"kind": kind, "height_ft": height_ft, "y": height_ft * FT,
		"depth_units": depth_units}


static func _emit_structure(g: _Geom, s: Dictionary, m: Dictionary) -> void:
	var L := _layout(s, m)
	var bays: int = L.bays
	var rows: int = L.rows
	var cols: int = L.cols
	var frame_depth: float = L.frame_depth
	var height: float = L.height
	var fx: Array = L.fx
	var rz: Array = L.rz
	var levels: Array = L.levels
	var notch: Dictionary = L.notch
	var x0: float = L.x0
	var z0: float = L.z0
	var total_x: float = L.total_x
	var total_z: float = L.total_z
	var decked := bool(s["decked"])
	var beam_ov: Dictionary = s.get("beam_overrides", {})

	# Uprights (frames) at every row x bay-boundary.
	for r in range(rows):
		var zf := float(rz[r])
		for bx in range(bays + 1):
			var x := float(fx[bx])
			if _in_notch(notch, x, zf + frame_depth * 0.5):
				continue
			_emit_frame(g, x, zf, zf + frame_depth, height)
			g.counts["uprights"] += 1

	# Beams at every level x row x bay (front + back side), honoring overrides
	# (deleted beams vanish; dy_in nudges them 1" at a time).
	for li in range(levels.size()):
		var y := float(levels[li]["y"])
		for r in range(rows):
			var zf := float(rz[r])
			for b in range(bays):
				var cx := (float(fx[b]) + float(fx[b + 1])) * 0.5
				var span := float(fx[b + 1]) - float(fx[b]) - POST_W
				for side in range(2):
					var zb := zf if side == 0 else zf + frame_depth
					if _in_notch(notch, cx, zb):
						continue
					var ov: Dictionary = beam_ov.get(_beam_key(li, r, b, side), {})
					if bool(ov.get("deleted", false)):
						continue
					var yy := y + float(ov.get("dy_in", 0.0)) * IN
					_emit_box(g.beam, Transform3D(Basis(), Vector3(cx, yy - BEAM_H * 0.5, zb)),
						Vector3(span, BEAM_H, BEAM_T))
					g.counts["beams"] += 1

	# Decks emitted PER CELL (bay x column) so each is individually raiseable,
	# resizeable, steppable, or removable. Within a cell the plywood keeps the
	# per-bay 4' tiling (3x 4' sheets fill each 12' clear span, ~3" post gap).
	for li in range(levels.size()):
		var lv: Dictionary = levels[li]
		for c in range(cols):
			var zb := _cell_z_bounds(rz, frame_depth, c, cols)
			for b in range(bays):
				var cell := _resolve_cell(s, b, c, li, lv, decked)
				var kind := str(cell["kind"])
				if kind == "none":
					continue
				var y := float(cell["y"])
				var bx0 := float(fx[b]) + POST_W * 0.5
				var bx1 := float(fx[b + 1]) - POST_W * 0.5
				var cz0: float = zb.x
				var cz1: float = zb.y
				var du := int(cell.get("depth_units", -1))
				if du >= 0:
					cz1 = minf(cz1, cz0 + float(du) * HALF_PANEL_FT * FT)
				var ccx := (bx0 + bx1) * 0.5
				if _in_notch(notch, ccx, (cz0 + cz1) * 0.5):
					continue
				if kind == "step":
					var y_lo := float(levels[li - 1]["y"]) if li > 0 else 0.0
					_emit_stairs(g, bx0, bx1, cz0, cz1, y_lo, y, notch)
					continue
				_emit_joists_span(g, s, bx0, bx1, cz0, cz1, y, notch)
				_emit_ply_field(g, bx0, bx1, cz0, cz1, y + JOIST_H + PLY_T * 0.5, notch)

	# Plywood walls on chosen perimeter faces.
	_emit_walls(g, s, m, x0, z0, total_x, total_z, height, notch)


static func _emit_frame(g: _Geom, x: float, z0: float, z1: float, h: float) -> void:
	# Two posts.
	for z in [z0, z1]:
		_emit_box(g.frame, Transform3D(Basis(), Vector3(x, h * 0.5, z)),
			Vector3(POST_W, h, POST_W))
	# Foot plates.
	for z in [z0, z1]:
		_emit_box(g.frame, Transform3D(Basis(), Vector3(x, 0.02, z)),
			Vector3(POST_W * 1.6, 0.04, POST_W * 1.8))
	# Horizontal + diagonal bracing in the Z-Y plane between the two posts.
	var nodes := [0.15]
	var steps := maxi(2, int(h / 1.2))
	for i in range(1, steps + 1):
		nodes.append(0.15 + (h - 0.3) * float(i) / float(steps))
	var brace := POST_W * 0.55
	for yy in nodes:
		_emit_strut(g.frame, Vector3(x, yy, z0), Vector3(x, yy, z1), brace)
	for i in range(nodes.size() - 1):
		var y_lo := float(nodes[i])
		var y_hi := float(nodes[i + 1])
		var za := z0 if (i % 2 == 0) else z1
		var zb := z1 if (i % 2 == 0) else z0
		_emit_strut(g.frame, Vector3(x, y_lo, za), Vector3(x, y_hi, zb), brace)


static func _emit_joists_span(g: _Geom, s: Dictionary, x_a: float, x_b: float,
		z_a: float, z_b: float, beam_y: float, notch: Dictionary) -> void:
	var joist_cy := beam_y + JOIST_H * 0.5
	var span_z := z_b - z_a
	var joist_len := span_z + 2.0 * BEARING
	var joist_cz := (z_a + z_b) * 0.5
	# Joists run in Z across the cell depth, spaced along X within the bay span.
	var spacing := float(s["joist_spacing_in"]) * IN
	var w := x_b - x_a
	var n := maxi(2, int(w / spacing) + 1)
	for i in range(n):
		var jx := x_a + minf(float(i) * spacing, w)
		if i == n - 1:
			jx = x_b
		if _in_notch(notch, jx, joist_cz):
			continue
		_emit_box(g.lumber, Transform3D(Basis(), Vector3(jx, joist_cy, joist_cz)),
			Vector3(JOIST_W, JOIST_H, joist_len))
		g.counts["lumber"] += 1


static func _emit_stairs(g: _Geom, x_a: float, x_b: float, z_a: float,
		z_b: float, y_lo: float, y_hi: float, notch: Dictionary) -> void:
	var span := z_b - z_a
	var step_dz := span / float(STAIR_STEPS)
	var cxm := (x_a + x_b) * 0.5
	var wx := x_b - x_a
	for s_i in range(STAIR_STEPS):
		var za := z_a + step_dz * float(s_i)
		var zb2 := za + step_dz
		var y := y_lo + (y_hi - y_lo) * float(s_i + 1) / float(STAIR_STEPS)
		var cz := (za + zb2) * 0.5
		if _in_notch(notch, cxm, cz):
			continue
		# Support lumber under the tread.
		_emit_box(g.lumber, Transform3D(Basis(), Vector3(cxm, y - JOIST_H * 0.5, cz)),
			Vector3(wx, JOIST_H, step_dz * 0.9))
		g.counts["lumber"] += 1
		_emit_ply_field(g, x_a, x_b, za, zb2, y + PLY_T * 0.5, notch)


static func _emit_ply_field(g: _Geom, x_a: float, x_b: float, z_a: float, z_b: float,
		cy: float, notch: Dictionary, skip_z: Array = []) -> void:
	# Deck sheets run their 4' short edge along X — three of them fill each 12' bay
	# span between uprights — and their 8' long edge along Z (front→back, spanning
	# across the joists), so the deck stays unbroken from the player to the wall
	# and re-tiles cleanly as the half-panel-snapped assembly spacing changes.
	var w := x_b - x_a
	var d := z_b - z_a
	var nx := maxi(1, int(ceil(w / SHEET_SHORT)))
	var nz := maxi(1, int(ceil(d / SHEET_LONG)))
	for ix in range(nx):
		var sx0 := x_a + float(ix) * SHEET_SHORT
		var sxw := minf(SHEET_SHORT, x_b - sx0) - SEAM
		if sxw <= 0.01:
			continue
		for iz in range(nz):
			var sz0 := z_a + float(iz) * SHEET_LONG
			var szw := minf(SHEET_LONG, z_b - sz0) - SEAM
			if szw <= 0.01:
				continue
			var ccx := sx0 + sxw * 0.5
			var ccz := sz0 + szw * 0.5
			if _in_notch(notch, ccx, ccz):
				continue
			if _z_in_ranges(skip_z, ccz):
				continue
			_emit_box(g.ply, Transform3D(Basis(), Vector3(ccx, cy, ccz)),
				Vector3(sxw, PLY_T, szw))
			g.counts["plywood"] += 1


static func _z_in_ranges(ranges: Array, z: float) -> bool:
	for r in ranges:
		if r is Array and (r as Array).size() >= 2:
			if z >= float(r[0]) and z <= float(r[1]):
				return true
	return false


static func _wall_faces(s: Dictionary, L: Dictionary) -> Array:
	# [face, a0, a1, fixed, height, along_x, notch] per enabled wall.
	var w: Dictionary = s["walls"]
	var x0: float = L.x0
	var z0: float = L.z0
	var total_x: float = L.total_x
	var total_z: float = L.total_z
	var height: float = L.height
	var notch: Dictionary = L.notch
	var out: Array = []
	if bool(w.get("front", false)):
		out.append(["front", x0, x0 + total_x, z0, height, true, notch])
	if bool(w.get("back", false)):
		out.append(["back", x0, x0 + total_x, z0 + total_z, height, true, {}])
	if bool(w.get("left", false)):
		out.append(["left", z0, z0 + total_z, x0, height, false, {}])
	if bool(w.get("right", false)):
		out.append(["right", z0, z0 + total_z, x0 + total_x, height, false, {}])
	return out


## Sheet tiling for one wall face: [{ia, iv, pos, size}]. Shared by emission +
## picking so a deleted sheet always matches the box the player clicked.
static func _wall_face_sheets(a0: float, a1: float, fixed: float, height: float,
		along_x: bool, notch: Dictionary) -> Array:
	var out: Array = []
	var w := a1 - a0
	var na := maxi(1, int(ceil(w / SHEET_SHORT)))
	var nv := maxi(1, int(ceil(height / SHEET_LONG)))
	for ia in range(na):
		var pa := a0 + float(ia) * SHEET_SHORT
		var paw := minf(SHEET_SHORT, a1 - pa) - SEAM
		if paw <= 0.01:
			continue
		for iv in range(nv):
			var vy := float(iv) * SHEET_LONG
			var vh := minf(SHEET_LONG, height - vy) - SEAM
			if vh <= 0.01:
				continue
			var cc := pa + paw * 0.5
			var cy := vy + vh * 0.5
			var pos: Vector3
			var size: Vector3
			if along_x:
				if _in_notch(notch, cc, fixed):
					continue
				pos = Vector3(cc, cy, fixed)
				size = Vector3(paw, vh, PLY_T)
			else:
				pos = Vector3(fixed, cy, cc)
				size = Vector3(PLY_T, vh, paw)
			out.append({"ia": ia, "iv": iv, "pos": pos, "size": size})
	return out


static func _emit_walls(g: _Geom, s: Dictionary, m: Dictionary, _x0: float, _z0: float,
		_total_x: float, _total_z: float, _height: float, _notch: Dictionary) -> void:
	var L := _layout(s, m)
	var deleted: Array = s.get("wall_sheet_deleted", [])
	for f in _wall_faces(s, L):
		for sh in _wall_face_sheets(f[1], f[2], f[3], f[4], f[5], f[6]):
			if deleted.has("%s,%d,%d" % [f[0], int(sh["ia"]), int(sh["iv"])]):
				continue
			_emit_box(g.ply, Transform3D(Basis(), sh["pos"]), sh["size"])
			g.counts["plywood"] += 1


static func _in_notch(notch: Dictionary, x: float, z: float) -> bool:
	if notch.is_empty():
		return false
	var eps := 0.02
	return x > float(notch["x0"]) + eps and x < float(notch["x1"]) - eps \
		and z > float(notch["z0"]) - eps and z < float(notch["z1"]) - eps


# ---------------------------------------------------------------------------
# Occupancy grid (bays x columns) — used by the self-test and future editors.
# ---------------------------------------------------------------------------

static func deck_grid(spec: Dictionary = {}) -> Array:
	var s := resolve_spec(spec)
	var m := _metrics(s)
	var bays := int(s["bay_count"])
	var cols := int(s["column_count"])
	var module_x: float = m.module_x
	var frame_depth: float = m.frame_depth
	var row_pitch := frame_depth + float(m.gap_z)
	var total_x: float = m.total_x
	var total_z: float = m.total_z
	var x0 := -total_x * 0.5
	var z0 := -total_z * 0.5
	var notch := {}
	if bool(s["u_shape"]):
		var ow := float(s["u_open_bays"]) * module_x
		var od := float(s["u_open_cols"]) * row_pitch
		notch = {"x0": -ow * 0.5, "x1": ow * 0.5, "z0": z0, "z1": z0 + od}
	var grid: Array = []
	for b in range(bays):
		var row: Array = []
		var cx := x0 + (float(b) + 0.5) * module_x
		for c in range(cols):
			var back_z := z0 + float(c) * row_pitch + frame_depth
			var cz := back_z + float(m.gap_z) * 0.5
			row.append(bool(s["decked"]) and not _in_notch(notch, cx, cz))
		grid.append(row)
	return grid


# ---------------------------------------------------------------------------
# Pick registry (pure math, no physics) — deck cells, beams, wall sheets,
# uprights. Consumed by the modal's ray picker for hover / select / manipulate.
# ---------------------------------------------------------------------------

## Minimum clickable half-thickness so thin members (beams, sheets) stay easy
## to hit with a ray.
const PICK_MIN_THICK := 0.08


static func pick_components(spec: Dictionary = {}) -> Array:
	var s := resolve_spec(spec)
	var m := _metrics(s)
	var L := _layout(s, m)
	var out: Array = []
	var fx: Array = L.fx
	var rz: Array = L.rz
	var levels: Array = L.levels
	var notch: Dictionary = L.notch
	var frame_depth: float = L.frame_depth
	var height: float = L.height
	var bays: int = L.bays
	var rows: int = L.rows
	var cols: int = L.cols
	var decked := bool(s["decked"])
	var beam_ov: Dictionary = s.get("beam_overrides", {})

	# Deck cells.
	for li in range(levels.size()):
		var lv: Dictionary = levels[li]
		for c in range(cols):
			var zb := _cell_z_bounds(rz, frame_depth, c, cols)
			for b in range(bays):
				var cell := _resolve_cell(s, b, c, li, lv, decked)
				if str(cell["kind"]) == "none":
					continue
				var bx0 := float(fx[b]) + POST_W * 0.5
				var bx1 := float(fx[b + 1]) - POST_W * 0.5
				var cz0: float = zb.x
				var cz1: float = zb.y
				var du := int(cell.get("depth_units", -1))
				if du >= 0:
					cz1 = minf(cz1, cz0 + float(du) * HALF_PANEL_FT * FT)
				var ccx := (bx0 + bx1) * 0.5
				if _in_notch(notch, ccx, (cz0 + cz1) * 0.5):
					continue
				var y := float(cell["y"])
				var lo := Vector3(bx0, y - JOIST_H, cz0)
				var hi := Vector3(bx1, y + JOIST_H + PLY_T + 0.02, cz1)
				out.append({
					"id": "cell:" + _cell_key(b, c, li), "kind": str(cell["kind"]),
					"aabb": AABB(lo, hi - lo), "bay": b, "col": c, "level": li,
					"height_ft": float(cell["height_ft"]), "z0": cz0, "z1": cz1,
					"depth_units": du,
				})

	# Beams (front + back of each row per bay per level).
	for li in range(levels.size()):
		var y := float(levels[li]["y"])
		for r in range(rows):
			var zf := float(rz[r])
			for b in range(bays):
				var cx := (float(fx[b]) + float(fx[b + 1])) * 0.5
				var span := float(fx[b + 1]) - float(fx[b]) - POST_W
				for side in range(2):
					var zb := zf if side == 0 else zf + frame_depth
					if _in_notch(notch, cx, zb):
						continue
					var ov: Dictionary = beam_ov.get(_beam_key(li, r, b, side), {})
					if bool(ov.get("deleted", false)):
						continue
					var yy := y + float(ov.get("dy_in", 0.0)) * IN
					var center := Vector3(cx, yy - BEAM_H * 0.5, zb)
					var size := Vector3(span, BEAM_H, maxf(BEAM_T, PICK_MIN_THICK * 2.0))
					out.append({
						"id": "beam:" + _beam_key(li, r, b, side), "kind": "beam",
						"aabb": AABB(center - size * 0.5, size),
						"level": li, "row": r, "bay": b, "side": side,
						"dy_in": float(ov.get("dy_in", 0.0)),
					})

	# Wall sheets.
	var deleted: Array = s.get("wall_sheet_deleted", [])
	for f in _wall_faces(s, L):
		for sh in _wall_face_sheets(f[1], f[2], f[3], f[4], f[5], f[6]):
			var key := "%s,%d,%d" % [f[0], int(sh["ia"]), int(sh["iv"])]
			if deleted.has(key):
				continue
			var pos: Vector3 = sh["pos"]
			var size: Vector3 = sh["size"]
			size = size.max(Vector3(PICK_MIN_THICK, PICK_MIN_THICK, PICK_MIN_THICK) * 2.0)
			out.append({"id": "wall:" + key, "kind": "wall_sheet",
				"aabb": AABB(pos - size * 0.5, size), "face": str(f[0])})

	# Uprights (selectable but not manipulated in this editor).
	for r in range(rows):
		var zf := float(rz[r])
		for bx in range(bays + 1):
			var x := float(fx[bx])
			if _in_notch(notch, x, zf + frame_depth * 0.5):
				continue
			var lo := Vector3(x - POST_W, 0.0, zf - POST_W)
			var hi := Vector3(x + POST_W, height, zf + frame_depth + POST_W)
			out.append({"id": "post:%d,%d" % [r, bx], "kind": "upright",
				"aabb": AABB(lo, hi - lo), "row": r, "bx": bx})
	return out


## Every (bay, col, level) cell slot INCLUDING empty ones (kind "none"), with an
## AABB at the level-template height. Used by the step-placement tool so the
## player can drop a step onto any grid slot — occupied or not.
static func cell_slots(spec: Dictionary = {}) -> Array:
	var s := resolve_spec(spec)
	var m := _metrics(s)
	var L := _layout(s, m)
	var out: Array = []
	var fx: Array = L.fx
	var rz: Array = L.rz
	var levels: Array = L.levels
	var notch: Dictionary = L.notch
	var frame_depth: float = L.frame_depth
	var bays: int = L.bays
	var cols: int = L.cols
	var decked := bool(s["decked"])
	for li in range(levels.size()):
		var lv: Dictionary = levels[li]
		for c in range(cols):
			var zb := _cell_z_bounds(rz, frame_depth, c, cols)
			for b in range(bays):
				var bx0 := float(fx[b]) + POST_W * 0.5
				var bx1 := float(fx[b + 1]) - POST_W * 0.5
				var ccx := (bx0 + bx1) * 0.5
				if _in_notch(notch, ccx, (float(zb.x) + float(zb.y)) * 0.5):
					continue
				var cell := _resolve_cell(s, b, c, li, lv, decked)
				var y := float(cell["y"])
				var lo := Vector3(bx0, y - JOIST_H, zb.x)
				var hi := Vector3(bx1, y + JOIST_H + PLY_T + 0.02, zb.y)
				out.append({
					"id": "cell:" + _cell_key(b, c, li), "kind": str(cell["kind"]),
					"aabb": AABB(lo, hi - lo), "bay": b, "col": c, "level": li,
				})
	return out


## Slab test: distance along `dir` to the first hit of `box`, or -1 if none.
static func ray_hits_aabb(origin: Vector3, dir: Vector3, box: AABB) -> float:
	var tmin := -INF
	var tmax := INF
	var bmin := box.position
	var bmax := box.position + box.size
	for i in range(3):
		var o: float = origin[i]
		var d: float = dir[i]
		if absf(d) < 1e-9:
			if o < bmin[i] or o > bmax[i]:
				return -1.0
		else:
			var t1 := (bmin[i] - o) / d
			var t2 := (bmax[i] - o) / d
			if t1 > t2:
				var tmp := t1
				t1 = t2
				t2 = tmp
			tmin = maxf(tmin, t1)
			tmax = minf(tmax, t2)
			if tmin > tmax:
				return -1.0
	if tmax < 0.0:
		return -1.0
	return tmin if tmin >= 0.0 else tmax


## Nearest component whose kind is in `kinds` (empty = any) along the ray.
static func pick_nearest(comps: Array, origin: Vector3, dir: Vector3,
		kinds: Array = []) -> Dictionary:
	var best: Dictionary = {}
	var best_t := INF
	for comp in comps:
		if not kinds.is_empty() and not kinds.has(str(comp.get("kind", ""))):
			continue
		var t := ray_hits_aabb(origin, dir, comp["aabb"] as AABB)
		if t >= 0.0 and t < best_t:
			best_t = t
			best = comp
	return best


# ---------------------------------------------------------------------------
# Box emission (merged into a SurfaceTool surface)
# ---------------------------------------------------------------------------

static func _emit_strut(st: SurfaceTool, a: Vector3, b: Vector3, thick: float) -> void:
	var dir := b - a
	var length := dir.length()
	if length < 0.001:
		return
	var xaxis := dir / length
	var up := Vector3.UP
	if absf(xaxis.dot(up)) > 0.99:
		up = Vector3.FORWARD
	var zaxis := xaxis.cross(up).normalized()
	var yaxis := zaxis.cross(xaxis).normalized()
	var basis := Basis(xaxis, yaxis, zaxis)
	var xf := Transform3D(basis, (a + b) * 0.5)
	_emit_box(st, xf, Vector3(length, thick, thick))


static func _emit_box(st: SurfaceTool, xf: Transform3D, size: Vector3) -> void:
	var h := size * 0.5
	var c := [
		Vector3(-h.x, -h.y, -h.z), Vector3(h.x, -h.y, -h.z),
		Vector3(h.x, h.y, -h.z), Vector3(-h.x, h.y, -h.z),
		Vector3(-h.x, -h.y, h.z), Vector3(h.x, -h.y, h.z),
		Vector3(h.x, h.y, h.z), Vector3(-h.x, h.y, h.z),
	]
	var faces := [
		[Vector3(1, 0, 0), 1, 2, 6, 5],
		[Vector3(-1, 0, 0), 4, 7, 3, 0],
		[Vector3(0, 1, 0), 3, 7, 6, 2],
		[Vector3(0, -1, 0), 4, 0, 1, 5],
		[Vector3(0, 0, 1), 4, 5, 6, 7],
		[Vector3(0, 0, -1), 1, 0, 3, 2],
	]
	var uv := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	for f in faces:
		var n: Vector3 = (xf.basis * (f[0] as Vector3)).normalized()
		# Two triangles: (0,1,2) and (0,2,3) over corners f[1..4].
		var tri := [[1, 2, 3], [1, 3, 4]]
		var uvmap := [[0, 1, 2], [0, 2, 3]]
		for t in range(2):
			for k in range(3):
				var corner_i: int = f[tri[t][k]]
				var uvi: int = uvmap[t][k]
				st.set_normal(n)
				st.set_uv(uv[uvi])
				st.add_vertex(xf * (c[corner_i] as Vector3))


# ---------------------------------------------------------------------------
# Materials
# ---------------------------------------------------------------------------

## Painted-steel upright frames. See core/structure_materials.gd for why these
## are now low-metallic (they used to read black in self-shadowed rack interiors)
## and carry procedural grain/relief.
static func _steel_frame_material() -> StandardMaterial3D:
	return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, Color(0.18, 0.45, 0.50))


static func _steel_beam_material() -> StandardMaterial3D:
	return StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, Color(0.86, 0.36, 0.13))


static func _lumber_material() -> StandardMaterial3D:
	return StructureMaterials.make(StructureMaterials.Kind.WOOD, Color(0.72, 0.55, 0.34))


static func _plywood_material() -> StandardMaterial3D:
	return StructureMaterials.make(StructureMaterials.Kind.PLYWOOD, Color(0.80, 0.66, 0.42))
