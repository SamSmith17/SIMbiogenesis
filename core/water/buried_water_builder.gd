class_name BuriedWaterBuilder
extends RefCounted

## Culvert and pipe spans of the stream network: where they run, how big they
## are, whether they can carry the flow — pure, plus a mesh/node builder.
##
## A run is a maximal stretch of consecutive profile stations on non-surface
## spans. Its invert follows the carved-profile bed (monotone downstream, so a
## culvert never runs uphill); the barrel centreline sits a radius above it.
## Capacity is CulvertHydraulics.manning_full_m3s at the run's own grade
## (concrete / HDPE n = 0.012, ASCE MOP 60). A run whose design discharge
## exceeds that is SURCHARGED — the editor flags it and the inlet floods.

const MANNING_N_PIPE := 0.012
## Standard round culvert sizes (m) the auto-size picks from (ASTM C76 /
## AASHTO M294 common diameters: 12, 18, 24, 36, 48, 60, 72, 96 in).
const STANDARD_D := [0.30, 0.45, 0.60, 0.90, 1.20, 1.50, 1.80, 2.40]
const MIN_COVER_M := 0.3


## Rain rate (mm/h) a culvert is sized to pass full-barrel. ~25 mm/h is the
## order of a 10-year, 1-hour storm across most temperate US sites (NOAA Atlas
## 14 point estimates run ~15–40 mm/h); the player overrides with culvert_d.
const DESIGN_RAIN_MMH := 25.0


## Barrel diameter (m): an explicit section "culvert_d", else the smallest
## standard size whose full-barrel Manning capacity at `slope` carries
## `design_q_lps` (the largest size when nothing does — it will surcharge).
static func diameter_for(section: Dictionary, design_q_lps: float = 0.0,
		slope: float = 0.01) -> float:
	var explicit := float(section.get("culvert_d", 0.0))
	if explicit > 0.0:
		return explicit
	for d in STANDARD_D:
		if CulvertHydraulics.manning_full_m3s(float(d), maxf(slope, 1e-4), MANNING_N_PIPE) * 1000.0 \
				>= design_q_lps:
			return float(d)
	return float(STANDARD_D.back())


## Runs of one feature: Array of {mode, i0, i1 (station indices, inclusive),
## path (PackedVector3Array of invert + radius), d, slope, capacity_lps,
## inlet (Vector3), outlet (Vector3), out_dir (Vector3), min_cover_m}.
## `ground_fn(x, z)` = the edited surface.
static func runs(feature: Dictionary, profile: Dictionary, ground_fn: Callable,
		design_q_fn: Callable = Callable()) -> Array:
	var out: Array = []
	var pts: PackedVector2Array = profile.get("points", PackedVector2Array())
	var s: PackedFloat32Array = profile.get("s", PackedFloat32Array())
	var bed: PackedFloat32Array = profile.get("bed", PackedFloat32Array())
	var varc: PackedFloat32Array = profile.get("varc", PackedFloat32Array())
	var n := pts.size()
	if n < 2:
		return out
	var i := 0
	while i < n - 1:
		var mid := 0.5 * (s[i] + s[i + 1])
		var mode := StreamNetwork.mode_at(feature, mid, varc)
		# A penstock span is drawn by the graph's routed conduit, not here.
		if mode == "surface" or mode == WaterFeatureLayer.MODE_PENSTOCK:
			i += 1
			continue
		var i0 := i
		while i < n - 1 and StreamNetwork.mode_at(feature, 0.5 * (s[i] + s[i + 1]), varc) == mode:
			i += 1
		var i1 := i
		var run_len := maxf(s[i1] - s[i0], 0.1)
		var run_slope := maxf((bed[i0] - bed[i1]) / run_len, 1e-4)
		var design_q := float(design_q_fn.call(i0)) if design_q_fn.is_valid() else 0.0
		var d := diameter_for(feature.get("section", {}), design_q, run_slope)
		var r := d * 0.5
		var path := PackedVector3Array()
		var min_cover := INF
		for k in range(i0, i1 + 1):
			path.append(Vector3(pts[k].x, bed[k] + r, pts[k].y))
			var g := float(ground_fn.call(pts[k].x, pts[k].y))
			min_cover = minf(min_cover, g - (bed[k] + d))
		var length := run_len
		var slope := run_slope
		var cap := CulvertHydraulics.manning_full_m3s(d, slope, MANNING_N_PIPE) * 1000.0
		var dir2 := (pts[i1] - pts[maxi(i1 - 1, i0)]).normalized()
		out.append({"mode": mode, "i0": i0, "i1": i1, "path": path, "d": d, "slope": slope,
			"capacity_lps": cap, "inlet": path[0], "outlet": path[path.size() - 1],
			"out_dir": Vector3(dir2.x, -slope, dir2.y).normalized(), "min_cover_m": min_cover,
			"length_m": length})
	return out


## True when the run cannot carry `q_lps` full-barrel.
static func surcharged(run: Dictionary, q_lps: float) -> bool:
	return q_lps > float(run.get("capacity_lps", INF))
