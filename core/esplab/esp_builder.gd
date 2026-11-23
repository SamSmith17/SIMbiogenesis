class_name EspBuilder
extends RefCounted

## A placed ESP board in the world: a sensor station on a stake. The board in
## a grey enclosure at the top (the PCB drawn at its real size behind a clear
## lid), each part where it would really go:
##   air / light sensors in a louvred radiation shield under the enclosure;
##   a distance sensor on an arm, looking DOWN (over a tank or the ground);
##   soil probes in the ground beside the stake;
##   a relay, buzzer or servo on the enclosure's side; a screen on its front;
##   an LED strip down the stake; a float switch / flow meter / scale as a
##   small module at the stake's foot (their cables go to whatever they
##   measure).
##
## Built from primitive meshes (no hand-wound triangles). Metas the runtime
## reads: `sensor_points` {iid: local position}, `distance_points`
## {iid: local position} (rays go straight down from there), `label_y`.

const MODEL_ID := "esplab_board"
const STAKE_H := 1.2
const BOX := Vector3(0.18, 0.13, 0.07)
const BOX_Y := 1.08

const C_STAKE := Color(0.42, 0.31, 0.20)
const C_BOX := Color(0.78, 0.80, 0.80)
const C_PCB := Color(0.06, 0.32, 0.18)
const C_MODULE := Color(0.10, 0.25, 0.62)
const C_BLACK := Color(0.05, 0.05, 0.06)
const C_SILVER := Color(0.75, 0.76, 0.78)
const C_RELAY := Color(0.12, 0.30, 0.75)
const C_SHIELD := Color(0.93, 0.93, 0.91)


static func handles(model_id: String) -> bool:
	return model_id == MODEL_ID


static func build_node(spec_in: Dictionary, node_name: String = "EspBoard") -> Node3D:
	var spec := EspSpec.resolve(spec_in)
	var board := EspBoards.get_board(str(spec["board"]))
	var root := Node3D.new()
	root.name = node_name
	var sensors := {}
	var dists := {}
	# Stake and enclosure.
	_box(root, "Stake", Vector3(0.05, STAKE_H, 0.05), Vector3(0, STAKE_H * 0.5, 0), C_STAKE, 0.85)
	_box(root, "Enclosure", BOX, Vector3(0, BOX_Y, 0.06), C_BOX, 0.6)
	var mm: Array = board.get("size_mm", [28.0, 52.0])
	var pcb := Vector3(float(mm[0]) * 0.001, float(mm[1]) * 0.001, 0.0016)
	var pcb_scale := minf(1.0, minf((BOX.x - 0.02) / pcb.x, (BOX.y - 0.02) / pcb.y))
	_box(root, "Board", Vector3(pcb.x * pcb_scale, pcb.y * pcb_scale, pcb.z), Vector3(0, BOX_Y, 0.06 + BOX.z * 0.5 + 0.002), C_PCB, 0.7)
	_box(root, "Module", Vector3(0.018 * pcb_scale, 0.025 * pcb_scale, 0.003), Vector3(0, BOX_Y + pcb.y * pcb_scale * 0.25, 0.06 + BOX.z * 0.5 + 0.004), C_SILVER, 0.3)
	_cyl(root, "Antenna", 0.004, 0.12, Vector3(BOX.x * 0.4, BOX_Y + BOX.y * 0.5 + 0.06, 0.06), C_BLACK)
	# Parts.
	var shield_n := 0
	var side_n := 0
	var ground_n := 0
	var foot_n := 0
	for inst in spec["parts"]:
		var iid := str(inst["iid"])
		var part := EspParts.get_part(str(inst["part"]))
		var cat := str(part.get("cat", ""))
		var pid := str(inst["part"])
		if pid in ["hcsr04", "jsnsr04t", "vl53l0x"]:
			# On an arm out from the stake, looking down.
			var arm_y := 0.9 - 0.08 * float(dists.size())
			_box(root, "Arm_%s" % iid, Vector3(0.3, 0.02, 0.02), Vector3(0.18, arm_y, 0), C_STAKE, 0.85)
			var at := Vector3(0.32, arm_y - 0.02, 0)
			_box(root, "Part_%s" % iid, Vector3(0.045, 0.004, 0.02), at, C_MODULE, 0.6)
			if pid != "vl53l0x":
				for sx in [-0.013, 0.013]:
					_cyl(root, "Eye_%s_%d" % [iid, int(sx * 1000)], 0.008, 0.012, at + Vector3(sx, -0.008, 0), C_SILVER)
			dists[iid] = at + Vector3(0, -0.015, 0)
			sensors[iid] = at
		elif cat in ["env", "air", "light"] and pid not in ["ds18b20", "max6675"]:
			if shield_n == 0:
				for k in 5:
					_cyl(root, "Shield_%d" % k, 0.06, 0.012, Vector3(0, BOX_Y - BOX.y * 0.5 - 0.05 - 0.022 * float(k), 0.06), C_SHIELD, 0.009)
			var y := BOX_Y - BOX.y * 0.5 - 0.07 - 0.02 * float(shield_n)
			_box(root, "Part_%s" % iid, Vector3(0.022, 0.016, 0.003), Vector3(0, y, 0.06), C_MODULE if cat != "light" else C_BLACK, 0.6)
			sensors[iid] = Vector3(0, y, 0.06)
			shield_n += 1
		if pid == "soil_cap":
			var gx := -0.15 - 0.09 * float(ground_n)
			_box(root, "Part_%s" % iid, Vector3(0.022, 0.1, 0.002), Vector3(gx, 0.03, 0.05), C_BLACK, 0.6)
			sensors[iid] = Vector3(gx, -0.03, 0.05)
			ground_n += 1
		elif pid in ["relay_1ch", "buzzer", "servo_sg90"]:
			var sy := BOX_Y + 0.04 - 0.045 * float(side_n)
			_box(root, "Part_%s" % iid, Vector3(0.02, 0.04, 0.05), Vector3(BOX.x * 0.5 + 0.012, sy, 0.06), C_RELAY if pid == "relay_1ch" else C_BLACK, 0.5)
			sensors[iid] = Vector3(BOX.x * 0.5 + 0.012, sy, 0.06)
			side_n += 1
		elif pid == "ssd1306":
			_box(root, "Part_%s" % iid, Vector3(0.027, 0.027, 0.003), Vector3(-BOX.x * 0.3, BOX_Y - 0.02, 0.06 + BOX.z * 0.5 + 0.003), C_BLACK, 0.3)
			var scr := _box(root, "Screen_%s" % iid, Vector3(0.024, 0.012, 0.001), Vector3(-BOX.x * 0.3, BOX_Y - 0.02, 0.06 + BOX.z * 0.5 + 0.0048), Color(0.2, 0.8, 1.0), 0.2)
			(scr.material_override as StandardMaterial3D).emission_enabled = true
			(scr.material_override as StandardMaterial3D).emission = Color(0.2, 0.7, 1.0)
			sensors[iid] = Vector3(-BOX.x * 0.3, BOX_Y - 0.02, 0.09)
		elif pid == "ws2812":
			for k in 8:
				var led := _box(root, "Led_%s_%d" % [iid, k], Vector3(0.012, 0.012, 0.004), Vector3(0, 0.15 + 0.08 * float(k), 0.027), Color(1, 0.6, 0.3), 0.3)
				(led.material_override as StandardMaterial3D).emission_enabled = true
				(led.material_override as StandardMaterial3D).emission = Color(1.0, 0.55, 0.25) * 0.6
			sensors[iid] = Vector3(0, 0.5, 0.03)
		elif not sensors.has(iid):
			# Probes and modules whose cable runs off to what they measure.
			var fx := 0.08 + 0.05 * float(foot_n)
			_box(root, "Part_%s" % iid, Vector3(0.03, 0.02, 0.03), Vector3(fx, 0.03, -0.05), C_MODULE if cat != "env" else C_SILVER, 0.6)
			sensors[iid] = Vector3(fx, 0.03, -0.05)
			foot_n += 1
	root.set_meta("sensor_points", sensors)
	root.set_meta("distance_points", dists)
	root.set_meta("label_y", STAKE_H + 0.35)
	root.set_meta("esp_board", true)
	return root


static func _mat(c: Color, rough: float) -> StandardMaterial3D:
	var metal := 0.75 if rough < 0.35 else 0.05
	var mat_id := StructureMaterials.infer_id(c, metal, rough, c.a)
	return ParametricMaterialLibrary.make(mat_id, c)


static func _box(root: Node3D, name: String, size: Vector3, at: Vector3, c: Color, rough: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.position = at
	mi.material_override = _mat(c, rough)
	root.add_child(mi)
	return mi


static func _cyl(root: Node3D, name: String, r: float, h: float, at: Vector3, c: Color, r2: float = -1.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name
	var cy := CylinderMesh.new()
	cy.top_radius = r if r2 < 0.0 else r2 * 6.0
	cy.bottom_radius = r
	cy.height = h
	cy.radial_segments = 12
	cy.rings = 1
	mi.mesh = cy
	mi.position = at
	mi.material_override = _mat(c, 0.5)
	root.add_child(mi)
	return mi


## The board's power (W): the design's 5 V draw.
static func power_w(spec: Dictionary) -> float:
	var d := EspDesign.solve(spec)
	return float((d["power"] as Dictionary).get("ma_5v", 250.0)) * 5.0 / 1000.0
