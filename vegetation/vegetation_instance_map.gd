class_name VegetationInstanceMap
extends RefCounted

## Maps bulk vegetation records to live MultiMesh instance slots for in-place
## growth-scale updates without a full rebuild (Phase 2 climelapse perf path).
##
## ONE ENTRY PER PLANT, not per MultiMesh slot (veg overhaul Phase 9). A tree in
## the NEAR ring lives in two MultiMeshes (leaf-shell tier + its FAR pair), so
## the map used to hold 2–3 entries for the same plant and a full growth pass
## re-ran the terrain height query and the growth-curve math once per SLOT — on
## a large map that was ~408k ground_y_at calls where ~150k plants exist. The
## per-plant entry now carries a list of slots: the query and the scale are
## computed once, and only the transform write repeats.
##
## The dedupe key is species + rounded position. Two plants of one species at
## the exact same coordinates would share an entry, which is visually identical
## (they already draw at the same transform) — this is deliberately not keyed on
## the record Dictionary, whose hashing is O(keys) per registration.

## Position quantisation for the dedupe key, in metres. Well under any real
## plant spacing, and far above float32 transform noise.
const KEY_PRECISION := 0.01


class PlantEntry:
	extends RefCounted

	var record: Dictionary = {}
	var species := ""
	var base_scale := 1.0
	var vert_off := 0.0
	var foot_y := 0.0
	var align := false
	var x := 0.0
	var z := 0.0
	var yaw := 0.0
	var ground_y := NAN
	## [{mmi, idx, reground}] — every MultiMesh slot drawing THIS plant.
	var slots: Array = []


var _entries: Array[PlantEntry] = []
## key -> index into _entries. Build-time lookup; kept afterwards (a few bytes
## per plant) so a partial rebuild can still find an existing plant.
var _index: Dictionary = {}
var _cursor := 0
var _slot_count := 0


func clear() -> void:
	_entries.clear()
	_index.clear()
	_cursor = 0
	_slot_count = 0


## Growth multiplier for entry `index` at the given settings (no base_scale).
func scale_mult_at(index: int, settings: Dictionary) -> float:
	if index < 0 or index >= _entries.size():
		return 1.0
	var e := _entries[index]
	return VegetationGrowth.instance_scale_mult(e.species, e.record, settings)


func is_empty() -> bool:
	return _entries.is_empty()


## Number of PLANTS (what a growth pass costs). Was the slot count before the
## Phase 9 dedupe — the growth selftest pins the difference.
func entry_count() -> int:
	return _entries.size()


## Number of MultiMesh slots across all plants (entry_count × tiers).
func slot_count() -> int:
	return _slot_count


func reset_cursor() -> void:
	_cursor = 0


static func _key(species: String, x: float, z: float) -> String:
	return "%s|%d|%d" % [species, roundi(x / KEY_PRECISION), roundi(z / KEY_PRECISION)]


## Register one MultiMesh slot. `base_scale` is the draw scale BEFORE the growth
## multiplier (record.scale × species bulk scale, matching rebuild paths).
## Repeated calls for the same plant (its other LOD tiers) attach another slot to
## the existing entry rather than duplicating the work it implies.
##
## `reground` false marks a slot whose transform should reuse the ground height
## sampled when the plant was registered — the OUTER-ring impostor tier, where
## the quad is a camera-facing card and a per-pass terrain query buys nothing.
func add(mmi: MultiMeshInstance3D, idx: int, record: Dictionary, species: String,
		base_scale: float, vert_off: float, foot_y: float, align_to_surface: bool,
		x: float, z: float, yaw: float, ground_y: float = NAN,
		reground: bool = true) -> void:
	if mmi == null or record.is_empty():
		return
	var key := _key(species, x, z)
	var slot := {"mmi": mmi, "idx": idx, "reground": reground}
	_slot_count += 1
	if _index.has(key):
		var existing := _entries[int(_index[key])]
		existing.slots.append(slot)
		# A later tier may know the ground height when the first did not.
		if is_nan(existing.ground_y) and not is_nan(ground_y):
			existing.ground_y = ground_y
		return
	var e := PlantEntry.new()
	e.record = record
	e.species = species
	e.base_scale = base_scale
	e.vert_off = vert_off
	e.foot_y = foot_y
	e.align = align_to_surface
	e.x = x
	e.z = z
	e.yaw = yaw
	e.ground_y = ground_y
	e.slots = [slot]
	_index[key] = _entries.size()
	_entries.append(e)


## Update transforms from the growth clock. `budget` < 0 applies all remaining
## entries; `budget` > 0 applies at most that many PLANTS. Returns remaining
## budget (0 if exhausted mid-pass, unchanged if budget < 0). Resets cursor to 0
## when the full map has been updated.
func apply_scales(settings: Dictionary, ground_y_at: Callable, budget: int) -> int:
	var rem := budget
	while _cursor < _entries.size():
		if rem == 0:
			break
		var e := _entries[_cursor]
		_cursor += 1
		if e.slots.is_empty():
			continue
		var scale: float = e.base_scale \
			* VegetationGrowth.instance_scale_mult(e.species, e.record, settings)
		# One terrain query per PLANT (it was one per tier), and none at all when
		# every slot is scale-only.
		var gy := e.ground_y
		if _entry_needs_ground(e):
			gy = float(ground_y_at.call(e.x, e.z))
			e.ground_y = gy
		elif is_nan(gy):
			gy = float(ground_y_at.call(e.x, e.z))
			e.ground_y = gy
		var xform := VegetationPaint.build_transform(
			e.x, gy, e.z, e.yaw, scale, e.align, Vector3.UP, e.vert_off, e.foot_y)
		var i := 0
		while i < e.slots.size():
			var slot: Dictionary = e.slots[i]
			# Read UNTYPED first: assigning a freed instance to a typed
			# MultiMeshInstance3D variable throws at the assignment, before any
			# is_instance_valid() guard can run.
			var raw: Variant = slot.get("mmi")
			if not is_instance_valid(raw) or not (raw is MultiMeshInstance3D):
				# The tier was freed by a rebuild; drop the slot, keep the plant.
				e.slots.remove_at(i)
				_slot_count = maxi(_slot_count - 1, 0)
				continue
			var mmi := raw as MultiMeshInstance3D
			if mmi.multimesh == null:
				e.slots.remove_at(i)
				_slot_count = maxi(_slot_count - 1, 0)
				continue
			mmi.multimesh.set_instance_transform(int(slot.get("idx", 0)), xform)
			i += 1
		if rem > 0:
			rem -= 1
	if _cursor >= _entries.size():
		_cursor = 0
	return rem


static func _entry_needs_ground(e: PlantEntry) -> bool:
	for slot in e.slots:
		if bool((slot as Dictionary).get("reground", true)):
			return true
	return false
