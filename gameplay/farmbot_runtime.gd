class_name FarmBotRuntime
extends Node

## A placed FarmBot working its days on the world's clock.
##
## Each frame: the days since the bed was planted (the record's
## `plant_abs_h`, else the hour it was first seen) and the second of the day
## give the robot's pose straight from FarmBotJobs (a pure function of the
## design and the day), so the robot is wherever its schedule has it at any
## moment: scrubbing the timeline back puts it back, and at speed it simply
## skips ahead. A day's plan is worked out once, when the day changes.
## The crops grow on the same count (FarmBotBuilder.set_days).

const NODE_NAME := "FarmBotRuntime"

var _builder: FarmBotBuilder = null
var _rec: Dictionary = {}
var _planted_h := NAN
var _plan_day := -999999
var _plan: Dictionary = {}
var _main: Node = null
## What it is doing now (harness, tooltips).
var state: Dictionary = {}


static func attach(prop: Node3D, rec: Dictionary) -> void:
	if str(rec.get("model_id", "")) != FarmBotBuilder.MODEL_ID or prop.get_node_or_null(NODE_NAME) != null:
		return
	var rt := FarmBotRuntime.new()
	rt.name = NODE_NAME
	rt._rec = rec
	prop.add_child(rt)


static func of(prop: Node) -> FarmBotRuntime:
	return prop.get_node_or_null(NODE_NAME) as FarmBotRuntime if prop != null else null


func builder() -> FarmBotBuilder:
	return _builder


func _ready() -> void:
	call_deferred("_bind")


func _bind() -> void:
	_builder = null
	var p := get_parent()
	if p == null:
		return
	for n in p.find_children("*", "Node3D", true, false):
		if n is FarmBotBuilder:
			_builder = n as FarmBotBuilder
			break
	_plan_day = -999999
	var ph: Variant = _rec.get("plant_abs_h", null)
	if ph != null and float(ph) >= 0.0:
		_planted_h = float(ph)


func _process(_delta: float) -> void:
	if _builder == null or not is_instance_valid(_builder) or not _builder.is_inside_tree():
		_bind()
		if _builder == null:
			return
	if _main == null or not is_instance_valid(_main):
		_main = get_tree().current_scene if get_tree() != null else null
	if _main == null or not _main.has_method("get_absolute_hours"):
		return
	PerfSpan.begin("farmbot")
	var now := float(_main.call("get_absolute_hours"))
	if is_nan(_planted_h):
		_planted_h = now
	var days := (now - _planted_h) / 24.0
	_builder.set_days(days)
	if days < 0.0:
		for i in _builder.arms.size():
			_builder.set_arm(i, FarmBotJobs.park_pos(_builder.spec, i), "", false)
		PerfSpan.end("farmbot")
		return
	# Its jobs run at clock hours: the day rolls at local midnight (absolute
	# hours count from it), day 0 being the day it was planted.
	var day := int(floor(now / 24.0)) - int(floor(_planted_h / 24.0))
	if day != _plan_day:
		_plan_day = day
		_plan = FarmBotJobs.day_plan(_builder.spec, _builder.design["layout"], day, true)
	var sec := fposmod(now, 24.0) * 3600.0
	var all := FarmBotJobs.sample_arms(_plan, sec)
	_builder.set_arms(all)
	var r: Dictionary = all[0]
	state = r
	# Busy when any arm is.
	for o in all:
		if bool((o as Dictionary).get("busy", false)):
			state["busy"] = true
			if str(state.get("job", "")).is_empty():
				state["job"] = str(o["job"])
	state["day"] = day
	PerfSpan.end("farmbot")
