class_name DrumBuilder
extends RefCounted
## A 55-gallon drum: the body cylinder, two rolling hoops (steel) or moulded
## ribs (HDPE), the chimes top and bottom, and two bungs on a tight head or a
## clamp ring on an open head. Floor at y = 0.

const STEEL := Color(0.16, 0.30, 0.55)
const HDPE := Color(0.20, 0.36, 0.70)
const RIM := Color(0.55, 0.57, 0.60)
const BUNG := Color(0.12, 0.12, 0.12)


static func emit(mesh: ArrayMesh, entry: Dictionary) -> void:
	var ex: Dictionary = entry.get("exterior", {})
	var d := float(ex.get("l_m", 0.585))
	var h := float(ex.get("h_m", 0.88))
	var p: Dictionary = entry.get("params", {})
	var steel := str(p.get("material", "steel")) == "steel"
	var open_head := str(p.get("head", "tight")) == "open"
	var r := d * 0.5
	var body := IntermodalMeshKit.new()
	var rim := IntermodalMeshKit.new()
	var bung := IntermodalMeshKit.new()
	body.cylinder(Vector3(0, h * 0.5, 0), r - 0.01, h - 0.02, Vector3.UP, 28)
	for f in [1.0 / 3.0, 2.0 / 3.0]:
		var hoop := rim if steel else body
		hoop.cylinder(Vector3(0, h * f, 0), r, 0.025, Vector3.UP, 28, false)
	rim.cylinder(Vector3(0, 0.01, 0), r, 0.02, Vector3.UP, 28)
	rim.cylinder(Vector3(0, h - 0.01, 0), r, 0.02, Vector3.UP, 28)
	if open_head:
		rim.cylinder(Vector3(0, h - 0.02, 0), r + 0.008, 0.035, Vector3.UP, 28, false)
	else:
		bung.cylinder(Vector3(r * 0.55, h + 0.005, 0), 0.035, 0.012, Vector3.UP, 12)
		bung.cylinder(Vector3(-r * 0.55, h + 0.005, 0), 0.022, 0.012, Vector3.UP, 12)
	body.commit(mesh, STEEL if steel else HDPE, 0.3 if steel else 0.0, 0.5)
	rim.commit(mesh, RIM, 0.7, 0.4)
	bung.commit(mesh, BUNG, 0.0, 0.7)
