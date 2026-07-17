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
##
## Mount styles (Wave 7):
##   ground_mount — raised rack posts, latitude-optimal tilt
##   roof_mount   — shallow rack clearance, latitude tilt (pitched roof arrays)
##   flat_mount   — near-flush, low/near-zero tilt (flat roof ballasted)

## Modern ~400 W module (EcoFlow 400W Rigid class): ~1.05 m × 1.76 m ≈ 1.85 m².
const PANEL_W := 1.05          # east–west width (m)
const PANEL_H := 1.76          # up-slope length (m)
const PANEL_WATTS := 400.0
const PANEL_VOC := 48.0
const PANEL_VMP := 41.0
const PANEL_ISC := 11.0
const PANEL_IMP := 9.76
const PANEL_THICKNESS := 0.04
const GAP_X := 0.04            # spacing between panels in a row (m)
const ROW_GAP := 0.35          # anti-shading gap between rows (m)
const ROOF_CLEARANCE := 0.12   # legacy default rack height (m)
const EDGE_INSET := 0.4        # keep panel centres this far inside the footprint (m)

const MOUNT_GROUND := "ground_mount"
const MOUNT_ROOF := "roof_mount"
const MOUNT_FLAT := "flat_mount"
const MOUNT_STYLES: Array[String] = [MOUNT_GROUND, MOUNT_ROOF, MOUNT_FLAT]


## Default module geometry + electricals used when the player hasn't overridden dims.
static func default_panel_spec() -> Dictionary:
	return {
		"panel_w_m": PANEL_W,
		"panel_h_m": PANEL_H,
		"panel_watts": PANEL_WATTS,
		"gap_x_m": GAP_X,
		"row_gap_m": ROW_GAP,
		"voc": PANEL_VOC,
		"vmp": PANEL_VMP,
		"isc": PANEL_ISC,
		"imp": PANEL_IMP,
	}


## Merge user overrides onto defaults. Accepts legacy keys (w/h/watts) too.
static func resolve_panel_spec(overrides: Dictionary = {}) -> Dictionary:
	var spec := default_panel_spec()
	if overrides.is_empty():
		return spec
	if overrides.has("panel_w_m"):
		spec["panel_w_m"] = float(overrides["panel_w_m"])
	elif overrides.has("w"):
		spec["panel_w_m"] = float(overrides["w"])
	if overrides.has("panel_h_m"):
		spec["panel_h_m"] = float(overrides["panel_h_m"])
	elif overrides.has("h"):
		spec["panel_h_m"] = float(overrides["h"])
	if overrides.has("panel_watts"):
		spec["panel_watts"] = float(overrides["panel_watts"])
	elif overrides.has("watts"):
		spec["panel_watts"] = float(overrides["watts"])
	if overrides.has("gap_x_m"):
		spec["gap_x_m"] = float(overrides["gap_x_m"])
	elif overrides.has("gap_x"):
		spec["gap_x_m"] = float(overrides["gap_x"])
	if overrides.has("row_gap_m"):
		spec["row_gap_m"] = float(overrides["row_gap_m"])
	elif overrides.has("row_gap"):
		spec["row_gap_m"] = float(overrides["row_gap"])
	for k in ["voc", "vmp", "isc", "imp"]:
		if overrides.has(k):
			spec[k] = float(overrides[k])
	spec["panel_w_m"] = maxf(0.2, float(spec["panel_w_m"]))
	spec["panel_h_m"] = maxf(0.2, float(spec["panel_h_m"]))
	spec["panel_watts"] = maxf(1.0, float(spec["panel_watts"]))
	spec["gap_x_m"] = maxf(0.0, float(spec["gap_x_m"]))
	spec["row_gap_m"] = maxf(0.0, float(spec["row_gap_m"]))
	return spec


## Normalize a mount_style id; unknown → ground_mount.
static func resolve_mount_style(style: String) -> String:
	var s := style.strip_edges().to_lower()
	if s in MOUNT_STYLES:
		return s
	if s in ["ground", "grounded", "pole"]:
		return MOUNT_GROUND
	if s in ["roof", "rooftop", "pitched"]:
		return MOUNT_ROOF
	if s in ["flat", "ballast", "flush"]:
		return MOUNT_FLAT
	return MOUNT_GROUND


## Infer mount style from OSM generator tags (location / mounting).
static func infer_mount_style(tags: Dictionary) -> String:
	var loc := str(tags.get("location", "")).to_lower()
	var mounting := str(tags.get("generator:mounting",
			tags.get("mounting", ""))).to_lower()
	if loc == "roof" or mounting.contains("roof"):
		if mounting.contains("flat") or mounting.contains("flush") \
				or mounting.contains("ballast"):
			return MOUNT_FLAT
		return MOUNT_ROOF
	if mounting.contains("flat") or mounting.contains("flush"):
		return MOUNT_FLAT
	if loc == "ground" or mounting.contains("ground") or mounting.contains("pole"):
		return MOUNT_GROUND
	# Default: ground arrays unless OSM said roof.
	return MOUNT_ROOF if loc == "roof" else MOUNT_GROUND


## Per-style defaults: tilt override (−1 = use latitude-optimal), rack height, label.
static func mount_defaults(mount_style: String, lat_deg: float = 35.0) -> Dictionary:
	var style := resolve_mount_style(mount_style)
	var lat_tilt := default_tilt_deg(lat_deg)
	match style:
		MOUNT_GROUND:
			return {
				"mount_style": MOUNT_GROUND,
				"label": "Ground mount",
				"tilt_deg": lat_tilt,
				"rack_height_m": 1.2,
				"show_rack_posts": true,
				"row_gap_scale": 1.0,
			}
		MOUNT_ROOF:
			return {
				"mount_style": MOUNT_ROOF,
				"label": "Roof mount",
				"tilt_deg": lat_tilt,
				"rack_height_m": 0.18,
				"show_rack_posts": false,
				"row_gap_scale": 0.85,
			}
		MOUNT_FLAT:
			return {
				"mount_style": MOUNT_FLAT,
				"label": "Flat mount",
				"tilt_deg": 5.0,
				"rack_height_m": 0.08,
				"show_rack_posts": false,
				"row_gap_scale": 0.55,
			}
	return mount_defaults(MOUNT_GROUND, lat_deg)


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
## Optional `panel_spec` overrides module width/height/gap/row-gap (see resolve_panel_spec).
static func plan_panels(poly: PackedVector2Array, tilt_deg: float,
		panel_spec: Dictionary = {}) -> Array:
	var out: Array = []
	if poly.size() < 3:
		return out
	var spec := resolve_panel_spec(panel_spec)
	var panel_w := float(spec["panel_w_m"])
	var panel_h := float(spec["panel_h_m"])
	var gap_x := float(spec["gap_x_m"])
	var row_gap := float(spec["row_gap_m"])
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
	var step_x := panel_w + gap_x
	var step_z := panel_h * cos(tilt) + row_gap
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


## Max panels that fit in `poly` for the given module dims (does not exceed footprint).
static func count_panels_for_footprint(poly: PackedVector2Array, tilt_deg: float,
		panel_spec: Dictionary = {}) -> int:
	return plan_panels(poly, tilt_deg, panel_spec).size()


static func summarize(panel_count: int, watts: float = PANEL_WATTS) -> Dictionary:
	return {
		"count": panel_count,
		"watts": watts,
		"capacity_kw": float(panel_count) * watts / 1000.0,
	}


## Build a node holding all panels as one MultiMesh, placed at world base_y, tilted
## `tilt_deg` and facing south (+Z). `panels` is the output of plan_panels().
## Optional `mount_style` adds rack posts / adjusts clearance for presentation.
static func build_array_node(node_name: String, panels: Array, base_y: float,
		tilt_deg: float, panel_spec: Dictionary = {},
		mount_style: String = MOUNT_ROOF) -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	root.set_meta("mount_style", resolve_mount_style(mount_style))
	if panels.is_empty():
		return root
	var style := resolve_mount_style(mount_style)
	var defs := mount_defaults(style)
	var rack_h := float(defs["rack_height_m"])
	var spec := resolve_panel_spec(panel_spec)
	var panel_w := float(spec["panel_w_m"])
	var panel_h := float(spec["panel_h_m"])
	var tilt := deg_to_rad(tilt_deg)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(panel_w, PANEL_THICKNESS, panel_h)
	mesh.material = _panel_material()

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = panels.size()
	# Rotate about +X so the panel face tilts toward +Z (south) and up; lift the
	# centre so the low (south) edge sits near base_y + clearance.
	var rise := panel_h * 0.5 * sin(tilt)
	var basis := Basis(Vector3.RIGHT, tilt)
	for i in panels.size():
		var rec: Dictionary = panels[i]
		var origin := Vector3(float(rec["x"]),
			base_y + rack_h + rise, float(rec["z"]))
		mm.set_instance_transform(i, Transform3D(basis, origin))

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Panels"
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(mmi)

	if bool(defs.get("show_rack_posts", false)):
		_attach_rack_posts(root, panels, base_y, rack_h, panel_w, panel_h, tilt)

	return root


## Sample rail/post presentation for ground-mount arrays (not structural FEA).
static func _attach_rack_posts(root: Node3D, panels: Array, base_y: float,
		rack_h: float, panel_w: float, panel_h: float, tilt: float) -> void:
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.06, maxf(rack_h, 0.2), 0.06)
	post_mesh.material = _rack_material()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = post_mesh
	# Two posts per panel (leading + trailing edge). Cap for dense arrays.
	var n := mini(panels.size() * 2, 400)
	mm.instance_count = n
	var i := 0
	for rec in panels:
		if i >= n:
			break
		var x := float(rec["x"])
		var z := float(rec["z"])
		var half_z := panel_h * 0.5 * cos(tilt)
		for dz in [-half_z * 0.7, half_z * 0.7]:
			if i >= n:
				break
			mm.set_instance_transform(i, Transform3D(Basis.IDENTITY,
				Vector3(x, base_y + rack_h * 0.5, z + dz)))
			i += 1
	mm.instance_count = i
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "RackPosts"
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	root.add_child(mmi)


static func _panel_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.04, 0.06, 0.16)
	mat.metallic = 0.35
	mat.metallic_specular = 0.6
	mat.roughness = 0.28
	return mat


static func _rack_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.45, 0.48, 0.52)
	mat.metallic = 0.75
	mat.roughness = 0.4
	return mat
