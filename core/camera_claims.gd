class_name CameraClaims
extends RefCounted

## An ordered stack of temporary claims on which camera is live.
##
## Why this exists: about eleven subsystems each swap the active camera by
## hand — set `.current = true`, remember the previous one in a private field,
## put it back on exit. That works alone and breaks the moment two overlap,
## because the second one snapshots the FIRST one's temporary camera and
## restores that instead of the player's:
##
##     harness capture starts -> saves PlayerCam, makes CaptureCam current
##     snowglobe opens        -> saves CaptureCam (!), makes GlobeCam current
##     snowglobe closes       -> restores CaptureCam
##     capture ends           -> frees CaptureCam
##
## and the viewport is left on a freed camera with nothing to restore it. This
## is the exact bug `core/clock_claims.gd` was written to kill for the clock,
## and the fix is the same: claims keyed by OWNER, resolved by precedence, so
## `release()` never has to know what came before it.
##
## Contract (identical to ClockClaims, deliberately — one idiom, learned once):
##   - claim()/release() are idempotent and order-independent.
##   - Re-claiming under a live owner replaces its values in place, never stacks.
##   - The top-most claim wins; with none, the base camera shows through.
##   - An EXCLUSIVE claim sits on top and makes competing claims a logged no-op.
##
## Values a claim may carry: `camera_id` (int), `hide_player_mesh` (bool),
## `shadow_max_distance` (float), `prop_cull_scale_m` (float),
## `capture_mouse` (bool). Cameras are held as `Object.get_instance_id()`
## rather than as nodes so this file stays PURE and offline-testable; Main
## resolves the id and owns every side effect. See core/camera_claims_selftest.gd.
##
## NOT claimants, permanently — do not "finish the job" by converting them:
## the six SubViewport modal previews (building builder, conduit style,
## connection port, machine setup, mud designer, print setup) and
## `graph_model_preview_service` each own a PRIVATE World3D, and
## `graph_soi_preview_service` renders the shared world into its own
## SubViewport. None of them ever touches the main viewport's active camera,
## so none of them is competing for anything.

signal effective_changed(values: Dictionary)

var _claims: Array[Dictionary] = []


func claim(owner: String, values: Dictionary, exclusive: bool = false) -> bool:
	if owner.is_empty():
		push_error("CameraClaims.claim: empty owner")
		return false
	var holder := exclusive_owner()
	if not holder.is_empty() and holder != owner:
		print("CameraClaims: '%s' refused — '%s' holds the camera exclusively" % [owner, holder])
		return false
	var before := effective()
	var idx := _index_of(owner)
	if idx >= 0:
		_claims[idx]["values"] = values.duplicate(true)
		_claims[idx]["exclusive"] = exclusive
	else:
		_claims.append({
			"owner": owner,
			"values": values.duplicate(true),
			"exclusive": exclusive,
		})
	_emit_if_changed(before)
	return true


## Drop `owner`'s claim. Safe when it holds none — which is what makes it safe
## on every exit path, including one that runs twice.
func release(owner: String) -> void:
	var idx := _index_of(owner)
	if idx < 0:
		return
	var before := effective()
	_claims.remove_at(idx)
	_emit_if_changed(before)


func has_claim(owner: String) -> bool:
	return _index_of(owner) >= 0


func is_empty() -> bool:
	return _claims.is_empty()


func exclusive_owner() -> String:
	for i in range(_claims.size() - 1, -1, -1):
		if bool(_claims[i].get("exclusive", false)):
			return str(_claims[i].get("owner", ""))
	return ""


## Merged values of the top-most claim, or {} when there are none.
func effective() -> Dictionary:
	if _claims.is_empty():
		return {}
	return (_claims[-1].get("values", {}) as Dictionary).duplicate(true)


## Value for `key` from the top-most claim that DEFINES it, else `base`. Falls
## through claims that omit the key, so a claim carrying only
## `prop_cull_scale_m` cannot blank out an underlying camera_id.
func value_or(key: String, base: Variant) -> Variant:
	for i in range(_claims.size() - 1, -1, -1):
		var vals: Dictionary = _claims[i].get("values", {}) as Dictionary
		if vals.has(key):
			return vals[key]
	return base


## The camera the stack currently wants live, or 0 for "the base camera".
func effective_camera_id() -> int:
	return int(value_or("camera_id", 0))


func owners() -> Array[String]:
	var out: Array[String] = []
	for c: Dictionary in _claims:
		out.append(str(c.get("owner", "")))
	return out


func clear() -> void:
	if _claims.is_empty():
		return
	var before := effective()
	_claims.clear()
	_emit_if_changed(before)


func _index_of(owner: String) -> int:
	for i in _claims.size():
		if str(_claims[i].get("owner", "")) == owner:
			return i
	return -1


func _emit_if_changed(before: Dictionary) -> void:
	var now := effective()
	if str(before) != str(now):
		effective_changed.emit(now)
