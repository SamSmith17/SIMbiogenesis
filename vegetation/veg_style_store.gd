class_name VegStyleStore
extends RefCounted

## Layered vegetation style store (veg overhaul Phase 2) — the ONE authority
## for user style persistence, replacing three flat files that merged
## last-writer-wins (global cfg, species-defaults JSON, per-map JSON).
##
## v2 schema (global file + per-map file, both JSON):
##   { "veg_style_version": 2,
##     "global":  { <unprefixed key>: value },          # wind/haze/auto_* …
##     "family":  { "pine": { "card_w": 1.3, … } },     # family-scoped edits
##     "species": { "spruce": { "card_w": 0.9, … } } }  # per-subspecies edits
##
## Resolution precedence (VegSpeciesCatalog.settings_with_variant consumes the
## side channels this store emits):
##   species override > user family edit > catalog SPECS variant > defaults()
##
## The layers hold ONLY explicit user edits — that sparseness is the entire
## fix. v1 files merged complete dicts, so the family keys ALWAYS existed and
## `_fill_missing` never applied a variant's SPECS dims: every subspecies
## rendered identical ("all subspecies are placeholders"). Migration therefore
## drops any v1 value equal to defaults() (which also purges the residue of
## the old terrain-options bug that saved a full defaults dump as "user
## edits").
##
## Migration is one-way and non-destructive: v1 files are read once when no
## v2 file exists, and left on disk untouched.

## v3 (Vegetation Overhaul v2): FRESH START. The v3 model retired the entire
## legacy tree-shape key set (real-world units + archetypes replaced it), so
## old stores are not migrated — v3 lives in NEW files and the old
## vegetation_style_v2*/v1 files simply stay on disk, unread (the de-facto
## backup). Painted tree POSITIONS live in the vegetation layer and survive.
const GLOBAL_V2_PATH := "user://vegetation_style_v3.json"
const VERSION := 3

## Family prefixes for flat-key splitting, longest first so grass_lawn_card_w
## never mis-splits as family "grass".
const FAMILY_PREFIXES: Array[String] = [
	"grass_field", "grass_lawn", "deciduous", "shrub", "pine",
]

## Reserved side-channel keys embedded in the flat merged dict. They ride the
## normal settings plumbing (and its hash-based batching) untouched.
const KEY_USER_FAMILY := "_user_family_keys"
const KEY_SPECIES_OVERRIDES := "_species_overrides"
## Species ids whose override came from THIS MAP's store (Select → Tune look →
## "All of these in this world"). Present only when non-empty, so a map
## without one resolves byte-identically. See settings_with_variant.
const KEY_MAP_SPECIES := "_map_species"

## Test hook: suffixed onto every file path so the selftest never touches the
## player's real style files.
static var path_suffix := ""

static var _global_cache: Dictionary = {}
static var _global_cache_valid := false


static func global_v2_path() -> String:
	return GLOBAL_V2_PATH + path_suffix


static func map_v2_path(lat: float, lon: float) -> String:
	return WorldPaths.site_file("vegetation_style_v3", lat, lon, "json" + path_suffix)


## The RETIRED v2/v1 style files for this map (kept on disk, never read; the
## reset tooling deletes them so "Reset site" really is fresh).
static func legacy_style_paths(lat: float, lon: float) -> Array[String]:
	return [
		WorldPaths.site_file("vegetation_style_v2", lat, lon, "json" + path_suffix),
		legacy_map_path(lat, lon),
	]


static func legacy_map_path(lat: float, lon: float) -> String:
	return WorldPaths.site_file("vegetation_style", lat, lon, "json" + path_suffix)


static func invalidate_cache() -> void:
	_global_cache_valid = false


# --- store loading ----------------------------------------------------------


static func empty_store() -> Dictionary:
	return {"veg_style_version": VERSION, "global": {}, "family": {}, "species": {}}


static func load_global_store() -> Dictionary:
	if _global_cache_valid:
		return _global_cache.duplicate(true)
	var store := _read_store(global_v2_path())
	if store.is_empty():
		store = empty_store()
	_global_cache = store.duplicate(true)
	_global_cache_valid = true
	return store


static func load_map_store(lat: float, lon: float) -> Dictionary:
	var store := _read_store(map_v2_path(lat, lon))
	if store.is_empty():
		store = empty_store()
	return store


## The flat settings dict every existing consumer understands: defaults() +
## user global keys + user family keys (re-prefixed), plus the two side
## channels for per-species resolution. Drop-in replacement for the old
## VegetationStyleConfig.load_merged().
static func flat_merged(lat: float, lon: float) -> Dictionary:
	var out: Dictionary = VegetationStyleConfig.defaults()
	var user_family: Dictionary = {}
	var species_over: Dictionary = {}
	var map_store := load_map_store(lat, lon)
	for store in [load_global_store(), map_store]:
		_apply_store_into(store, out, user_family, species_over)
	var fam_keys: Array = user_family.keys()
	fam_keys.sort()
	out[KEY_USER_FAMILY] = fam_keys
	out[KEY_SPECIES_OVERRIDES] = species_over
	var map_sps: Array = []
	var raw_sps: Variant = map_store.get("species", {})
	if raw_sps is Dictionary:
		for sid in (raw_sps as Dictionary):
			map_sps.append(str(sid))
	if not map_sps.is_empty():
		map_sps.sort()
		out[KEY_MAP_SPECIES] = map_sps
	return out


static func _apply_store_into(store: Dictionary, out: Dictionary,
		user_family: Dictionary, species_over: Dictionary) -> void:
	var g: Dictionary = store.get("global", {})
	for k in g:
		out[str(k)] = g[k]
	var fams: Dictionary = store.get("family", {})
	for fam in fams:
		var fd: Dictionary = fams[fam]
		for k in fd:
			var flat_key := "%s_%s" % [fam, k]
			out[flat_key] = fd[k]
			user_family[flat_key] = true
	var sps: Dictionary = store.get("species", {})
	for sid in sps:
		var sd: Dictionary = sps[sid]
		if not species_over.has(sid):
			species_over[sid] = {}
		var tgt: Dictionary = species_over[sid]
		for k in sd:
			tgt[str(k)] = sd[k]


# --- writes ------------------------------------------------------------------


## Persist a FLAT patch of user edits at global scope: family-prefixed keys go
## to the family layer, everything else to the global layer. Merge, not
## clobber (matches old save_global semantics).
##
## Values equal to defaults() are PRUNED, not stored: the layers hold only
## explicit user edits (the Phase 2 invariant). The Tune-look modal's "Apply to
## map" sends every slider key, and storing the untouched ones as user family
## edits would shadow every SPECS subspecies variant forever — the exact
## "all subspecies are placeholders" bug the v2 store exists to fix. Pruning
## (rather than skipping) also erases a key the player moved and later moved
## BACK to its default, and cleans residue from earlier polluting applies.
static func save_global_patch(patch: Dictionary) -> void:
	var store := load_global_store()
	var defaults: Dictionary = VegetationStyleConfig.defaults()
	var sets := {}
	var prunes: Array[String] = []
	for k in patch:
		var key := str(k)
		if key.begins_with("_"):
			continue
		if defaults.has(key) and values_equal(defaults[key], patch[k]):
			prunes.append(key)
		else:
			sets[key] = patch[k]
	_split_flat_into(sets, store)
	_prune_flat_keys(prunes, store)
	_write_store(global_v2_path(), store)
	invalidate_cache()


## Remove flat keys from whichever layer they live in (global / family /
## subspecies-tint species layer).
static func _prune_flat_keys(keys: Array[String], store: Dictionary) -> void:
	var g: Dictionary = store.get("global", {})
	var fams: Dictionary = store.get("family", {})
	var sps: Dictionary = store.get("species", {})
	for key in keys:
		var sub_split := _split_subspecies_tint(key)
		if not sub_split.is_empty():
			var cur: Dictionary = sps.get(sub_split[0], {})
			cur.erase(sub_split[1])
			if cur.is_empty():
				sps.erase(sub_split[0])
			else:
				sps[sub_split[0]] = cur
			continue
		var parts := split_flat_key(key)
		if str(parts[0]).is_empty():
			g.erase(key)
		else:
			var fd: Dictionary = fams.get(parts[0], {})
			fd.erase(str(parts[1]))
			if fd.is_empty():
				fams.erase(parts[0])
			else:
				fams[str(parts[0])] = fd
	store["global"] = g
	store["family"] = fams
	store["species"] = sps


## Persist a full flat style for one map. Sparse: only values differing from
## defaults() are written (per-map files no longer freeze a complete dict).
static func save_map_style(lat: float, lon: float, flat_style: Dictionary) -> void:
	var store := load_map_store(lat, lon)
	store["global"] = {}
	store["family"] = {}
	# species layer is preserved as-is: per-map species edits are only written
	# through save_species_override(..., map coords).
	var defaults: Dictionary = VegetationStyleConfig.defaults()
	var sparse := {}
	for k in flat_style:
		var key := str(k)
		if key.begins_with("_") or key == "drape_tex" or key == "drape_extent_m" \
				or key == "seasonal_tint":
			continue
		if defaults.has(key) and values_equal(defaults[key], flat_style[k]):
			continue
		sparse[key] = flat_style[k]
	_split_flat_into(sparse, store)
	_write_store(map_v2_path(lat, lon), store)


## Persist per-subspecies overrides (unprefixed keys: card_w, albedo_tint, …)
## at GLOBAL scope. Values equal to the family flat key are still stored —
## an explicit species save is an explicit user choice.
##
## An entry saved for a GENERIC family id ("Save as species default" while
## plain Deciduous was selected) stays in the species layer, but resolution
## treats it as the WEAKEST user layer: settings_with_variant only applies it
## where no user family edit exists, so a map's own tuning (or a later
## family-wide Apply) always wins — it used to outrank per-map family edits
## and "my per-map tuning does nothing" was the visible symptom. It also never
## touches named subspecies, so their SPECS dims survive.
static func save_species_override(species: String, values: Dictionary) -> void:
	if species.is_empty() or values.is_empty():
		return
	var store := load_global_store()
	var sps: Dictionary = store.get("species", {})
	var cur: Dictionary = sps.get(species, {})
	for k in values:
		cur[str(k)] = values[k]
	sps[species] = cur
	store["species"] = sps
	_write_store(global_v2_path(), store)
	invalidate_cache()


## The same, for ONE map: values land in that map's species layer, which
## flat_merged applies after the global one (so per key, this map wins) and
## lists under KEY_MAP_SPECIES.
static func save_species_override_map(lat: float, lon: float, species: String,
		values: Dictionary) -> void:
	if species.is_empty() or values.is_empty():
		return
	var store := load_map_store(lat, lon)
	var sps: Dictionary = store.get("species", {})
	var cur: Dictionary = sps.get(species, {})
	for k in values:
		cur[str(k)] = values[k]
	sps[species] = cur
	store["species"] = sps
	_write_store(map_v2_path(lat, lon), store)
	invalidate_cache()


## Drop `keys` from one map's species entry (an empty entry is removed) — a
## new every-world default must not stay shadowed on the map it was set on.
static func remove_species_override_keys_map(lat: float, lon: float, species: String,
		keys: Array) -> void:
	var store := load_map_store(lat, lon)
	var sps: Dictionary = store.get("species", {})
	if not sps.has(species):
		return
	var cur: Dictionary = sps[species]
	for k in keys:
		cur.erase(str(k))
	if cur.is_empty():
		sps.erase(species)
	else:
		sps[species] = cur
	store["species"] = sps
	_write_store(map_v2_path(lat, lon), store)
	invalidate_cache()


static func species_override(species: String) -> Dictionary:
	var store := load_global_store()
	var sps: Dictionary = store.get("species", {})
	var raw: Variant = sps.get(species, {})
	return (raw as Dictionary).duplicate(true) if raw is Dictionary else {}


static func clear_species_override(species: String) -> void:
	var store := load_global_store()
	var sps: Dictionary = store.get("species", {})
	if sps.has(species):
		sps.erase(species)
		store["species"] = sps
		_write_store(global_v2_path(), store)
		invalidate_cache()


# --- key splitting ------------------------------------------------------------


## "pine_card_w" -> ["pine", "card_w"]; unprefixed keys -> ["", key].
## Tint keys for NAMED SUBSPECIES ("spruce_albedo_tint") -> species layer.
static func split_flat_key(key: String) -> Array:
	for fam in FAMILY_PREFIXES:
		if key.begins_with(fam + "_"):
			return [fam, key.substr(fam.length() + 1)]
	return ["", key]


static func _split_flat_into(patch: Dictionary, store: Dictionary) -> void:
	var g: Dictionary = store.get("global", {})
	var fams: Dictionary = store.get("family", {})
	var sps: Dictionary = store.get("species", {})
	for k in patch:
		var key := str(k)
		if key.begins_with("_"):
			continue
		var sub_split := _split_subspecies_tint(key)
		if not sub_split.is_empty():
			var sid: String = sub_split[0]
			var cur: Dictionary = sps.get(sid, {})
			cur[sub_split[1]] = patch[k]
			sps[sid] = cur
			continue
		var parts := split_flat_key(key)
		if str(parts[0]).is_empty():
			g[key] = patch[k]
		else:
			var fd: Dictionary = fams.get(parts[0], {})
			fd[str(parts[1])] = patch[k]
			fams[str(parts[0])] = fd
	store["global"] = g
	store["family"] = fams
	store["species"] = sps


## "spruce_albedo_tint" -> ["spruce", "albedo_tint"] for NAMED subspecies only
## (family tints stay at family level). Empty when not a subspecies tint key.
static func _split_subspecies_tint(key: String) -> Array:
	for suffix in ["_albedo_tint", "_highlight_tint"]:
		if key.ends_with(suffix):
			var sid := key.substr(0, key.length() - suffix.length())
			if sid in VegSpeciesCatalog.BASE_FAMILIES:
				return []
			if VegSpeciesCatalog.MESH_FAMILY.has(sid):
				return [sid, suffix.substr(1)]
	return []


# --- v1 migration -------------------------------------------------------------


# --- helpers -------------------------------------------------------------------


static func _store_is_empty(store: Dictionary) -> bool:
	if store.is_empty():
		return true
	return (store.get("global", {}) as Dictionary).is_empty() \
		and (store.get("family", {}) as Dictionary).is_empty() \
		and (store.get("species", {}) as Dictionary).is_empty()


static func values_equal(a: Variant, b: Variant) -> bool:
	if a is Color and b is Color:
		return (a as Color).is_equal_approx(b as Color)
	if (a is float or a is int) and (b is float or b is int):
		return absf(float(a) - float(b)) < 0.0005
	if a is Dictionary and b is Dictionary:
		var da: Dictionary = a
		var db: Dictionary = b
		if da.size() != db.size():
			return false
		for k in da:
			if not db.has(k) or not values_equal(da[k], db[k]):
				return false
		return true
	return a == b


static func _read_store(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return {}
	var d: Dictionary = parsed
	if int(d.get("veg_style_version", 0)) != VERSION:
		return {}
	var store := {
		"veg_style_version": VERSION,
		"global": VegetationStyleConfig.from_serializable(d.get("global", {}) as Dictionary),
		"family": _levels_from_json(d.get("family", {}) as Dictionary),
		"species": _levels_from_json(d.get("species", {}) as Dictionary),
	}
	_drop_black_tints(store)
	return store


## A tint is a MULTIPLIER on the leaf / needle / bark colour, so pure black
## renders the whole family as solid black silhouettes. No look wants that, and
## at least one saved map (Mount Vernon: pine albedo_tint [0,0,0,1]) carried
## exactly that — every pine printed black. Treat a (near-)black tint as an
## invalid edit and fall back to the layer below it; the next save drops it.
const BLACK_TINT_MAX := 0.02


## The pre-2026-10 `deciduous_albedo_tint` default. Under the old tint maths it
## was multiplied onto leaves already painted green (near-black crowns); stores
## that persisted it verbatim were saving the default, not a choice, so it is
## dropped too and the family falls back to untinted.
const LEGACY_DECIDUOUS_DEFAULT_TINT := Color(0.0435791, 0.19921875, 0.075193405)


static func is_black_tint(key: String, v: Variant) -> bool:
	if not key.contains("tint") or not (v is Color):
		return false
	var c: Color = v
	if maxf(c.r, maxf(c.g, c.b)) < BLACK_TINT_MAX:
		return true
	var o := LEGACY_DECIDUOUS_DEFAULT_TINT
	return key.contains("albedo_tint") and absf(c.r - o.r) < 0.002 \
			and absf(c.g - o.g) < 0.002 and absf(c.b - o.b) < 0.002


static func _drop_black_tints(store: Dictionary) -> void:
	var levels: Array = [store.get("global", {})]
	for group in ["family", "species"]:
		var g: Dictionary = store.get(group, {}) as Dictionary
		for id in g:
			levels.append(g[id])
	for lvl in levels:
		if not (lvl is Dictionary):
			continue
		var bad: Array = []
		for k in (lvl as Dictionary):
			if is_black_tint(str(k), lvl[k]):
				bad.append(k)
		for k in bad:
			push_warning("VegStyleStore: dropped stale '%s' tint (black / the old dark default)" % str(k))
			(lvl as Dictionary).erase(k)


static func _write_store(path: String, store: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"veg_style_version": VERSION,
		"global": VegetationStyleConfig.to_serializable(store.get("global", {}) as Dictionary),
		"family": _levels_to_json(store.get("family", {}) as Dictionary),
		"species": _levels_to_json(store.get("species", {}) as Dictionary),
	}, "\t"))


static func _levels_to_json(levels: Dictionary) -> Dictionary:
	var out := {}
	for id in levels:
		out[id] = VegetationStyleConfig.to_serializable(levels[id] as Dictionary)
	return out


static func _levels_from_json(levels: Dictionary) -> Dictionary:
	var out := {}
	for id in levels:
		if levels[id] is Dictionary:
			out[str(id)] = VegetationStyleConfig.from_serializable(levels[id] as Dictionary)
	return out
