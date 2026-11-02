class_name SiteGateBuilder
extends RefCounted

## Procedural SITE GATE — two timber posts, a crossbeam and a sign: where the
## camp's vehicles drive in (VehicleDrive). The gate faces along its yaw: a
## vehicle passes through it heading the gate's forward (-Z), so the road in
## starts a little OUTSIDE it (`approach_xz`).
##
## Built from Godot primitive meshes (BoxMesh) — no hand-wound triangles.

const MODEL_ID := "site_gate"

const WIDTH_M := 6.0
const POST_M := 0.25
const HEIGHT_M := 4.2
const BEAM_H_M := 0.35
const SIGN_W_M := 2.6
const SIGN_H_M := 0.7
## Vehicles start this far outside the gate.
const OUTSIDE_M := 12.0

const WOOD := Color(0.30, 0.20, 0.12)
const SIGN := Color(0.86, 0.80, 0.62)


static func build_node(_spec: Dictionary = {}, node_name: String = "SiteGate") -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	var wood := _mat(WOOD)
	for sx in [-1.0, 1.0]:
		var post := MeshInstance3D.new()
		post.name = "Post%s" % ("L" if sx < 0.0 else "R")
		var bm := BoxMesh.new()
		bm.size = Vector3(POST_M, HEIGHT_M, POST_M)
		post.mesh = bm
		post.position = Vector3(sx * WIDTH_M * 0.5, HEIGHT_M * 0.5, 0.0)
		post.material_override = wood
		root.add_child(post)
	var beam := MeshInstance3D.new()
	beam.name = "Beam"
	var bb := BoxMesh.new()
	bb.size = Vector3(WIDTH_M + POST_M * 2.0, BEAM_H_M, POST_M)
	beam.mesh = bb
	beam.position = Vector3(0.0, HEIGHT_M - BEAM_H_M * 0.5, 0.0)
	beam.material_override = wood
	root.add_child(beam)
	var sign_mi := MeshInstance3D.new()
	sign_mi.name = "Sign"
	var sb := BoxMesh.new()
	sb.size = Vector3(SIGN_W_M, SIGN_H_M, 0.06)
	sign_mi.mesh = sb
	sign_mi.position = Vector3(0.0, HEIGHT_M - BEAM_H_M - SIGN_H_M * 0.5 - 0.05, 0.0)
	sign_mi.material_override = _mat(SIGN)
	root.add_child(sign_mi)
	var label := Label3D.new()
	label.name = "Label"
	label.text = "WELCOME HOME"
	label.font_size = 64
	label.pixel_size = 0.004
	label.modulate = Color(0.18, 0.10, 0.05)
	label.outline_size = 0
	label.position = sign_mi.position + Vector3(0.0, 0.0, 0.035)
	root.add_child(label)
	var back := label.duplicate() as Label3D
	back.name = "LabelBack"
	back.position = sign_mi.position - Vector3(0.0, 0.0, 0.035)
	back.rotation.y = PI
	root.add_child(back)
	return root


## Where a vehicle starts: outside the gate, behind it along its heading.
static func approach_xz(pos: Vector2, yaw_deg: float) -> Vector2:
	var yaw := deg_to_rad(yaw_deg)
	return pos - Vector2(-sin(yaw), -cos(yaw)) * OUTSIDE_M


static func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.85
	return m
