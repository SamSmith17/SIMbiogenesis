class_name ClockClaims
extends RefCounted

## An ordered stack of temporary claims on world-clock state.
##
## Why this exists: nine different subsystems each did the same thing by hand —
## stash `main.time_scale` in a private `_saved_time_scale`, set their own value,
## and write the saved one back on exit. That works alone and breaks the moment
## two of them overlap, because the second one snapshots the FIRST one's
## temporary value and restores that instead of the user's:
##
##     CSV playback starts   -> saves 0.01 (the user's), sets 0.0
##     SoI snowglobe opens   -> saves 0.0  (CSV's!),     sets 0.0
##     snowglobe closes      -> restores 0.0
##     CSV playback ends     -> restores 0.01
##
## Between those last two the clock is stuck paused with nothing left to unpause
## it, and the user has no way to tell why. There is no ordering of the same
## save/restore pattern that fixes this: the bug is the private "previous"
## field, so this replaces it. Claims are keyed by OWNER and resolved by
## precedence, so `release()` never has to know what came before it.
##
## Contract:
##   - claim()/release() are idempotent and order-independent.
##   - Re-claiming under a live owner replaces that owner's values in place; it
##     does NOT stack, so a repeated call cannot leak a claim.
##   - The top-most claim wins. With no claims, the base value shows through.
##   - An EXCLUSIVE claim (video export, challenge bake — the "this system owns
##     the clock" contract) sits on top and makes any competing claim a logged
##     no-op until released.
##
## Pure logic, no engine state: everything here is unit-testable offline. See
## core/clock_claims_selftest.gd.

## Emitted whenever the effective (top-most) claim changes, including on release
## back to base. Carries the merged values so a listener can apply side-effecting
## properties it owns — Main uses this for `analemma_mode`, which lives on Main
## rather than on the clock and has a setter with side effects.
signal effective_changed(values: Dictionary)

var _claims: Array[Dictionary] = []   # [{owner: String, values: Dictionary, exclusive: bool}]


## Take or update a claim. `values` is a free-form dict — the clock reads
## "time_scale", Main reads "analemma_mode" — so one claim covers state owned by
## more than one node without needing two stacks that could disagree.
## Returns false when refused by a foreign exclusive claim.
func claim(owner: String, values: Dictionary, exclusive: bool = false) -> bool:
	if owner.is_empty():
		push_error("ClockClaims.claim: empty owner")
		return false
	var holder := exclusive_owner()
	if not holder.is_empty() and holder != owner:
		# Not an error: a UI claim arriving mid-export is expected and simply
		# does not get the clock. Logged so it is visible if it was a surprise.
		print("ClockClaims: '%s' refused — '%s' holds the clock exclusively" % [owner, holder])
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


## Drop `owner`'s claim. Safe to call when it holds none — which is what makes
## it safe on every exit path, including one that runs twice.
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


## The owner of the current exclusive claim, or "" when none. Exposed so UI can
## disable speed controls rather than let the user press a button that a logged
## no-op will silently swallow.
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


## Value for `key` from the top-most claim that defines it, else `base`.
## Falls THROUGH claims that do not carry the key, so a claim covering only
## analemma_mode does not blank out an underlying time_scale claim.
func value_or(key: String, base: Variant) -> Variant:
	for i in range(_claims.size() - 1, -1, -1):
		var vals: Dictionary = _claims[i].get("values", {}) as Dictionary
		if vals.has(key):
			return vals[key]
	return base


## Owners currently holding a claim, bottom to top. Diagnostics only.
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
	if now != before:
		effective_changed.emit(now)
