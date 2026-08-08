class_name LinkageHwParamFields
extends RefCounted
## Which `params` a hardware part exposes, and how to edit each one.
##
## Port of `HW_PARAM_FIELDS` (hardware-detail.js:2240), extended to cover the
## keys the Godot meshes actually read that the web's own table omits. It exists
## so the inspector can BUILD ITSELF: a part's editor is this table walked once,
## not thirty hand-placed widgets that fall out of date the moment
## `LinkageHardware.default_part_params` gains an entry.
##
## Each field carries:
##   key      — the `params` key it edits
##   label    — what the row says, units included
##   kind     — "num" | "enum" | "bool" | "text", which picks the widget
##   min/max/step/dec — numeric bounds (num only)
##   options  — allowed values (enum only)
##
## Ranges are editorial, not physical: they set what a SLIDER sweeps, so they
## should span what someone would plausibly build, not what the maths tolerates.
## A value outside them can still be typed.
##
## Anything deliberately hidden goes in HIDDEN with a reason. Between the two,
## every key in `default_part_params` is accounted for — `_test_hw_param_fields`
## asserts exactly that, which is what stops this table rotting the next time a
## mesh gains a parameter.

const FIELDS := {
	"bolt": [
		{"key": "diameter", "label": "Shank ⌀ (in)", "kind": "num",
			"min": 0.0625, "max": 1.5, "step": 0.0625, "dec": 4},
		{"key": "length", "label": "Length (in)", "kind": "num",
			"min": 0.25, "max": 24.0, "step": 0.125, "dec": 3},
		{"key": "threadLength", "label": "Thread (in)", "kind": "num",
			"min": 0.0, "max": 24.0, "step": 0.125, "dec": 3},
		{"key": "headType", "label": "Head", "kind": "enum",
			"options": ["hex", "button", "socket", "flat"]},
		{"key": "headDia", "label": "Head ⌀ (in)", "kind": "num",
			"min": 0.1, "max": 3.0, "step": 0.03125, "dec": 4},
		{"key": "headHeight", "label": "Head ht (in)", "kind": "num",
			"min": 0.05, "max": 1.5, "step": 0.03125, "dec": 4},
	],
	"bushing": [
		{"key": "id", "label": "Bore ⌀ (in)", "kind": "num",
			"min": 0.0625, "max": 2.0, "step": 0.03125, "dec": 4},
		{"key": "od", "label": "Outer ⌀ (in)", "kind": "num",
			"min": 0.0625, "max": 3.0, "step": 0.03125, "dec": 4},
		{"key": "length", "label": "Length (in)", "kind": "num",
			"min": 0.05, "max": 8.0, "step": 0.0625, "dec": 4},
		{"key": "flangeOd", "label": "Flange ⌀ (in)", "kind": "num",
			"min": 0.0, "max": 4.0, "step": 0.03125, "dec": 4},
		{"key": "flangeThickness", "label": "Flange t (in)", "kind": "num",
			"min": 0.0, "max": 1.0, "step": 0.015625, "dec": 4},
	],
	"washer": [
		{"key": "id", "label": "Bore ⌀ (in)", "kind": "num",
			"min": 0.0625, "max": 2.0, "step": 0.03125, "dec": 4},
		{"key": "od", "label": "Outer ⌀ (in)", "kind": "num",
			"min": 0.0625, "max": 4.0, "step": 0.03125, "dec": 4},
		{"key": "thickness", "label": "Thickness (in)", "kind": "num",
			"min": 0.005, "max": 0.75, "step": 0.0078125, "dec": 4},
	],
	"lockWasher": [
		{"key": "id", "label": "Bore ⌀ (in)", "kind": "num",
			"min": 0.0625, "max": 2.0, "step": 0.03125, "dec": 4},
		{"key": "od", "label": "Outer ⌀ (in)", "kind": "num",
			"min": 0.0625, "max": 4.0, "step": 0.03125, "dec": 4},
		{"key": "thickness", "label": "Thickness (in)", "kind": "num",
			"min": 0.005, "max": 0.75, "step": 0.0078125, "dec": 4},
		{"key": "style", "label": "Style", "kind": "enum",
			"options": ["split", "star"]},
	],
	# A rivet nut is stored as a nut with `style: "rivet"`, so one table serves
	# both and the rivet-only keys simply read blank on a hex nut.
	"nut": [
		{"key": "id", "label": "Thread ⌀ (in)", "kind": "num",
			"min": 0.0625, "max": 2.0, "step": 0.03125, "dec": 4},
		{"key": "widthAcrossFlats", "label": "Across flats (in)", "kind": "num",
			"min": 0.1, "max": 3.0, "step": 0.03125, "dec": 4},
		{"key": "height", "label": "Height (in)", "kind": "num",
			"min": 0.05, "max": 2.0, "step": 0.03125, "dec": 4},
		{"key": "style", "label": "Style", "kind": "enum",
			"options": ["hex", "rivet"]},
		{"key": "thread", "label": "Thread", "kind": "text"},
		{"key": "od", "label": "Body ⌀ (in, rivet)", "kind": "num",
			"min": 0.0, "max": 3.0, "step": 0.03125, "dec": 4},
		{"key": "length", "label": "Length (in, rivet)", "kind": "num",
			"min": 0.0, "max": 4.0, "step": 0.03125, "dec": 4},
		{"key": "flangeOd", "label": "Flange ⌀ (in, rivet)", "kind": "num",
			"min": 0.0, "max": 4.0, "step": 0.03125, "dec": 4},
		{"key": "flangeThickness", "label": "Flange t (in, rivet)", "kind": "num",
			"min": 0.0, "max": 1.0, "step": 0.015625, "dec": 4},
	],
	"bracket": [
		{"key": "useGlb", "label": "Use GLB model", "kind": "bool"},
		{"key": "height", "label": "Height (in)", "kind": "num",
			"min": 0.5, "max": 12.0, "step": 0.0625, "dec": 4},
		{"key": "width", "label": "Width (in)", "kind": "num",
			"min": 0.5, "max": 12.0, "step": 0.0625, "dec": 4},
		{"key": "depth", "label": "Depth (in)", "kind": "num",
			"min": 0.5, "max": 12.0, "step": 0.0625, "dec": 4},
		{"key": "wallThickness", "label": "Wall (in)", "kind": "num",
			"min": 0.02, "max": 1.0, "step": 0.015625, "dec": 4},
		# Moves the bolt hole, and with it the whole stack — this is the single
		# most consequential number on a bracket.
		{"key": "sideHoleFromTop", "label": "Hole from top (in)", "kind": "num",
			"min": 0.0, "max": 8.0, "step": 0.0625, "dec": 4},
		{"key": "holeDiameter", "label": "Hole ⌀ (in)", "kind": "num",
			"min": 0.05, "max": 2.0, "step": 0.03125, "dec": 4},
		{"key": "bottomLip", "label": "Bottom lip (in)", "kind": "num",
			"min": 0.0, "max": 4.0, "step": 0.0625, "dec": 4},
		{"key": "cutoffHeight", "label": "Cutoff (in)", "kind": "num",
			"min": 0.0, "max": 12.0, "step": 0.0625, "dec": 4},
		{"key": "glbScaleMul", "label": "GLB scale ×", "kind": "num",
			"min": 0.1, "max": 5.0, "step": 0.01, "dec": 3},
		{"key": "glbRotX", "label": "GLB rot X (°)", "kind": "num",
			"min": -180.0, "max": 180.0, "step": 1.0, "dec": 1},
		{"key": "glbRotY", "label": "GLB rot Y (°)", "kind": "num",
			"min": -180.0, "max": 180.0, "step": 1.0, "dec": 1},
		{"key": "glbRotZ", "label": "GLB rot Z (°)", "kind": "num",
			"min": -180.0, "max": 180.0, "step": 1.0, "dec": 1},
		# Applied to the assembly seat AND the bracket mesh, deliberately —
		# see LinkageHwPlacement.transform_for.
		{"key": "posX", "label": "Nudge X (in)", "kind": "num",
			"min": -6.0, "max": 6.0, "step": 0.01, "dec": 3},
		{"key": "posY", "label": "Nudge Y (in)", "kind": "num",
			"min": -6.0, "max": 6.0, "step": 0.01, "dec": 3},
		{"key": "posZ", "label": "Nudge Z (in)", "kind": "num",
			"min": -6.0, "max": 6.0, "step": 0.01, "dec": 3},
	],
	"beam": [
		{"key": "width", "label": "Width (in)", "kind": "num",
			"min": 0.5, "max": 24.0, "step": 0.25, "dec": 3},
		{"key": "thickness", "label": "Thickness (in)", "kind": "num",
			"min": 0.25, "max": 12.0, "step": 0.25, "dec": 3},
		{"key": "length", "label": "Length (in)", "kind": "num",
			"min": 4.0, "max": 240.0, "step": 1.0, "dec": 2},
		{"key": "holeOffset", "label": "Hole from end (in)", "kind": "num",
			"min": 0.0, "max": 120.0, "step": 0.25, "dec": 3},
		{"key": "holeDiameter", "label": "Hole ⌀ (in)", "kind": "num",
			"min": 0.05, "max": 3.0, "step": 0.03125, "dec": 4},
		{"key": "holeAlign", "label": "Bolt hole", "kind": "enum",
			"options": ["near", "center", "far"]},
		{"key": "rotDeg", "label": "Roll (°)", "kind": "num",
			"min": -180.0, "max": 180.0, "step": 1.0, "dec": 1},
		{"key": "syncStructure", "label": "Sync dims from design", "kind": "bool"},
	],
}

## Keys the editor withholds, and why. Editing these by hand either does
## nothing or breaks something quieter than it fixes.
const HIDDEN := {
	"bolt": {
		"driveSize": "cosmetic — the mesh has no drive recess",
		"metric": "a label, carried for the BOM only",
	},
	"beam": {
		"color": "packed 0xRRGGBB int; the timber material owns the look",
	},
	"nut": {},
	"washer": {},
	"lockWasher": {},
	"bushing": {},
	"bracket": {},
}


## Editable fields for a part type, in display order. `rivetNut` shares the nut
## table — the two differ by a `style` value, not by a schema.
static func for_type(type: String) -> Array:
	var key := "nut" if type == "rivetNut" else type
	var rows = FIELDS.get(key)
	return rows if rows is Array else []


static func hidden_for_type(type: String) -> Dictionary:
	var key := "nut" if type == "rivetNut" else type
	var rows = HIDDEN.get(key)
	return rows if rows is Dictionary else {}


## The field row for one key, or {}.
static func field(type: String, key: String) -> Dictionary:
	for row in for_type(type):
		if str((row as Dictionary).get("key", "")) == key:
			return row as Dictionary
	return {}
