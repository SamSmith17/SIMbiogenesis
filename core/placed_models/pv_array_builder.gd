class_name PvArrayBuilder
extends RefCounted

## A placeable ground-mount PV array (model id "pv_array"): `cols × rows`
## modules on a tilted rack, built FACING local +Z — which is due SOUTH at
## yaw 0 (CelestialClock: north −Z, east +X). The prop's yaw turns it; the
## rack's tilt is part of its spec. Its orientation is what the energy model
## uses for this array (`orientation_for`), so turning the rack in the world
## changes the plane-of-array irradiance.
##
## Spec keys (all optional): count, cols, rows, tilt_deg, panel_w_m,
## panel_h_m, mount_style, plus the module's electrical keys (wmp, voc, vmp,
## isc, imp) which ride along to the graph array it binds to.

const MODEL_ID := "pv_array"
## JA Solar JAM60S20 module: 1769 × 1052 mm (portrait: long side up-slope).
const DEFAULT_PANEL_W_M := 1.052
const DEFAULT_PANEL_H_M := 1.769
const DEFAULT_TILT_DEG := 35.0
const DEFAULT_COUNT := 9


static func resolve_spec(spec: Dictionary) -> Dictionary:
	var s := spec.duplicate(true)
	var count := maxi(int(s.get("count", DEFAULT_COUNT)), 1)
	var cols := int(s.get("cols", 0))
	var rows := int(s.get("rows", 0))
	if cols <= 0 and rows <= 0:
		cols = count if count <= 12 else int(ceil(sqrt(float(count) * 2.0)))
	if cols <= 0:
		cols = int(ceil(float(count) / float(maxi(rows, 1))))
	rows = int(ceil(float(count) / float(cols)))
	s["count"] = count
	s["cols"] = cols
	s["rows"] = rows
	s["tilt_deg"] = clampf(float(s.get("tilt_deg", DEFAULT_TILT_DEG)), 0.0, 90.0)
	s["panel_w_m"] = maxf(float(s.get("panel_w_m", DEFAULT_PANEL_W_M)), 0.2)
	s["panel_h_m"] = maxf(float(s.get("panel_h_m", DEFAULT_PANEL_H_M)), 0.2)
	s["mount_style"] = SolarArrayBuilder.resolve_mount_style(str(s.get("mount_style", SolarArrayBuilder.MOUNT_GROUND)))
	return s


## Panel centres (local xz), centred on the origin, rows marching north (−Z)
## so the front row is nearest the sun.
static func layout(spec: Dictionary) -> Array:
	var s := resolve_spec(spec)
	var count := int(s["count"])
	var cols := int(s["cols"])
	var rows := int(s["rows"])
	var pw := float(s["panel_w_m"])
	var ph := float(s["panel_h_m"])
	var tilt := deg_to_rad(float(s["tilt_deg"]))
	var step_x := pw + SolarArrayBuilder.GAP_X
	var step_z := ph * cos(tilt) + SolarArrayBuilder.ROW_GAP
	var out: Array = []
	for r in rows:
		for c in cols:
			if out.size() >= count:
				break
			out.append({
				"x": (float(c) - float(cols - 1) * 0.5) * step_x,
				"z": (float(rows - 1) * 0.5 - float(r)) * step_z,
			})
	return out


static func build_node(spec: Dictionary) -> Node3D:
	var s := resolve_spec(spec)
	var panels := layout(s)
	var root := SolarArrayBuilder.build_array_node("PvArray", panels, 0.0,
			float(s["tilt_deg"]), {"panel_w_m": float(s["panel_w_m"]), "panel_h_m": float(s["panel_h_m"])},
			str(s["mount_style"]))
	root.set_meta("pv_array_spec", s)
	root.add_child(_collision_mesh(panels, s))
	return root


## Hidden solid of the tilted modules: PlacedProp builds its collision and
## pick bounds from MeshInstance3D children, and MultiMesh panels have none.
static func _collision_mesh(panels: Array, s: Dictionary) -> MeshInstance3D:
	var defs := SolarArrayBuilder.mount_defaults(str(s["mount_style"]))
	var rack_h := float(defs.get("rack_height_m", 0.5))
	var tilt := deg_to_rad(float(s["tilt_deg"]))
	var ph := float(s["panel_h_m"])
	var box := BoxMesh.new()
	box.size = Vector3(float(s["panel_w_m"]), 0.08, ph)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var basis := Basis(Vector3.RIGHT, tilt)
	var rise := ph * 0.5 * sin(tilt)
	for p_v in panels:
		var p: Dictionary = p_v
		st.append_from(box, 0, Transform3D(basis, Vector3(float(p["x"]), rack_h + rise, float(p["z"]))))
	var mi := MeshInstance3D.new()
	mi.name = "CollisionMesh"
	mi.visible = false
	mi.mesh = st.commit()
	return mi


## The array's plane: tilt from horizontal and the compass azimuth its face
## points to (0 = N, 90 = E, 180 = S), for a prop at `yaw_deg` (Godot yaw
## about +Y, as PlacedProp applies it). Pure — the same answer whether the
## prop is built or not.
static func orientation_for(yaw_deg: float, tilt_deg: float) -> Dictionary:
	var t := deg_to_rad(clampf(tilt_deg, 0.0, 90.0))
	var n_local := Vector3(0.0, cos(t), sin(t))
	var n_world := Basis(Vector3.UP, deg_to_rad(yaw_deg)) * n_local
	var az := 180.0
	if Vector2(n_world.x, n_world.z).length() > 1e-4:
		az = fposmod(rad_to_deg(atan2(n_world.x, -n_world.z)), 360.0)
	return {"tilt_deg": clampf(tilt_deg, 0.0, 90.0), "azimuth_deg": az}


## Prop yaw that makes the array face compass azimuth `az_deg` (inverse of
## orientation_for).
static func yaw_for_azimuth(az_deg: float) -> float:
	return fposmod(180.0 - az_deg, 360.0)
