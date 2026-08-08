extends Node3D

## Tagged spaces, drawn on the ground in the settlement view.
##
## The only genuinely new overlay this view needs — people, work sites and
## desire lines all reuse what already exists (`NpcAvatar`s, the pooled crew
## markers on `NpcPopulationHost`, `NpcDesireOverlay`). Spaces are the
## exception because nothing renders them in 3D at all: they exist as polygons
## in `SpaceRegistry` and are drawn only on the 2D Site Plan.
##
## Terrain-following by construction: each triangulated vertex samples the
## ground under it. `TerrainBuilder.build_polygon_highlight` would be the
## obvious reuse, but it takes a DEM grid + extent rather than a height
## callable, and this view has to work on any scene including ones with no
## TerrainLoader — `TerrainSurfaceQuery.ground_height_at` covers both.

const LABEL_HEIGHT_M := 2.0
## Lift above the ground: enough to beat z-fighting on a sloped tile, small
## enough that the patch still reads as painted ON the ground.
const LIFT_M := 0.12

var _built_for := ""


## Rebuild from the live registry. Cheap enough to call on entry; the tagged
## set changes only when the player tags something.
func rebuild(main: Node) -> void:
	for c in get_children():
		c.queue_free()
	_built_for = ""
	var reg := _registry(main)
	if reg == null:
		return
	for sp in reg.spaces:
		var sd: Dictionary = sp
		var tgt: Dictionary = sd.get("target", {})
		if str(tgt.get("kind", "")) != "area":
			continue   # prop-anchored spaces are visible as their prop
		var poly: Array = tgt.get("poly", []) as Array
		if poly.size() < 3:
			continue
		var stype := str(sd.get("space_type", ""))
		var col: Color = SpaceTypes.COLORS.get(stype, Color(0.6, 0.7, 0.9))
		col.a = 0.30
		var pts := PackedVector2Array()
		for p in poly:
			var pa: Array = p
			pts.append(Vector2(float(pa[0]), float(pa[1])))
		var patch := _build_patch(main, pts, col)
		if patch != null:
			add_child(patch)
		var centre := SpaceRegistry.polygon_centroid(poly)
		var lbl := Label3D.new()
		lbl.text = "%s %s" % [str(SpaceTypes.ICONS.get(stype, "")),
			SpaceTypes.label(stype)]
		lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lbl.no_depth_test = true
		lbl.font_size = 36
		lbl.pixel_size = 0.007
		lbl.outline_size = 10
		lbl.modulate = SpaceTypes.COLORS.get(stype, Color.WHITE)
		lbl.position = Vector3(centre.x,
			TerrainSurfaceQuery.ground_height_at(main, centre.x, centre.y) + LABEL_HEIGHT_M,
			centre.y)
		add_child(lbl)
	_built_for = str(reg.spaces.size())


## One tinted, unshaded, terrain-following patch. Unshaded so the colour is
## the space's identity rather than whatever the sun is doing, and no depth
## write so overlapping spaces do not fight each other.
static func _build_patch(main: Node, pts: PackedVector2Array,
		col: Color) -> MeshInstance3D:
	var tris := Geometry2D.triangulate_polygon(pts)
	if tris.is_empty():
		return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in tris.size():
		var p := pts[tris[i]]
		st.set_color(col)
		st.add_vertex(Vector3(p.x,
			TerrainSurfaceQuery.ground_height_at(main, p.x, p.y) + LIFT_M, p.y))
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _registry(main: Node) -> SpaceRegistry:
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader != null:
		var reg: Variant = loader.get("npc_spaces")
		if reg is SpaceRegistry:
			return reg
	return null
