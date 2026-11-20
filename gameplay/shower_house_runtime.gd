class_name ShowerHouseRuntime
extends Node

## A shower house's curtains and water: a stall someone has taken draws its
## curtain and runs its shower head; when they leave the water stops and the
## curtain is pushed back. Read from the population bridge's stall occupancy
## four times a second (the same stalls a toilet bank uses); the curtain eases
## on the cosmetic clock, and a paused world stops the water.

const POLL_S := 0.25

var _prop_id := ""
var _acc := 0.0
var _busy: Array = []
var _open: Array = []      # 0 = drawn shut, 1 = pushed back
var _bridge: Object = null
var _paused := false


func configure(prop_id: String) -> void:
	_prop_id = prop_id


func _process(delta: float) -> void:
	var rate := SimFxRate.target_rate(_time_scale(), SimFxRate.FX_CAP_NPC)
	_set_paused(rate <= 0.0)
	if rate <= 0.0:
		return
	_acc += delta
	if _acc >= POLL_S:
		_acc = 0.0
		_poll()
	var root := _house_root()
	if root == null:
		return
	for k in _open.size():
		var want := 0.0 if bool(_busy[k]) else 1.0
		var o := float(_open[k])
		if absf(o - want) < 0.01:
			continue
		o = move_toward(o, want, delta * 2.5 * maxf(rate, 1.0))
		_open[k] = o
		var pivot := root.get_node_or_null("Curtains/C%d" % k) as Node3D
		if pivot != null:
			pivot.scale.x = lerpf(1.0, ShowerHouseBuilder.CURTAIN_OPEN, o)


func _poll() -> void:
	var bridge := _find_bridge()
	if bridge == null:
		return
	var busy: Array = bridge.call("stalls_busy", _prop_id)
	if busy.size() != _busy.size():
		_busy = []
		_busy.resize(busy.size())
		_busy.fill(false)
		_open.resize(busy.size())
		_open.fill(1.0)
	var root := _house_root()
	for k in busy.size():
		var now := bool(busy[k])
		if now == bool(_busy[k]):
			continue
		_busy[k] = now
		if root != null:
			var spray := root.get_node_or_null("Sprays/S%d" % k) as GPUParticles3D
			if spray != null:
				spray.emitting = now


## A paused world holds its water mid-fall (speed 0), as the fire does.
func _set_paused(p: bool) -> void:
	if p == _paused:
		return
	_paused = p
	var root := _house_root()
	if root == null:
		return
	var sprays := root.get_node_or_null("Sprays")
	if sprays == null:
		return
	for c in sprays.get_children():
		if c is GPUParticles3D:
			(c as GPUParticles3D).speed_scale = 0.0 if p else 1.0


## Which stalls run their water right now (for probes).
func running() -> Array:
	return _busy.duplicate()


func _house_root() -> Node:
	var p := get_parent()
	if p == null:
		return null
	if p.has_meta("shower_spec"):
		return p
	for c in p.get_children():
		if c.has_meta("shower_spec"):
			return c
	return null


func _find_bridge() -> Object:
	if _bridge != null and is_instance_valid(_bridge):
		return _bridge
	var view := get_tree().root.find_child("SystemGraphView", true, false) if is_inside_tree() else null
	if view == null or not view.has_method("npc_population_bridge"):
		return null
	var b: Variant = view.call("npc_population_bridge")
	if b is Object and (b as Object).has_method("stalls_busy"):
		_bridge = b
	return _bridge


func _time_scale() -> float:
	if not is_inside_tree():
		return 0.0
	return absf(SimFxRate.time_scale_of(null))
