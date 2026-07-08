class_name SolarArrayBuilder
extends RefCounted

## Turns an OSM rooftop/ground PV array footprint (a local-metres polygon) into a
## packed grid of physical solar panels for the 3D world, plus the derived array
## sizing (panel count, peak kW, tilt, azimuth) that drives SolarUI and the system
## graph (ROADMAP Pillar 1 — real on-site generation from real-world data).
##
## Convention matches the terrain mesh: +X east, +Z south (north is −Z). Panels are
## laid out in south-facing rows (canonical fixed-tilt array) and tilted about the
## east–west (X) axis so their face normal points south + up.

## Modern ~400 W module (EcoFlow 400W Rigid class): ~1.05 m × 1.76 m ≈ 1.85 m².
const PANEL_W := 1.05          # east–west width (m)
const PANEL_H := 1.76          # up-slope length (m)
const PANEL_WATTS := 400.0
const PANEL_THICKNESS := 0.04
const GAP_X := 0.04            # spacing between panels in a row (m)
const ROW_GAP := 0.35          # anti-shading gap between rows (m)
const ROOF_CLEARANCE := 0.12   # rack height above the roof/ground base (m)
const EDGE_INSET := 0.4        # keep panel centres this far inside the footprint (m)


## Latitude-tuned fixed annual-optimal tilt (Lave & Kleissl 2011 fit), clamped.
static func default_tilt_deg(lat_deg: float) -> float:
	return clampf(absf(lat_deg) * 0.76 + 3.1, 5.0, 50.0)


## Azimuth the panels face, in SolarUI's convention (180 = due south). Arrays are
## oriented equatorward: south (180) in the N hemisphere, north (0) in the S.
static func default_azimuth_deg(lat_deg: float) -> float:
	return 180.0 if lat_deg >= 0.0 else 0.0


static func centroid(poly: PackedVector2Array) -> Vector2:
	if poly.is_empty():
		return Vector2.ZERO
	var c := Vector2.ZERO
	for p in poly:
		c += p
	return c / float(poly.size())


## Pack south-facing panel rows into `poly`. Returns local centres [{x, z}] for each
## panel whose centre sits inside the footprint. `tilt_deg` foreshortens row pitch.
static func plan_panels(poly: PackedVector2Array, tilt_deg: float) -> Array:
	var out: Array = []
	if poly.size() < 3:
		return out
	var min_x := poly[0].x
	var max_x := poly[0].x
	var min_z := poly[0].y
	var max_z := poly[0].y
	for p in poly:
		min_x = minf(min_x, p.x); max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.y); max_z = maxf(max_z, p.y)
	min_x += EDGE_INSET; max_x -= EDGE_INSET
	min_z += EDGE_INSET; max_z -= EDGE_INSET
	if max_x <= min_x or max_z <= min_z:
		return out
	var tilt := deg_to_rad(tilt_deg)
	var step_x := PANEL_W + GAP_X
	var step_z := PANEL_H * cos(tilt) + ROW_GAP
	if step_x <= 0.0 or step_z <= 0.0:
		return out
	
	# Safety check: prevent freeze if footprint is extremely large or malformed
	var iter_x := int(ceil((max_x - min_x) / step_x))
	var iter_z := int(ceil((max_z - min_z) / step_z))
	if iter_x <= 0 or iter_z <= 0 or iter_x * iter_z > 100000:
		push_warning("SolarArrayBuilder: plan_panels footprint too large or invalid (%dx%d iterations)" % [iter_x, iter_z])
		return out
		
	var z := min_z + step_z * 0.5
	while z <= max_z:
		var x := min_x + step_x * 0.5
		while x <= max_x:
			var p := Vector2(x, z)
			if Geometry2D.is_point_in_polygon(p, poly):
				out.append({"x": x, "z": z})
			x += step_x
		z += step_z
	return out


static func summarize(panel_count: int) -> Dictionary:
	return {
		"count": panel_count,
		"watts": PANEL_WATTS,
		"capacity_kw": float(panel_count) * PANEL_WATTS / 1000.0,
	}


## Build a node holding all panels as one MultiMesh, placed at world base_y, tilted
## `tilt_deg` and facing south (+Z). `panels` is the output of plan_panels().
static func build_array_node(node_name: String, panels: Array, base_y: float,
		tilt_deg: float) -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	if panels.is_empty():
		return root
	var tilt := deg_to_rad(tilt_deg)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(PANEL_W, PANEL_THICKNESS, PANEL_H)
	mesh.material = _panel_material()

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = panels.size()
	# Rotate about +X so the panel face tilts toward +Z (south) and up; lift the
	# centre so the low (south) edge sits near base_y + clearance.
	var rise := PANEL_H * 0.5 * sin(tilt)
	var basis := Basis(Vector3.RIGHT, tilt)
	for i in panels.size():
		var rec: Dictionary = panels[i]
		var origin := Vector3(float(rec["x"]),
			base_y + ROOF_CLEARANCE + rise, float(rec["z"]))
		mm.set_instance_transform(i, Transform3D(basis, origin))

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Panels"
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(mmi)
	return root


static func _panel_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.04, 0.06, 0.16)
	mat.metallic = 0.35
	mat.metallic_specular = 0.6
	mat.roughness = 0.28
	return mat
