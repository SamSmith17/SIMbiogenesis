class_name GlobeWindField
extends RefCounted

## Wind streamlines for the globe (pure, deterministic). Fields are
## Grib2Decoder.to_field dicts (u and v at 10 m, m/s).
##
## Seeds on a Fibonacci sphere; from each seed the line is traced both ways
## along the wind's DIRECTION in fixed steps (the geometry of a streamline,
## not a particle path), stopping in calm air, near a pole, or on entering a
## cell another line already owns (a simplified Jobard & Lefer 1997 evenly
## spaced streamline placement: lines never pile up, empty space is filled
## by later seeds). Speed rides along per vertex for the colour and the
## animation, which moves a highlight down each line at a rate set by the
## wind speed.

const DEFAULTS := {
	"seeds": 2600,
	"step_deg": 0.45,
	"max_steps": 36,       # each way
	"cell_deg": 1.6,       # spacing between lines
	"min_speed": 0.4,      # m/s: calmer air ends a line
	"max_lines": 2600,
	"min_points": 5,
}


static func fibonacci_seed(i: int, n: int) -> PackedFloat64Array:
	var golden := PI * (3.0 - sqrt(5.0))
	var y := 1.0 - (float(i) + 0.5) / float(n) * 2.0
	var lat := rad_to_deg(asin(clampf(y, -1.0, 1.0)))
	var lon := fposmod(rad_to_deg(golden * float(i)) + 180.0, 360.0) - 180.0
	return PackedFloat64Array([lat, lon])


static func _cell(lat: float, lon: float, c: float) -> Vector3i:
	var p := GlobeMath.to_unit(lat, lon)
	return Vector3i(int(floor(p.x / c)), int(floor(p.y / c)), int(floor(p.z / c)))


## {lines: [{ll: PackedFloat64Array lat,lon pairs, spd: PackedFloat32Array}]}.
static func trace(fu: Dictionary, fv: Dictionary, opts: Dictionary = {}) -> Array:
	var o := DEFAULTS.duplicate()
	o.merge(opts, true)
	var c := deg_to_rad(float(o.cell_deg))
	var owner := {}   # Vector3i -> line id
	var lines: Array = []
	var n := int(o.seeds)
	for i in n:
		if lines.size() >= int(o.max_lines):
			break
		var s := fibonacci_seed(i, n)
		if absf(s[0]) > 85.0:
			continue
		var k0 := _cell(s[0], s[1], c)
		if owner.has(k0):
			continue
		var s_spd := speed_at(fu, fv, s[0], s[1])
		if s_spd < float(o.min_speed):
			continue
		var id := lines.size()
		var back := _march(fu, fv, s[0], s[1], -1.0, o, owner, id, c)
		var fwd := _march(fu, fv, s[0], s[1], 1.0, o, owner, id, c)
		var ll := PackedFloat64Array()
		var spd := PackedFloat32Array()
		for j in range(back.ll.size() / 2 - 1, -1, -1):
			ll.append(back.ll[j * 2])
			ll.append(back.ll[j * 2 + 1])
			spd.append(back.spd[j])
		ll.append(s[0])
		ll.append(s[1])
		spd.append(s_spd)
		ll.append_array(fwd.ll)
		spd.append_array(fwd.spd)
		if spd.size() < int(o.min_points):
			# Too short to draw: give its cells back.
			for k in back.cells:
				owner.erase(k)
			for k in fwd.cells:
				owner.erase(k)
			continue
		owner[k0] = id
		lines.append({"ll": ll, "spd": spd})
	return lines


static func speed_at(fu: Dictionary, fv: Dictionary, lat: float, lon: float) -> float:
	var u := Grib2Decoder.sample(fu, lat, lon)
	var v := Grib2Decoder.sample(fv, lat, lon)
	return sqrt(u * u + v * v)


static func _march(fu: Dictionary, fv: Dictionary, lat: float, lon: float, sgn: float,
		o: Dictionary, owner: Dictionary, id: int, c: float) -> Dictionary:
	var ll := PackedFloat64Array()
	var spd := PackedFloat32Array()
	var cells: Array = []
	var step := float(o.step_deg)
	for _s in int(o.max_steps):
		var u := Grib2Decoder.sample(fu, lat, lon)
		var v := Grib2Decoder.sample(fv, lat, lon)
		var sp := sqrt(u * u + v * v)
		if sp < float(o.min_speed):
			break
		# Midpoint (RK2) step along the direction.
		var mlat := lat + sgn * v / sp * step * 0.5
		var mlon := lon + sgn * u / sp * step * 0.5 / maxf(cos(deg_to_rad(lat)), 0.05)
		var u2 := Grib2Decoder.sample(fu, mlat, mlon)
		var v2 := Grib2Decoder.sample(fv, mlat, mlon)
		var sp2 := sqrt(u2 * u2 + v2 * v2)
		if sp2 < float(o.min_speed):
			break
		lat += sgn * v2 / sp2 * step
		lon += sgn * u2 / sp2 * step / maxf(cos(deg_to_rad(mlat)), 0.05)
		lon = fposmod(lon + 180.0, 360.0) - 180.0
		if absf(lat) > 86.0:
			break
		var k := _cell(lat, lon, c)
		if owner.has(k) and int(owner[k]) != id:
			break
		if not owner.has(k):
			cells.append(k)
		owner[k] = id
		ll.append(lat)
		ll.append(lon)
		spd.append(sp2)
	return {"ll": ll, "spd": spd, "cells": cells}


## Line-list mesh arrays at `radius`: two vertices per segment; UV.x = the
## distance along the line in degrees, UV.y = a per-line phase 0..1; COLOR.r
## = speed / 40 m/s. Positions are relative to the sphere centre.
static func line_arrays(lines: Array, radius: float, step_deg: float) -> Dictionary:
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var cols := PackedColorArray()
	for li in lines.size():
		var ll: PackedFloat64Array = lines[li].ll
		var spd: PackedFloat32Array = lines[li].spd
		var phase := fposmod(float(li) * 0.618034, 1.0)
		var np := spd.size()
		for j in np - 1:
			for q in 2:
				var idx := j + q
				verts.append(GlobeMath.to_unit(ll[idx * 2], ll[idx * 2 + 1]) * radius)
				uvs.append(Vector2(float(idx) * step_deg, phase))
				cols.append(Color(clampf(spd[idx] / 40.0, 0.0, 1.0), 0.0, 0.0, 1.0))
	return {"verts": verts, "uvs": uvs, "cols": cols}


## The power in the wind at a hub height (W/m²), from the 10 m speed by the
## neutral log law (Manwell et al.) with roughness z0 = 0.03 m (open land;
## the sea is smoother, so this underestimates offshore) and sea-level air
## (1.225 kg/m³): P = ½ ρ v³.
static func power_density(v10: float, hub_m: float = 100.0, z0: float = 0.03) -> float:
	var vh := v10 * log(hub_m / z0) / log(10.0 / z0)
	return 0.5 * 1.225 * vh * vh * vh


## Wind direction it blows FROM, degrees clockwise from north.
static func from_dir_deg(u: float, v: float) -> float:
	return fposmod(rad_to_deg(atan2(-u, -v)), 360.0)


## 360 x 180 cell-centred equirect overlay image (as GlobeGhiOverlay's: R =
## (value + offset_add) / scale, G = 1 everywhere) from any value function.
static func overlay_image(value_at: Callable, scale: float, offset_add: float) -> Image:
	var img := Image.create(360, 180, false, Image.FORMAT_RGBA8)
	for y in 180:
		var lat := 90.0 - (float(y) + 0.5)
		for x in 360:
			var lon := -180.0 + (float(x) + 0.5)
			var val := float(value_at.call(lat, lon))
			img.set_pixel(x, y, Color(clampf((val + offset_add) / scale, 0.0, 1.0), 1.0, 0.0, 1.0))
	return img
