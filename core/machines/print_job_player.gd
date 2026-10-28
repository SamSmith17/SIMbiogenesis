class_name PrintJobPlayer
extends RefCounted

## Plays a stored job on the clock: loads it by id, plans it (the same
## planner the Simulate tab runs), and answers where the nozzle is at a
## progress fraction. Both in-world runtimes (the GLB machines' and the
## designed gantry's) read this, so the machine in the world moves exactly
## as the preview did — the head decelerates into corners, rapids between
## islands, and the roads grow under it move by move.
##
## Progress p (0..1, the graph's clock-derived fraction of the job's
## duration) maps to t = p × total_s of the plan.

var job: Dictionary = {}
var plan: Dictionary = {}
var total_s := 0.0
var job_id := ""
var line_mm := 0.4
var layer_mm := 0.2
var layer_starts := PackedInt32Array()
var layer_z := PackedFloat32Array()
var additive := true


func is_loaded() -> bool:
	return not plan.is_empty() and int(plan.get("n", 0)) > 0


## Load + plan. `specs` supplies limits and speeds for an old point-list job.
func load(id: String, specs: Dictionary = {}) -> bool:
	job_id = id
	job = {}
	plan = {}
	total_s = 0.0
	var data := MachineJobStore.load(id)
	if data.is_empty():
		return false
	if PrintMoves.count(data.get("moves", [])) > 0:
		var limits: Dictionary = data.get("limits", {})
		if limits.is_empty():
			limits = PrintJob.limits_for_specs(specs)
		job = data
		job["limits"] = limits
		if not job.has("ok"):
			job["ok"] = true
	else:
		var parse := {
			"ok": true, "kind": str(data.get("kind", "toolpath")),
			"points": data.get("points", PackedVector3Array()), "extruding": data.get("extruding", PackedInt32Array()),
			"line_width_mm": specs.get("line_width_mm", 0.4), "layer_height_mm": specs.get("layer_height_mm", -1.0),
		}
		job = PrintJob.from_toolpath(parse, specs)
		if not bool(job.get("ok", false)):
			return false
	return set_job(job)


## Use a job dict directly (the print setup's studio before it is stored).
func set_job(j: Dictionary) -> bool:
	job = j
	plan = j.get("plan", {}) if j.has("plan") and not (j["plan"] as Dictionary).is_empty() else PrintJob.plan(j)
	if plan.is_empty() or int(plan.get("n", 0)) == 0:
		plan = {}
		return false
	total_s = float(plan.get("total_s", 0.0))
	line_mm = maxf(float(j.get("line_width_mm", 0.4)), 0.05)
	layer_mm = float(j.get("layer_height_mm", -1.0))
	if layer_mm <= 0.0:
		layer_mm = PrintRoads.layer_guess_mm(j["moves"], line_mm)
	layer_starts = j.get("layer_starts", PackedInt32Array())
	if layer_starts.is_empty():
		layer_starts = PrintJob.layer_starts(j["moves"])
	layer_z = j.get("layer_z", PackedFloat32Array())
	additive = bool(j.get("additive", true))
	return true


## The job's moves (PrintMoves; an Array only for a job set by hand).
func moves() -> Variant:
	return job.get("moves", [])


## The nozzle at progress p: {pos (work mm), i, s, v, extruding, rapid, t,
## remaining_s, layer (1-based), layers, feed}.
func sample(progress: float) -> Dictionary:
	if plan.is_empty():
		return {"pos": Vector3.ZERO, "i": -1, "s": 0.0, "v": 0.0, "extruding": false, "rapid": false, "t": 0.0, "remaining_s": 0.0, "layer": 0, "layers": 0, "feed": 0.0}
	var t := clampf(progress, 0.0, 1.0) * total_s
	var smp := GantryLabMotion.sample(plan, t)
	smp["t"] = t
	smp["remaining_s"] = maxf(total_s - t, 0.0)
	smp["layer"] = layer_of_move(int(smp["i"]))
	smp["layers"] = layer_starts.size()
	return smp


## 1-based layer of move i (0 before the first extrusion).
func layer_of_move(i: int) -> int:
	if layer_starts.is_empty() or i < 0:
		return 0
	var lo := 0
	var hi := layer_starts.size() - 1
	if i < layer_starts[0]:
		return 0
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		if layer_starts[mid] <= i:
			lo = mid
		else:
			hi = mid - 1
	return lo + 1


## Progress at the start of a layer (1-based), for a layer slider.
func progress_of_layer(layer: int) -> float:
	if plan.is_empty() or layer_starts.is_empty() or total_s <= 0.0:
		return 0.0
	var k := clampi(layer - 1, 0, layer_starts.size() - 1)
	return GantryLabMotion.move_start_s(plan, layer_starts[k]) / total_s


func material_kg(specs: Dictionary) -> float:
	return PrintJob.material_kg(job, specs)
