class_name ShowerHouseBuilder
extends RefCounted

## Procedural SHOWER HOUSE: a row of shower stalls on a slatted timber deck
## under a shed roof, each with a curtain, a shower head on the back wall and
## a drain, a solar water tank on the roof. One person per stall
## (SpaceRegistry.set_stalls, as a toilet bank's), everyone else waiting in
## one first-come line in front; ShowerHouseRuntime draws the curtain and
## runs the water while a stall is in use.
##
## Before this a shower was a bare area: people crowded round its middle on a
## spiral. The water is still the person's (NpcAgent "hygiene": ~12 L a
## shower, billed to their habitat).
##
## Frame (the model's local space): stalls run along X, curtains on the +Z
## face; a second row (`rows` 2) stands back to back with its curtains on -Z,
## a service chase between the two back walls. The origin is the middle of
## the house on the ground. Meta (the same shapes as ToiletBankBuilder's, so
## the population bridge reads both one way):
##   stall_spots  [{pos (where a standing body's feet go: the deck), yaw
##                (NpcSeatPose: turns -Z to the way faced — toward the shower
##                head), kind "stand", door (on the ground in front of the
##                porch), row, shower: true}]
##   queue_line   {origin, dir, side}
##   curtain_nodes, spray_nodes  per-stall node names (under Curtains /
##                Sprays)
## Built from Godot primitive meshes: no hand-wound triangles.

const MODEL_ID := "shower_house"

## Stall geometry (metres): a 1 x 1.05 m stall (an accessible one is wider;
## ~0.9 m square is the usual minimum, est).
const STALL_W := 1.0
const STALL_D := 1.05
const WALL_T := 0.03
const FLOOR_Y := 0.18        # top of the slatted deck
const WALL_H := 2.05         # partitions above the deck
const PORCH := 0.9           # deck strip and roof overhang in front of the stalls
const BACK_GAP := 0.3        # service chase between two rows
const HEAD_H := 1.95         # shower head above the deck
const RAIL_H := 1.98         # curtain rail above the deck
const CURTAIN_H := 1.62
const CURTAIN_Y0 := 0.32     # curtain hem above the deck
const CURTAIN_OPEN := 0.16   # an open curtain bunched to this share of the stall
## Where a showering body stands: this far out from the back wall (under the
## head, a little forward of it).
const STAND_FROM_BACK := 0.45
## The line forms this far in front of the porch.
const QUEUE_OFF := 1.6
const QUEUE_GAP := 0.9

const STYLE_TIMBER := "timber"
const STYLE_TIN := "tin"
const STYLES: Array = [STYLE_TIMBER, STYLE_TIN]
const HEATER_SOLAR := "solar"
const HEATER_NONE := "none"
const HEATERS: Array = [HEATER_SOLAR, HEATER_NONE]

const MAX_STALLS := 12
const DEFAULT_STALLS := 4

const TIMBER_COLOR := Color(0.56, 0.39, 0.23)
const DECK_COLOR := Color(0.43, 0.31, 0.19)
const TIN_COLOR := Color(0.62, 0.64, 0.66)
const ROOF_COLOR := Color(0.70, 0.72, 0.74)
const PIPE_COLOR := Color(0.78, 0.78, 0.76)
const TANK_COLOR := Color(0.06, 0.06, 0.07)
const HEAD_COLOR := Color(0.80, 0.80, 0.82)
const CURTAIN_COLORS := [Color(0.13, 0.52, 0.55), Color(0.86, 0.47, 0.16), Color(0.90, 0.88, 0.80),
	Color(0.45, 0.30, 0.58), Color(0.30, 0.55, 0.28)]


## Normalise a spec: {stalls, rows, style, heater, color}.
static func resolve(spec: Dictionary) -> Dictionary:
	var n := clampi(int(spec.get("stalls", DEFAULT_STALLS)), 1, MAX_STALLS)
	var rows := clampi(int(spec.get("rows", 2 if n > 6 else 1)), 1, 2)
	if n < 2:
		rows = 1
	var style := str(spec.get("style", STYLE_TIMBER))
	if not STYLES.has(style):
		style = STYLE_TIMBER
	var heater := str(spec.get("heater", HEATER_SOLAR))
	if not HEATERS.has(heater):
		heater = HEATER_SOLAR
	return {"stalls": n, "rows": rows, "style": style, "heater": heater,
		"color": posmod(int(spec.get("color", 0)), CURTAIN_COLORS.size())}


## How many stalls stand in row `r` (the first row takes the odd one).
static func row_count(s: Dictionary, r: int) -> int:
	var n := int(s["stalls"])
	if int(s["rows"]) == 1:
		return n if r == 0 else 0
	var first := (n + 1) / 2
	return first if r == 0 else n - first


## The middle of stall `k` on the ground, which way its curtain faces (+1 =
## +Z, -1 = -Z) and its row.
static func stall_frame(s: Dictionary, k: int) -> Dictionary:
	var n0 := row_count(s, 0)
	var r := 0 if k < n0 else 1
	var i := k if r == 0 else k - n0
	var in_row := row_count(s, r)
	var x := (float(i) - float(in_row - 1) * 0.5) * STALL_W
	var z := 0.0
	var face := 1.0
	if int(s["rows"]) == 2:
		z = (STALL_D + BACK_GAP) * 0.5 * (1.0 if r == 0 else -1.0)
		face = 1.0 if r == 0 else -1.0
	return {"x": x, "z": z, "face": face, "row": r}


## The stand spots (local) — see the header.
static func stall_spots(spec: Dictionary) -> Array:
	var s := resolve(spec)
	var out: Array = []
	for k in int(s["stalls"]):
		var f := stall_frame(s, k)
		var face := float(f["face"])
		var cx := float(f["x"])
		var cz := float(f["z"])
		var stand_z := cz + face * (-STALL_D * 0.5 + WALL_T + STAND_FROM_BACK)
		var door_z := cz + face * (STALL_D * 0.5 + PORCH + 0.35)
		out.append({"pos": Vector3(cx, FLOOR_Y, stand_z),
			# Facing the head on the back wall: -Z for row 0 (yaw 0), +Z for
			# row 1 (yaw PI).
			"yaw": 0.0 if face > 0.0 else PI,
			"kind": NpcSeatPose.KIND_STAND, "door": Vector3(cx, 0.0, door_z),
			"row": int(f["row"]), "shower": true})
	return out


## Where the line forms (local): in front of row 0's porch, from the middle.
static func queue_line(spec: Dictionary) -> Dictionary:
	var s := resolve(spec)
	var front := STALL_D * 0.5 + PORCH
	if int(s["rows"]) == 2:
		front += (STALL_D + BACK_GAP) * 0.5
	return {"origin": Vector3(0.0, 0.0, front + QUEUE_OFF), "dir": Vector3(0.0, 0.0, 1.0),
		"side": Vector3(1.0, 0.0, 0.0)}


## Place `k` in a line (local metres): straight out from the porch for eight,
## then bending sideways.
static func queue_point(line: Dictionary, k: int) -> Vector3:
	var o: Vector3 = line["origin"]
	var d: Vector3 = line["dir"]
	var sd: Vector3 = line["side"]
	if k < 8:
		return o + d * QUEUE_GAP * float(k)
	return o + d * QUEUE_GAP * 7.0 + sd * QUEUE_GAP * float(k - 7)


## Footprint size (metres): x along the rows (end walls included), z across
## (porches included).
static func footprint(spec: Dictionary) -> Vector2:
	var s := resolve(spec)
	var w := float(row_count(s, 0)) * STALL_W + WALL_T * 2.0
	var d := STALL_D + PORCH
	if int(s["rows"]) == 2:
		d = (STALL_D + PORCH) * 2.0 + BACK_GAP
	return Vector2(w, d)


static func build_node(spec: Dictionary = {}, node_name: String = "ShowerHouse") -> Node3D:
	var s := resolve(spec)
	var root := Node3D.new()
	root.name = node_name
	var tin := str(s["style"]) == STYLE_TIN
	var wall := _mat(TIN_COLOR if tin else TIMBER_COLOR, 0.5 if tin else 0.85, 0.55 if tin else 0.0)
	var frame := _mat(TIMBER_COLOR.darkened(0.15), 0.85, 0.0)
	var deck := _mat(DECK_COLOR, 0.9, 0.0)
	var roof := _mat(ROOF_COLOR, 0.4, 0.6)
	var pipe := _mat(PIPE_COLOR, 0.35, 0.1)
	var chrome := _mat(HEAD_COLOR, 0.2, 0.8)
	var dark := _mat(Color(0.12, 0.12, 0.13), 0.7, 0.0)
	var curtains := Node3D.new()
	curtains.name = "Curtains"
	root.add_child(curtains)
	var sprays := Node3D.new()
	sprays.name = "Sprays"
	root.add_child(sprays)
	var curtain_names: Array = []
	var spray_names: Array = []
	for r in int(s["rows"]):
		_build_row(root, s, r, wall, frame, deck, roof, pipe, dark)
	for k in int(s["stalls"]):
		var f := stall_frame(s, k)
		var stall := Node3D.new()
		stall.name = "Stall%d" % k
		stall.position = Vector3(float(f["x"]), 0.0, float(f["z"]))
		# Row 1 is turned round: everything below is built curtain-on-+Z.
		if float(f["face"]) < 0.0:
			stall.rotation.y = PI
		root.add_child(stall)
		_build_stall(stall, chrome, pipe, dark)
		# The curtain: a pivot at the stall's -X jamb, the cloth hanging off
		# it toward +X. The runtime bunches it (scale x) to open it. Kept under
		# Curtains, out of the prop's collision.
		var pivot := Node3D.new()
		pivot.name = "C%d" % k
		var hinge_local := Vector3(-STALL_W * 0.5 + WALL_T, FLOOR_Y + CURTAIN_Y0, STALL_D * 0.5 - 0.02)
		pivot.transform = stall.transform * Transform3D(Basis(), hinge_local)
		pivot.scale = Vector3(CURTAIN_OPEN, 1.0, 1.0)
		curtains.add_child(pivot)
		var cw := STALL_W - WALL_T * 2.0
		var cloth := _box(Vector3(cw, CURTAIN_H, 0.015), Vector3(cw * 0.5, CURTAIN_H * 0.5, 0.0),
			_mat(CURTAIN_COLORS[(int(s["color"]) + k) % CURTAIN_COLORS.size()], 0.95, 0.0))
		cloth.name = "Cloth"
		cloth.set_meta("skip_prop_collision", true)
		pivot.add_child(cloth)
		curtain_names.append(pivot.name)
		# The water: a cone of drops from the head, off until someone is in.
		var spray := _spray()
		spray.name = "S%d" % k
		var head_local := Vector3(0.0, FLOOR_Y + HEAD_H - 0.04, -STALL_D * 0.5 + WALL_T + 0.22)
		spray.transform = stall.transform * Transform3D(Basis(), head_local)
		sprays.add_child(spray)
		spray_names.append(spray.name)
	_build_tank(root, s, pipe)
	root.set_meta("stall_spots", stall_spots(spec))
	root.set_meta("queue_line", queue_line(spec))
	root.set_meta("curtain_nodes", curtain_names)
	root.set_meta("spray_nodes", spray_names)
	root.set_meta("shower_spec", s)
	return root


## One row's deck, back wall, end walls, partitions, curtain rails and roof,
## built curtains-on-+Z (row 1 is the same turned round about the middle).
static func _build_row(root: Node3D, s: Dictionary, r: int, wall: Material, frame: Material,
		deck: Material, roof: Material, pipe: Material, dark: Material) -> void:
	var n := row_count(s, r)
	if n <= 0:
		return
	var row := Node3D.new()
	row.name = "Row%d" % r
	if int(s["rows"]) == 2:
		row.position = Vector3(0.0, 0.0, (STALL_D + BACK_GAP) * 0.5 * (1.0 if r == 0 else -1.0))
		if r == 1:
			row.rotation.y = PI
	root.add_child(row)
	var len_x := float(n) * STALL_W
	var hd := STALL_D * 0.5
	var wall_y := FLOOR_Y + WALL_H * 0.5
	# Deck on bearers: the stalls and the porch in front, slats across.
	var deck_d := STALL_D + PORCH
	var deck_z := -hd + deck_d * 0.5
	for bx: float in [-len_x * 0.5 + 0.1, 0.0, len_x * 0.5 - 0.1]:
		row.add_child(_box(Vector3(0.09, FLOOR_Y - 0.04, deck_d), Vector3(bx, (FLOOR_Y - 0.04) * 0.5, deck_z), frame))
	var slat_n := int(ceil(deck_d / 0.12))
	for i in slat_n:
		var z := -hd + (float(i) + 0.5) * deck_d / float(slat_n)
		var slat := _box(Vector3(len_x + WALL_T * 2.0, 0.04, 0.095), Vector3(0.0, FLOOR_Y - 0.02, z), deck)
		row.add_child(slat)
	# Back wall and the partitions (end walls included).
	row.add_child(_box(Vector3(len_x + WALL_T * 2.0, WALL_H, WALL_T), Vector3(0.0, wall_y, -hd + WALL_T * 0.5), wall))
	for i in n + 1:
		var x := -len_x * 0.5 + float(i) * STALL_W
		row.add_child(_box(Vector3(WALL_T, WALL_H, STALL_D), Vector3(x, wall_y, 0.0), wall))
	# Posts at the porch edge and the curtain rails between the partitions.
	for i in n + 1:
		var x2 := -len_x * 0.5 + float(i) * STALL_W
		if i == 0 or i == n or i % 2 == 0:
			row.add_child(_box(Vector3(0.08, WALL_H + 0.25, 0.08),
				Vector3(x2, FLOOR_Y + (WALL_H + 0.25) * 0.5, hd + PORCH - 0.06), frame))
	var rail := _box(Vector3(len_x, 0.025, 0.025), Vector3(0.0, FLOOR_Y + RAIL_H, hd - 0.02), pipe)
	rail.set_meta("skip_prop_collision", true)
	row.add_child(rail)
	# Shed roof: high over the porch, falling to the back wall (rain off the
	# back into the gutter), with a gutter.
	var rise := 0.30
	var roof_d := deck_d + 0.25
	var roof_y := FLOOR_Y + WALL_H + 0.10 + rise * 0.5
	var slope := atan2(rise, roof_d)
	var cap := _box(Vector3(len_x + 0.30, 0.05, roof_d / cos(slope)),
		Vector3(0.0, roof_y, -hd - 0.12 + roof_d * 0.5), roof)
	cap.rotation.x = -slope
	row.add_child(cap)
	for i in int(ceil(len_x / 0.25)):
		var x3 := -len_x * 0.5 + (float(i) + 0.5) * 0.25
		var rib := _box(Vector3(0.025, 0.02, roof_d / cos(slope)), Vector3(x3, roof_y + 0.035, -hd - 0.12 + roof_d * 0.5), roof)
		rib.rotation.x = -slope
		rib.set_meta("skip_prop_collision", true)
		row.add_child(rib)
	row.add_child(_box(Vector3(len_x + 0.30, 0.10, 0.12),
		Vector3(0.0, roof_y - rise * 0.5 - 0.02, -hd - 0.18), dark))
	# The header pipe along the back wall above the heads.
	var header := _cyl(0.022, len_x, pipe)
	header.rotation.z = PI * 0.5
	header.position = Vector3(0.0, FLOOR_Y + HEAD_H + 0.06, -hd + WALL_T + 0.05)
	header.set_meta("skip_prop_collision", true)
	row.add_child(header)
	# The drain line under the deck, out of the back to a soakaway.
	var drain := _cyl(0.05, len_x, dark)
	drain.rotation.z = PI * 0.5
	drain.position = Vector3(0.0, 0.05, -hd + 0.15)
	drain.set_meta("skip_prop_collision", true)
	row.add_child(drain)


## One stall's fittings, curtain on +Z, centred on the local origin.
static func _build_stall(stall: Node3D, chrome: Material, pipe: Material, dark: Material) -> void:
	var hd := STALL_D * 0.5
	var back := -hd + WALL_T
	# The riser down from the header, the head on its arm, the mixer.
	var riser := _cyl(0.012, 0.08, pipe)
	riser.position = Vector3(0.0, FLOOR_Y + HEAD_H + 0.03, back + 0.05)
	riser.set_meta("skip_prop_collision", true)
	stall.add_child(riser)
	var arm := _cyl(0.011, 0.20, pipe)
	arm.rotation.x = PI * 0.5
	arm.position = Vector3(0.0, FLOOR_Y + HEAD_H, back + 0.14)
	arm.set_meta("skip_prop_collision", true)
	stall.add_child(arm)
	var head := MeshInstance3D.new()
	var hc := CylinderMesh.new()
	hc.top_radius = 0.035
	hc.bottom_radius = 0.075
	hc.height = 0.05
	hc.radial_segments = 16
	head.mesh = hc
	head.position = Vector3(0.0, FLOOR_Y + HEAD_H - 0.02, back + 0.22)
	head.material_override = chrome
	head.set_meta("skip_prop_collision", true)
	stall.add_child(head)
	var mixer := _box(Vector3(0.10, 0.12, 0.05), Vector3(0.0, FLOOR_Y + 1.05, back + 0.025), chrome)
	mixer.set_meta("skip_prop_collision", true)
	stall.add_child(mixer)
	var lever := _box(Vector3(0.10, 0.015, 0.02), Vector3(0.04, FLOOR_Y + 1.05, back + 0.06), chrome)
	lever.set_meta("skip_prop_collision", true)
	stall.add_child(lever)
	# A soap shelf, a towel hook by the curtain and the drain.
	var shelf := _box(Vector3(0.22, 0.02, 0.10), Vector3(0.28, FLOOR_Y + 1.25, back + 0.05), chrome)
	shelf.set_meta("skip_prop_collision", true)
	stall.add_child(shelf)
	var hook := _box(Vector3(0.02, 0.06, 0.06), Vector3(STALL_W * 0.5 - WALL_T - 0.02, FLOOR_Y + 1.65, hd - 0.18), chrome)
	hook.set_meta("skip_prop_collision", true)
	stall.add_child(hook)
	var drain := _cyl(0.06, 0.012, dark)
	drain.position = Vector3(0.0, FLOOR_Y + 0.002, back + STAND_FROM_BACK)
	drain.set_meta("skip_prop_collision", true)
	stall.add_child(drain)


## The water tank on the roof: a black horizontal tank on a frame over the
## back of row 0 (a batch solar water heater: the sun warms it), or a white
## header tank. Its feed pipe drops to the header.
static func _build_tank(root: Node3D, s: Dictionary, pipe: Material) -> void:
	var solar := str(s["heater"]) == HEATER_SOLAR
	var n := row_count(s, 0)
	var len_x := float(n) * STALL_W
	var tank_len := clampf(len_x * 0.7, 0.9, 2.4)
	var z := -STALL_D * 0.5 + 0.35
	if int(s["rows"]) == 2:
		z = 0.0
	var top := FLOOR_Y + WALL_H + 0.10
	var tank := Node3D.new()
	tank.name = "WaterTank"
	tank.position = Vector3(0.0, top + 0.18, z)
	root.add_child(tank)
	var body := _cyl(0.30, tank_len, _mat(TANK_COLOR if solar else Color(0.92, 0.92, 0.90), 0.35, 0.2))
	body.rotation.z = PI * 0.5
	body.position = Vector3(0.0, 0.30, 0.0)
	body.set_meta("skip_prop_collision", true)
	tank.add_child(body)
	for sx: float in [-1.0, 1.0]:
		var leg := _box(Vector3(0.06, 0.32, 0.55), Vector3(sx * tank_len * 0.4, 0.0, 0.0), _mat(TIMBER_COLOR.darkened(0.2), 0.85, 0.0))
		leg.set_meta("skip_prop_collision", true)
		tank.add_child(leg)
	if solar:
		# A glazed collector panel on the porch side of the roof.
		var panel := _box(Vector3(clampf(len_x * 0.8, 0.9, 3.0), 0.06, 0.9),
			Vector3(0.0, 0.08, 0.85), _mat(Color(0.08, 0.10, 0.16), 0.15, 0.4))
		panel.rotation.x = -0.35
		panel.set_meta("skip_prop_collision", true)
		tank.add_child(panel)
	var feed := _cyl(0.02, 0.5, pipe)
	feed.position = Vector3(tank_len * 0.5 - 0.1, -0.08, -0.1)
	feed.set_meta("skip_prop_collision", true)
	tank.add_child(feed)


## The falling drops of one shower head (off until the runtime turns it on).
## Launched down at 1.5 m/s, they fall the ~1.9 m to the deck in 0.48 s.
static func _spray() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 56
	p.lifetime = 0.48
	p.emitting = false
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-0.6, -2.2, -0.6), Vector3(1.2, 2.4, 1.2))
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0.0, -1.0, 0.0)
	pm.spread = 13.0
	pm.initial_velocity_min = 1.3
	pm.initial_velocity_max = 1.7
	pm.gravity = Vector3(0.0, -9.8, 0.0)
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.045
	pm.scale_min = 0.7
	pm.scale_max = 1.2
	p.process_material = pm
	var q := QuadMesh.new()
	q.size = Vector2(0.012, 0.075)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	m.billboard_keep_scale = true
	m.albedo_color = Color(0.82, 0.90, 1.0, 0.55)
	q.material = m
	p.draw_pass_1 = q
	return p


static func _box(size: Vector3, at: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.position = at
	mi.material_override = mat
	return mi


static func _cyl(radius: float, length: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = radius
	c.bottom_radius = radius
	c.height = length
	c.radial_segments = 12
	mi.mesh = c
	mi.material_override = mat
	return mi


static func _mat(col: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.roughness = rough
	m.metallic = metal
	return m
