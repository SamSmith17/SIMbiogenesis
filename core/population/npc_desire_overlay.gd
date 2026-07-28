class_name NpcDesireOverlay
extends MeshInstance3D

## Desire lines draped on the terrain (POPULATION_PLAN.md Tier 3f).
##
## One terrain-following mesh over the desire map's rect, with world-XZ UVs
## baked straight into the vertices — so registration is the mesh itself and
## there is no bbox uniform to keep in sync (unlike the terrain drape shader's
## lat/lon patches). Texture updates are a single uniform set; the mesh is
## only rebuilt when the region actually moves.
##
## Deliberately grid-tessellated rather than reusing
## TerrainBuilder.build_polygon_highlight, which only samples the polygon's
## own corners and therefore floats or sinks over rolling ground.
##
## Cost: one mesh, one material, one texture upload per refresh. It is built
## lazily on first enable and freed on disable, so a player who never opens
## the view pays nothing.

const SHADER := preload("res://core/population/npc_desire_drape.gdshader")

## Tessellation. Fine enough to hug terrain, coarse enough that the one-off
## ground sampling (a raycast per vertex on scenes with no TerrainLoader)
## stays cheap.
const STEP_M := 6.0
const MAX_SPAN_CELLS := 96
## Lift above the ground so the drape never z-fights the terrain it sits on.
const LIFT_M := 0.18

var _rect := Rect2()
var _mat: ShaderMaterial = null


func _ready() -> void:
	name = "NpcDesireOverlay"
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	gi_mode = GeometryInstance3D.GI_MODE_DISABLED


## Rebuild the draped mesh for `rect` (world XZ). No-op when the region has
## not moved — this is the expensive part.
func rebuild(main: Node, rect: Rect2) -> void:
	if main == null or rect.size.x <= 0.0 or rect.size.y <= 0.0:
		return
	if _rect.is_equal_approx(rect) and mesh != null:
		return
	_rect = rect
	var nx := clampi(int(ceil(rect.size.x / STEP_M)), 2, MAX_SPAN_CELLS)
	var nz := clampi(int(ceil(rect.size.y / STEP_M)), 2, MAX_SPAN_CELLS)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Sample the ground once per vertex, then stitch quads from the cache.
	var ys := PackedFloat32Array()
	ys.resize((nx + 1) * (nz + 1))
	for iz in nz + 1:
		for ix in nx + 1:
			var w := _vertex_xz(ix, iz, nx, nz)
			ys[iz * (nx + 1) + ix] = TerrainSurfaceQuery.ground_height_at(main, w.x, w.y) + LIFT_M
	for iz in nz:
		for ix in nx:
			_quad(st, ix, iz, nx, nz, ys)
	st.generate_normals()
	mesh = st.commit()
	if _mat == null:
		_mat = ShaderMaterial.new()
		_mat.shader = SHADER
	material_override = _mat


func _vertex_xz(ix: int, iz: int, nx: int, nz: int) -> Vector2:
	return _rect.position + Vector2(
			_rect.size.x * float(ix) / float(nx),
			_rect.size.y * float(iz) / float(nz))


func _quad(st: SurfaceTool, ix: int, iz: int, nx: int, nz: int,
		ys: PackedFloat32Array) -> void:
	var stride := nx + 1
	for tri in [[0, 0, 1, 0, 1, 1], [0, 0, 1, 1, 0, 1]]:
		for k in 3:
			var ox := int(tri[k * 2])
			var oz := int(tri[k * 2 + 1])
			var gx := ix + ox
			var gz := iz + oz
			var w := _vertex_xz(gx, gz, nx, nz)
			# UV IS the registration: world position normalised over the rect.
			st.set_uv(Vector2(float(gx) / float(nx), float(gz) / float(nz)))
			st.add_vertex(Vector3(w.x, ys[gz * stride + gx], w.y))


## Swap in the latest heat texture. Cheap — one uniform set, no mesh work.
func set_heat(tex: Texture2D, strength: float = 1.0) -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("heat_tex", tex)
	_mat.set_shader_parameter("strength", strength)
	visible = tex != null
