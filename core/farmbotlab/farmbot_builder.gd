class_name FarmBotBuilder
extends Node3D

## A FarmBot-style garden robot on its raised bed, as a scene.
##
## Frame (metres): origin on the ground under the middle of the bed, +X along
## the bed's length (the tracks), +Z across it. The machine's own coordinates
## (FarmBotJobs, mm) map to it as x_local = x/1000 − L/2, z_local = y/1000 − W/2
## and the tool tip's height = soil + (z − soil_z)/1000.
##
## Nodes:
##   Bed       walls + soil (collides)
##   Crops     one MultiMesh per crop at the layout's own positions, growing on
##             the garden crop shader (`set_days`)
##   Frame     the tracks on the wall tops and the tool bay
##   Gantry    (moves along X)  two columns, the black main beam, X motors,
##             the electronics box, the seed trough
##     CrossSlide (moves across)   the white cross-slide plate, Y motor
##       ZAxis    (moves up/down)  the white Z extrusion, Z motor, the tool
##                                 mount and its camera
##   Tools     one node per tool: in its slot, or on the tool mount
##   Spray     the water from the nozzle while watering
## `set_machine(pos_mm, tool, spray)` is the one pose call.
##
## RADIAL (the keyhole bed, FarmBotGeom): the keyhole's ring beds and compost
## basket, a centre post in the basket with the tool ring round it, a curved
## rail on the outer ring's wall, and per arm ("Arm<i>", turning about the
## post): a light triangle truss out to the rail, its outer leg on a driven
## wheel, a carriage running along the arm ("Carriage", local +Z = out) and the
## Z axis under it. `set_arm(i, pos_mm, tool, spray)` poses one arm;
## set_machine is arm 0.

const MODEL_ID := "farmbot"
const WALL_T := {"concrete": 0.10, "galvanized": 0.02, "timber": 0.05}
const WALL_COL := {"concrete": Color(0.64, 0.62, 0.58), "galvanized": Color(0.72, 0.74, 0.76),
	"timber": Color(0.52, 0.38, 0.24)}
const SOIL_BELOW_TOP := 0.04
const TRACK_W := 0.04
const TRACK_H := 0.06
const BEAM_W := 0.06
const BEAM_H := 0.09
const COLUMN_W := 0.06
const TOOL_LEN := 0.09
const UTM_H := 0.07
const COLS := {
	"alu": Color(0.78, 0.79, 0.8), "black": Color(0.07, 0.07, 0.08), "white": Color(0.93, 0.93, 0.92),
	"motor": Color(0.09, 0.09, 0.1), "chrome": Color(0.85, 0.86, 0.88), "soil": Color(0.2, 0.14, 0.09),
	"box": Color(0.94, 0.94, 0.93), "hose": Color(0.12, 0.12, 0.13), "tool": Color(0.88, 0.88, 0.86),
	"green": Color(0.25, 0.62, 0.32), "trough": Color(0.18, 0.18, 0.2), "wall": Color(0.64, 0.62, 0.58),
	"cap": Color(0.2, 0.55, 0.85),
}
const _CROP_SHADER := preload("res://vegetation/garden_crop.gdshader")
const TRUSS_H := 0.32
const TRUSS_W := 0.16
const RAIL_H := 0.035
const WHEEL_R := 0.06

var spec: Dictionary = {}
var design: Dictionary = {}
var gantry: Node3D
var cross: Node3D
var zaxis: Node3D
var tools: Dictionary = {}       # id -> Node3D
var spray: MeshInstance3D
var mounted := ""
var machine_pos := Vector3.ZERO
var _crop_mat: ShaderMaterial
var _L := 6.0
var _W := 3.0
var _soil_y := 0.38
var _beam_y := 1.28
var _radial := false
## Per arm: {node, carriage, z, tools: {id: Node3D}, spray, mounted, pos}.
## Arm 0 is also gantry / cross / zaxis / tools / spray above.
var arms: Array = []


static func build_node(p_spec: Dictionary = {}, node_name := "FarmBot") -> FarmBotBuilder:
	var n := FarmBotBuilder.new()
	n.name = node_name
	n.build(p_spec)
	return n


func build(p_spec: Dictionary) -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	tools = {}
	arms.clear()
	design = FarmBotDesign.solve(p_spec)
	spec = design["spec"]
	var b: Dictionary = spec["bed"]
	_L = float(b["length_m"])
	_W = float(b["width_m"])
	_soil_y = float(b["wall_h_m"]) - SOIL_BELOW_TOP
	_beam_y = _soil_y + float((spec["gantry"] as Dictionary)["clearance_m"])
	_radial = FarmBotGeom.is_radial(spec)
	var holder := Node3D.new()
	holder.name = "Tools"
	if _radial:
		_build_bed_radial()
		_build_crops()
		_build_frame_radial()
		add_child(holder)
		for i in FarmBotGeom.arm_count(spec):
			_build_arm(i)
			_build_tools(i, holder)
	else:
		_build_bed()
		_build_crops()
		_build_frame()
		_build_gantry()
		add_child(holder)
		_build_tools(0, holder)
	var a0: Dictionary = arms[0]
	gantry = a0["node"]
	cross = a0["carriage"]
	zaxis = a0["z"]
	tools = a0["tools"]
	spray = a0["spray"]
	set_meta("farmbot", true)
	for i2 in arms.size():
		set_arm(i2, FarmBotJobs.park_pos(spec, i2), "", false)


## Days since the bed was planted: what the crops show.
func set_days(d: float) -> void:
	if _crop_mat != null:
		_crop_mat.set_shader_parameter("now_d", d)


## The tool tip's height for a machine z (mm).
func tip_y(z_mm: float) -> float:
	return _soil_y + (z_mm - float((spec["gantry"] as Dictionary)["soil_z_mm"])) / 1000.0


## A machine point (mm) in the builder's frame.
func machine_to_local(p: Vector3) -> Vector3:
	var b := FarmBotGeom.to_bed(spec, p.x, p.y)
	return Vector3(b.x, tip_y(p.z), b.y)


## Pose: arm 0 at `p` (mm), `tool` on the mount ("" = none).
func set_machine(p: Vector3, tool: String, sprays: bool) -> void:
	set_arm(0, p, tool, sprays)


## Every arm from FarmBotJobs.sample_arms.
func set_arms(samples: Array) -> void:
	for i in mini(samples.size(), arms.size()):
		var r: Dictionary = samples[i]
		set_arm(i, r["pos"], str(r["tool"]), bool(r["spray"]))


## Pose one arm (machine mm).
func set_arm(i: int, p: Vector3, tool: String, sprays: bool) -> void:
	if i < 0 or i >= arms.size():
		return
	var e: Dictionary = arms[i]
	e["pos"] = p
	var lp := machine_to_local(p)
	if _radial:
		(e["node"] as Node3D).rotation.y = FarmBotGeom.arm_angle(spec, p.x)
		(e["carriage"] as Node3D).position = Vector3(0.0, 0.0, p.y / 1000.0)
	else:
		(e["node"] as Node3D).position = Vector3(lp.x, 0.0, 0.0)
		(e["carriage"] as Node3D).position = Vector3(0.0, 0.0, lp.z)
	(e["z"] as Node3D).position = Vector3(0.0, lp.y + TOOL_LEN, 0.0)
	if tool != str(e["mounted"]):
		e["mounted"] = tool
		for id in (e["tools"] as Dictionary).keys():
			_place_tool(i, str(id))
	elif tool != "":
		_place_tool(i, tool)
	var sp: MeshInstance3D = e["spray"]
	sp.visible = sprays
	if sprays:
		var drop := maxf(lp.y - _soil_y, 0.02)
		sp.position = Vector3(lp.x, lp.y - drop * 0.5, lp.z)
		sp.scale = Vector3(1.0, drop, 1.0)
	if i == 0:
		machine_pos = p
		mounted = tool


## Where arm 0's tool tip is now (builder frame).
func tip_local() -> Vector3:
	return machine_to_local(machine_pos)


func _place_tool(arm: int, id: String) -> void:
	var e: Dictionary = arms[arm]
	var n: Node3D = (e["tools"] as Dictionary).get(id)
	if n == null:
		return
	if id == str(e["mounted"]):
		n.position = machine_to_local(e["pos"])
	else:
		n.position = machine_to_local(FarmBotJobs.slot_of(spec, id, arm))


# --- parts ----------------------------------------------------------------

func _build_bed() -> void:
	var b: Dictionary = spec["bed"]
	var wall := str(b["wall"])
	var t := float(WALL_T.get(wall, 0.1))
	var h := float(b["wall_h_m"])
	var sts := {}
	var w := GantryLabDetail._st(sts, "wall")
	var L := _L
	var W := _W
	# Long walls, then the end walls between them.
	for sz: float in [-1.0, 1.0]:
		GantryLabDetail.box(w, Vector3(0.0, h * 0.5, sz * (W * 0.5 + t * 0.5)), Vector3(L + 2.0 * t, h, t))
	for sx: float in [-1.0, 1.0]:
		GantryLabDetail.box(w, Vector3(sx * (L * 0.5 + t * 0.5), h * 0.5, 0.0), Vector3(t, h, W))
	if wall == "galvanized":
		# Corrugation ribs and a rolled top edge.
		var rib := GantryLabDetail._st(sts, "wall")
		var n := int(L / 0.076)
		for i in n:
			var x := -L * 0.5 + (float(i) + 0.5) * L / float(n)
			for sz2: float in [-1.0, 1.0]:
				GantryLabDetail.box(rib, Vector3(x, h * 0.5, sz2 * (W * 0.5 + t + 0.006)), Vector3(0.03, h * 0.96, 0.012))
	GantryLabDetail.box(GantryLabDetail._st(sts, "soil"), Vector3(0.0, _soil_y * 0.5, 0.0), Vector3(L, _soil_y, W))
	var mi := MeshInstance3D.new()
	mi.name = "Bed"
	mi.mesh = _commit(sts, {"wall": WALL_COL.get(wall, COLS["wall"])}, wall == "galvanized")
	add_child(mi)


func _build_crops() -> void:
	var holder := Node3D.new()
	holder.name = "Crops"
	add_child(holder)
	_crop_mat = ShaderMaterial.new()
	_crop_mat.shader = _CROP_SHADER
	var by: Dictionary = {}
	var lay: Dictionary = design["layout"]
	for p in (lay["plants"] as Array):
		var crop := str(p["crop"])
		if not by.has(crop):
			by[crop] = []
		(by[crop] as Array).append(p)
	for crop in by.keys():
		var list: Array = by[crop]
		var info := GardenCrops.info(str(crop))
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = GardenCrops.mesh(str(crop))
		mm.instance_count = list.size()
		for i in list.size():
			var e: Dictionary = list[i]
			var hseed := fposmod(float(hash("%s:%d" % [crop, i])) / 2147483647.0, 1.0)
			var bas := Basis(Vector3.UP, hseed * TAU).scaled(Vector3.ONE * (0.9 + 0.2 * fposmod(hseed * 7.31, 1.0)))
			mm.set_instance_transform(i, Transform3D(bas, Vector3(float(e["x"]), _soil_y, float(e["z"]))))
			mm.set_instance_custom_data(i, Color(float(e["sow_d"]), float(info["cycle"]), float(info["mature"]), hseed))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Crop_%s" % str(crop)
		mmi.multimesh = mm
		mmi.material_override = _crop_mat
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if bool(info.get("shadow", false)) \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visibility_range_end = GrowBed.CROP_DRAW_M
		mmi.visibility_range_end_margin = 10.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		mmi.set_meta("skip_prop_collision", true)
		holder.add_child(mmi)


func _build_frame() -> void:
	var b: Dictionary = spec["bed"]
	var t := float(WALL_T.get(str(b["wall"]), 0.1))
	var h := float(b["wall_h_m"])
	var sts := {}
	var alu := GantryLabDetail._st(sts, "alu")
	for sz: float in [-1.0, 1.0]:
		var z := sz * (_W * 0.5 + t * 0.5)
		GantryLabDetail.box(alu, Vector3(0.0, h + TRACK_H * 0.5, z), Vector3(_L + 0.1, TRACK_H, TRACK_W))
		# The track's top slot, darker.
		GantryLabDetail.box(GantryLabDetail._st(sts, "black"), Vector3(0.0, h + TRACK_H + 0.001, z),
			Vector3(_L + 0.1, 0.002, 0.008))
	# The tool bay: a rail on the wall top with a slot for each tool.
	var tb := GantryLabDetail._st(sts, "black")
	var y0 := tip_y(FarmBotJobs.slot_of(spec, "seeder").z)
	var x_end := FarmBotJobs.SLOT_X0_MM + FarmBotJobs.SLOT_PITCH_MM * float(FarmBotJobs.TOOL_ORDER.size() - 1)
	var lx0 := FarmBotJobs.SLOT_X0_MM / 1000.0 - 0.1 - _L * 0.5
	var lx1 := x_end / 1000.0 + 0.1 - _L * 0.5
	var zb := FarmBotJobs.SLOT_Y_MM / 1000.0 - _W * 0.5
	GantryLabDetail.box_ab(tb, Vector3(lx0, y0 + TOOL_LEN - 0.012, zb - 0.06), Vector3(lx1, y0 + TOOL_LEN, zb + 0.03))
	for sx: float in [lx0, lx1]:
		GantryLabDetail.box_ab(tb, Vector3(sx - 0.01, h, zb - 0.06), Vector3(sx + 0.01, y0 + TOOL_LEN, zb - 0.04))
	var mi := MeshInstance3D.new()
	mi.name = "Frame"
	mi.mesh = _commit(sts, {}, false)
	add_child(mi)


func _build_gantry() -> void:
	var b: Dictionary = spec["bed"]
	var t := float(WALL_T.get(str(b["wall"]), 0.1))
	var h := float(b["wall_h_m"])
	gantry = Node3D.new()
	gantry.name = "Gantry"
	add_child(gantry)
	var sts := {}
	var blk := GantryLabDetail._st(sts, "black")
	var alu := GantryLabDetail._st(sts, "alu")
	var zc := _W * 0.5 + t * 0.5
	var top := _beam_y + BEAM_H
	for sz: float in [-1.0, 1.0]:
		var z := sz * zc
		# The carriage on the track and the column up to the beam.
		GantryLabDetail.box(alu, Vector3(0.0, h + TRACK_H + 0.012, z), Vector3(0.16, 0.02, 0.09))
		GantryLabDetail.box(alu, Vector3(0.0, (h + TRACK_H + top) * 0.5, z), Vector3(COLUMN_W, top - h - TRACK_H, 0.02))
		GantryLabDetail.box(alu, Vector3(0.0, (h + TRACK_H + top) * 0.5, z - sz * 0.025), Vector3(0.02, top - h - TRACK_H, 0.03))
		# X motor on the carriage, shaft across toward the track.
		GantryLabDetail.emit(sts, {"kind": "motor", "frame": 0.042, "len": 0.04,
			"c": Vector3(0.11, h + TRACK_H + 0.04, z), "basis": GantryLabDetail.basis_y(Vector3(0, 0, -sz))})
		# Wheels on the track.
		for sx: float in [-0.06, 0.06]:
			GantryLabDetail.cyl(GantryLabDetail._st(sts, "black"), Vector3(sx, h + TRACK_H * 0.5, z - 0.03),
				Vector3(sx, h + TRACK_H * 0.5, z - 0.018), 0.018, 14)
			GantryLabDetail.cyl(GantryLabDetail._st(sts, "black"), Vector3(sx, h + TRACK_H * 0.5, z + 0.018),
				Vector3(sx, h + TRACK_H * 0.5, z + 0.03), 0.018, 14)
	# The main beam across the bed (black, as on the Genesis).
	GantryLabDetail.box(blk, Vector3(0.0, _beam_y + BEAM_H * 0.5, 0.0), Vector3(BEAM_W, BEAM_H, 2.0 * zc + 0.04))
	GantryLabDetail.box(GantryLabDetail._st(sts, "alu"), Vector3(0.0, _beam_y + BEAM_H + 0.003, 0.0),
		Vector3(BEAM_W * 0.5, 0.006, 2.0 * zc))
	# The electronics box on the -Z column, and the cable carrier along it.
	var bx := GantryLabDetail._st(sts, "box")
	GantryLabDetail.box(bx, Vector3(-0.09, _beam_y - 0.2, -zc - 0.06), Vector3(0.12, 0.26, 0.09))
	GantryLabDetail.box(GantryLabDetail._st(sts, "cap"), Vector3(-0.09, _beam_y - 0.07, -zc - 0.105), Vector3(0.05, 0.01, 0.002))
	GantryLabDetail.box(GantryLabDetail._st(sts, "hose"), Vector3(0.0, _beam_y + BEAM_H + 0.03, 0.0),
		Vector3(0.035, 0.03, 2.0 * zc))
	# The seed trough on the beam's far side.
	var tz := _W * 0.5 - FarmBotJobs.TROUGH_IN_MM / 1000.0
	var ty := tip_y(float((spec["gantry"] as Dictionary)["soil_z_mm"]) + FarmBotJobs.TOOL_ABOVE_SOIL_MM)
	GantryLabDetail.box(GantryLabDetail._st(sts, "trough"), Vector3(0.0, ty - 0.012, tz), Vector3(0.12, 0.024, 0.07))
	GantryLabDetail.box_ab(GantryLabDetail._st(sts, "alu"), Vector3(-0.01, ty, tz - 0.01), Vector3(0.01, _beam_y, tz + 0.01))
	var gm := MeshInstance3D.new()
	gm.name = "GantryMesh"
	gm.mesh = _commit(sts, {}, false)
	gm.set_meta("skip_prop_collision", true)
	gantry.add_child(gm)
	# The cross-slide: a white plate riding the beam, its motor on top.
	cross = Node3D.new()
	cross.name = "CrossSlide"
	gantry.add_child(cross)
	var cs := {}
	var wh := GantryLabDetail._st(cs, "white")
	GantryLabDetail.box(wh, Vector3(0.05, _beam_y + BEAM_H * 0.5, 0.0), Vector3(0.012, BEAM_H + 0.05, 0.14))
	GantryLabDetail.box(wh, Vector3(-0.05, _beam_y + BEAM_H * 0.5, 0.0), Vector3(0.012, BEAM_H + 0.05, 0.14))
	GantryLabDetail.box(wh, Vector3(0.0, _beam_y + BEAM_H + 0.03, 0.0), Vector3(0.11, 0.012, 0.14))
	GantryLabDetail.emit(cs, {"kind": "motor", "frame": 0.042, "len": 0.04,
		"c": Vector3(0.0, _beam_y + BEAM_H + 0.036, 0.04), "basis": GantryLabDetail.basis_y(Vector3.DOWN)})
	var cm := MeshInstance3D.new()
	cm.name = "CrossMesh"
	cm.mesh = _commit(cs, {}, false)
	cm.set_meta("skip_prop_collision", true)
	cross.add_child(cm)
	# The Z axis: a white extrusion through the cross-slide, the tool mount
	# at its foot. Built in a frame whose origin is the tool mount's bottom.
	zaxis = Node3D.new()
	zaxis.name = "ZAxis"
	cross.add_child(zaxis)
	var zs := {}
	var zt := float((spec["gantry"] as Dictionary)["z_travel_mm"]) / 1000.0
	GantryLabDetail.box(GantryLabDetail._st(zs, "white"), Vector3(0.075, UTM_H + zt * 0.5 + 0.06, 0.0),
		Vector3(0.04, zt + 0.12, 0.04))
	GantryLabDetail.emit(zs, {"kind": "motor", "frame": 0.042, "len": 0.04,
		"c": Vector3(0.075, UTM_H + zt + 0.12, 0.0), "basis": GantryLabDetail.basis_y(Vector3.DOWN)})
	# The universal tool mount: magnets underneath, the camera on its side.
	GantryLabDetail.box(GantryLabDetail._st(zs, "white"), Vector3(0.03, UTM_H * 0.5, 0.0), Vector3(0.1, UTM_H, 0.07))
	GantryLabDetail.cyl(GantryLabDetail._st(zs, "black"), Vector3(-0.025, 0.002, 0.0), Vector3(-0.025, UTM_H - 0.01, 0.0), 0.012, 12)
	GantryLabDetail.cyl(GantryLabDetail._st(zs, "chrome"), Vector3(0.0, -0.002, 0.0), Vector3(0.0, 0.004, 0.0), 0.022, 16)
	var zm := MeshInstance3D.new()
	zm.name = "ZMesh"
	zm.mesh = _commit(zs, {}, false)
	zm.set_meta("skip_prop_collision", true)
	zaxis.add_child(zm)
	# Water from the nozzle (a unit-height column, scaled to the drop).
	spray = MeshInstance3D.new()
	spray.name = "Spray"
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.006
	cyl.bottom_radius = 0.05
	cyl.height = 1.0
	cyl.radial_segments = 12
	cyl.rings = 1
	spray.mesh = cyl
	var wm := StandardMaterial3D.new()
	wm.albedo_color = Color(0.55, 0.75, 0.95, 0.35)
	wm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wm.cull_mode = BaseMaterial3D.CULL_DISABLED
	spray.material_override = wm
	spray.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	spray.visible = false
	spray.set_meta("skip_prop_collision", true)
	add_child(spray)
	arms.append({"node": gantry, "carriage": cross, "z": zaxis, "tools": {}, "spray": spray, "mounted": "",
		"pos": Vector3.ZERO})


func _build_tools(arm: int, holder: Node3D) -> void:
	var e: Dictionary = arms[arm]
	for id in FarmBotJobs.TOOL_ORDER:
		if not bool((spec["tools"] as Dictionary).get(id, false)):
			continue
		var sts := {}
		var tl := GantryLabDetail._st(sts, "tool")
		# Body: origin at the tip, up to the mount.
		GantryLabDetail.cyl(tl, Vector3(0, TOOL_LEN * 0.45, 0), Vector3(0, TOOL_LEN, 0), 0.024, 14)
		GantryLabDetail.cyl(GantryLabDetail._st(sts, "chrome"), Vector3(0, TOOL_LEN - 0.003, 0), Vector3(0, TOOL_LEN, 0), 0.02, 14)
		match str(id):
			"seeder":
				GantryLabDetail.cyl(GantryLabDetail._st(sts, "chrome"), Vector3.ZERO, Vector3(0, TOOL_LEN * 0.45, 0), 0.003, 8)
				GantryLabDetail.cyl(GantryLabDetail._st(sts, "green"), Vector3(0.022, TOOL_LEN * 0.7, 0), Vector3(0.04, TOOL_LEN * 0.8, 0), 0.004, 8)
			"watering":
				GantryLabDetail.cyl(GantryLabDetail._st(sts, "cap"), Vector3.ZERO, Vector3(0, TOOL_LEN * 0.45, 0), 0.012, 12)
			"weeder":
				for k: float in [-1.0, 1.0]:
					GantryLabDetail.box(GantryLabDetail._st(sts, "chrome"), Vector3(k * 0.012, TOOL_LEN * 0.22, 0), Vector3(0.004, TOOL_LEN * 0.45, 0.012))
			"soil_sensor":
				for k2: float in [-1.0, 1.0]:
					GantryLabDetail.cyl(GantryLabDetail._st(sts, "chrome"), Vector3(k2 * 0.008, 0, 0), Vector3(k2 * 0.008, TOOL_LEN * 0.45, 0), 0.0025, 6)
				GantryLabDetail.box(GantryLabDetail._st(sts, "green"), Vector3(0, TOOL_LEN * 0.5, 0), Vector3(0.03, 0.015, 0.006))
			"rotary":
				GantryLabDetail.cyl(GantryLabDetail._st(sts, "black"), Vector3(0, 0.0, 0), Vector3(0, 0.006, 0), 0.03, 16)
				GantryLabDetail.cyl(GantryLabDetail._st(sts, "chrome"), Vector3(0, 0.006, 0), Vector3(0, TOOL_LEN * 0.45, 0), 0.005, 8)
		var mi := MeshInstance3D.new()
		mi.name = "Tool_%s" % str(id) if arm == 0 else "Tool%d_%s" % [arm, str(id)]
		mi.mesh = _commit(sts, {}, false)
		mi.set_meta("skip_prop_collision", true)
		holder.add_child(mi)
		(e["tools"] as Dictionary)[str(id)] = mi
		_place_tool(arm, str(id))


# --- the radial robot -----------------------------------------------------

func _build_bed_radial() -> void:
	var k := FarmBotGeom.keyhole(spec)
	var shell := GrowBedShell.new()
	shell.disc(float(k["outer_r"]) + 0.35, Color(0.52, 0.42, 0.3), 0.025)
	for r in FarmBotGeom.rings(spec):
		var rr: Dictionary = r
		shell.ring_bed(float(rr["r0"]), float(rr["r1"]), float(rr["a0"]), float(rr["a1"]), float(k["wall_h"]), true, true)
	shell.compost_basket(float(k["centre_r"]) * 0.5, 0.85)
	var mi := MeshInstance3D.new()
	mi.name = "Bed"
	mi.mesh = shell.commit()
	add_child(mi)


func _build_frame_radial() -> void:
	var k := FarmBotGeom.keyhole(spec)
	var h := float(k["wall_h"])
	var rr := FarmBotGeom.rail_r(spec)
	var sw := FarmBotGeom.sweep(spec)
	var sts := {}
	var alu := GantryLabDetail._st(sts, "alu")
	# The rail: a flat bar rolled to the radius on the outer wall's top.
	var n := maxi(int(ceilf(sw.y * rr / 0.3)), 8)
	for i in n:
		var a0 := sw.x + sw.y * float(i) / float(n)
		var a1 := sw.x + sw.y * float(i + 1) / float(n)
		GantryLabDetail.bar(alu, Vector3(sin(a0) * rr, h + RAIL_H * 0.5, cos(a0) * rr),
			Vector3(sin(a1) * rr, h + RAIL_H * 0.5, cos(a1) * rr), 0.03, RAIL_H)
	# Brackets holding it to the wall every metre or so.
	var nb := maxi(int(sw.y * rr / 1.2), 4)
	for j in nb + 1:
		var a := sw.x + sw.y * float(j) / float(nb)
		GantryLabDetail.bar(GantryLabDetail._st(sts, "black"), Vector3(sin(a) * (rr - 0.04), h - 0.06, cos(a) * (rr - 0.04)),
			Vector3(sin(a) * (rr + 0.02), h + 0.005, cos(a) * (rr + 0.02)), 0.04, 0.008)
	# The centre post (in the compost basket) and its bearing at the top.
	var top := _beam_y + TRUSS_H + 0.08
	GantryLabDetail.box(alu, Vector3(0.0, top * 0.5, 0.0), Vector3(0.1, top, 0.1))
	GantryLabDetail.cyl(GantryLabDetail._st(sts, "black"), Vector3(0, top - 0.03, 0), Vector3(0, top + 0.05, 0), 0.12, 20)
	# The tool ring round the post: a hoop at tool height on four spokes.
	var tr := FarmBotGeom.tool_r(spec)
	var ty := tip_y(float((spec["gantry"] as Dictionary)["soil_z_mm"]) + FarmBotJobs.TOOL_ABOVE_SOIL_MM) + TOOL_LEN
	var blk := GantryLabDetail._st(sts, "black")
	for i2 in 36:
		var b0 := TAU * float(i2) / 36.0
		var b1 := TAU * float(i2 + 1) / 36.0
		GantryLabDetail.bar(blk, Vector3(sin(b0) * tr, ty, cos(b0) * tr), Vector3(sin(b1) * tr, ty, cos(b1) * tr), 0.025, 0.012)
	for i3 in 4:
		var c := TAU * (float(i3) + 0.5) / 4.0
		GantryLabDetail.bar(blk, Vector3(sin(c) * 0.05, ty, cos(c) * 0.05), Vector3(sin(c) * tr, ty, cos(c) * tr), 0.02, 0.012)
	var mi := MeshInstance3D.new()
	mi.name = "Frame"
	mi.mesh = _commit(sts, {}, false)
	add_child(mi)


func _build_arm(i: int) -> void:
	var k := FarmBotGeom.keyhole(spec)
	var h := float(k["wall_h"])
	var rr := FarmBotGeom.rail_r(spec)
	var arm := Node3D.new()
	arm.name = "Arm%d" % i
	add_child(arm)
	# The truss, in the arm's frame (+Z out from the post).
	var sts := {}
	var alu := GantryLabDetail._st(sts, "alu")
	var z0 := 0.14
	var y0 := _beam_y
	var y1 := _beam_y + TRUSS_H
	var hw := TRUSS_W * 0.5
	for sx: float in [-hw, hw]:
		GantryLabDetail.cyl(alu, Vector3(sx, y0, z0), Vector3(sx, y0, rr), 0.016, 8)
	GantryLabDetail.cyl(alu, Vector3(0, y1, z0), Vector3(0, y1, rr), 0.02, 8)
	var nd := maxi(int((rr - z0) / 0.45), 2)
	for j in nd + 1:
		var z := lerpf(z0, rr, float(j) / float(nd))
		var zn := lerpf(z0, rr, float(mini(j + 1, nd)) / float(nd))
		for sx2: float in [-hw, hw]:
			GantryLabDetail.cyl(alu, Vector3(sx2, y0, z), Vector3(0, y1, z), 0.008, 6)
			if j < nd:
				GantryLabDetail.cyl(alu, Vector3(sx2, y0, z), Vector3(0, y1, zn), 0.007, 6)
		GantryLabDetail.cyl(alu, Vector3(-hw, y0, z), Vector3(hw, y0, z), 0.007, 6)
	# The hub on the post's bearing.
	GantryLabDetail.box(GantryLabDetail._st(sts, "black"), Vector3(0, (y0 + y1) * 0.5, 0.0), Vector3(0.26, TRUSS_H + 0.06, 0.26))
	# The outer leg down to the wheel on the rail, the drive motor beside it.
	var wy := h + RAIL_H + WHEEL_R
	GantryLabDetail.box(alu, Vector3(0, (wy + y1) * 0.5, rr), Vector3(0.05, y1 - wy, 0.05))
	GantryLabDetail.cyl(GantryLabDetail._st(sts, "black"), Vector3(-0.025, wy, rr), Vector3(0.025, wy, rr), WHEEL_R, 18)
	GantryLabDetail.emit(sts, {"kind": "motor", "frame": 0.042, "len": 0.05,
		"c": Vector3(0.05, wy, rr), "basis": GantryLabDetail.basis_y(Vector3(-1, 0, 0))})
	# The controller on the leg, the cable along the top chord.
	GantryLabDetail.box(GantryLabDetail._st(sts, "box"), Vector3(0.0, y0 - 0.2, rr - 0.08), Vector3(0.12, 0.24, 0.08))
	GantryLabDetail.cyl(GantryLabDetail._st(sts, "hose"), Vector3(0, y1 + 0.03, z0), Vector3(0, y1 + 0.03, rr), 0.012, 6)
	# The seed trough under the arm, over a path.
	var trz := FarmBotGeom.trough_r(spec)
	var t_y := tip_y(float((spec["gantry"] as Dictionary)["soil_z_mm"]) + FarmBotJobs.TOOL_ABOVE_SOIL_MM)
	GantryLabDetail.box(GantryLabDetail._st(sts, "trough"), Vector3(0.0, t_y - 0.012, trz), Vector3(0.07, 0.024, 0.12))
	GantryLabDetail.box_ab(alu, Vector3(-0.01, t_y, trz - 0.01), Vector3(0.01, y0, trz + 0.01))
	var am := MeshInstance3D.new()
	am.name = "ArmMesh"
	am.mesh = _commit(sts, {}, false)
	am.set_meta("skip_prop_collision", true)
	arm.add_child(am)
	# The carriage riding the bottom chords, its motor on top.
	var car := Node3D.new()
	car.name = "Carriage"
	arm.add_child(car)
	var cs := {}
	var wh := GantryLabDetail._st(cs, "white")
	for sx3: float in [-1.0, 1.0]:
		GantryLabDetail.box(wh, Vector3(sx3 * (hw + 0.02), y0 + 0.02, 0.0), Vector3(0.012, 0.12, 0.16))
	GantryLabDetail.box(wh, Vector3(0.0, y0 - 0.035, 0.0), Vector3(TRUSS_W + 0.06, 0.012, 0.16))
	GantryLabDetail.emit(cs, {"kind": "motor", "frame": 0.042, "len": 0.04,
		"c": Vector3(hw + 0.05, y0 + 0.05, 0.0), "basis": GantryLabDetail.basis_y(Vector3(-1, 0, 0))})
	var cm := MeshInstance3D.new()
	cm.name = "CarriageMesh"
	cm.mesh = _commit(cs, {}, false)
	cm.set_meta("skip_prop_collision", true)
	car.add_child(cm)
	var zn2 := Node3D.new()
	zn2.name = "ZAxis"
	car.add_child(zn2)
	var zs := {}
	var zt := float((spec["gantry"] as Dictionary)["z_travel_mm"]) / 1000.0
	GantryLabDetail.box(GantryLabDetail._st(zs, "white"), Vector3(0.0, UTM_H + zt * 0.5 + 0.06, -0.06),
		Vector3(0.04, zt + 0.12, 0.04))
	GantryLabDetail.emit(zs, {"kind": "motor", "frame": 0.042, "len": 0.04,
		"c": Vector3(0.0, UTM_H + zt + 0.12, -0.06), "basis": GantryLabDetail.basis_y(Vector3.DOWN)})
	GantryLabDetail.box(GantryLabDetail._st(zs, "white"), Vector3(0.0, UTM_H * 0.5, -0.02), Vector3(0.07, UTM_H, 0.1))
	GantryLabDetail.cyl(GantryLabDetail._st(zs, "black"), Vector3(0.0, 0.002, 0.025), Vector3(0.0, UTM_H - 0.01, 0.025), 0.012, 12)
	GantryLabDetail.cyl(GantryLabDetail._st(zs, "chrome"), Vector3(0.0, -0.002, 0.0), Vector3(0.0, 0.004, 0.0), 0.022, 16)
	var zm := MeshInstance3D.new()
	zm.name = "ZMesh"
	zm.mesh = _commit(zs, {}, false)
	zm.set_meta("skip_prop_collision", true)
	zn2.add_child(zm)
	var sp := _make_spray()
	sp.name = "Spray" if i == 0 else "Spray%d" % i
	add_child(sp)
	arms.append({"node": arm, "carriage": car, "z": zn2, "tools": {}, "spray": sp, "mounted": "", "pos": Vector3.ZERO})


func _make_spray() -> MeshInstance3D:
	var sp := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.006
	cyl.bottom_radius = 0.05
	cyl.height = 1.0
	cyl.radial_segments = 12
	cyl.rings = 1
	sp.mesh = cyl
	var wm := StandardMaterial3D.new()
	wm.albedo_color = Color(0.55, 0.75, 0.95, 0.35)
	wm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	wm.cull_mode = BaseMaterial3D.CULL_DISABLED
	sp.material_override = wm
	sp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	sp.visible = false
	sp.set_meta("skip_prop_collision", true)
	return sp


func _commit(sts: Dictionary, over: Dictionary, metal_wall: bool) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for key in sts.keys():
		var st: SurfaceTool = sts[key]
		st.commit(mesh)
		var col: Color = over.get(key, COLS.get(key, Color(0.5, 0.5, 0.5)))
		var mat_id := "powder_coat"
		match str(key):
			"alu": mat_id = "aluminium"
			"chrome": mat_id = "stainless"
			"soil": mat_id = "concrete"
			"wall": mat_id = "metal_roofing" if metal_wall else "lumber"
			"hose": mat_id = "rubber"
			"black", "trough": mat_id = "plastic"
			"motor": mat_id = "powder_coat"
		var m := ParametricMaterialLibrary.make(mat_id, col)
		mesh.surface_set_material(mesh.get_surface_count() - 1, m)
	return mesh
