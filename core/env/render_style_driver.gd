class_name RenderStyleDriver
extends Node
## Main's child "RenderStyle": puts the visual-style post pass (RenderStyleEffect)
## on the world's WorldEnvironment compositor and keeps it in step with the
## player's choice (RenderStylePrefs) and the exposure.
##
## The environment half of a style (ambient, haze, glow, adjustment) is applied
## by Main itself at the end of its environment update — see
## RenderStyle.apply_env; this node only asks Main for a fresh update when the
## choice changes.
##
## The compositor sits on the WorldEnvironment, so every camera of this world
## gets the look: the player, the drone, the settlement view, the window wall,
## video export, and the graph lens previews. Modals and thumbnail studios have
## their own worlds and stay unstyled.

var _main: Node
var _effect: RenderStyleEffect
var _gen := -1
var _exposure := -1.0
var _params: Dictionary = {}
var _labels: StyleLabelOverlay


static func current() -> Dictionary:
	return RenderStylePrefs.resolved()


func setup(main: Node) -> void:
	_main = main


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	# World labels are drawn as 2D text while a style is on (StyleLabelOverlay).
	_labels = StyleLabelOverlay.new()
	_labels.setup(_main)
	add_child(_labels)
	if RenderingServer.get_rendering_device() == null:
		# Compatibility renderer: no compute. The environment half still applies.
		return
	var we := _world_environment()
	if we == null:
		return
	_effect = RenderStyleEffect.new()
	var comp: Compositor = we.compositor
	if comp == null:
		comp = Compositor.new()
		we.compositor = comp
	var effects: Array[CompositorEffect] = comp.compositor_effects.duplicate()
	effects.append(_effect)
	comp.compositor_effects = effects


func _exit_tree() -> void:
	var we := _world_environment()
	if we != null and we.compositor != null and _effect != null:
		var effects: Array[CompositorEffect] = []
		for e in we.compositor.compositor_effects:
			if e != _effect:
				effects.append(e)
		we.compositor.compositor_effects = effects


func _process(_delta: float) -> void:
	var g := RenderStylePrefs.generation()
	var changed := g != _gen
	if changed:
		_gen = g
		_params = RenderStylePrefs.resolved()
		if _main != null and _main.has_method("_update_environment"):
			_main.call("_update_environment")
	if _effect == null:
		return
	var exposure := _current_exposure()
	if changed or absf(exposure - _exposure) > 1e-3:
		_exposure = exposure
		_effect.set_params(RenderStyle.post_floats(_params, exposure),
			float(_params.get("outline_normals", 1.0)) > 0.5, RenderStyle.extra_floats(_params))
	var want := bool(_params.get("post_on", false))
	if _effect.enabled != want:
		_effect.enabled = want
	if _labels != null and _labels.is_active() != want:
		_labels.set_active(want)


## For probes: whether the post pass is running and the numbers it has.
func debug_state() -> Dictionary:
	return {
		"style": String(_params.get("id", "")),
		"post_on": _effect != null and _effect.enabled,
		"compiled": _effect != null and _effect.ready_to_render(),
		"compile_error": _effect.compile_error() if _effect != null else "no effect (compatibility renderer?)",
		"exposure": _exposure,
		"labels_mirrored": _labels.mirrored_count() if _labels != null else 0,
		"labels_drawn": _labels.drawn_count() if _labels != null else 0,
	}


func label_overlay() -> StyleLabelOverlay:
	return _labels


func _current_exposure() -> float:
	var we := _world_environment()
	if we != null and we.environment != null:
		return we.environment.tonemap_exposure
	return 1.0


func _world_environment() -> WorldEnvironment:
	if _main == null:
		return null
	var we = _main.get("environment")
	return we as WorldEnvironment if we is WorldEnvironment else null
