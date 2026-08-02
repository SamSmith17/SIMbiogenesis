class_name VegAssetCache
extends RefCounted

## Process-wide memo for procedurally BUILT vegetation assets (ArrayMesh /
## ShaderMaterial), keyed by content — conventionally
## "<kind>|<species>|<tier>|<hash(settings)>". Before this cache existed the
## runtimes regenerated an identical mesh + procedural FastNoise texture PER
## 256 m CHUNK PER LOD TIER: a large auto map rebuilt ~288 deciduous meshes and
## ~576 procedural textures on every load/rebuild, none shared. Sharing one
## mesh/material per distinct settings dict also collapses
## VegetationEnvironmentSync's per-material seasonal/wind uniform pushes.
##
## Trusting hash(settings) for identity matches the runtimes' own batch
## partitioning (_batch_settings_key): identical dicts share, distinct dicts
## fork. Bounded: past MAX_ENTRIES the whole cache clears — the next rebuild
## repopulates only what is actually in use (simple and allocation-free vs a
## true LRU; rebuilds are already the slow path).

const MAX_ENTRIES := 128

static var _cache: Dictionary = {}
static var _hits := 0
static var _misses := 0


static func fetch(key: String) -> Variant:
	var v: Variant = _cache.get(key)
	if v != null:
		_hits += 1
	return v


static func store(key: String, asset: Variant) -> Variant:
	_misses += 1
	if _cache.size() >= MAX_ENTRIES:
		_cache.clear()
	_cache[key] = asset
	return asset


## Call whenever a style/settings change could produce a DIFFERENT asset for
## the SAME key — i.e. anything that mutates dicts in place rather than
## producing a new settings dict (apply_vegetation_look does this).
static func clear() -> void:
	_cache.clear()


static func stats() -> Dictionary:
	return {"entries": _cache.size(), "hits": _hits, "misses": _misses}
