class_name ToiletBankBuilder
extends RefCounted

## Procedural TOILET BANK (NPC life pass, Phase 3): a row of portable toilets
## (or composting-toilet stalls), each a real stall a person walks into, turns
## round in, and sits on facing the door — with the door that opens and shuts
## behind them and an occupied flag (ToiletBankRuntime animates both).
##
## Before this a restroom was a bare area: people crowded round its middle on
## a spiral, facing it, in an invisible chair. Now a restroom has STALLS:
## exactly one person per stall (SpaceRegistry.set_stalls), and everyone else
## waits in one first-come line in front of the bank.
##
## Frame (the model's local space): stalls run along X, doors on the +Z face;
## a second row (`rows` 2) stands back to back with its doors on -Z. The origin
## is the middle of the bank on the ground. Meta:
##   stall_spots — [{pos: Vector3 (the seat surface, where a sitting body's
##                  origin goes), yaw (NpcSeatPose: turns -Z to the way faced —
##                  out of the door), kind "toilet", door: Vector3 (on the
##                  ground just outside the door), row}]
##   queue_line  — {origin: Vector3, dir: Vector3, side: Vector3}: the line
##                 forms from `origin` out along `dir`, bending along `side`.
##   door_nodes  — the per-stall door pivots, by stall index (names).
## Built from Godot primitive meshes (BoxMesh / CylinderMesh / TorusMesh): no
## hand-wound triangles, so none of the clockwise-front-face traps.

const MODEL_ID := "toilet_bank"

## Stall geometry (metres) — a standard portable toilet (~44 x 48 x 90 in).
const STALL_W := 1.12
const STALL_D := 1.22
const STALL_H := 2.30
const GAP := 0.12            # between stalls in a row
const ROW_GAP := 0.25        # between back-to-back rows
const WALL_T := 0.04
const FLOOR_Y := 0.14        # top of the skid / floor
const DOOR_W := 0.72
const DOOR_H := 1.95
## The toilet: seat top 0.42 m over the stall floor (a standard bowl).
const SEAT_TOP := FLOOR_Y + 0.42
const BOWL_W := 0.40
const BOWL_D := 0.52
## The line forms this far in front of the doors.
const QUEUE_OFF := 1.9
const QUEUE_GAP := 0.9

const STYLE_PORTA := "porta"
const STYLE_COMPOST := "compost"
const STYLES: Array = [STYLE_PORTA, STYLE_COMPOST]

const MAX_STALLS := 16
const DEFAULT_STALLS := 4

const PORTA_COLORS := [Color(0.16, 0.34, 0.62), Color(0.18, 0.46, 0.26), Color(0.55, 0.47, 0.33)]
const ROOF_COLOR := Color(0.88, 0.88, 0.84)
const BOWL_COLOR := Color(0.93, 0.93, 0.91)
const SEAT_COLOR := Color(0.08, 0.08, 0.09)
const SKID_COLOR := Color(0.12, 0.12, 0.13)
const TIMBER_COLOR := Color(0.47, 0.33, 0.20)
const TIN_COLOR := Color(0.58, 0.60, 0.62)
const FREE_COLOR := Color(0.15, 0.75, 0.25)
const BUSY_COLOR := Color(0.85, 0.12, 0.10)


## Normalise a spec: {stalls, rows, style, wash, color}.
static func resolve(spec: Dictionary) -> Dictionary:
	var n := clampi(int(spec.get("stalls", DEFAULT_STALLS)), 1, MAX_STALLS)
	var rows := clampi(int(spec.get("rows", 2 if n > 8 else 1)), 1, 2)
	if n < 2:
		rows = 1
	var style := str(spec.get("style", STYLE_PORTA))
	if not STYLES.has(style):
		style = STYLE_PORTA
	return {"stalls": n, "rows": rows, "style": style, "wash": bool(spec.get("wash", true)),
		"color": int(spec.get("color", 0)) % PORTA_COLORS.size()}


## How many stalls stand in row `r` (the first row takes the odd one).
static func row_count(s: Dictionary, r: int) -> int:
	var n := int(s["stalls"])
	if int(s["rows"]) == 1:
		return n
	var first := (n + 1) / 2
	return first if r == 0 else n - first


## The middle of stall `k` (in its row) on the ground, its door facing
## (+1 = doors on +Z, -1 = on -Z) and row.
static func stall_frame(s: Dictionary, k: int) -> Dictionary:
	var rows := int(s["rows"])
	var n0 := row_count(s, 0)
	var r := 0 if k < n0 else 1
	var i := k if r == 0 else k - n0
	var in_row := row_count(s, r)
	var x := (float(i) - float(in_row - 1) * 0.5) * (STALL_W + GAP)
	var z := 0.0
	var face := 1.0
	if rows == 2:
		z = (STALL_D + ROW_GAP) * 0.5 * (1.0 if r == 0 else -1.0)
		face = 1.0 if r == 0 else -1.0
	return {"x": x, "z": z, "face": face, "row": r}


## The seat spots (local) — see the header.
static func stall_spots(spec: Dictionary) -> Array:
	var s := resolve(spec)
	var out: Array = []
	for k in int(s["stalls"]):
		var f := stall_frame(s, k)
		var face := float(f["face"])
		var cx := float(f["x"])
		var cz := float(f["z"])
		# The bowl stands at the back; the seated body's origin is its seat
		# surface a little in front of the bowl's middle.
		var seat_z := cz + face * (-STALL_D * 0.5 + WALL_T + BOWL_D * 0.5 + 0.06)
		var door_z := cz + face * (STALL_D * 0.5 + 0.45)
		out.append({"pos": Vector3(cx, SEAT_TOP, seat_z),
			# Facing out of the door: +Z for row 0 (yaw PI turns -Z to +Z).
			"yaw": PI if face > 0.0 else 0.0,
			"kind": NpcSeatPose.KIND_TOILET, "door": Vector3(cx, 0.0, door_z), "row": int(f["row"]),
			# Chemical and composting toilets flush nothing.
			"flush": 0.0})
	return out


## Where the line forms (local) — see the header. In front of row 0's doors,
## starting at the middle of the bank.
static func queue_line(spec: Dictionary) -> Dictionary:
	var s := resolve(spec)
	var z0 := (STALL_D * 0.5 + (STALL_D + ROW_GAP) * 0.5 if int(s["rows"]) == 2 else STALL_D * 0.5)
	return {"origin": Vector3(0.0, 0.0, z0 + QUEUE_OFF), "dir": Vector3(0.0, 0.0, 1.0),
		"side": Vector3(1.0, 0.0, 0.0)}


## Place `k` in a line (local metres): straight out from the doors for eight,
## then bending sideways so a long line does not run off into the camp.
static func queue_point(line: Dictionary, k: int) -> Vector3:
	var o: Vector3 = line["origin"]
	var d: Vector3 = line["dir"]
	var sd: Vector3 = line["side"]
	if k < 8:
		return o + d * QUEUE_GAP * float(k)
	return o + d * QUEUE_GAP * 7.0 + sd * QUEUE_GAP * float(k - 7)


## Footprint size (metres): x along the row, z across.
static func footprint(spec: Dictionary) -> Vector2:
	var s := resolve(spec)
	var in_row := row_count(s, 0)
	var w := float(in_row) * STALL_W + float(in_row - 1) * GAP
	if bool(s["wash"]):
		w += 1.1
	var d := STALL_D if int(s["rows"]) == 1 else STALL_D * 2.0 + ROW_GAP
	return Vector2(w, d)


static func build_node(spec: Dictionary = {}, node_name: String = "ToiletBank") -> Node3D:
	var s := resolve(spec)
	var root := Node3D.new()
	root.name = node_name
	var porta := str(s["style"]) == STYLE_PORTA
	var shell_col: Color = PORTA_COLORS[int(s["color"])] if porta else TIMBER_COLOR
	var shell := _mat(shell_col, 0.55 if porta else 0.85, 0.0)
	var roof := _mat(ROOF_COLOR if porta else TIN_COLOR, 0.45, 0.0 if porta else 0.6)
	var skid := _mat(SKID_COLOR, 0.8, 0.0)
	var bowl := _mat(BOWL_COLOR, 0.25, 0.0)
	var seat := _mat(SEAT_COLOR, 0.4, 0.0)
	var doors := Node3D.new()
	doors.name = "Doors"
	root.add_child(doors)
	var door_names: Array = []
	for k in int(s["stalls"]):
		var f := stall_frame(s, k)
		var stall := Node3D.new()
		stall.name = "Stall%d" % k
		stall.position = Vector3(float(f["x"]), 0.0, float(f["z"]))
		# Row 1 is turned round: everything below is built doors-on-+Z.
		if float(f["face"]) < 0.0:
			stall.rotation.y = PI
		root.add_child(stall)
		_build_stall(stall, porta, shell, roof, skid, bowl, seat)
		# The door: a pivot at the hinge (the stall's -X jamb), the leaf
		# hanging off it toward +X. Kept apart (under Doors) so the runtime
		# swings it and the prop's collision ignores it.
		var pivot := Node3D.new()
		pivot.name = "D%d" % k
		var hinge_local := Vector3(-DOOR_W * 0.5, FLOOR_Y, STALL_D * 0.5)
		pivot.transform = stall.transform * Transform3D(Basis(), hinge_local)
		doors.add_child(pivot)
		var leaf := _box(Vector3(DOOR_W, DOOR_H, 0.035), Vector3(DOOR_W * 0.5, DOOR_H * 0.5, 0.0),
			_mat(shell_col.darkened(0.12), 0.55 if porta else 0.85, 0.0))
		leaf.name = "Leaf"
		leaf.set_meta("skip_prop_collision", true)
		pivot.add_child(leaf)
		var handle := _box(Vector3(0.03, 0.16, 0.05), Vector3(DOOR_W - 0.09, 1.0, 0.04),
			_mat(Color(0.75, 0.75, 0.72), 0.3, 0.7))
		handle.set_meta("skip_prop_collision", true)
		pivot.add_child(handle)
		# The occupied flag over the handle (green / red, set by the runtime).
		var flag := _box(Vector3(0.09, 0.05, 0.02), Vector3(DOOR_W - 0.09, 1.16, 0.035),
			_flag_mat(FREE_COLOR))
		flag.name = "Flag"
		flag.set_meta("skip_prop_collision", true)
		pivot.add_child(flag)
		door_names.append(pivot.name)
	if bool(s["wash"]):
		_build_wash(root, s, porta)
	root.set_meta("stall_spots", stall_spots(spec))
	root.set_meta("queue_line", queue_line(spec))
	root.set_meta("door_nodes", door_names)
	root.set_meta("toilet_spec", s)
	return root


## One stall, doors on +Z, centred on the local origin.
static func _build_stall(stall: Node3D, porta: bool, shell: Material, roof: Material,
		skid: Material, bowl: Material, seat: Material) -> void:
	var hw := STALL_W * 0.5
	var hd := STALL_D * 0.5
	var wall_h := STALL_H - FLOOR_Y - 0.08
	var wall_y := FLOOR_Y + wall_h * 0.5
	# Skid + floor.
	stall.add_child(_box(Vector3(STALL_W, FLOOR_Y, STALL_D), Vector3(0.0, FLOOR_Y * 0.5, 0.0), skid))
	# Back and side walls.
	stall.add_child(_box(Vector3(STALL_W, wall_h, WALL_T), Vector3(0.0, wall_y, -hd + WALL_T * 0.5), shell))
	for sx: float in [-1.0, 1.0]:
		stall.add_child(_box(Vector3(WALL_T, wall_h, STALL_D), Vector3(sx * (hw - WALL_T * 0.5), wall_y, 0.0), shell))
	# The front around the door: two jambs and a header.
	var jamb_w := (STALL_W - DOOR_W) * 0.5
	for sx: float in [-1.0, 1.0]:
		stall.add_child(_box(Vector3(jamb_w, wall_h, WALL_T),
			Vector3(sx * (DOOR_W * 0.5 + jamb_w * 0.5), wall_y, hd - WALL_T * 0.5), shell))
	var header_h := wall_h - DOOR_H
	stall.add_child(_box(Vector3(DOOR_W, header_h, WALL_T),
		Vector3(0.0, FLOOR_Y + DOOR_H + header_h * 0.5, hd - WALL_T * 0.5), shell))
	# Roof: a translucent dome-ish cap on a porta-potty, tin on a timber stall.
	var cap := _box(Vector3(STALL_W + 0.08, 0.10, STALL_D + 0.08),
		Vector3(0.0, STALL_H - 0.05, 0.0 if porta else -0.04), roof)
	if not porta:
		cap.rotation.x = 0.08
	stall.add_child(cap)
	if porta:
		# Corner ribs (the moulded look) and the vent stack at the back.
		for sx: float in [-1.0, 1.0]:
			for sz: float in [-1.0, 1.0]:
				stall.add_child(_box(Vector3(0.07, wall_h, 0.07),
					Vector3(sx * (hw - 0.02), wall_y, sz * (hd - 0.02)), shell))
		var vent := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.05
		cyl.bottom_radius = 0.05
		cyl.height = 0.45
		cyl.radial_segments = 10
		vent.mesh = cyl
		vent.position = Vector3(hw - 0.2, STALL_H + 0.18, -hd + 0.18)
		vent.material_override = _mat(SKID_COLOR, 0.6, 0.0)
		stall.add_child(vent)
	# The toilet against the back wall: a bowl block, a black seat ring.
	var bz := -hd + WALL_T + BOWL_D * 0.5
	stall.add_child(_box(Vector3(BOWL_W, SEAT_TOP - FLOOR_Y - 0.03, BOWL_D),
		Vector3(0.0, FLOOR_Y + (SEAT_TOP - FLOOR_Y - 0.03) * 0.5, bz), bowl))
	var ring := MeshInstance3D.new()
	var tor := TorusMesh.new()
	tor.inner_radius = 0.12
	tor.outer_radius = 0.19
	tor.rings = 16
	tor.ring_segments = 6
	ring.mesh = tor
	ring.scale = Vector3(1.0, 0.2, 1.15)
	ring.position = Vector3(0.0, SEAT_TOP - 0.01, bz + 0.03)
	ring.material_override = seat
	stall.add_child(ring)
	# A paper roll on the side wall.
	var roll := MeshInstance3D.new()
	var rc := CylinderMesh.new()
	rc.top_radius = 0.055
	rc.bottom_radius = 0.055
	rc.height = 0.11
	rc.radial_segments = 10
	roll.mesh = rc
	roll.rotation.z = PI * 0.5
	roll.position = Vector3(hw - WALL_T - 0.06, FLOOR_Y + 0.72, bz + 0.15)
	roll.material_override = _mat(Color(0.95, 0.95, 0.93), 0.9, 0.0)
	stall.add_child(roll)


## A hand-wash stand at the +X end of row 0: a frame, two basins, a tank.
static func _build_wash(root: Node3D, s: Dictionary, porta: bool) -> void:
	var fp := footprint({"stalls": s["stalls"], "rows": s["rows"], "wash": false})
	var x := fp.x * 0.5 + 0.6
	var z := 0.0 if int(s["rows"]) == 1 else (STALL_D + ROW_GAP) * 0.5
	var wash := Node3D.new()
	wash.name = "WashStation"
	wash.position = Vector3(x, 0.0, z)
	root.add_child(wash)
	var body_col := ROOF_COLOR if porta else TIMBER_COLOR
	wash.add_child(_box(Vector3(0.9, 0.85, 0.55), Vector3(0.0, 0.425, 0.0), _mat(body_col, 0.5, 0.0)))
	for sx: float in [-0.22, 0.22]:
		var basin := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.17
		cyl.bottom_radius = 0.12
		cyl.height = 0.12
		cyl.radial_segments = 16
		basin.mesh = cyl
		basin.position = Vector3(sx, 0.9, 0.04)
		basin.material_override = _mat(BOWL_COLOR, 0.25, 0.0)
		wash.add_child(basin)
	wash.add_child(_box(Vector3(0.9, 0.45, 0.2), Vector3(0.0, 1.18, -0.2), _mat(body_col.darkened(0.15), 0.5, 0.0)))


static func _box(size: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.position = at
	mi.material_override = mat
	return mi


static func _mat(col: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	return m


static func _flag_mat(col: Color) -> StandardMaterial3D:
	var m := _mat(col, 0.4, 0.0)
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 0.6
	return m


## Recolour one stall's occupied flag (the runtime).
static func set_flag(flag: MeshInstance3D, busy: bool) -> void:
	if flag == null:
		return
	var m := flag.material_override as StandardMaterial3D
	if m == null:
		return
	var col := BUSY_COLOR if busy else FREE_COLOR
	if m.albedo_color != col:
		m = m.duplicate() as StandardMaterial3D
		m.albedo_color = col
		m.emission = col
		flag.material_override = m
