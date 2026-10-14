class_name ChoreLedger
extends RefCounted

## Per-map human-attention (chore hours) ledger.
##
## Since the labour merge this is the **meter, not the supply**. A recipe step
## that needs hands no longer draws from an abstract pool — it mints a real
## chore at the machine (NpcPopulationBridge.ensure_machine_chore) and waits
## for somebody to walk over and do it. The completed chore's effect calls the
## same `confirm_chore` the player's button always did, which debits here — so
## the totals that feed the Site Report keep working, with the crew as the
## gate. One code path, two roles, no duplicate accounting.
##
##   - infinite_labor TRUE: the old behaviour — auto-debit never pauses, and
##     machines effectively run themselves. Now a DIFFICULTY setting.
##   - infinite_labor FALSE: labour-gated steps wait for the crew (or for the
##     player's Confirm, which stays as the override when no crew can reach).
##   - require_confirm steps always pause for the player regardless: the
##     designer asked for a decision, not for hands.
##
## Persisted at user://maps/labor_<lat>_<lon>.json

const VERSION := 1

## Default for a map that has never had a ledger saved. FALSE so new sites get
## the crew-gated behaviour; `TerrainLoader` keeps a LOADED ledger exactly as
## it was, so no existing site silently stops producing.
const DEFAULT_INFINITE_FOR_NEW_MAPS := false

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
	return WorldPaths.site_file("labor", lat, lon)


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


## Record hours a REAL PERSON actually worked. Never refuses, and never draws
## down `chore_hours_available`, because the labour did not come from that
## pool — a crew member walked to the machine and did it. This is the ledger
## acting as the METER while the crew is the gate; `try_debit` remains the
## abstract-pool path for `infinite_labor` maps and the player's own Confirm.
##
## Without this the merge deadlocks in the obvious way: finite labour means an
## empty pool, an empty pool refuses the debit, and the step the crew just
## finished refuses to resume.
func record_worked(hours: float) -> void:
	if hours <= 0.0:
		return
	chore_hours_consumed_total += hours
	chore_hours_consumed_ytd += hours


func set_infinite(v: bool) -> void:
	infinite_labor = v
