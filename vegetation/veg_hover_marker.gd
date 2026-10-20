class_name VegHoverMarker
extends Node3D

## The V toolbar Select tool's "this one": a ring round the hovered plant's
## foot, a fainter one at its crown, and its name floating over the top.
## Drawn through everything (no depth test) — the plant is usually standing
## in front of its own ring, and the label has to read from inside a forest.
## The OTHER plants of the species are lit by the shader instance uniform
## (TerrainLoader.set_veg_species_glow), not by this node.

const COLOR := Color(1.0, 0.8, 0.3)

var _base: MeshInstance3D = null
var _crown: MeshInstance3D = null
var _label: Label3D = null


func _ready() -> void:
	top_level = true
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = true
	mat.albedo_color = Color(COLOR.r, COLOR.g, COLOR.b, 0.85)
	mat.render_priority = 10
	_base = _ring(mat)
	var faint := mat.duplicate() as StandardMaterial3D
	faint.albedo_color = Color(COLOR.r, COLOR.g, COLOR.b, 0.35)
	_crown = _ring(faint)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.fixed_size = true
	_label.pixel_size = 0.0011
	_label.font_size = 26
	_label.outline_size = 9
	_label.modulate = Color(1.0, 0.93, 0.75)
	_label.outline_modulate = Color(0.05, 0.04, 0.02, 0.9)
	_label.render_priority = 11
	_label.outline_render_priority = 10
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	add_child(_label)
	visible = false


func _ring(mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.9
	torus.outer_radius = 1.0
	torus.rings = 48
	torus.ring_segments = 6
	mi.mesh = torus
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mi


## `base` = the plant's foot in world space, `h` its height, `r` its crown
## radius. `text` may carry a second line.
func show_at(base: Vector3, h: float, r: float, text: String) -> void:
	if _base == null:
		return
	global_position = base
	var rr := maxf(r, 0.4)
	_base.position = Vector3(0, 0.15, 0)
	_base.scale = Vector3(rr, maxf(rr * 0.6, 0.3), rr)
	_crown.position = Vector3(0, maxf(h * 0.62, 0.6), 0)
	_crown.scale = Vector3(rr * 1.05, maxf(rr * 0.5, 0.25), rr * 1.05)
	_crown.visible = h > 2.0
	_label.position = Vector3(0, h + 0.8, 0)
	_label.text = text
	visible = true


func hide_marker() -> void:
	visible = false
