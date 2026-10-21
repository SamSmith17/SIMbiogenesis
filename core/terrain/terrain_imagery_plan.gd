class_name TerrainImageryPlan
## What terrain imagery a quality tier asks for at a site — the detail drape,
## the sharp "hyper" layer and the native "site" patch — as plain data: each
## layer's square, stitch target, zoom cap, source chain and CACHE KEY (the
## very key ImageryService.request_imagery computes). Pure and static, so the
## TerrainLoader, the Share window and the world panel all agree on:
##   * is_cached()   — would this layer load from disk with no download?
##   * vram_bytes()  — what the layers cost on the GPU, here, in this build;
##   * infer_tier()  — which tier a world's cached imagery was made at (packs
##                     made before worlds recorded it).
##
## Why per-world tiers exist: the quality setting is per COMPUTER
## (terrain_config.cfg [terrain] quality_tier) while a shared world arrives
## with its author's imagery cached at the author's tier. A friend on another
## tier would otherwise ask for layers the pack does not hold — downloading
## them, or with no internet seeing only the blurry base drape. A world's
## record keeps {"tier", "mode"} (see TerrainLoader "Per-world imagery"):
## "saved" shows the author's layers from the cache, "local" fetches this
## computer's tier and falls back to the saved layers when that fails.

const _ImgSvc := preload("res://core/terrain/imagery_service.gd")

const TIER_COUNT := 4
const TIER_DEFAULT := 1
const TIER_NAMES := ["Low", "Medium", "High", "Ultra"]
## Detail-drape stitch target (px) per tier — the real lever on centre sharpness.
const DETAIL_TARGET_PX := [2048, 4096, 8192, 8192]
## Hyper (sharpest) layer half-extent (m) per tier.
const HYPER_HALF_EXTENT := [500.0, 500.0, 1000.0, 1500.0]
## Hyper stitch target (px) per tier (an explicit [terrain] hyper_target_px still wins).
const HYPER_TARGET_PX := [4096, 8192, 8192, 8192]
## Native "site" patch half-extent (m) per tier, 0 = off (shrunk to fit SITE_TARGET_PX).
const SITE_HALF_EXTENT := [0.0, 400.0, 500.0, 600.0]
const SITE_TARGET_PX := 8192
const DETAIL_MAX_ZOOM := 19
const HYPER_MAX_ZOOM := 19
const CONFIG_PATH := "user://terrain_config.cfg"

const TAGS := ["detail", "hyper", "site"]


## This computer's tier (the Terrain options slider).
static func local_tier() -> int:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		return clampi(int(cfg.get_value("terrain", "quality_tier", TIER_DEFAULT)), 0, TIER_COUNT - 1)
	return TIER_DEFAULT


## The player's manual overrides from terrain_config.cfg that change a layer.
static func config_overrides() -> Dictionary:
	var out := {}
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return out
	if cfg.has_section_key("terrain", "hyper_target_px"):
		out["hyper_target_px"] = int(cfg.get_value("terrain", "hyper_target_px", HYPER_TARGET_PX[TIER_DEFAULT]))
	if cfg.has_section_key("terrain", "site_half_extent_m"):
		out["site_half_extent_m"] = float(cfg.get_value("terrain", "site_half_extent_m", 0.0))
	return out


static func tier_name(tier: int) -> String:
	return str(TIER_NAMES[clampi(tier, 0, TIER_COUNT - 1)]) if tier >= 0 else "unknown"


## One layer of `tier` at this site. {} when the tier has no such layer (the
## site patch is off on Low). Keys: tag, tier, half, px, max_zoom, chain, hq,
## zoom, key. `detail_half` is the hi-res patch half-extent (m).
static func layer(tag: String, tier: int, lat: float, lon: float, detail_half: float,
		overrides: Dictionary = {}) -> Dictionary:
	var t := clampi(tier, 0, TIER_COUNT - 1)
	var half := 0.0
	var px := 0
	var max_zoom := DETAIL_MAX_ZOOM
	var chain: Array = []
	var hq := false
	match tag:
		"detail":
			half = detail_half
			px = int(DETAIL_TARGET_PX[t])
		"hyper":
			half = TerrainExtents.overlay_half(float(HYPER_HALF_EXTENT[t]), detail_half)
			px = int(overrides.get("hyper_target_px", HYPER_TARGET_PX[t]))
			max_zoom = HYPER_MAX_ZOOM
			chain = ImagerySources.chain_for(lat, lon)
		"site":
			var want := float(overrides.get("site_half_extent_m", SITE_HALF_EXTENT[t]))
			if want <= 1.0:
				return {}
			chain = ImagerySources.chain_for(lat, lon)
			max_zoom = ImagerySources.native_zoom(chain, lat)
			# 0.95: pick_zoom measures the bbox in tiles, and a bbox straddling
			# tile edges costs one extra column.
			var fit := float(SITE_TARGET_PX) * ImagerySources.metres_per_px(max_zoom, lat) * 0.5 * 0.95
			half = TerrainExtents.overlay_half(minf(want, fit), detail_half)
			px = SITE_TARGET_PX
			hq = true
		_:
			return {}
	if half <= 0.0:
		return {}
	var z := GeoMath.pick_zoom(GeoMath.bbox_for(lat, lon, half), px, max_zoom)
	return {"tag": tag, "tier": t, "half": half, "px": px, "max_zoom": max_zoom, "chain": chain,
		"hq": hq, "zoom": z, "key": _ImgSvc.layer_key(lat, lon, half, px, max_zoom, chain)}


## Every tier-dependent layer of `tier`, by tag (the site patch may be absent).
static func layers(tier: int, lat: float, lon: float, detail_half: float,
		overrides: Dictionary = {}) -> Dictionary:
	var out := {}
	for tag in TAGS:
		var l := layer(tag, tier, lat, lon, detail_half, overrides)
		if not l.is_empty():
			out[tag] = l
	return out


## On disk under any name request_imagery() would load it from (its own,
## the pre-v3 one, or the plain pre-source-chain one).
static func is_cached(l: Dictionary) -> bool:
	return not l.is_empty() and not _ImgSvc.cached_file_for_key(str(l["key"])).is_empty()


## How many of the tier's layers are on disk, and how many it has.
static func cached_count(tier: int, lat: float, lon: float, detail_half: float,
		overrides: Dictionary = {}) -> Vector2i:
	var ls := layers(tier, lat, lon, detail_half, overrides)
	var n := 0
	for tag in ls:
		if is_cached(ls[tag]):
			n += 1
	return Vector2i(n, ls.size())


## The tier a site's cached imagery was made at: the highest tier whose detail
## AND hyper layers are both on disk. -1 when no tier is complete.
static func infer_tier(lat: float, lon: float, detail_half: float, overrides: Dictionary = {}) -> int:
	for t in range(TIER_COUNT - 1, -1, -1):
		if is_cached(layer("detail", t, lat, lon, detail_half, overrides)) \
				and is_cached(layer("hyper", t, lat, lon, detail_half, overrides)):
			return t
	return -1


## The hi-res patch half-extent a world record (and its snapshot) was built at.
static func detail_half_of(rec: Dictionary, snap: Dictionary = {}) -> float:
	var map: Dictionary = rec.get("map", {}) if rec.get("map", {}) is Dictionary else {}
	var dhe := float(snap.get("detail_half_extent_m", 0.0))
	if dhe <= 0.0:
		dhe = float(map.get("detail_half_extent_m", 0.0))
	return dhe if dhe > 0.0 else TerrainExtents.DETAIL_HALF_DEFAULT


## The imagery record for a world that just arrived in a pack: it opens with
## the imagery its author saw ("saved"). The author's record says which tier
## that was; a pack made before worlds recorded it is read off the cached
## files. {} when neither is known (the world then uses this computer's tier).
static func record_for_import(rec: Dictionary, snap: Dictionary = {}) -> Dictionary:
	var ti: Dictionary = rec.get("terrain_imagery", {}) if rec.get("terrain_imagery", {}) is Dictionary else {}
	if ti.is_empty():
		var extras: Variant = snap.get("world_extras", {})
		if extras is Dictionary and (extras as Dictionary).get("terrain_imagery", null) is Dictionary:
			ti = (extras as Dictionary)["terrain_imagery"]
	var tier := int(ti.get("tier", -1))
	var map: Dictionary = rec.get("map", {}) if rec.get("map", {}) is Dictionary else {}
	if tier < 0 and WorldStore.is_generated_map(map):
		tier = infer_tier(float(map.get("lat", 0.0)), float(map.get("lon", 0.0)),
			detail_half_of(rec, snap), config_overrides())
	if tier < 0:
		return {}
	tier = clampi(tier, 0, TIER_COUNT - 1)
	return {"tier": tier, "saved_tier": tier, "mode": "saved"}


## What the "terrain imagery" choice needs to show for a world record that is
## not running: {saved_tier, local_tier, mode, vram_saved, vram_local}.
## saved_tier -1 = nothing to choose (made here, or tier unknown).
static func summary_for_record(rec: Dictionary, snap: Dictionary = {}) -> Dictionary:
	var ti: Dictionary = rec.get("terrain_imagery", {}) if rec.get("terrain_imagery", {}) is Dictionary else {}
	var map: Dictionary = rec.get("map", {}) if rec.get("map", {}) is Dictionary else {}
	var lat := float(map.get("lat", 0.0))
	var lon := float(map.get("lon", 0.0))
	var dh := detail_half_of(rec, snap)
	var ov := config_overrides()
	var saved := int(ti.get("saved_tier", -1))
	var local := local_tier()
	var out := {"saved_tier": saved, "local_tier": local, "mode": str(ti.get("mode", "local")),
		"vram_local": vram_bytes(local, lat, lon, dh, ov)}
	if saved >= 0:
		out["vram_saved"] = vram_bytes(saved, lat, lon, dh, ov)
	return out


## Pixels of one layer as stitched + cropped: the square at its zoom's m/px.
static func layer_pixels(l: Dictionary, lat: float) -> int:
	if l.is_empty():
		return 0
	var side := 2.0 * float(l["half"]) / maxf(ImagerySources.metres_per_px(int(l["zoom"]), lat), 0.001)
	return int(side * side)


## GPU memory (bytes, with mipmaps) of the tier's layers. In the editor the
## drapes are compressed (DXT1 = 0.5 B/px, the site patch BC7 = 1 B/px); an
## exported game has no BC compressor, so they upload as RGBA8 (4 B/px).
static func vram_bytes(tier: int, lat: float, lon: float, detail_half: float,
		overrides: Dictionary = {}, compressed: bool = not OS.has_feature("template")) -> int:
	var total := 0.0
	var ls := layers(tier, lat, lon, detail_half, overrides)
	for tag in ls:
		var l: Dictionary = ls[tag]
		var bpp := 4.0
		if compressed:
			bpp = 1.0 if bool(l["hq"]) else 0.5
		total += float(layer_pixels(l, lat)) * bpp * 4.0 / 3.0
	return int(total)


## "1.2 GB" / "340 MB" for the UI.
static func format_bytes(b: int) -> String:
	if b >= 1024 * 1024 * 1024:
		return "%.1f GB" % (float(b) / 1073741824.0)
	return "%d MB" % int(round(float(b) / 1048576.0))
