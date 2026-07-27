class_name ElevationProfile
extends RefCounted

## Shared DEM section sampler for Elevation canvas + Siphon Lab.
## Samples world elevations along a cut; callers project to screen with zoom/pan.
## Pure static — no Node ownership.

const MIN_SAMPLES := 32
const MAX_SAMPLES := 96
## Siphon Lab framed window — denser DEM for tight CT zoom.
const LAB_MAX_SAMPLES := 160


## Sample count from on-screen disc diameter (never grows past MAX_SAMPLES).
static func sample_count_for_r_px(r_px: float) -> int:
	# ~1 sample every 4 screen px across the diameter, clamped.
	return clampi(int(ceil((2.0 * maxf(r_px, 1.0)) / 4.0)), MIN_SAMPLES, MAX_SAMPLES)


## Denser sample count for a Lab along-window (~0.35 m spacing, capped).
static func sample_count_for_lab_window(along_span_m: float) -> int:
	var span := maxf(along_span_m, 2.0)
	return clampi(int(ceil(span / 0.35)), MIN_SAMPLES, LAB_MAX_SAMPLES)


## Bake elevations along the section. Returns PackedFloat32Array of ground Y
## (length = samples+1), plus along_m packed in a parallel array via out args.
## `out_along` / `out_elev` are cleared and filled.
static func bake(
		soi_svc: Node,
		center3: Vector3,
		heading_rad: float,
		offset_m: float,
		r_m: float,
		sample_count: int,
		out_along: PackedFloat32Array,
		out_elev: PackedFloat32Array) -> void:
	out_along.clear()
	out_elev.clear()
	var n := clampi(sample_count, MIN_SAMPLES, MAX_SAMPLES)
	var along_dir := Vector2(cos(heading_rad), sin(heading_rad))
	var cross_dir := Vector2(-sin(heading_rad), cos(heading_rad))
	var offset := clampf(offset_m, -r_m, r_m)
	var datum := center3.y
	out_along.resize(n + 1)
	out_elev.resize(n + 1)
	for i in range(n + 1):
		var t := float(i) / float(n)
		var along := lerpf(-r_m, r_m, t)
		var site := along_dir * along + cross_dir * offset
		var world := GraphSiteLayout.site_to_world_xz(site, center3)
		var gy := datum
		if soi_svc != null and soi_svc.has_method("ground_y_at"):
			gy = float(soi_svc.call("ground_y_at", world.x, world.y))
		out_along[i] = along
		out_elev[i] = gy


## Narrow window bake for Siphon Lab (pond-centered span).
static func bake_window(
		soi_svc: Node,
		center3: Vector3,
		heading_rad: float,
		offset_m: float,
		along0: float,
		along1: float,
		sample_count: int,
		out_along: PackedFloat32Array,
		out_elev: PackedFloat32Array) -> void:
	out_along.clear()
	out_elev.clear()
	var n := clampi(sample_count, MIN_SAMPLES, LAB_MAX_SAMPLES)
	var along_dir := Vector2(cos(heading_rad), sin(heading_rad))
	var cross_dir := Vector2(-sin(heading_rad), cos(heading_rad))
	var a0 := minf(along0, along1)
	var a1 := maxf(along0, along1)
	if a1 - a0 < 1.0:
		a1 = a0 + 1.0
	var datum := center3.y
	out_along.resize(n + 1)
	out_elev.resize(n + 1)
	for i in range(n + 1):
		var t := float(i) / float(n)
		var along := lerpf(a0, a1, t)
		var site := along_dir * along + cross_dir * offset_m
		var world := GraphSiteLayout.site_to_world_xz(site, center3)
		var gy := datum
		if soi_svc != null and soi_svc.has_method("ground_y_at"):
			gy = float(soi_svc.call("ground_y_at", world.x, world.y))
		out_along[i] = along
		out_elev[i] = gy


## Cache key for invalidation (heading/offset/radius/samples — not zoom/pan).
static func cache_key(heading_rad: float, offset_m: float, r_m: float,
		sample_count: int, datum_y: float) -> String:
	return "%.5f|%.2f|%.1f|%d|%.2f" % [
		heading_rad, offset_m, r_m, sample_count, datum_y]
