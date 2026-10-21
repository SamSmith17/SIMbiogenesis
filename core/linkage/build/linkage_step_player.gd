class_name LinkageStepPlayer
extends Node3D
## The Lab's build-step player (LINKAGE_PARITY.md A5) — the playback engine of
## LinkageLab's build-steps-anim.js plus a renderer for LinkageStepScene
## frames. A sibling of the Lab's LinkageStructureBuilder (same local frame).
##
## Engine: per step a TRANSITION (the camera eases to the step's framing,
## transitionMs), the OP (LinkageStepScene at t = 0..1 over durationMs), and a
## short HOLD, then the next step — or the next GROUP when the repeat mode is
## "skip" (a group of identical steps plays once); "fast" plays repeats at the
## settings' fastFactor.
##
## Renderer: builder part states (future parts hidden, parked parts displaced,
## parts moving in), the fold pose, the workbench (bench steps hide the
## structure), and the tool (FabToolCatalog — the same saw / drill / driver the
## NPC crews hold).

signal step_changed(index: int)
signal frame_shown(frame: Dictionary)

const IN_TO_M := 0.0254
const HOLD_S := 0.4
const STEP_FOLD_EPS_DEG := 0.01

var builder: LinkageStructureBuilder = null
var params: LinkageParams = null
var steps: Array = []
var settings: Dictionary = LinkageBuildSteps.default_settings()

var index := 0
var t := 0.0                  # op progress 0..1
var phase := "idle"           # transition | op | hold | done | idle
var playing := false
var speed := 1.0
var active := false

var _phase_s := 0.0
var _ctx_cache: Dictionary = {}     # fold (0.01 deg) -> LinkageStepScene context
var _joint_of_part: Dictionary = {} # ctx fold key -> {part key -> joint key}
var _deployed_deg := NAN
var _design_fold_deg := 0.0
var _saved_fold := NAN
var _bench: Node3D = null
var _bench_meshes: Array = []
var _tools: Dictionary = {}
var _last_frame: Dictionary = {}


func setup(b: LinkageStructureBuilder, p: LinkageParams) -> void:
	builder = b
	params = p
	_ctx_cache.clear()
	_joint_of_part.clear()
	_deployed_deg = rad_to_deg(LinkageKinematics.optimal_closed_angle(p))
	_design_fold_deg = rad_to_deg(b.get_fold_angle()) if b != null else rad_to_deg(p.fold_angle)


func set_steps(list: Array, s: Dictionary = {}) -> void:
	steps = list
	settings = LinkageBuildSteps.normalize_settings(s)
	index = clampi(index, 0, maxi(0, steps.size() - 1))


## Enter playback at step `i` (the design's fold is remembered for exit).
func enter(i: int = 0) -> void:
	if not active:
		active = true
		_saved_fold = rad_to_deg(builder.get_fold_angle()) if builder != null else NAN
		_design_fold_deg = _saved_fold if not is_nan(_saved_fold) else _design_fold_deg
	go_to(i)


## Leave playback: every part seated, the design's fold back, no bench/tool.
func exit() -> void:
	if not active:
		return
	active = false
	playing = false
	phase = "idle"
	if builder != null:
		builder.visible = true
		builder.clear_part_states()
		if not is_nan(_saved_fold):
			builder.set_fold_angle(deg_to_rad(_saved_fold))
	_hide_bench_and_tools()


func go_to(i: int) -> void:
	if steps.is_empty():
		index = 0
		phase = "idle"
		return
	index = clampi(i, 0, steps.size() - 1)
	var st: Dictionary = steps[index]
	t = 0.0
	_phase_s = 0.0
	phase = "transition" if int(st.get("transitionMs", 0)) > 0 and playing else "op"
	step_changed.emit(index)
	show_frame()


func next() -> void:
	var n := LinkageBuildSteps.next_index_after(steps, index, str(settings.get("repeatMode", "skip")))
	if n >= 0:
		go_to(n)


func prev() -> void:
	# Back to the previous group's first step (or the previous step).
	var i := index - 1
	if i < 0:
		return
	var g := LinkageBuildSteps.group_of(steps, i)
	if str(settings.get("repeatMode", "skip")) == "skip" and int(g["count"]) > 1:
		i = int(g["first"])
	go_to(i)


func play() -> void:
	if steps.is_empty():
		return
	if not active:
		enter(index)
	if phase == "done":
		go_to(0)
	playing = true


func pause() -> void:
	playing = false


## Scrub the current step's op to u.
func scrub(u: float) -> void:
	t = clampf(u, 0.0, 1.0)
	phase = "op"
	show_frame()


func _process(delta: float) -> void:
	if not active or not playing or steps.is_empty():
		return
	var st: Dictionary = steps[index]
	var k := speed * _repeat_speed()
	_phase_s += delta * k
	match phase:
		"transition":
			if _phase_s * 1000.0 >= float(st.get("transitionMs", 0)):
				phase = "op"
				_phase_s = 0.0
			show_frame()
		"op":
			var dur := maxf(0.05, float(st.get("durationMs", 1500)) / 1000.0)
			t = clampf(_phase_s / dur, 0.0, 1.0)
			show_frame()
			if t >= 1.0:
				phase = "hold"
				_phase_s = 0.0
		"hold":
			if _phase_s >= HOLD_S:
				var n := LinkageBuildSteps.next_index_after(steps, index, str(settings.get("repeatMode", "skip")))
				if n < 0:
					phase = "done"
					playing = false
				else:
					go_to(n)


## Repeats of a group play faster in "fast" mode.
func _repeat_speed() -> float:
	if str(settings.get("repeatMode", "skip")) != "fast":
		return 1.0
	var g := LinkageBuildSteps.group_of(steps, index)
	if int(g["count"]) > 1 and not bool(g["isFirst"]):
		return float(settings.get("fastFactor", 4))
	return 1.0


## The transition's camera progress (0..1), for the Lab's camera tween.
func transition_u() -> float:
	if phase != "transition" or steps.is_empty():
		return 1.0
	var ms := maxf(1.0, float((steps[index] as Dictionary).get("transitionMs", 1)))
	return LinkageBuildSteps.ease_in_out_cubic(clampf(_phase_s * 1000.0 / ms, 0.0, 1.0))


func last_frame() -> Dictionary:
	return _last_frame


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

func context_for(fold_deg: float) -> Dictionary:
	var key := int(roundf(fold_deg * 100.0))
	if not _ctx_cache.has(key):
		if _ctx_cache.size() > 6:
			_ctx_cache.clear()
			_joint_of_part.clear()
		var ctx := LinkageStepScene.make_context(params, fold_deg, _deployed_deg)
		_ctx_cache[key] = ctx
		var jo := {}
		for rec in ctx["parts"]:
			var jk := LinkagePartKeys.joint_key(rec["obj"], rec["kind"])
			if jk.begins_with("joint:"):
				jo[rec["key"]] = jk
		_joint_of_part[key] = jo
	return _ctx_cache[key]


## Draw the current (index, t). Returns the frame.
func show_frame() -> Dictionary:
	if builder == null or params == null or steps.is_empty():
		return {}
	# The builder's frame (the Lab offsets it inside its holder).
	transform = builder.transform
	var fold := LinkageStepScene.fold_for_step(steps, index, _design_fold_deg)
	if absf(rad_to_deg(builder.get_fold_angle()) - fold) > STEP_FOLD_EPS_DEG:
		builder.set_fold_angle(deg_to_rad(fold))
	var ctx := context_for(fold)
	var fr := LinkageStepScene.frame(steps, index, t if phase != "transition" else 0.0, ctx)
	_last_frame = fr
	_apply_parts(fr, _joint_of_part[int(roundf(fold * 100.0))])
	builder.visible = not bool(fr["bench"])
	_apply_bench(fr)
	_apply_tool(fr)
	frame_shown.emit(fr)
	return fr


func _apply_parts(fr: Dictionary, joint_of_part: Dictionary) -> void:
	var parts: Dictionary = fr["parts"]
	# Hardware the builder draws its own way (simple brackets, its bolts and
	# washers) follows its JOINT: shown once a part of that joint that a step
	# introduces is shown. Hardware on a joint no step introduces would hang
	# in the air over an empty site, so it waits for the last step.
	var joint_state := {}
	var referenced := {}
	for key in parts:
		var jk = joint_of_part.get(key)
		if jk == null:
			continue
		var ps: Dictionary = parts[key]
		if str(ps.get("status", "")) == "unreferenced":
			continue
		referenced[jk] = true
		if bool(ps["visible"]) and not joint_state.has(jk):
			joint_state[jk] = {"visible": true, "offset": ps["offset"]}
	var last := bool(fr.get("last", false))
	var builder_joint := builder.part_joint_keys()
	var states := {}
	for key in builder.part_keys():
		var s = parts.get(key)
		var hardware := builder_joint.has(key)
		if hardware and (s == null or str((s as Dictionary).get("status", "")) == "unreferenced"):
			var jk2: String = builder_joint[key]
			if joint_state.has(jk2):
				s = joint_state[jk2]
			elif referenced.has(jk2) or not last:
				s = {"visible": false, "offset": Vector3.ZERO}
			else:
				s = null
		if s is Dictionary:
			var off: Vector3 = s["offset"]
			if not bool(s["visible"]) or off.length_squared() > 1e-8:
				states[key] = {"visible": bool(s["visible"]), "offset": Transform3D(Basis(), off * IN_TO_M)}
	builder.set_part_states(states)


## The bench frame: inches -> metres, the bench plane centred under the origin.
func bench_transform(fr: Dictionary) -> Transform3D:
	var bp: Dictionary = fr.get("bench_plane", {})
	var c: Vector3 = bp.get("center", Vector3.ZERO)
	return Transform3D(Basis().scaled(Vector3.ONE * IN_TO_M), Vector3(-c.x, 0.0, -c.z) * IN_TO_M)


## The structure frame: inches -> metres plus the builder's ground offset.
func structure_point(p_in: Vector3) -> Vector3:
	return p_in * IN_TO_M + Vector3(0, builder.ground_offset(), 0)


## Where the frame's focus is, in this node's PARENT frame (the Lab's
## holder), metres.
func focus_local(fr: Dictionary) -> Dictionary:
	var f: Dictionary = fr.get("focus", {})
	if f.is_empty():
		return {"center": transform.origin, "radius": 3.0}
	var c: Vector3 = f["center"]
	var pos := bench_transform(fr) * c if bool(fr.get("bench", false)) else structure_point(c)
	return {"center": transform * pos, "radius": float(f["radius"]) * IN_TO_M}


func _apply_bench(fr: Dictionary) -> void:
	if _bench == null:
		_bench = Node3D.new()
		_bench.name = "Workbench"
		add_child(_bench)
	if not bool(fr["bench"]):
		_bench.visible = false
		return
	_bench.visible = true
	_bench.transform = bench_transform(fr)
	var boxes: Array = []
	var bp: Dictionary = fr["bench_plane"]
	if not bp.is_empty():
		boxes.append({"center": bp["center"], "size": bp["size"], "color": Color(0.23, 0.25, 0.28), "roll": 0.0})
	for b in fr["bench_boxes"]:
		var col := Color(0.86, 0.7, 0.5) if str(b["kind"]) != "offcut" else Color(0.7, 0.55, 0.38)
		boxes.append({"center": b["center"], "size": b["size"], "color": col, "roll": float(b["roll"])})
	for h in fr["holes"]:
		var r := float(h["radius"])
		boxes.append({"center": (h["pos"] as Vector3) + Vector3(0, 0.02, 0), "size": Vector3(r * 2.0, 0.06, r * 2.0),
			"color": Color(0.08, 0.06, 0.04), "roll": 0.0})
	while _bench_meshes.size() < boxes.size():
		var mi := MeshInstance3D.new()
		mi.mesh = BoxMesh.new()
		var m := StandardMaterial3D.new()
		m.roughness = 0.85
		mi.material_override = m
		_bench.add_child(mi)
		_bench_meshes.append(mi)
	for i in _bench_meshes.size():
		var mi: MeshInstance3D = _bench_meshes[i]
		if i >= boxes.size():
			mi.visible = false
			continue
		var b: Dictionary = boxes[i]
		mi.visible = true
		(mi.mesh as BoxMesh).size = b["size"]
		(mi.material_override as StandardMaterial3D).albedo_color = b["color"]
		mi.transform = Transform3D(Basis(Vector3(0, 0, 1), float(b["roll"])), b["center"])


func _apply_tool(fr: Dictionary) -> void:
	var tl: Dictionary = fr.get("tool", {})
	for id in _tools:
		(_tools[id] as Node3D).visible = false
	if tl.is_empty() or not bool(tl.get("visible", false)):
		return
	var id := str(tl["id"])
	if not _tools.has(id):
		var node := FabToolCatalog.build(id)
		add_child(node)
		_tools[id] = node
	var tool: Node3D = _tools[id]
	tool.visible = true
	var xf: Transform3D = tl["xform"]
	var pos := bench_transform(fr) * xf.origin if str(tl["frame"]) == "bench" else structure_point(xf.origin)
	tool.transform = Transform3D(xf.basis, pos)
	FabToolCatalog.set_spin(tool, float(tl.get("spin", 0.0)))


func _hide_bench_and_tools() -> void:
	if _bench != null:
		_bench.visible = false
	for id in _tools:
		(_tools[id] as Node3D).visible = false


func tool_node(id: String) -> Node3D:
	return _tools.get(id)
