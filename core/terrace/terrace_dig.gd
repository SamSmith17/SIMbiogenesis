class_name TerraceDig
extends RefCounted

## Cutting a terrace field, step by step (pure static). Terraces are dug from
## the top of the slope down, one step at a time: the crew cuts into the
## uphill side of the step, carries the soil a few metres to the downhill
## side, packs it, levels the floor and builds the bund. Each step is a crew
## job worked in a line along the step (NpcRowWork), so the cut face moves
## along it as the job is done.
##
## HOURS. By hand ~3 person-hours a cubic metre moved: digging ordinary soil
## 1–1.5 h/m³, carrying it 10–20 m in baskets and packing it about as much
## again (ILO labour-based works norms put excavation at 3–5 m³ a person-day
## in normal soil, less in hard soil; carrying and compaction are separate
## tasks). Then ~0.05 h/m² of floor to level it, puddle it and raise the
## bund. A 3–5 t mini excavator moves ~6 m³/h on this kind of cut and fill
## with an operator and a helper shaping behind it, burning ~4 L of diesel an
## hour; the floors still want ~0.02 h/m² of hand finishing. All estimates.
## Every person-hour is ~80 Wh of work and ~320 Wh of food.

## The machines a step can be cut with (the game's own vehicles): earth moved
## an hour on terrace cut-and-fill, the people with it (the operator and a
## helper shaping behind), diesel an hour, hand finishing per m² of floor.
## A ~70 hp skid steer pushes and carries ~10 m³/h a short way at ~7 L/h; a
## ~40 hp compact tractor with a front loader ~6 m³/h at ~4.5 L/h (estimates
## from loader cycle times: a 0.3–0.4 m³ bucket, 1–2 min a cycle).
const MACHINES := {
	"skid_steer": {"label": "Skid steer", "model": "vehicle_skid_steer", "m3_h": 10.0,
		"fuel_lph": 7.0, "crew": 2, "finish_h_m2": 0.02},
	"tractor": {"label": "Tractor with front loader", "model": "vehicle_tractor", "m3_h": 6.0,
		"fuel_lph": 4.5, "crew": 2, "finish_h_m2": 0.03},
}

const HAND_H_PER_M3 := 3.0
const HAND_FINISH_H_M2 := 0.05
const MACHINE_M3_H := 6.0
const MACHINE_CREW := 2
const MACHINE_FUEL_LPH := 4.0
const MACHINE_FINISH_H_M2 := 0.02
## People a hand crew uses per metre of step it works along at most.
const HAND_M_PER_WORKER := 4.0
const HAND_CREW_MAX := 16


## The work to cut one step: {hours (person-hours), machine_h, fuel_l,
## work_kwh, food_kwh, fuel_kwh, crew_min, crew_max}.
static func estimate(vol_m3: float, floor_m2: float, mode: String, length_m: float = 20.0) -> Dictionary:
	var hours := 0.0
	var mh := 0.0
	var fuel := 0.0
	var cmin := 2
	var cmax := 2
	if mode == "machine":
		mode = "skid_steer"
	if MACHINES.has(mode):
		var mc: Dictionary = MACHINES[mode]
		mh = maxf(vol_m3, 0.0) / float(mc["m3_h"])
		hours = mh * float(mc["crew"]) + maxf(floor_m2, 0.0) * float(mc["finish_h_m2"])
		fuel = mh * float(mc["fuel_lph"])
		cmin = int(mc["crew"])
		cmax = int(mc["crew"]) + 2
	else:
		hours = maxf(vol_m3, 0.0) * HAND_H_PER_M3 + maxf(floor_m2, 0.0) * HAND_FINISH_H_M2
		cmin = 2
		cmax = clampi(int(ceil(length_m / HAND_M_PER_WORKER)), 2, HAND_CREW_MAX)
	var work := hours * TerraceFarm.WORK_WH_PER_H / 1000.0
	return {"hours": hours, "machine_h": mh, "fuel_l": fuel, "work_kwh": work,
		"food_kwh": work / TerraceFarm.MUSCLE_EFF, "fuel_kwh": fuel * TerraceFarm.DIESEL_KWH_L,
		"crew_min": cmin, "crew_max": cmax}


## Each step of a solved field as a piece of work, top step first:
## [{m, vol_m3 (earth moved: the larger of the cut and the fill), cut_m3,
## fill_m3, floor_m2, cells, spine [[x, z], …], half_w, length_m}].
static func steps_of(solved: Dictionary) -> Array:
	var grid: Dictionary = solved.get("grid", {})
	if grid.is_empty():
		return []
	var cell := float(grid["cell"])
	var a_cell := cell * cell
	var by_m := {}
	var deltas: Dictionary = solved.get("deltas", {})
	var dm: Dictionary = solved.get("delta_m", {})
	for key in deltas.keys():
		var m := int(dm.get(key, TerraceField.NO_STEP))
		if m == TerraceField.NO_STEP:
			continue
		if not by_m.has(m):
			by_m[m] = {"m": m, "cut_m3": 0.0, "fill_m3": 0.0, "floor_m2": 0.0, "pts": PackedVector2Array()}
		var e: Dictionary = by_m[m]
		var dl := float(deltas[key])
		if dl < 0.0:
			e["cut_m3"] = float(e["cut_m3"]) - dl * a_cell
		else:
			e["fill_m3"] = float(e["fill_m3"]) + dl * a_cell
		var kv: Vector2i = key
		var pts: PackedVector2Array = e["pts"]
		pts.append(Vector2(float(kv.x) * cell, float(kv.y) * cell))
		e["pts"] = pts
	for p in solved.get("paddies", []):
		var pd: Dictionary = p
		var m2 := int(pd.get("m", TerraceField.NO_STEP))
		if by_m.has(m2):
			(by_m[m2] as Dictionary)["floor_m2"] = float((by_m[m2] as Dictionary)["floor_m2"]) + float(pd["area"])
	var ms: Array = by_m.keys()
	ms.sort()
	ms.reverse()
	var out: Array = []
	for m3 in ms:
		var e2: Dictionary = by_m[m3]
		var sp := spine_of(e2["pts"])
		out.append({"m": int(m3), "vol_m3": maxf(float(e2["cut_m3"]), float(e2["fill_m3"])),
			"cut_m3": float(e2["cut_m3"]), "fill_m3": float(e2["fill_m3"]),
			"floor_m2": float(e2["floor_m2"]), "cells": (e2["pts"] as PackedVector2Array).size(),
			"spine": sp["spine"], "half_w": sp["half_w"], "length_m": sp["length_m"],
			"axis": sp["axis"], "u0": sp["u0"], "u1": sp["u1"]})
	return out


## A line down the middle of a set of points, following its bend: the points'
## long axis, cut into a few pieces, the middle of each. {spine [[x, z]…],
## half_w, length_m, axis (unit Vector2), u0, u1 (the points' extent along
## it)}.
static func spine_of(pts: PackedVector2Array, pieces: int = 8) -> Dictionary:
	var n := pts.size()
	if n == 0:
		return {"spine": [], "half_w": 1.0, "length_m": 0.0, "axis": Vector2(1, 0), "u0": 0.0, "u1": 0.0}
	var c := Vector2.ZERO
	for p in pts:
		c += p
	c /= float(n)
	var sxx := 0.0
	var szz := 0.0
	var sxz := 0.0
	for p in pts:
		var d := p - c
		sxx += d.x * d.x
		szz += d.y * d.y
		sxz += d.x * d.y
	var ang := 0.5 * atan2(2.0 * sxz, sxx - szz)
	var ax := Vector2(cos(ang), sin(ang))
	var nx := Vector2(-ax.y, ax.x)
	var u0 := INF
	var u1 := -INF
	for p in pts:
		var u := (p - c).dot(ax)
		u0 = minf(u0, u)
		u1 = maxf(u1, u)
	var k := clampi(pieces, 1, 32)
	var span := maxf(u1 - u0, 1e-3)
	var sums: Array = []
	var cnt := PackedInt32Array()
	var wsum := PackedFloat64Array()
	sums.resize(k)
	cnt.resize(k)
	wsum.resize(k)
	for i in k:
		sums[i] = Vector2.ZERO
	for p in pts:
		var b := clampi(int(((p - c).dot(ax) - u0) / span * float(k)), 0, k - 1)
		sums[b] = (sums[b] as Vector2) + p
		cnt[b] += 1
	var spine: Array = []
	var mids: Array = []
	for i in k:
		if cnt[i] > 0:
			var m := (sums[i] as Vector2) / float(cnt[i])
			mids.append(m)
			spine.append([m.x, m.y])
	# Half the width: the mean spread across the line, ×√3 (a uniform strip).
	var acc := 0.0
	for p in pts:
		var b2 := clampi(int(((p - c).dot(ax) - u0) / span * float(k)), 0, k - 1)
		if cnt[b2] > 0:
			var m2 := (sums[b2] as Vector2) / float(cnt[b2])
			acc += absf((p - m2).dot(nx))
	var half_w := clampf(acc / float(n) * 2.0, 0.6, 40.0)
	var length := 0.0
	for i in range(1, mids.size()):
		length += (mids[i] as Vector2).distance_to(mids[i - 1])
	return {"spine": spine, "half_w": half_w, "length_m": length, "axis": ax, "u0": u0 + c.dot(ax),
		"u1": u1 + c.dot(ax)}


## How much of a cell's cut is done when its step is `frac` dug: the cut face
## moves along the step's long axis, with a few metres of ramp behind it.
static func cell_share(u: float, u0: float, u1: float, frac: float, ramp_m: float = 3.0) -> float:
	if frac >= 0.999:
		return 1.0
	if frac <= 0.0:
		return 0.0
	var front := lerpf(u0 - ramp_m, u1, frac)
	return clampf((front - u) / ramp_m + 1.0, 0.0, 1.0) if front < u else 1.0


## The per-paddy line a farm crew works: {spine, half_w} for each paddy of a
## solved field, from its own cells.
static func paddy_rows(solved: Dictionary) -> Array:
	var grid: Dictionary = solved.get("grid", {})
	var pads: Array = solved.get("paddies", [])
	var out: Array = []
	if grid.is_empty():
		return out
	var cell := float(grid["cell"])
	var cols := int(grid["cols"])
	var rows := int(grid["rows"])
	var i0 := int(grid["i0"])
	var j0 := int(grid["j0"])
	var label: PackedInt32Array = grid["label"]
	var pts: Array = []
	for i in pads.size():
		pts.append(PackedVector2Array())
	for cj in rows:
		for ci in cols:
			var l := label[cj * cols + ci]
			if l >= 0 and l < pads.size():
				var a: PackedVector2Array = pts[l]
				a.append(Vector2(float(i0 + ci) * cell, float(j0 + cj) * cell))
				pts[l] = a
	for i in pads.size():
		var sp := spine_of(pts[i], 6)
		out.append({"spine": sp["spine"], "half_w": sp["half_w"], "length_m": sp["length_m"]})
	return out
