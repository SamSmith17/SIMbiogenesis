class_name ToiletBankRuntime
extends Node

## A toilet bank's doors and occupied flags (NPC life pass, Phase 3): a stall
## that someone has just taken opens its door while they step in, then shuts
## and shows red; when they leave it opens again behind them, then shuts and
## shows green. Read from the population bridge's stall occupancy four times a
## second; the door swing eases on the cosmetic clock, so a paused world holds
## its doors where they are.

const POLL_S := 0.25
## A door stays open this long (real seconds at 1x) after a stall changes
## hands — someone walking in or out.
const OPEN_S := 1.6
const OPEN_DEG := 100.0

var _prop_id := ""
var _acc := 0.0
var _busy: Array = []
var _open_left: Array = []
var _angle: Array = []
var _bridge: Object = null


func configure(prop_id: String) -> void:
	_prop_id = prop_id


func _process(delta: float) -> void:
	var rate := SimFxRate.target_rate(_time_scale(), SimFxRate.FX_CAP_NPC)
	if rate <= 0.0:
		return
	_acc += delta
	if _acc >= POLL_S:
		_acc = 0.0
		_poll()
	var doors := get_parent().get_node_or_null("Doors") if get_parent() != null else null
	if doors == null:
		var root := _bank_root()
		doors = root.get_node_or_null("Doors") if root != null else null
	if doors == null:
		return
	for k in _angle.size():
		if _open_left[k] > 0.0:
			_open_left[k] = maxf(float(_open_left[k]) - delta * rate, 0.0)
		var want := OPEN_DEG if float(_open_left[k]) > 0.0 else 0.0
		var a := float(_angle[k])
		if absf(a - want) < 0.05:
			continue
		a = lerpf(a, want, minf(delta * 7.0 * maxf(rate, 1.0), 1.0))
		_angle[k] = a
		var pivot := doors.get_node_or_null("D%d" % k) as Node3D
		if pivot != null:
			# Row 1's doors face -Z (the stall is turned round), so they swing
			# the other way about Y.
			var base_y := pivot.get_meta("base_yaw", pivot.rotation.y) as float
			if not pivot.has_meta("base_yaw"):
				pivot.set_meta("base_yaw", base_y)
			pivot.rotation.y = base_y - deg_to_rad(a)


func _poll() -> void:
	var bridge := _find_bridge()
	if bridge == null:
		return
	var busy: Array = bridge.call("toilet_stalls_busy", _prop_id)
	if busy.size() != _busy.size():
		_busy = []
		_busy.resize(busy.size())
		_busy.fill(false)
		_open_left.resize(busy.size())
		_open_left.fill(0.0)
		_angle.resize(busy.size())
		_angle.fill(0.0)
	var root := _bank_root()
	for k in busy.size():
		var now := bool(busy[k])
		if now != bool(_busy[k]):
			_open_left[k] = OPEN_S
			_busy[k] = now
			if root != null:
				var flag := root.get_node_or_null("Doors/D%d/Flag" % k) as MeshInstance3D
				ToiletBankBuilder.set_flag(flag, now)


func _bank_root() -> Node:
	var p := get_parent()
	if p == null:
		return null
	if p.has_meta("stall_spots"):
		return p
	for c in p.get_children():
		if c.has_meta("stall_spots"):
			return c
	return null


func _find_bridge() -> Object:
	if _bridge != null and is_instance_valid(_bridge):
		return _bridge
	var view := get_tree().root.find_child("SystemGraphView", true, false) if is_inside_tree() else null
	if view == null or not view.has_method("npc_population_bridge"):
		return null
	var b: Variant = view.call("npc_population_bridge")
	if b is Object and (b as Object).has_method("toilet_stalls_busy"):
		_bridge = b
	return _bridge


func _time_scale() -> float:
	var main := get_tree().root.find_child("Main", true, false) if is_inside_tree() else null
	if main != null and "time_scale" in main:
		return absf(float(main.get("time_scale")))
	return 0.0
