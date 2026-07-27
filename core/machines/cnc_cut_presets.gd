class_name CncCutPresets
extends RefCounted

## Built-in CNC router cut operations. Demonstrates an alternate recipe pathway:
## extrude recycled-plastic beams → mill rounded struts + bolt holes on the
## router → assemble the 2V dome (hubs still come from the trash printer).

const PRESETS: Array = [
	{
		"id": "cut_dome_strut_a",
		"label": "Cut Dome A-Strut (long)",
		"note": "Mills one recycled-plastic beam into a long 2V A-strut (rounded ends + bolt holes).",
		"stl_path": "res://assets/dome/A-strut.stl",
		"produce_part_id": "dome_strut_a",
		"produce_label": "Dome A-Strut (long)",
		"consume_qty": 1,
		"min_beam_length_m": 1.40,
	},
	{
		"id": "cut_dome_strut_b",
		"label": "Cut Dome B-Strut (short)",
		"note": "Mills one recycled-plastic beam into a short 2V B-strut (rounded ends + bolt holes).",
		"stl_path": "res://assets/dome/B-strut.stl",
		"produce_part_id": "dome_strut_b",
		"produce_label": "Dome B-Strut (short)",
		"consume_qty": 1,
		"min_beam_length_m": 1.25,
	},
]


static func all() -> Array:
	return PRESETS.duplicate(true)


static func find(preset_id: String) -> Dictionary:
	for p: Dictionary in PRESETS:
		if str(p.get("id", "")) == preset_id:
			return (p as Dictionary).duplicate(true)
	return {}
