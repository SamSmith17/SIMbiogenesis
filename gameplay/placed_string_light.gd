class_name PlacedStringLight
extends Node3D

## A string light placed with the J Light Studio: a sagging wire between the
## player's pins, a bulb every `bulb_spacing_m`, and a handful of real
## OmniLights so it actually lights what is under it.
##
## Deliberately NOT a conduit (no ConduitManager parent, no x-ray material, no
## `power_consumers` membership): conduits are hidden in first person and draw
## through walls by design, and a J string must be neither. It is not a graph
## load until the player presses "Add to graph" (PlacedLightPower).
##
## Two looks, chosen by the preset's `continuous` flag:
##   bulbs      one MultiMesh on led_bulb.gdshader (festoon, fairy, pixels);
##   continuous the TUBE glows (led_rope.gdshader — rope light, LED neon flex,
##              glass neon, EL wire), a pixel every 1/leds_per_m along it.
## Both shaders include led_effects.gdshaderinc, which mirrors
## LedEffects.color_at; `real_lights` OmniLights sample the same function at
## their own pixel indices on the shared PlacedLightClock.

const BULB_SHADER := preload("res://gameplay/led_bulb.gdshader")
const ROPE_SHADER := preload("res://gameplay/led_rope.gdshader")
const LIGHT_HZ := 15.0
## Real lights on a string fade out by default — a festoon 200 m away does not
## need dynamic lights, its glowing bulbs are the look.
const DEFAULT_FADE_M := 90.0

var light_id: String = ""
var record: Dictionary = {}
var fields: Dictionary = {}
var length_m := 0.0
var bulb_count := 0
var samples := PackedVector3Array()

var _geo_key := ""
var _tube: MeshInstance3D = null
var _wire_mat: StandardMaterial3D = null
var _bulbs: MultiMeshInstance3D = null
var _bulb_mat: ShaderMaterial = null
var _bulb_pos := PackedVector3Array()
var _rope: MeshInstance3D = null
var _rope_mat: ShaderMaterial = null
var _continuous := false
var _omnis: Array[OmniLight3D] = []
var _omni_idx := PackedInt32Array()
var _pins: Array[PlacedLightWaypoint] = []
var _selected := false
var _lit := true
var _light_acc := 0.0
var _poll := 0.0
var _main: Node = null


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY


func configure(rec: Dictionary, res: Dictionary, main: Node) -> void:
	record = rec
	fields = res
	light_id = str(rec.get("id", ""))
	_main = main
	var pts := PlacedLightLayer.waypoints_of(rec)
	var key := "%s|%s|%s|%s|%s|%s|%s|%s" % [str(pts), str(fields.get("sag")),
		str(fields.get("bulb_spacing_m")), str(fields.get("bulb_size")), str(fields.get("preset")),
		str(fields.get("continuous")), str(fields.get("tube_diameter_mm")), str(fields.get("leds_per_m"))]
	if key != _geo_key:
		_geo_key = key
		_rebuild_geometry(pts)
	_sync_pins(pts)
	_apply_look()
	_update_lit()


func set_selected(on: bool) -> void:
	_selected = on
	for p in _pins:
		if is_instance_valid(p):
			p.set_string_selected(on)


func pin(i: int) -> PlacedLightWaypoint:
	return _pins[i] if i >= 0 and i < _pins.size() else null


func _ground_fn() -> Callable:
	var m := _main
	if m == null:
		return Callable()
	return func(p: Vector3) -> float: return TerrainSurfaceQuery.ground_height_at(m, p.x, p.z)


func _rebuild_geometry(pts: Array) -> void:
	var geo := LightStringGeometry.build(pts, fields, _ground_fn())
	samples = geo["samples"]
	length_m = float(geo["length_m"])
	_continuous = bool(fields.get("continuous", false))
	if _continuous:
		_rebuild_rope()
		return
	if _rope != null:
		_rope.visible = false
	_bulb_pos = geo["bulbs"]
	bulb_count = _bulb_pos.size()
	var size := clampf(float(fields.get("bulb_size", 0.06)), 0.005, 0.3)
	# Tube.
	if _tube == null:
		_tube = MeshInstance3D.new()
		_tube.name = "Wire"
		_tube.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_wire_mat = StandardMaterial3D.new()
		_wire_mat.roughness = 0.8
		_tube.material_override = _wire_mat
		add_child(_tube)
	_tube.mesh = ConduitMeshBuilder.build_tube(samples, clampf(size * 0.08, 0.0015, 0.006), 6) \
		if samples.size() >= 2 else null
	# Bulbs: hang just under the wire, festoon bulbs a little elongated.
	if _bulbs == null:
		_bulbs = MultiMeshInstance3D.new()
		_bulbs.name = "Bulbs"
		_bulbs.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_bulb_mat = ShaderMaterial.new()
		_bulb_mat.shader = BULB_SHADER
		_bulbs.material_override = _bulb_mat
		add_child(_bulbs)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 8
	sphere.rings = 4
	mm.mesh = sphere
	mm.instance_count = bulb_count
	var festoon := str(fields.get("preset", "patio")) == "patio"
	var drop := size * (1.4 if festoon else 0.6)
	var scl := Vector3(size, size * (1.35 if festoon else 1.0), size)
	var seed := float(hash(light_id) % 1000)
	for i in bulb_count:
		var p: Vector3 = _bulb_pos[i] - Vector3(0.0, drop, 0.0)
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY.scaled(scl), p))
		mm.set_instance_custom_data(i, Color(float(i), float(bulb_count), seed, 0.0))
	_bulbs.multimesh = mm
	_rebuild_omnis(drop)


## Continuous tube: one glowing mesh, pixels every 1/leds_per_m along it (the
## real lights sit at pixel positions so their colours match the tube's).
func _rebuild_rope() -> void:
	var per_m := clampf(float(fields.get("leds_per_m", 36.0)), 1.0, 240.0)
	_bulb_pos = ConduitMeshBuilder.bulb_positions_along(samples, 1.0 / per_m)
	bulb_count = _bulb_pos.size()
	if _bulbs != null:
		_bulbs.visible = false
	if _tube != null:
		_tube.visible = false
	if _rope == null:
		_rope = MeshInstance3D.new()
		_rope.name = "Rope"
		_rope.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_rope_mat = ShaderMaterial.new()
		_rope_mat.shader = ROPE_SHADER
		_rope.material_override = _rope_mat
		add_child(_rope)
	_rope.visible = true
	var radius := clampf(float(fields.get("tube_diameter_mm", 13.0)), 1.0, 80.0) * 0.0005
	_rope.mesh = LightStringGeometry.build_tube(samples, radius, 8 if radius > 0.003 else 5)
	_rope_mat.set_shader_parameter("leds_per_m", per_m)
	_rope_mat.set_shader_parameter("total_px", float(maxi(bulb_count, 1)))
	_rebuild_omnis(radius + 0.05)


func _rebuild_omnis(drop: float) -> void:
	var want := clampi(int(fields.get("real_lights", 6)), 0, 16)
	_omni_idx = LightStringGeometry.light_indices(bulb_count, want)
	while _omnis.size() > _omni_idx.size():
		_omnis.pop_back().queue_free()
	while _omnis.size() < _omni_idx.size():
		var o := OmniLight3D.new()
		o.shadow_enabled = false
		o.light_specular = 0.2
		add_child(o)
		_omnis.append(o)
	for k in _omni_idx.size():
		_omnis[k].position = _bulb_pos[_omni_idx[k]] - Vector3(0.0, drop + 0.05, 0.0)


func _sync_pins(pts: Array) -> void:
	while _pins.size() > pts.size():
		_pins.pop_back().queue_free()
	while _pins.size() < pts.size():
		var p := PlacedLightWaypoint.new()
		p.name = "Pin_%d" % _pins.size()
		add_child(p)
		_pins.append(p)
	for i in pts.size():
		_pins[i].setup(light_id, i, pts[i])
		_pins[i].set_string_selected(_selected)
	# The plug end: a feed conduit from the graph lands on the FIRST pin
	# (ConduitManager.anchor_global_for_item looks for a conduit_anchor child —
	# this node itself sits at the origin, its geometry is in world space).
	var anchor := get_node_or_null("PlugAnchor") as Node3D
	if anchor == null:
		anchor = Node3D.new()
		anchor.name = "PlugAnchor"
		anchor.add_to_group(ConnectionPortDefs.ANCHOR_GROUP)
		add_child(anchor)
	if not pts.is_empty():
		anchor.position = pts[0]


func _apply_look() -> void:
	# "Show bulb" off: only the light the string casts, no bulb geometry.
	if _bulbs != null:
		_bulbs.visible = bool(fields.get("show_body", true)) and not _continuous
	if _tube != null:
		_tube.visible = not _continuous
	if _rope != null:
		_rope.visible = _continuous and bool(fields.get("show_body", true))
	if _wire_mat != null:
		_wire_mat.albedo_color = PlacedLightPower.parse_color(str(fields.get("wire_color", "141414")))
	var base := PlacedLightPower.parse_color(str(fields.get("color", "ffd18c")))
	for mat in [_bulb_mat, _rope_mat]:
		if mat == null:
			continue
		var m: ShaderMaterial = mat
		m.set_shader_parameter("base_color", base)
		m.set_shader_parameter("fx_mode", LedEffects.effect_index(str(fields.get("effect", "solid"))))
		m.set_shader_parameter("fx_speed", float(fields.get("fx_speed", 6.0)))
		m.set_shader_parameter("fx_span", float(fields.get("fx_span", 24.0)))
		m.set_shader_parameter("fx_gap", float(fields.get("fx_gap", 3.0)))
		m.set_shader_parameter("fx_saturation", float(fields.get("fx_saturation", 1.0)))
		m.set_shader_parameter("fx_direction", float(fields.get("fx_direction", 1.0)))
		m.set_shader_parameter("fx_time", fx_time())
	var fade := float(fields.get("fade_m", 0.0))
	if fade <= 0.0:
		fade = DEFAULT_FADE_M
	var rng := clampf(float(fields.get("light_range", 4.0)), 0.3, 40.0)
	for o in _omnis:
		o.omni_range = rng
		o.distance_fade_enabled = true
		o.distance_fade_begin = fade * 0.75
		o.distance_fade_length = fade * 0.25
	_push_energy()
	_push_light_colors()


func _push_energy() -> void:
	var e := float(fields.get("energy", 2.5)) * sound_level
	if _bulb_mat != null:
		# HDR enough that a 6 cm bulb still blooms into a point from across a
		# field (the WorldEnvironment glow carries it).
		_bulb_mat.set_shader_parameter("glow", e * 4.0 if _lit else 0.0)
	if _rope_mat != null:
		_rope_mat.set_shader_parameter("glow", e * 2.5 if _lit else 0.0)
	# A string's energy is spread over its real lights: more lights, each dimmer.
	var per := e * 2.0 / sqrt(float(maxi(_omnis.size(), 1)))
	for o in _omnis:
		o.light_energy = per if _lit else 0.0
		o.visible = _lit


func _push_light_colors() -> void:
	var base := PlacedLightPower.parse_color(str(fields.get("color", "ffd18c")))
	for k in _omnis.size():
		_omnis[k].light_color = LedEffects.color_at(fields, _omni_idx[k], bulb_count, _effect_t(), base)


func _process(delta: float) -> void:
	_poll -= delta
	if _poll <= 0.0:
		_poll = 0.5
		_update_lit()
	_update_sound()
	if str(fields.get("effect", "solid")) == "solid" or not _lit:
		return
	var t := _effect_t()
	for mat in [_bulb_mat, _rope_mat]:
		if mat != null:
			(mat as ShaderMaterial).set_shader_parameter("fx_time", t)
	_light_acc += delta
	if _light_acc >= 1.0 / LIGHT_HZ:
		_light_acc = 0.0
		_push_light_colors()


func _update_lit() -> void:
	var lit := PlacedLightPower.is_lit(_main, record, fields)
	if lit != _lit:
		_lit = lit
		_push_energy()


## The shared effect clock (PlacedLightClock): every string and fixture reads
## the same one, so duplicated strings chase in step.
func fx_time() -> float:
	return PlacedLightClock.now(_main)


# --- sound reactive (StageBeat) ----------------------------------------------
## Brightness from the music (1 = none) and the music itself ({} = silence or
## not reactive). Heard at the middle of the string.
var sound_level := 1.0
var _sound_beat: Dictionary = {}
var _sounding := false


func _update_sound() -> void:
	if not (_lit and bool(fields.get("sound_reactive", false))):
		_sound_beat = {}
		if _sounding:
			_sounding = false
			sound_level = 1.0
			_push_energy()
		return
	var ear := samples[samples.size() / 2] if not samples.is_empty() else global_position
	_sound_beat = StageBeat.at(ear, false)
	var mode := str(fields.get("sound_mode", "pulse"))
	sound_level = 1.0 if mode == "beat" else \
		StageBeat.light_level(_sound_beat, float(fields.get("sound_depth", 0.8)))
	_sounding = true
	_push_energy()


## The effect clock, moving with the music in a "beat" sound mode.
func _effect_t() -> float:
	if not _sound_beat.is_empty() and str(fields.get("sound_mode", "pulse")) != "pulse":
		return StageBeat.light_time(_sound_beat)
	return fx_time()


func is_continuous() -> bool:
	return _continuous


func bulb_world_positions() -> PackedVector3Array:
	return _bulb_pos


func is_lit() -> bool:
	return _lit


# -- Graph load interface (GraphAcLoad reads this through the item's
# scene_device_path once the player has pressed "Add to graph") -------------

func get_current_power() -> float:
	if str(record.get("graph_item_id", "")).is_empty() or not _lit:
		return 0.0
	return float(record.get("graph_watts", 0.0))
