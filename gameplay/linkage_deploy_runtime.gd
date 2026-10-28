class_name LinkageDeployRuntime
extends Node

## Live in-world fold controller for a placed Linkage Lab structure.
##
## Attached by PlacedPropRuntime to every PlacedProp whose model is the
## procedural "linkage_structure" (mirrors WindTurbineSpin / CspTroughTracker's
## attach pattern). The prop's ModelRoot IS the LinkageStructureBuilder, so
## folding is just set_fold_angle() — MultiMesh transform rewrites, no mesh
## rebuild per frame. Interact (crosshair) toggles deploy <-> stow with the
## same 3 s full-cycle animation as the designer modal; support/RCP beams and
## solar panels appear/disappear through their visibility angles automatically
## (the builder owns that gating).
##
## Fold state persists on the placed-prop record (linkage_fold_deg /
## linkage_deployed) via PlacedPropService.update_prop_record — saved when an
## animation settles, so reloads restore the exact pose. The walkable
## collision mesh is only refreshed when motion stops (per-frame trimesh
## rebuilds would be wasteful); the stale collider during the ~3 s sweep is
## acceptable.

signal deploy_state_changed(deployed: bool)

## Full stow->deploy sweep duration (matches the designer modal / web app).
const FULL_CYCLE_S := 3.0
## "Deployed" tolerance against the ring-closure angle (rad).
const DEPLOY_EPS := 0.02

var _prop: PlacedProp = null
var _builder: LinkageStructureBuilder = null
var _rec: Dictionary = {}
var _animating := false
var _target_rad := 0.0
var _rate := 1.0   # rad/s, sign gives direction
## The sweep's own angle (advances every frame) and the time since the
## builder last re-solved: a heavy design (fold_cost_ms) is re-solved at most
## every MAX_FOLD_GAP_S x its cost / HEAVY_FOLD_MS, never more than ~13 times
## a second apart — the fold still keeps time, it is drawn in fewer steps.
var _fold := 0.0
var _since := 0.0
const HEAVY_FOLD_MS := 3.0
const FOLD_GAP_PER_MS := 0.004
const MAX_FOLD_GAP_S := 0.08


func configure(rec: Dictionary) -> void:
	_rec = rec.duplicate(true)


func _ready() -> void:
	_prop = get_parent() as PlacedProp
	if _prop == null:
		set_process(false)
		return
	_builder = _prop.get_node_or_null("ModelRoot") as LinkageStructureBuilder
	if _builder == null:
		set_process(false)
		return
	# Restore the persisted fold pose (record wins over the spec's foldAngle).
	if _rec.has("linkage_fold_deg"):
		var fold := deg_to_rad(float(_rec["linkage_fold_deg"]))
		if absf(fold - _builder.get_fold_angle()) > 0.001:
			_builder.set_fold_angle(fold)
			_builder.refresh_collision_mesh()
			_prop.setup_collision()
	_update_prompt()
	set_process(false)


func is_deployed() -> bool:
	if _builder == null:
		return false
	return _builder.get_fold_angle() >= _builder.closed_angle() - DEPLOY_EPS


func is_animating() -> bool:
	return _animating


## Fold to `angle` with the same sweep (the crew's build pose before a
## pack-up). deploy_state_changed fires when it settles; at the pose already
## it settles at once.
func fold_to(angle: float) -> void:
	if _builder == null:
		return
	if not _animating:
		_fold = _builder.get_fold_angle()
		_since = 0.0
	_target_rad = angle
	if absf(_fold - angle) < 1e-4:
		_animating = false
		_builder.set_fold_angle(angle)
		_settle.call_deferred()
		return
	var span := maxf(_builder.closed_angle() - maxf(_builder.min_fold_angle(), LinkageKinematics.MIN_FOLD_ANGLE), 0.01)
	_rate = (span / FULL_CYCLE_S) * (1.0 if angle > _fold else -1.0)
	_animating = true
	set_process(true)
	_update_prompt()


## Interact entry point: deploy when stowed (or mid-stow), stow when deployed.
func toggle_deploy() -> void:
	if _builder == null:
		return
	# A build rehearsal owns the fold while its crew works.
	var site := _prop.get_node_or_null(PalletRackBuildSite.NODE_NAME) as PalletRackBuildSite if _prop != null else null
	if site != null and site.is_running():
		return
	var closed := _builder.closed_angle()
	var stowed := maxf(_builder.min_fold_angle(), LinkageKinematics.MIN_FOLD_ANGLE)
	var deploying: bool
	if _animating:
		deploying = _rate < 0.0   # reverse mid-flight
	else:
		deploying = not is_deployed()
	_target_rad = closed if deploying else stowed
	if not _animating:
		_fold = _builder.get_fold_angle()
		_since = 0.0
	var span := maxf(closed - stowed, 0.01)
	_rate = (span / FULL_CYCLE_S) * (1.0 if deploying else -1.0)
	_animating = true
	set_process(true)
	_update_prompt()


func _process(delta: float) -> void:
	PerfSpan.begin("prop_ticks")
	_perf_tick(delta)
	PerfSpan.end("prop_ticks")


## The per-frame body; `_process` above only times it.
func _perf_tick(delta: float) -> void:
	if not _animating or _builder == null:
		set_process(false)
		return
	_fold += _rate * delta
	_since += delta
	var done := (_rate > 0.0 and _fold >= _target_rad) or (_rate < 0.0 and _fold <= _target_rad)
	if done:
		_fold = _target_rad
	var gap := 0.0
	if _builder.fold_cost_ms > HEAVY_FOLD_MS:
		gap = minf(_builder.fold_cost_ms * FOLD_GAP_PER_MS, MAX_FOLD_GAP_S)
	if done or _since >= gap:
		_since = 0.0
		_builder.set_fold_angle(_fold)
	if done:
		_animating = false
		set_process(false)
		_settle()


## Motion stopped: rebuild walkable collision, persist pose, notify listeners.
func _settle() -> void:
	_builder.refresh_collision_mesh()
	if _prop != null:
		_prop.setup_collision()
	_update_prompt()
	var deployed := is_deployed()
	var main := _find_main()
	if main != null and _prop != null and not _prop.prop_id.is_empty():
		PlacedPropService.update_prop_record(main, _prop.prop_id, {
			"linkage_fold_deg": rad_to_deg(_builder.get_fold_angle()),
			"linkage_deployed": deployed,
		})
		# Deploy-gate the structure's graph array: stowed = folded away, no
		# capacity until redeployed (mirrors how destroyed controllers shed AC).
		var sgv := ServiceLocator.graph()
		if sgv == null:
			sgv = main.find_child("SystemGraphView", true, false)
		if sgv != null and sgv.has_method("set_imported_array_stowed"):
			sgv.call("set_imported_array_stowed",
				PlacedPropService.linkage_array_tag(_prop.prop_id), not deployed)
	deploy_state_changed.emit(deployed)


func _update_prompt() -> void:
	if _prop == null:
		return
	if _animating:
		_prop.prompt = "Reverse fold (Interact)"
	elif is_deployed():
		_prop.prompt = "Stow structure (Interact) / Edit (click)"
	else:
		_prop.prompt = "Deploy structure (Interact) / Edit (click)"


func _find_main() -> Node:
	if not is_inside_tree():
		return null
	var tree := get_tree()
	if tree == null:
		return null
	return tree.current_scene
