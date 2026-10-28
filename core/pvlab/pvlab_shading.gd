class_name PvLabShading
extends RefCounted

## Shade on a placed designed solar array, substring by substring.
##
## Each module carries shading samples where its cell paths are
## (PvLabModule.sample_points, 1 or 2 per path, more across thin-film
## strips). A sample is put in the world on the module's face, 3 cm out
## along its normal (the module's own collider stops at its face), and a ray
## toward the sun says lit or shaded. A shaded sample keeps the diffuse part
## of the plane-of-array light; a lit one gets all of it. The bypass-diode
## I–V model (PvLabIV) turns those into what the strings really make — one
## shaded cell costs its whole substring, a shadow along a half-cut module's
## bottom edge costs half — and the array's factor is that over what it would
## make unshaded at the same light and temperature.
##
## The plane-of-array split is the same model SolarUI uses (_compute_solar_kw:
## Erbs et al. 1982 decomposition of measured GHI, isotropic sky, ground
## albedo 0.25, the ASHRAE incidence-angle modifier b0 = 0.05; clear-sky DNI /
## DHI with the cloud correction when there is no measured GHI).

const SAMPLE_LIFT_M := 0.03
const RAY_LEN_M := 300.0
const SUN_MOVE_DEG := 0.25
const COARSE_MAX := 48
const ALBEDO := 0.25
const IAM_B0 := 0.05


## Plane-of-array irradiance (W/m²) on a plane tilted `tilt` toward compass
## `az`: {beam, sky, ground, total, diffuse_share}.
static func poa(sun_az: float, sun_el: float, tilt: float, az: float, ghi_real: float, has_real: bool,
		cloud: float) -> Dictionary:
	if sun_el <= -2.0:
		return {"beam": 0.0, "sky": 0.0, "ground": 0.0, "total": 0.0, "diffuse_share": 1.0}
	var cos_z := maxf(sin(deg_to_rad(sun_el)), 0.01)
	var cos_inc := SolarPosition.panel_cos_incidence(sun_az, sun_el, az, tilt)
	var iam := 0.0
	if cos_inc > 0.0 and rad_to_deg(acos(cos_inc)) <= 85.0:
		iam = clampf(1.0 - IAM_B0 * (1.0 / cos_inc - 1.0), 0.0, 1.0)
	var t := deg_to_rad(tilt)
	var f_sky := (1.0 + cos(t)) * 0.5
	var f_gnd := (1.0 - cos(t)) * 0.5
	var beam := 0.0
	var sky := 0.0
	var gnd := 0.0
	if has_real:
		var ghi := maxf(ghi_real, 0.0)
		var kt := clampf(ghi / maxf(1000.0 * cos_z, 1.0), 0.0, 1.0)
		var dfrac := 0.0
		if kt <= 0.22:
			dfrac = 1.0 - 0.09 * kt
		elif kt <= 0.80:
			dfrac = 0.9511 - 0.1604 * kt + 4.388 * kt * kt - 16.638 * pow(kt, 3.0) + 12.336 * pow(kt, 4.0)
		else:
			dfrac = 0.165
		var dhi := ghi * clampf(dfrac, 0.0, 1.0)
		var dni := maxf(ghi - dhi, 0.0) / cos_z
		beam = dni * maxf(cos_inc, 0.0) * iam
		sky = dhi * f_sky
		gnd = ghi * ALBEDO * f_gnd
	else:
		var dni2 := SolarIrradiance.dni_clear_sky_wm2(sun_el)
		var dhi2 := SolarIrradiance.dhi_clear_sky_wm2(sun_el, dni2)
		var ghi_est := dni2 * cos_z + dhi2
		beam = dni2 * maxf(cos_inc, 0.0) * iam
		if cloud > 0.0:
			beam *= 1.0 - cloud * 0.95
			dhi2 *= 1.0 + cloud * 0.5 if cloud < 0.3 else 1.15 - (cloud - 0.3) * 0.7
			ghi_est *= 1.0 - cloud * 0.5
		sky = dhi2 * f_sky
		gnd = ghi_est * ALBEDO * f_gnd
	var total := clampf(beam + sky + gnd, 0.0, 1200.0)
	return {"beam": beam, "sky": sky, "ground": gnd, "total": total,
		"diffuse_share": clampf((sky + gnd) / maxf(total, 1e-6), 0.0, 1.0) if total > 0.0 else 1.0}


## Every shading sample of every module, in the world: {pos: PackedVector3Array,
## normal: PackedVector3Array (per sample), per_panel: samples a module}.
static func world_samples(d: Dictionary, array_xf: Transform3D, tracker_deg: float = 0.0) -> Dictionary:
	var m: Dictionary = d["module"]
	var lay: Dictionary = d["layout"]
	var uvs := PvLabModule.sample_points(m)
	var w := float(m["dims_mm"]["w"]) * 0.001
	var h := float(m["dims_mm"]["h"]) * 0.001
	var t := float(m["dims_mm"]["t"]) * 0.001
	var pos := PackedVector3Array()
	var nrm := PackedVector3Array()
	for p in lay["panels"]:
		var xf := array_xf * PvLabArray.panel_xf(lay, p, tracker_deg)
		var n := (xf.basis * Vector3.UP).normalized()
		for uv in uvs:
			pos.append(xf * Vector3(float(uv.x) * w, t * 0.5, float(uv.y) * h) + n * SAMPLE_LIFT_M)
			nrm.append(n)
	return {"pos": pos, "normal": nrm, "per_panel": uvs.size()}


## The array's factor from lit flags (1 lit / 0 shaded, sample order), the
## diffuse share a shaded sample keeps, the light on the plane and the cell
## temperature: what its strings make over what they would make unshaded.
static func factor_from_lit(d: Dictionary, lit: PackedByteArray, diffuse_share: float, g: float = 1000.0,
		t_cell: float = 25.0) -> float:
	var m: Dictionary = d["module"]
	var per := PvLabModule.sample_points(m).size()
	var n := (d["layout"]["panels"] as Array).size()
	if lit.size() < per * n:
		return 1.0
	var shaded_any := false
	var paths: Array = []
	for pi in n:
		var s: Array = []
		for k in per:
			var on := lit[pi * per + k] != 0
			if not on:
				shaded_any = true
			s.append(g * (1.0 if on else diffuse_share))
		paths.append(PvLabIV.path_irradiance(m, s))
	if not shaded_any:
		return 1.0
	return _ratio(d, paths, g, t_cell)


## Per module, per substring: whether every sample on it is lit (the panel
## cards' substring strip). [[bool per substring] per module].
static func substring_lit(d: Dictionary, lit: PackedByteArray) -> Array:
	var m: Dictionary = d["module"]
	var counts: Array = []
	for sub in PvLabModule.substrings(m):
		var c := 0
		for path in sub["paths"]:
			for band in path["bands"]:
				c += (band as Array).size()
		counts.append(c)
	var per := PvLabModule.sample_points(m).size()
	var out: Array = []
	for pi in (d["layout"]["panels"] as Array).size():
		var row: Array = []
		var k := pi * per
		for c2 in counts:
			var all_on := true
			for _j in int(c2):
				if k >= lit.size() or lit[k] == 0:
					all_on = false
				k += 1
			row.append(all_on)
		out.append(row)
	return out


## Coarse factor: one lit / shaded flag per MODULE (the render path's
## budget), each shaded module at the diffuse share on every path.
static func factor_from_modules(d: Dictionary, lit_by_module: Dictionary, diffuse_share: float,
		g: float = 1000.0, t_cell: float = 25.0) -> float:
	var model: Dictionary = d["iv"]
	var n := (d["layout"]["panels"] as Array).size()
	var np := int(model["n_paths"])
	var paths: Array = []
	var shaded_any := false
	for pi in n:
		var on := bool(lit_by_module.get(pi, true))
		if not on:
			shaded_any = true
		var s: Array = []
		for _k in np:
			s.append(g * (1.0 if on else diffuse_share))
		paths.append(s)
	if not shaded_any:
		return 1.0
	return _ratio(d, paths, g, t_cell)


static func _ratio(d: Dictionary, paths_by_panel: Array, g: float, t_cell: float) -> float:
	var model: Dictionary = d["iv"]
	var np := int(model["n_paths"])
	var full_path: Array = []
	for _k in np:
		full_path.append(g)
	var actual := 0.0
	var ideal := 0.0
	var strings: Array = d["strings"]
	for grp in d["groups"]:
		var sts: Array = []
		var sts_full: Array = []
		for si in grp:
			var st: Array = []
			var stf: Array = []
			for pi in strings[int(si)]:
				st.append(paths_by_panel[int(pi)])
				stf.append(full_path)
			sts.append(st)
			sts_full.append(stf)
		if sts.is_empty():
			continue
		actual += float(PvLabIV.array_mpp(model, sts, t_cell)["p"])
		ideal += float(PvLabIV.array_mpp(model, sts_full, t_cell)["p"])
	return clampf(actual / ideal, 0.0, 1.0) if ideal > 0.0 else 1.0


## The tracker's rotation (degrees) for a placed array at this sun — the same
## rule the visual runtime and the energy model use.
static func tracker_deg_for(d: Dictionary, array_xf: Transform3D, sun_dir: Vector3, wind_ms: float = 0.0) -> float:
	if str(d["layout"]["mount"]) != "tracker":
		return 0.0
	var z := array_xf.basis.z
	var axis_az := fposmod(rad_to_deg(atan2(z.x, -z.z)), 360.0) if Vector2(z.x, z.z).length() > 1e-5 else 180.0
	var sd := sun_dir.normalized()
	var el := rad_to_deg(asin(clampf(sd.y, -1.0, 1.0)))
	var az := fposmod(rad_to_deg(atan2(sd.x, -sd.z)), 360.0)
	return PvLabTracker.angle_at(az, el, axis_az, d["spec"]["tracker"], float(d["layout"]["gcr"]), wind_ms)


## Coarse factor at a sun direction, ray-casting one sample per module
## (strided to COARSE_MAX): the batch render's per-instant shade.
static func coarse_factor_at(d: Dictionary, array_xf: Transform3D, sun_dir: Vector3, intersect: Callable,
		exclude: Array = [], diffuse_share: float = 0.2) -> float:
	if sun_dir.y <= 0.01:
		return 1.0
	var lay: Dictionary = d["layout"]
	var m: Dictionary = d["module"]
	var n := (lay["panels"] as Array).size()
	var stride := maxi(int(ceil(float(n) / float(COARSE_MAX))), 1)
	var tr := tracker_deg_for(d, array_xf, sun_dir)
	var t := float(m["dims_mm"]["t"]) * 0.001
	var lit := {}
	var sd := sun_dir.normalized()
	var i := 0
	while i < n:
		var p: Dictionary = (lay["panels"] as Array)[i]
		var xf := array_xf * PvLabArray.panel_xf(lay, p, tr)
		var nn := (xf.basis * Vector3.UP).normalized()
		var o := xf * Vector3(0, t * 0.5, 0) + nn * SAMPLE_LIFT_M
		var hit: Dictionary = intersect.call(o, o + sd * RAY_LEN_M, exclude)
		var on := hit.is_empty()
		for k in range(i, mini(i + stride, n)):
			lit[k] = on
		i += stride
	return factor_from_modules(d, lit, diffuse_share)


## A physics ray as `intersect` wants it.
static func physics_ray(space: PhysicsDirectSpaceState3D, from: Vector3, to: Vector3, exclude: Array) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.collision_mask = 1
	q.exclude = exclude
	return space.intersect_ray(q)


## Live shading of every placed designed array, a few rays a tick: one pass
## over an array's samples, restarted when the sun moves SUN_MOVE_DEG or the
## design changes. `factor(tag)` is the last finished pass's result.
class Live extends RefCounted:
	var _state := {}

	func factor(tag: String) -> float:
		return float((_state.get(tag, {}) as Dictionary).get("factor", 1.0))

	func lit_flags(tag: String) -> PackedByteArray:
		return (_state.get(tag, {}) as Dictionary).get("lit_done", PackedByteArray())

	## arrays: [{tag, design, xf: Transform3D, exclude: [RID]}]. Returns the
	## tags whose factor changed this tick.
	func tick(arrays: Array, space: PhysicsDirectSpaceState3D, sun_dir: Vector3, budget: int,
			light: Callable) -> Array:
		var changed: Array = []
		var seen := {}
		var sd := sun_dir.normalized()
		for a in arrays:
			var tag := str(a["tag"])
			seen[tag] = true
			var d: Dictionary = a["design"]
			var st: Dictionary = _state.get(tag, {})
			var key := "%s|%s" % [str(d["spec"].hash()), str(a["xf"])]
			var restart := str(st.get("key", "")) != key
			if not restart and (st.get("sun_at") is Vector3):
				restart = rad_to_deg((st["sun_at"] as Vector3).angle_to(sd)) > SUN_MOVE_DEG and int(st.get("cursor", 0)) == -1
			if restart:
				var tr := PvLabShading.tracker_deg_for(d, a["xf"], sd)
				var ws := PvLabShading.world_samples(d, a["xf"], tr)
				# Packed arrays are values: size it here, then store it.
				var fresh := PackedByteArray()
				fresh.resize((ws["pos"] as PackedVector3Array).size())
				st = {"key": key, "pos": ws["pos"], "lit": fresh, "cursor": 0, "sun_at": sd,
					"factor": float(st.get("factor", 1.0)), "lit_done": st.get("lit_done", PackedByteArray())}
				_state[tag] = st
		# Spend the budget round the arrays still mid-pass.
		var left := budget
		for a2 in arrays:
			if left <= 0:
				break
			var tag2 := str(a2["tag"])
			var st2: Dictionary = _state[tag2]
			var cur := int(st2["cursor"])
			if cur < 0:
				continue
			var pts: PackedVector3Array = st2["pos"]
			var lit: PackedByteArray = st2["lit"]
			var night := sd.y <= 0.01
			while cur < pts.size() and left > 0:
				var on := 1
				if not night:
					var hit := PvLabShading.physics_ray(space, pts[cur], pts[cur] + sd * PvLabShading.RAY_LEN_M,
						a2.get("exclude", []))
					on = 0 if not hit.is_empty() else 1
				lit[cur] = on
				cur += 1
				left -= 1
			st2["lit"] = lit
			if cur >= pts.size():
				st2["cursor"] = -1
				st2["lit_done"] = lit
				var lt: Dictionary = light.call(a2) if light.is_valid() else {}
				var f := PvLabShading.factor_from_lit(a2["design"], lit, float(lt.get("diffuse_share", 0.2)),
					float(lt.get("g", 1000.0)), float(lt.get("t_cell", 25.0)))
				if absf(f - float(st2.get("factor", 1.0))) > 0.002:
					changed.append(tag2)
				st2["factor"] = f
			else:
				st2["cursor"] = cur
		for k in _state.keys():
			if not seen.has(k):
				_state.erase(k)
		return changed
