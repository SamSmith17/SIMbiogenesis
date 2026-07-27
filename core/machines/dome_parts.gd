class_name DomeParts
extends RefCounted

## Recycled-plastic 2V geodesic dome part kit (hub connectors + A/B struts).
## STL sources live under res://assets/dome/ (tracked — not the gitignored
## Imported Models pack). Craft BOM + trash-printer presets + GeodesicDomeBuilder
## all share these ids / paths / scale.

const DIR := "res://assets/dome"

const PART_HUB_4 := "dome_hub_4way"
const PART_HUB_5 := "dome_hub_5way"
const PART_HUB_6 := "dome_hub_6way"
const PART_STRUT_A := "dome_strut_a"
const PART_STRUT_B := "dome_strut_b"
## Extruded beam feedstock (CNC mills these into finished A/B struts).
const PART_BEAM := "pp_beam"

## Grounded 2V dome BOM (user-specified).
const BOM := {
	PART_HUB_4: 10,
	PART_HUB_5: 6,
	PART_HUB_6: 10,
	PART_STRUT_A: 35,
	PART_STRUT_B: 30,
}

const STL := {
	PART_HUB_4: DIR + "/four-way-hub.stl",
	PART_HUB_5: DIR + "/five-way-hub.stl",
	PART_HUB_6: DIR + "/six-way-hub.stl",
	PART_STRUT_A: DIR + "/A-strut.stl",
	PART_STRUT_B: DIR + "/B-strut.stl",
}

const LABELS := {
	PART_HUB_4: "4-way Dome Hub",
	PART_HUB_5: "5-way Dome Hub",
	PART_HUB_6: "6-way Dome Hub",
	PART_STRUT_A: "Dome A-Strut (long)",
	PART_STRUT_B: "Dome B-Strut (short)",
	PART_BEAM: "Recycled Plastic Beam",
}

## Native A-strut length in the STL (mm) — measured from binary bbox.
const STL_A_LENGTH_MM := 96.64
const STL_B_LENGTH_MM := 82.34
## Class-I 2V chord factors (strut length / radius).
const CF_A := 0.618034
const CF_B := 0.546533
## Target standing dome radius (metres) — interior height ≈ R for a hemisphere.
const TARGET_RADIUS_M := 2.4


static func assembly_scale() -> float:
	# World metres per STL millimetre so the long chord lands on TARGET_RADIUS_M.
	var a_m := TARGET_RADIUS_M * CF_A
	return a_m / (STL_A_LENGTH_MM * 0.001)


static func strut_a_length_m() -> float:
	return TARGET_RADIUS_M * CF_A


static func strut_b_length_m() -> float:
	return TARGET_RADIUS_M * CF_B


## Trash-printer modal presets: part_id, label, stl path, suggested print scale
## (fit ~80% of a 600 mm bed for hubs; struts scale similarly).
static func print_presets() -> Array:
	return [
		_preset(PART_HUB_4, 1.0),
		_preset(PART_HUB_5, 1.0),
		_preset(PART_HUB_6, 1.0),
		_preset(PART_STRUT_A, 1.0),
		_preset(PART_STRUT_B, 1.0),
	]


static func _preset(part_id: String, scale: float) -> Dictionary:
	return {
		"part_id": part_id,
		"label": str(LABELS.get(part_id, part_id)),
		"stl_path": str(STL.get(part_id, "")),
		"print_scale": scale,
		"count": 1,
	}


static func label_for(part_id: String) -> String:
	return str(LABELS.get(part_id, part_id))
