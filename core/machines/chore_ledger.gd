class_name ChoreLedger
extends RefCounted

## Per-map human-attention (chore hours) ledger. Hybrid model:
##   - infinite_labor (default true): auto-debit never blocks for scarcity
##   - when infinite_labor is false, available hours gate auto steps
##   - require_confirm steps always pause for player Confirm regardless
##
## Persisted at user://maps/labor_<lat>_<lon>.json

const VERSION := 1

## When true, auto-debit steps never pause for insufficient labor.
var infinite_labor: bool = true
## Optional cap when infinite_labor is false (hours currently available).
var chore_hours_available: float = 8.0
## Lifetime / session accounting (Site Report hook).
var chore_hours_consumed_total: float = 0.0
var chore_hours_consumed_ytd: float = 0.0


static func create_default() -> ChoreLedger:
	return ChoreLedger.new()


func save_path_for_map(lat: float, lon: float) -> String:
	return "user://maps/labor_%s_%s.json" % [CoordToken.token(lat), CoordToken.token(lon)]


func save(lat: float, lon: float) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://maps"))
	var f := FileAccess.open(save_path_for_map(lat, lon), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(serialize()))


func load_for_map(lat: float, lon: float) -> bool:
	var path := save_path_for_map(lat, lon)
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return false
	deserialize(parsed as Dictionary)
	return true


func serialize() -> Dictionary:
	return {
		"version": VERSION,
		"infinite_labor": infinite_labor,
		"chore_hours_available": chore_hours_available,
		"chore_hours_consumed_total": chore_hours_consumed_total,
		"chore_hours_consumed_ytd": chore_hours_consumed_ytd,
	}


func deserialize(data: Dictionary) -> void:
	infinite_labor = bool(data.get("infinite_labor", true))
	chore_hours_available = maxf(float(data.get("chore_hours_available", 8.0)), 0.0)
	chore_hours_consumed_total = maxf(float(data.get("chore_hours_consumed_total", 0.0)), 0.0)
	chore_hours_consumed_ytd = maxf(float(data.get("chore_hours_consumed_ytd", 0.0)), 0.0)


## True if an auto (non-confirm) step of `hours` can proceed without pausing.
func can_auto_debit(hours: float) -> bool:
	if hours <= 0.0:
		return true
	if infinite_labor:
		return true
	return chore_hours_available + 1e-6 >= hours


## Debit hours. Returns false if scarcity blocks (only when not infinite).
func try_debit(hours: float) -> bool:
	if hours <= 0.0:
		return true
	if not infinite_labor and chore_hours_available + 1e-6 < hours:
		return false
	if not infinite_labor:
		chore_hours_available = maxf(chore_hours_available - hours, 0.0)
	chore_hours_consumed_total += hours
	chore_hours_consumed_ytd += hours
	return true


func credit_available(hours: float) -> void:
	if hours <= 0.0:
		return
	chore_hours_available += hours


func set_infinite(v: bool) -> void:
	infinite_labor = v
