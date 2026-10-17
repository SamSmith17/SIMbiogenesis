class_name VegMix
extends RefCounted

## A vegetation MIX (2026-10-15): everything one Mix brush paints, and the ONE
## scatter both the brush and the Tune-look preview run — so the preview shows
## exactly what painting gives (same spacing rule, species pick, patchiness,
## young-tree share, yaw, scale and understory; only the patch of ground and
## the random seed differ).
##
## Before this there were three mixes that never agreed: the toolbar and the
## legacy dock painted a hard-coded pine/deciduous/shrub/grass split, while
## the Tune-look "Mixed woodland" previewed the style's mix weights through a
## different picker, spacing and yaw and painted nothing at all.
##
## A mix is a plain Dictionary (JSON-safe — no arrays of 3+ numbers, which the
## style store would read back as Colors):
##   label         display name
##   trees         {species: weight}            the canopy
##   spacing_m     canopy spacing at brush density 1
##   patchiness    0 salt-and-pepper .. 1 single-species patches
##   patch_m       patch size (world-anchored noise, so strokes join up)
##   young_share   share of trees that are younger / smaller (new growth)
##   understory    {species: plants per tree}   ferns, shrubs round the trees
##   ring_min_m / ring_max_m   understory distance from the trunk
##   floor_moss    forest-floor moss 0..1      (style forest_floor_moss)
##   bark_moss     trunk moss 0..1              (style bark_moss)
##   deadwood      stumps + logs per 100 trees  (style deadwood_per_100_trees)
## The last three are SITE looks: painting a mix raises the map's values to
## the mix's (never lowers them) so what was previewed is what appears.

const KEY_STYLE := "paint_mix"
const USER_PATH := "user://veg_mixes.json"
const MAX_SCATTER := 2500

const DEFAULTS := {
	"label": "Custom mix",
	"trees": {"pine": 0.45, "deciduous": 0.45},
	"spacing_m": 7.0,
	"patchiness": 0.3,
	"patch_m": 45.0,
	"young_share": 0.15,
	"understory": {},
	"ring_min_m": 1.2,
	"ring_max_m": 5.0,
	"floor_moss": 0.0,
	"bark_moss": 0.0,
	"deadwood": 0.0,
}

## Built-in mixes. Weights / rates from Franklin & Dyrness (1973, Natural
## Vegetation of Oregon and Washington) for the western hemlock zone — the
## lowland forest of the Puget trough and Cascade foothills.
const PRESETS := {
	"pnw_lowland": {
		"label": "PNW lowland forest",
		"trees": {"douglas_fir": 0.42, "cedar": 0.20, "hemlock": 0.14,
			"maple": 0.16, "alder": 0.08},
		"spacing_m": 6.5, "patchiness": 0.45, "patch_m": 50.0, "young_share": 0.25,
		"understory": {"sword_fern": 1.6, "salal": 0.35, "bracken": 0.15,
			"blackberry": 0.08},
		"ring_min_m": 1.2, "ring_max_m": 5.5,
		"floor_moss": 0.75, "bark_moss": 0.55, "deadwood": 5.0},
	"pnw_cedar_bottom": {
		"label": "PNW cedar bottomland",
		"trees": {"cedar": 0.48, "hemlock": 0.18, "maple": 0.18, "alder": 0.16},
		"spacing_m": 7.0, "patchiness": 0.35, "patch_m": 40.0, "young_share": 0.2,
		"understory": {"sword_fern": 2.2, "salal": 0.2},
		"ring_min_m": 1.4, "ring_max_m": 6.0,
		"floor_moss": 0.95, "bark_moss": 0.8, "deadwood": 7.0},
	"pnw_maple_alder": {
		"label": "Maple–alder slope",
		"trees": {"maple": 0.5, "alder": 0.32, "douglas_fir": 0.12, "cedar": 0.06},
		"spacing_m": 8.0, "patchiness": 0.3, "patch_m": 35.0, "young_share": 0.3,
		"understory": {"sword_fern": 1.0, "bracken": 0.5, "blackberry": 0.35},
		"ring_min_m": 1.5, "ring_max_m": 6.0,
		"floor_moss": 0.5, "bark_moss": 0.9, "deadwood": 4.0},
	"pnw_second_growth_fir": {
		"label": "Second-growth Douglas-fir",
		"trees": {"douglas_fir": 0.8, "hemlock": 0.12, "cedar": 0.08},
		"spacing_m": 5.0, "patchiness": 0.2, "patch_m": 60.0, "young_share": 0.15,
		"understory": {"sword_fern": 0.9, "salal": 0.6},
		"ring_min_m": 1.2, "ring_max_m": 4.5,
		"floor_moss": 0.55, "bark_moss": 0.3, "deadwood": 6.0},
	"mixed_woodland": {
		"label": "Mixed woodland (generic)",
		"trees": {"pine": 0.45, "deciduous": 0.45},
		"spacing_m": 7.0, "patchiness": 0.3, "patch_m": 45.0, "young_share": 0.15,
		"understory": {"shrub": 0.25},
		"floor_moss": 0.0, "bark_moss": 0.0, "deadwood": 0.0},
}
const PRESET_ORDER := ["pnw_lowland", "pnw_cedar_bottom", "pnw_maple_alder",
	"pnw_second_growth_fir", "mixed_woodland"]


static func preset(id: String) -> Dictionary:
	if PRESETS.has(id):
		return normalized(PRESETS[id])
	var users := load_user_mixes()
	if users.has(id):
		return normalized(users[id])
	return {}


## A mix with every key present (DEFAULTS filled in), weights as floats.
static func normalized(mix: Dictionary) -> Dictionary:
	var out: Dictionary = DEFAULTS.duplicate(true)
	for k in mix:
		out[str(k)] = mix[k]
	for group in ["trees", "understory"]:
		var g: Dictionary = {}
		var src: Variant = out.get(group, {})
		if src is Dictionary:
			for sid in src:
				var w := float(src[sid])
				if w > 0.0 and VegSpeciesCatalog.is_paintable(str(sid)):
					g[str(sid)] = w
		out[group] = g
	return out


## {id: mix} saved by the player.
static func load_user_mixes() -> Dictionary:
	if not FileAccess.file_exists(USER_PATH):
		return {}
	var f := FileAccess.open(USER_PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


## Save a mix under a player-chosen name. Returns its id.
static func save_user_mix(name: String, mix: Dictionary) -> String:
	var id := "user_" + name.strip_edges().to_lower().replace(" ", "_").validate_filename()
	var all := load_user_mixes()
	var m := normalized(mix)
	m["label"] = name.strip_edges()
	all[id] = m
	var f := FileAccess.open(USER_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(all, "\t"))
	return id


static func delete_user_mix(id: String) -> void:
	var all := load_user_mixes()
	if all.erase(id):
		var f := FileAccess.open(USER_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(all, "\t"))


## [[id, label], ...] — built-ins first, then the player's.
static func choices() -> Array:
	var out: Array = []
	for id in PRESET_ORDER:
		out.append([id, str(PRESETS[id]["label"])])
	var users := load_user_mixes()
	var ids := users.keys()
	ids.sort()
	for id in ids:
		out.append([str(id), str((users[id] as Dictionary).get("label", id))])
	return out


# --- the scatter --------------------------------------------------------------

## World-anchored smooth 0..1 noise on a `cell` m lattice (pure, deterministic).
static func patch_noise(x: float, z: float, cell: float, salt: float) -> float:
	var fx := x / maxf(cell, 1.0)
	var fz := z / maxf(cell, 1.0)
	var ix := floorf(fx)
	var iz := floorf(fz)
	var tx := fx - ix
	var tz := fz - iz
	tx = tx * tx * (3.0 - 2.0 * tx)
	tz = tz * tz * (3.0 - 2.0 * tz)
	return lerpf(lerpf(_h(ix, iz, salt), _h(ix + 1.0, iz, salt), tx),
		lerpf(_h(ix, iz + 1.0, salt), _h(ix + 1.0, iz + 1.0, salt), tx), tz)


static func _h(x: float, z: float, salt: float) -> float:
	var v := sin(x * 12.9898 + z * 78.233 + salt * 37.719) * 43758.5453
	return v - floor(v)


## Pick a canopy species at (x, z): the mix weights, each bent by its own
## world-anchored patch noise (patchiness 0 = the plain weights).
static func pick_tree(mix: Dictionary, x: float, z: float, u: float) -> String:
	var trees: Dictionary = mix.get("trees", {})
	if trees.is_empty():
		return ""
	var patchy := clampf(float(mix.get("patchiness", 0.0)), 0.0, 1.0)
	var cell := float(mix.get("patch_m", 45.0))
	var ids := trees.keys()
	ids.sort()
	var ws: Array[float] = []
	var total := 0.0
	for i in ids.size():
		var sid := str(ids[i])
		var n := patch_noise(x, z, cell, float(absi(sid.hash()) % 997))
		# Squared so a species clearly dominates where its noise is high.
		var bend := lerpf(1.0, 3.0 * n * n, patchy)
		var w := maxf(float(trees[sid]) * bend, 0.0)
		ws.append(w)
		total += w
	if total <= 0.0:
		return str(ids[0])
	var r := u * total
	for i in ids.size():
		r -= ws[i]
		if r <= 0.0:
			return str(ids[i])
	return str(ids[ids.size() - 1])


## Scatter one region. params: density (spacing divisor), size_var 0..0.5,
## scale (tree brush scale), cap (max trees), existing (Array[Vector2] of
## occupied spots), excluded (Callable Vector2 -> bool, optional).
## Returns [{species, x, z, yaw, scale, young: bool, understory: bool}].
static func scatter(poly: PackedVector2Array, mix_in: Dictionary, seed: int,
		params: Dictionary = {}) -> Array:
	var mix := normalized(mix_in)
	var out: Array = []
	if poly.size() < 3:
		return out
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var density := maxf(float(params.get("density", 1.0)), 0.1)
	var sv := clampf(float(params.get("size_var", 0.2)), 0.0, 0.5)
	var brush_scale := clampf(float(params.get("scale", 1.0)), 0.1, 5.0)
	var cap := clampi(int(params.get("cap", MAX_SCATTER)), 1, MAX_SCATTER)
	var existing: Array[Vector2] = []
	var ex_in: Variant = params.get("existing", [])
	if ex_in is Array:
		for p in ex_in:
			if p is Vector2:
				existing.append(p)
	var excluded: Callable = params.get("excluded", Callable())
	var spacing := maxf(float(mix["spacing_m"]) / density, 0.5)
	var spots := VegetationPaint.poisson_fill(poly, spacing, rng, existing, cap)
	var young := clampf(float(mix["young_share"]), 0.0, 1.0)
	var under: Dictionary = mix["understory"]
	var under_ids := under.keys()
	under_ids.sort()
	var r0 := float(mix["ring_min_m"])
	var r1 := maxf(float(mix["ring_max_m"]), r0 + 0.2)
	for spot in spots:
		var x := float(spot["x"])
		var z := float(spot["z"])
		if excluded.is_valid() and bool(excluded.call(Vector2(x, z))):
			continue
		var sid := pick_tree(mix, x, z, rng.randf())
		if sid.is_empty():
			continue
		var sc := lerpf(1.0 - sv, 1.0 + sv, rng.randf()) * brush_scale
		var is_young := rng.randf() < young
		if is_young:
			sc *= rng.randf_range(0.35, 0.7)
		out.append({"species": sid, "x": x, "z": z, "yaw": rng.randf() * TAU,
			"scale": sc, "young": is_young, "understory": false})
		for usid in under_ids:
			var rate := float(under[usid]) * density
			var n := int(rate) + (1 if rng.randf() < rate - floorf(rate) else 0)
			for _j in n:
				var a := rng.randf() * TAU
				var d := rng.randf_range(r0, r1)
				var ux := x + cos(a) * d
				var uz := z + sin(a) * d
				if not Geometry2D.is_point_in_polygon(Vector2(ux, uz), poly):
					continue
				if excluded.is_valid() and bool(excluded.call(Vector2(ux, uz))):
					continue
				out.append({"species": str(usid), "x": ux, "z": uz,
					"yaw": rng.randf() * TAU,
					"scale": lerpf(0.75, 1.3, rng.randf()), "young": false,
					"understory": true})
	return out


## The site-look keys a mix carries, as style keys.
static func style_extras(mix_in: Dictionary) -> Dictionary:
	var mix := normalized(mix_in)
	return {
		VegFloorMoss.KEY: float(mix["floor_moss"]),
		"bark_moss": float(mix["bark_moss"]),
		VegDeadwood.KEY_DENSITY: float(mix["deadwood"]),
	}
