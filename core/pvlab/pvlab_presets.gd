class_name PvLabPresets
extends RefCounted

## Built-in modules and arrays for the Solar designer, and the player's
## library (user://pvlab_library.json: {modules: [...], designs: [...]}).
##
## Modules in "datasheet" mode carry a real nameplate (cited); the rest are
## "derived" from their cells (PvLabCells), labelled as a class of module,
## not a product.

const LIBRARY_PATH := "user://pvlab_library.json"

## The EG4 6000XP's PV input (its data sheet, as ComponentPresets): 480 V
## max Voc, MPPT 120–385 V, 100 V start-up, 25 A short circuit per MPPT,
## 8 kW of PV.
const EG4_6000XP := {"name": "EG4 6000XP", "max_voc": 480.0, "mppt_min_v": 120.0, "mppt_max_v": 385.0,
	"startup_v": 100.0, "max_isc": 25.0, "max_pv_watts": 8000.0}


static func modules() -> Array:
	return [
		# JA Solar JAM60S20-380/MR data sheet (the graph's preset): 1769 ×
		# 1052 × 35 mm, 120 half-cut M6 mono PERC, 20.5 kg, 3 split boxes,
		# 1200 mm leads, Voc 41.62 / Vmp 34.77 / Isc 11.47 / Imp 10.93,
		# −0.272 / +0.044 / −0.35 %/°C, NOCT 45.
		{"id": "ja_380", "name": "JA Solar JAM60S20 380 W", "spec": PvLabModule.resolve({
			"name": "JA Solar JAM60S20 380 W", "maker": "JA Solar", "type": "rigid",
			"dims_mm": {"w": 1052.0, "h": 1769.0, "t": 35.0},
			"cells": {"tech": "mono_perc", "format": "m6", "cut": "half", "cols": 6, "rows": 20, "gap_mm": 2.0,
				"split_gap_mm": 8.0, "busbars": 9},
			"frame": {"style": "silver", "height_mm": 35.0, "width_mm": 14.0},
			"backsheet": {"front": "white", "back": "white"}, "glass": "ar",
			"jbox": {"layout": "split3", "leads_mm": 1200.0, "connector": "mc4"}, "bypass_diodes": 3,
			"electrical": {"mode": "datasheet", "wmp": 380.0, "voc": 41.62, "vmp": 34.77, "isc": 11.47,
				"imp": 10.93, "voc_coeff": -0.272, "isc_coeff": 0.044, "pmax_coeff": -0.35, "noct_c": 45.0,
				"mass_kg": 20.5}})},
		{"id": "topcon_430_black", "name": "TOPCon 430 W all-black (108 half-cut M10)", "spec": PvLabModule.resolve({
			"name": "TOPCon 430 W all-black", "type": "rigid",
			"dims_mm": {"w": 1134.0, "h": 1722.0, "t": 30.0},
			"cells": {"tech": "topcon", "format": "m10", "cut": "half", "cols": 6, "rows": 18, "gap_mm": 2.0,
				"split_gap_mm": 6.0, "busbars": 16},
			"frame": {"style": "black", "height_mm": 30.0, "width_mm": 12.0},
			"backsheet": {"front": "black", "back": "black"},
			"jbox": {"layout": "split3", "leads_mm": 1200.0, "connector": "mc4_evo2"}})},
		{"id": "poly_275", "name": "Polycrystalline 275 W (60 cells)", "spec": PvLabModule.resolve({
			"name": "Poly 275 W", "type": "rigid", "dims_mm": {"w": 992.0, "h": 1650.0, "t": 35.0},
			"cells": {"tech": "poly", "format": "m2", "cut": "full", "cols": 6, "rows": 10, "gap_mm": 3.0, "busbars": 4},
			"frame": {"style": "silver", "height_mm": 35.0, "width_mm": 14.0},
			"backsheet": {"front": "white", "back": "white"},
			"jbox": {"layout": "top", "leads_mm": 1000.0, "connector": "mc4"}})},
		{"id": "ibc_375", "name": "Back-contact 375 W (Maxeon class, 104 cells)", "spec": PvLabModule.resolve({
			"name": "Back-contact 375 W", "type": "rigid", "dims_mm": {"w": 1046.0, "h": 1690.0, "t": 40.0},
			"cells": {"tech": "ibc", "format": "m0", "cut": "full", "cols": 8, "rows": 13, "gap_mm": 2.0},
			"frame": {"style": "black", "height_mm": 40.0, "width_mm": 10.0},
			"backsheet": {"front": "black", "back": "black"},
			"jbox": {"layout": "top", "leads_mm": 1200.0, "connector": "mc4"}, "bypass_diodes": 4})},
		{"id": "rigid_100_12v", "name": "100 W 12 V module (36 cells)", "spec": PvLabModule.resolve({
			"name": "100 W 12 V", "type": "rigid", "dims_mm": {"w": 560.0, "h": 1195.0, "t": 30.0},
			"cells": {"tech": "mono_perc", "format": "m0", "cut": "full", "cols": 4, "rows": 9, "gap_mm": 2.0,
				"busbars": 5},
			"frame": {"style": "silver", "height_mm": 30.0, "width_mm": 14.0},
			"jbox": {"layout": "top", "leads_mm": 900.0, "connector": "mc4"}, "bypass_diodes": 2,
			"electrical": {"mode": "datasheet", "wmp": 100.0, "voc": 22.5, "vmp": 18.6, "isc": 5.86, "imp": 5.38}})},
		# The graph's "Alrska Flexible 100W": 21.6 / 18.0 / 6.10 / 5.56.
		{"id": "flex_100", "name": "Flexible 100 W (ETFE)", "spec": PvLabModule.resolve({
			"name": "Flexible 100 W", "type": "flexible", "dims_mm": {"w": 540.0, "h": 1160.0, "t": 2.5},
			"cells": {"tech": "mono_perc", "format": "m0", "cut": "full", "cols": 4, "rows": 9, "gap_mm": 1.5,
				"busbars": 9},
			"frame": {"style": "none"}, "glass": "etfe", "backsheet": {"front": "black", "back": "black"},
			"jbox": {"layout": "top", "leads_mm": 900.0, "connector": "mc4"}, "bypass_diodes": 1,
			"electrical": {"mode": "datasheet", "wmp": 100.0, "voc": 21.6, "vmp": 18.0, "isc": 6.10, "imp": 5.56}})},
		# The graph's "BougeRV CIGS 200W": 34.0 / 28.0 / 7.50 / 7.14.
		{"id": "cigs_200", "name": "CIGS flexible 200 W", "spec": PvLabModule.resolve({
			"name": "CIGS flexible 200 W", "type": "flexible", "dims_mm": {"w": 1000.0, "h": 1200.0, "t": 3.0},
			"cells": {"tech": "cigs", "rows": 50, "gap_mm": 0.6}, "frame": {"style": "none"}, "glass": "etfe",
			"backsheet": {"front": "black", "back": "black"},
			"jbox": {"layout": "top", "leads_mm": 900.0, "connector": "mc4"}, "bypass_diodes": 1,
			"electrical": {"mode": "datasheet", "wmp": 200.0, "voc": 34.0, "vmp": 28.0, "isc": 7.50, "imp": 7.14}})},
		# First Solar Series 6 FS-6420 data sheet: 2009 × 1232 × 49 mm, 264
		# CdTe cells, 34.5 kg, Voc 219.2 / Vmp 180.5 / Isc 2.54 / Imp 2.33,
		# −0.28 %/°C Voc, −0.32 %/°C Pmax, no bypass diodes.
		{"id": "cdte_420", "name": "First Solar Series 6 420 W (CdTe)", "spec": PvLabModule.resolve({
			"name": "First Solar Series 6 420 W", "maker": "First Solar", "type": "thin_film",
			"dims_mm": {"w": 1232.0, "h": 2009.0, "t": 49.0}, "cells": {"tech": "cdte", "rows": 264, "gap_mm": 0.2},
			"frame": {"style": "black", "height_mm": 49.0, "width_mm": 8.0}, "glass": "ar",
			"backsheet": {"front": "black", "back": "black"},
			"jbox": {"layout": "center", "leads_mm": 1100.0, "connector": "mc4"}, "bypass_diodes": 0,
			"electrical": {"mode": "datasheet", "wmp": 420.0, "voc": 219.2, "vmp": 180.5, "isc": 2.54, "imp": 2.33,
				"voc_coeff": -0.28, "pmax_coeff": -0.32, "mass_kg": 34.5}})},
		{"id": "fold_200", "name": "Folding 200 W portable (4 leaves)", "spec": PvLabModule.resolve({
			"name": "Folding 200 W", "type": "folding", "dims_mm": {"w": 545.0, "h": 2260.0, "t": 4.0},
			"cells": {"tech": "mono_perc", "format": "m0", "cut": "full", "cols": 4, "rows": 12, "gap_mm": 2.0,
				"busbars": 9},
			"frame": {"style": "fabric", "height_mm": 6.0, "width_mm": 16.0}, "glass": "etfe",
			"backsheet": {"front": "black", "back": "black"},
			"folding": {"leaves": 4, "hinge_mm": 20.0, "kickstands": 2},
			"jbox": {"layout": "corner", "leads_mm": 4000.0, "connector": "anderson"}, "bypass_diodes": 4,
			"electrical": {"mode": "datasheet", "wmp": 200.0, "voc": 23.2, "vmp": 19.2, "isc": 11.1, "imp": 10.4}})},
	]


static func module(id: String) -> Dictionary:
	for m in modules():
		if str(m["id"]) == id:
			return m["spec"]
	return PvLabModule.default_spec()


static func builtins() -> Array:
	return [
		{"id": "backyard_2x4", "name": "Backyard rack in 2x4s (12 × JA 380 W)",
			"blurb": "Two portrait rows of six on a 2x4 lumber A-frame at 30°, 0.5 m off the ground; 2 strings of 6.",
			"spec": PvLabSpec.resolve({"name": "Backyard 2x4 rack", "module": module("ja_380"),
				"array": {"mount": "ground", "rows": 1, "cols": 6, "stack": 2, "tilt_deg": 30.0, "clearance_m": 0.5},
				"rack": {"material": "lumber_2x4", "leg_spacing_m": 1.2}, "target": EG4_6000XP,
				"strings": {"mode": "rows", "size": 6}})},
		{"id": "unistrut_ground", "name": "Unistrut ground rack (2 rows × 8)",
			"blurb": "Two tables of 4 × 2 portrait on Unistrut P1000 at 35°, rows spaced for no winter shade; one string per MPPT input.",
			"spec": PvLabSpec.resolve({"name": "Unistrut ground rack", "module": module("topcon_430_black"),
				"array": {"mount": "ground", "rows": 2, "cols": 4, "stack": 2, "tilt_deg": 35.0, "clearance_m": 0.6},
				"rack": {"material": "unistrut_p1000", "leg_spacing_m": 1.4},
				"target": EG4_6000XP,
				"strings": {"mode": "rows", "size": 8, "inputs": 2}})},
		{"id": "roof_flush_rail", "name": "Roof, flush on aluminium rail (10 × 430 W)",
			"blurb": "Two rows of five portrait on light aluminium rail and L-feet, flush with the roof.",
			"spec": PvLabSpec.resolve({"name": "Roof array", "module": module("topcon_430_black"),
				"array": {"mount": "roof_flush", "rows": 1, "cols": 5, "stack": 2, "gap_mm": 20.0},
				"rack": {"material": "alu_rail_light", "leg_spacing_m": 1.2, "standoff_mm": 110.0},
				"target": EG4_6000XP, "strings": {"mode": "rows", "size": 10}})},
		{"id": "ballast_flat", "name": "Flat roof, ballasted (2 × 5 landscape)",
			"blurb": "Two rows of five landscape modules on 10° ballasted trays.",
			"spec": PvLabSpec.resolve({"name": "Ballasted flat roof", "module": module("ja_380"),
				"array": {"mount": "ballast", "rows": 2, "cols": 5, "stack": 1, "orientation": "landscape",
					"tilt_deg": 10.0, "clearance_m": 0.15},
				"rack": {"material": "alu_rail_heavy", "leg_spacing_m": 1.6}, "target": EG4_6000XP,
				"strings": {"mode": "rows", "size": 10}})},
		{"id": "tracker_1p", "name": "Single-axis tracker (3 rows of 12)",
			"blurb": "Three north–south tracker rows of twelve portrait modules (1P), ±60°, backtracking.",
			"spec": PvLabSpec.resolve({"name": "Tracker field", "module": module("ja_380"),
				"array": {"mount": "tracker", "rows": 3, "cols": 12, "stack": 1, "gcr": 0.35},
				"rack": {"material": "alu_rail_heavy", "hub_h_m": 1.6, "leg_spacing_m": 2.0},
				"tracker": {"max_deg": 60.0, "backtrack": true},
				"target": EG4_6000XP,
				"strings": {"mode": "rows", "size": 9, "inputs": 2}})},
		{"id": "pole_100", "name": "Pole mount (4 × 100 W, 12 V)",
			"blurb": "Four 100 W modules on one pole at 45°, wired 2S2P for a 12 V charge controller.",
			"spec": PvLabSpec.resolve({"name": "Pole mount", "module": module("rigid_100_12v"),
				"array": {"mount": "pole", "rows": 1, "cols": 4, "stack": 1, "tilt_deg": 45.0},
				"rack": {"material": "unistrut_p1000", "pole_h_m": 2.4, "leg_spacing_m": 1.0},
				"target": {"name": "Victron SmartSolar 100/20", "max_voc": 100.0, "max_pv_watts": 580.0},
				"strings": {"mode": "rows", "size": 2}})},
		{"id": "flex_laid", "name": "Flexible panels laid flat (4 × 100 W)",
			"blurb": "Four flexible 100 W modules glued straight to a surface, no rack.",
			"spec": PvLabSpec.resolve({"name": "Flexible on the roof", "module": module("flex_100"),
				"array": {"mount": "none", "rows": 1, "cols": 4, "stack": 1, "gap_mm": 40.0},
				"target": {"name": "Victron SmartSolar 100/20", "max_voc": 100.0, "max_pv_watts": 580.0},
				"strings": {"mode": "rows", "size": 4}})},
	]


static func builtin(id: String) -> Dictionary:
	for p in builtins():
		if str(p["id"]) == id:
			return p
	return {}


static func load_library(path: String = LIBRARY_PATH) -> Dictionary:
	var out := {"modules": [], "designs": []}
	if not FileAccess.file_exists(path):
		return out
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	var data: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if not (data is Dictionary):
		return out
	for k in ["modules", "designs"]:
		for d in (data as Dictionary).get(k, []):
			if d is Dictionary and (d as Dictionary).get("spec") is Dictionary:
				(out[k] as Array).append(d)
	return out


static func save_library(lib: Dictionary, path: String = LIBRARY_PATH) -> bool:
	var mods: Array = []
	for d in lib.get("modules", []):
		mods.append({"id": str(d["id"]), "name": str(d["name"]), "spec": PvLabModule.to_json_safe(d["spec"])})
	var des: Array = []
	for d in lib.get("designs", []):
		des.append({"id": str(d["id"]), "name": str(d["name"]), "spec": PvLabSpec.to_json_safe(d["spec"])})
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": 1, "modules": mods, "designs": des}, "\t"))
	f.close()
	return true
