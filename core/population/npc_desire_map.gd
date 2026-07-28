class_name NpcDesireMap
extends RefCounted

## Desire lines: where the population actually wears paths into the site
## (POPULATION_PLAN.md Tier 3e).
##
## WHY A RASTER, NOT POLYLINES. Storing every route as geometry grows without
## bound — 50 people × a day of trips is tens of thousands of segments, and
## you cannot see the pattern in the pile anyway. Real desire-line analysis
## rasterises, and so do we: a coarse grid accumulating metres walked per
## cell. O(1) memory, and the aggregate IS the thing you want to look at.
##
## Per-need channels so the view can answer "show me only the trips to
## water", which is what turns a pretty picture into a diagnostic.
##
## Rendering is one ImageTexture and one draw call — 16k draw_rect calls per
## frame would be unusable. The texture is rebuilt on demand and throttled by
## the caller.

## Coarser than the nav grid: this is a density field, not a walkable one.
const CELL_M := 2.0
const MAX_CELLS_AXIS := 256

## How far back the map remembers. `TODAY` resets at the sim-day boundary so
## the picture always reflects the CURRENT layout rather than a fossil of one
## you already fixed.
## NOTE: named Retention, not Window — `Window` shadows Godot's native class.
enum Retention { TODAY, WEEK, ALL }
const WEEK_DECAY := 0.75          # per sim-day, ~7-day half-life-ish

## Channels are the need (or "chore") that drove the trip.
const CHANNELS: Array = ["hunger", "thirst", "bladder", "sleep", "hygiene",
		"enrichment", "chore"]

var origin := Vector2.ZERO
var cell_m := CELL_M
var nx := 0
var nz := 0
var retention: int = Retention.WEEK

var _total := PackedFloat32Array()
var _channels: Dictionary = {}     # channel -> PackedFloat32Array
var _peak := 0.0
var _dirty := true


func configure(center: Vector2, half_extent_m: float, cell := CELL_M) -> bool:
	cell_m = maxf(cell, 0.5)
	var n := clampi(int(ceil(half_extent_m * 2.0 / cell_m)), 2, MAX_CELLS_AXIS)
	nx = n
	nz = n
	origin = center - Vector2(1.0, 1.0) * (float(n) * cell_m * 0.5)
	_total = PackedFloat32Array()
	_total.resize(n * n)
	_channels = {}
	for c in CHANNELS:
		var arr := PackedFloat32Array()
		arr.resize(n * n)
		_channels[c] = arr
	_peak = 0.0
	_dirty = true
	return true


func is_configured() -> bool:
	return nx > 0 and nz > 0


func world_rect() -> Rect2:
	return Rect2(origin, Vector2(float(nx), float(nz)) * cell_m)


func peak() -> float:
	return _peak


## Cells carrying at least `threshold` metres — a cheap "is anything actually
## being worn in" check for the harness.
func hot_cells(threshold: float = 1.0) -> int:
	var n := 0
	for v in _total:
		if v >= threshold:
			n += 1
	return n


func total_metres() -> float:
	var t := 0.0
	for v in _total:
		t += v
	return t


# --- accumulation ------------------------------------------------------------

## Rasterise one walked segment, adding `metres` spread along it. Sampling at
## half-cell steps is approximate but stable, and a density field does not
## need exact supercover coverage.
func add_segment(a: Vector2, b: Vector2, channel: String, metres: float) -> void:
	if not is_configured() or metres <= 0.0:
		return
	var arr: PackedFloat32Array = _channels.get(channel, PackedFloat32Array())
	var has_channel := arr.size() == _total.size()
	var len_m := a.distance_to(b)
	var steps := maxi(int(ceil(len_m / (cell_m * 0.5))), 1)
	var share := metres / float(steps)
	for s in range(steps):
		var t := (float(s) + 0.5) / float(steps)
		var p := a.lerp(b, t)
		var ix := int(floor((p.x - origin.x) / cell_m))
		var iz := int(floor((p.y - origin.y) / cell_m))
		if ix < 0 or iz < 0 or ix >= nx or iz >= nz:
			continue
		var i := iz * nx + ix
		_total[i] += share
		if _total[i] > _peak:
			_peak = _total[i]
		if has_channel:
			arr[i] += share
	_dirty = true


## Apply the retention policy. Call once per sim-day boundary.
func roll_day() -> void:
	match retention:
		Retention.TODAY:
			_scale_all(0.0)
		Retention.WEEK:
			_scale_all(WEEK_DECAY)
	_dirty = true


func _scale_all(k: float) -> void:
	for i in _total.size():
		_total[i] *= k
	for c in _channels:
		var arr: PackedFloat32Array = _channels[c]
		for i in arr.size():
			arr[i] *= k
	_peak *= k


func clear() -> void:
	_scale_all(0.0)


func set_retention(w: int) -> void:
	retention = clampi(w, 0, Retention.ALL)


static func retention_label(w: int) -> String:
	match w:
		Retention.TODAY: return "Today"
		Retention.WEEK: return "Past week"
	return "All time"


# --- rendering ---------------------------------------------------------------

## Heat texture for `channel` ("" = all traffic). Log-scaled, because foot
## traffic is heavy-tailed: on a linear ramp one corridor saturates and
## everything else vanishes.
func texture(channel: String = "") -> ImageTexture:
	if not is_configured():
		return null
	var src: PackedFloat32Array = _total
	if not channel.is_empty() and _channels.has(channel):
		src = _channels[channel]
	var peak_v := 0.0
	for v in src:
		peak_v = maxf(peak_v, v)
	if peak_v <= 0.0:
		return null
	# Explicitly cleared: a freshly created Image is not reliably zero-filled,
	# and an unwritten pixel reads as opaque white, which paints the whole
	# region as one solid block over the map.
	var img := Image.create_empty(nx, nz, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var denom := log(1.0 + peak_v)
	for iz in nz:
		for ix in nx:
			var v := src[iz * nx + ix]
			if v <= 0.0:
				img.set_pixel(ix, iz, Color(0, 0, 0, 0))
				continue
			var t := clampf(log(1.0 + v) / denom, 0.0, 1.0)
			img.set_pixel(ix, iz, heat_color(t))
	return ImageTexture.create_from_image(img)


## Perceptually ordered cool -> hot ramp, alpha-weighted so cold cells fade
## out rather than fogging the whole map.
static func heat_color(t: float) -> Color:
	var x := clampf(t, 0.0, 1.0)
	var c: Color
	if x < 0.5:
		c = Color(0.15, 0.35, 0.75).lerp(Color(0.35, 0.80, 0.55), x * 2.0)
	else:
		c = Color(0.35, 0.80, 0.55).lerp(Color(0.98, 0.42, 0.20), (x - 0.5) * 2.0)
	c.a = clampf(0.12 + x * 0.72, 0.0, 1.0)
	return c


func take_dirty() -> bool:
	var d := _dirty
	_dirty = false
	return d
