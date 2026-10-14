class_name SoiRimSun
extends MeshInstance3D

## The water-cycle emblem's rim sun: a disc pinned just off the SoI sphere along
## the REAL sun direction, so it doubles as a live clock readout (it slides round
## the globe as time runs). Hidden below the horizon — a rim sun under the
## ground would read as a bug, not a moon.
##
## One instance, owned by SoiService and reference-counted by owner
## ("snowglobe" = the full-screen globe, "graph_globe" = the graph's Globe lens),
## so both globes draw the same sun. Lifted out of soi_snowglobe_camera.gd,
## which used to build its own.

## Distance and size relative to the globe radius.
const SUN_DIST_MULT := 1.14
const SUN_SIZE_MULT := 0.18


func _ready() -> void:
	name = "SoiRimSun"
	top_level = true
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE  # scaled per-frame from the globe radius
	mesh = quad
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	# Billboard mode DISCARDS node scale unless told otherwise — without this
	# the r×0.18 disc rendered at its raw 1 m mesh size: a four-pixel dot.
	mat.billboard_keep_scale = true
	# Alpha blend, NOT additive — an additive disc disappears against a bright
	# sky, which is exactly where a daytime sun sits.
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(1.0, 0.85, 0.30, 1.0)
	mat.albedo_texture = make_disc_texture()
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.72, 0.22)
	mat.emission_energy_multiplier = 1.4
	# Emblem icon, not scenery: always draw over globe/terrain so the rim sun
	# reads from any orbit angle (the diagram never occludes its sun).
	mat.no_depth_test = true
	mat.render_priority = 10
	mat.disable_fog = true
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visible = false


## Pin to `center` + sun direction × r·SUN_DIST_MULT. `sun` may be null (a
## fixed upper-right default is used, as the old gizmo did).
func update_from(center: Vector3, r: float, sun: DirectionalLight3D) -> void:
	var dir := Vector3(0.7, 0.6, 0.0).normalized()
	if sun != null and is_instance_valid(sun):
		# Godot lights shine along −Z, so the sun ITSELF sits along +basis.z.
		dir = sun.global_transform.basis.z.normalized()
	if dir.y < -0.05:
		visible = false
		return
	visible = true
	global_position = center + dir * (r * SUN_DIST_MULT)
	var s := r * SUN_SIZE_MULT
	scale = Vector3(s, s, s)


## Soft radial disc, generated (no asset; matches the project's synthesized-
## resources convention): hot core, feathered corona.
static func make_disc_texture(px: int = 128) -> ImageTexture:
	var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
	var c := float(px - 1) * 0.5
	for y in px:
		for x in px:
			var d := Vector2(float(x) - c, float(y) - c).length() / c
			var core := clampf(1.0 - smoothstep(0.30, 0.55, d), 0.0, 1.0)
			var corona := clampf(1.0 - smoothstep(0.35, 1.0, d), 0.0, 1.0)
			var a := clampf(core + corona * 0.5, 0.0, 1.0)
			img.set_pixel(x, y, Color(1.0, lerpf(0.75, 0.95, core), lerpf(0.25, 0.75, core), a))
	return ImageTexture.create_from_image(img)
