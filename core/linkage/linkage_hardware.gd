class_name LinkageHardware
extends RefCounted
## Hardware-assembly data model for the LinkageLab port (all static).
##
## A "hardware assembly" is the ordered stack of physical parts at one joint of
## the scissor linkage — bolt, bushing, lock washer, beam, washer, nut — laid
## out along an axis through the pivot. Four assemblies describe a whole
## structure (see `default_assemblies`), and because each part carries `axis`
## and `seq`, the assembly IS the assembly instruction: the order it lists parts
## in is the order a person threads them onto the pivot. `LinkageBom` turns that
## into build-guide steps and NPC fabrication chores.
##
## Port of `js/linkage/hardware-detail.js` (data half:
## `getDefaultHardwareAssemblies` :878, `getHardwarePartDefaults` :854,
## `ensureHardwareAssemblies` :994). The layout MATHS lives in
## `LinkageHwLayout`; the meshes in `LinkageHwParts`.
##
## [b]Key casing is deliberately camelCase here[/b], unlike every other
## dictionary in this port. The assembly graph is an open-ended user-authored
## part tree — seven part types with a dozen params each, plus `presetId` /
## `bomKey` / `sharedKey` and whatever a newer web-app build adds. A
## snake_case translation layer would have to enumerate every key, and any key
## it did not know about would be silently dropped on round-trip. Storing the
## web app's own shape verbatim means an unknown key survives untouched. This
## class is the only place allowed to index into that shape.

## Inches per millimetre — metric fasteners are authored in mm, stored in inches.
const MM_TO_IN := 1.0 / 25.4

const PART_TYPES: PackedStringArray = [
	"bolt", "bushing", "washer", "lockWasher", "nut", "bracket", "beam",
]

## Human labels per part type (`HW_TYPE_LABELS`, hardware-detail.js:2294).
const TYPE_LABELS := {
	"bolt": "Bolt",
	"bushing": "Bushing",
	"washer": "Washer",
	"lockWasher": "Lock Washer",
	"nut": "Nut",
	"rivetNut": "Rivet Nut",
	"bracket": "Bracket",
	"beam": "Beam",
}

## Part types that contribute their own BOM lines beyond the legacy formula
## rows (bolts and washers are still counted analytically — see
## `getAssemblyHardwareItems`, hardware-detail.js:3403).
const BOM_EXTRA_TYPES: PackedStringArray = ["bushing", "lockWasher", "nut"]

const ASSEMBLY_IDS: PackedStringArray = [
	"outerVBeam", "innerVBeam", "hCenter", "vCenter",
]

## Assemblies whose H-beams form a sandwich around a centre gap washer.
const HBEAM_SANDWICH_ASSEMBLY_IDS: PackedStringArray = [
	"outerVBeam", "innerVBeam", "hCenter",
]

const HBEAM_GAP_WASHER_SHARED_KEY := "hBeamGapWasher"


# ---------------------------------------------------------------------------
# Part defaults
# ---------------------------------------------------------------------------

## Default position/orientation fields carried by every stack part
## (`hwDefaultPartPos`, hardware-detail.js:52).
static func default_part_pos() -> Dictionary:
	return {
		"posAssembled": 0.0,
		"posExploded": 0.0,
		"crossOffset": 0.0,
		"flipAxis": false,
	}


## Parameter defaults for a freshly added part of `type`
## (`getHardwarePartDefaults`, hardware-detail.js:854).
static func default_part_params(type: String) -> Dictionary:
	match type:
		"bolt":
			return {
				"diameter": 0.5, "length": 3.0, "threadLength": 1.0,
				"headType": "hex", "headDia": 0.75, "headHeight": 0.3125,
				"driveSize": 0.0, "metric": "",
			}
		"bushing":
			return {
				"id": 0.3125, "od": 0.625, "length": 1.25,
				"flangeOd": 0.0, "flangeThickness": 0.0,
			}
		"washer":
			return {"id": 0.3125, "od": 1.0, "thickness": 0.0625}
		"lockWasher":
			return {"id": 0.3125, "od": 0.5, "thickness": 0.078, "style": "split"}
		"nut":
			return {
				"id": 0.5, "widthAcrossFlats": 0.75, "height": 0.4375,
				"style": "hex", "thread": "",
			}
		"rivetNut":
			return default_rivet_nut_params()
		"bracket":
			return {
				"useGlb": true, "height": 3.77, "width": 2.15, "depth": 1.57,
				"wallThickness": 0.12, "holeDiameter": 0.41, "bottomLip": 1.01,
				"sideHoleFromTop": 1.1875, "cutoffHeight": 0.0,
				"glbScaleMul": 1.0, "glbRotX": 0.0, "glbRotY": 90.0, "glbRotZ": 0.0,
				"posX": 0.0, "posY": 0.0, "posZ": 0.0,
			}
		"beam":
			return {
				"width": 3.5, "thickness": 1.5, "length": 96.0,
				"holeOffset": 1.5, "holeDiameter": 8.0 / 25.4, "holeAlign": "near",
				"rotDeg": 90.0, "syncStructure": true, "color": 0x8B6914,
			}
	return {}


## `getRivetNutDefaults` (hardware-detail.js:841).
static func default_rivet_nut_params() -> Dictionary:
	return {
		"id": 0.5,
		"od": 17.0 * MM_TO_IN,
		"length": 0.5,
		"flangeOd": 18.0 * MM_TO_IN,
		"flangeThickness": MM_TO_IN,
		"style": "rivet",
		"thread": "1/2-13",
	}


## Build a stack part, filling in the position defaults.
static func make_part(id: String, type: String, label: String, axis: String,
		seq: int, qty: int, per_module: int, cost: float,
		params: Dictionary, extra: Dictionary = {}) -> Dictionary:
	var part := default_part_pos()
	part["id"] = id
	part["type"] = type
	part["label"] = label
	part["axis"] = axis
	part["seq"] = seq
	part["qty"] = qty
	part["perModule"] = per_module
	part["cost"] = cost
	part["params"] = params.duplicate(true)
	for k in extra:
		part[k] = extra[k]
	return part


# ---------------------------------------------------------------------------
# Default assemblies (`getDefaultHardwareAssemblies`, hardware-detail.js:878)
# ---------------------------------------------------------------------------

static func _outer_v_bolt_params() -> Dictionary:
	# M8x60 button head — authored in mm, stored in inches.
	return {
		"diameter": snappedf(8.0 * MM_TO_IN, 0.0001),
		"length": snappedf(60.0 * MM_TO_IN, 0.0001),
		"threadLength": snappedf(24.0 * MM_TO_IN, 0.0001),
		"headType": "button",
		"headDia": snappedf(13.0 * MM_TO_IN, 0.0001),
		"headHeight": snappedf(5.0 * MM_TO_IN, 0.0001),
		"driveSize": snappedf(4.0 * MM_TO_IN, 0.0001),
		"metric": "M8x1.25",
	}


static func _bushing_params() -> Dictionary:
	return {"id": 0.3125, "od": 0.625, "length": 1.25,
		"flangeOd": 0.0, "flangeThickness": 0.0}


static func _lock_params() -> Dictionary:
	return {"id": 0.3125, "od": 0.5, "thickness": 0.078, "style": "split"}


static func _hbeam_params() -> Dictionary:
	return {
		"width": 3.5, "thickness": 1.5, "length": 18.0,
		"holeOffset": 9.0, "holeDiameter": 0.5,
		"rotDeg": 0.0, "syncStructure": "hBeam", "color": 0x8B6914,
	}


## The paired H-beams that sandwich the pivot (`hwDefaultHBeamPairParts` :84).
static func default_hbeam_pair_parts() -> Array:
	return [
		make_part("u-hbeam", "beam", "Horizontal H-Beam", "up", 0, 1, 0, 0.0, _hbeam_params()),
		make_part("d-hbeam", "beam", "Horizontal H-Beam", "down", 0, 1, 0, 0.0, _hbeam_params()),
	]


## The shared centre-slot washer that sets the H-beam sandwich gap
## (`hwDefaultHBeamGapWasherPart` :65).
static func default_hbeam_gap_washer_part(asm_id: String) -> Dictionary:
	return make_part(
		"%s-hbeam-gap-washer" % asm_id, "washer",
		"H-Beam Gap Washer 1/2\"ID 2\"OD", "center", 0, 1, 0, 0.10,
		{"id": 0.5, "od": 2.0, "thickness": 0.0625},
		{"sharedKey": HBEAM_GAP_WASHER_SHARED_KEY})


static func default_assemblies() -> Dictionary:
	return {
		"activeId": "outerVBeam",
		"explode": 0.0,
		"snap": true,
		"assemblies": {
			"outerVBeam": _default_outer_v_beam(),
			"innerVBeam": _default_inner_v_beam(),
			"hCenter": _default_h_center(),
			"vCenter": _default_v_center(),
		},
	}


## Outer V-beam joint: the U-bracket rides above the top H-beam, and the outer
## vertical beam bolts through a bushing + lock washer on each side.
static func _default_outer_v_beam() -> Dictionary:
	var parts: Array = [
		make_part("bracket", "bracket", "U-Bracket (Unistrut Trolley)", "up",
			5, 1, 4, 5.0, default_part_params("bracket")),
		make_part("r-beam", "beam", "Outer V-Beam", "right", 1, 1, 2, 0.0, {
			"width": 3.5, "thickness": 1.5, "length": 96.0,
			"holeOffset": 1.5, "holeDiameter": 8.0 / 25.4,
			"rotDeg": 90.0, "syncStructure": true, "color": 0x8B6914,
		}),
		make_part("r-bushing", "bushing", "Bushing 5/16\"ID 5/8\"OD 1.25\"",
			"right", 2, 1, 2, 0.85, _bushing_params()),
		make_part("r-lock", "lockWasher", "5/16\" Split Lock Washer",
			"right", 3, 1, 2, 0.06, _lock_params()),
		make_part("r-bolt", "bolt", "Outer V-Beam Bolt (8x60mm button)",
			"right", 4, 1, 2, 0.55, _outer_v_bolt_params()),
	]
	parts.append_array(default_hbeam_pair_parts())
	parts.append(default_hbeam_gap_washer_part("outerVBeam"))
	parts.append(make_part("c-bolt", "bolt", "H-Pivot Bolt 1/2\"x3\" Hex",
		"down", 2, 1, 1, 0.75, default_part_params("bolt")))
	parts.append(make_part("c-outer-washer", "washer", "Outer Washer 5/16\"ID 1.5\"OD",
		"down", 3, 1, 1, 0.08, {"id": 0.3125, "od": 1.5, "thickness": 0.0625}))
	parts.append(make_part("c-nut", "nut", "1/2\"-13 Rivet Nut",
		"down", 4, 1, 1, 0.40, default_rivet_nut_params()))
	return {
		"id": "outerVBeam",
		"label": "Outer V-Beam Assembly",
		"detailed": true,
		"explodeGap": 1.4,
		"detailCam": {"pitchDeg": 8.0, "distMul": 2.0},
		"sandwichPlane": "vertical",
		# Right and left horizontal stacks are identical and mirrored: only the
		# 'right' parts are stored, 'left' is rendered as a live mirror.
		"mirror": {"from": "right", "to": "left"},
		"parts": parts,
	}


static func _default_inner_v_beam() -> Dictionary:
	var parts: Array = [
		make_part("r-beam", "beam", "Inner V-Beam", "right", 1, 1, 2, 0.0, {
			"width": 3.5, "thickness": 1.5, "length": 96.0,
			"holeOffset": 1.5, "holeDiameter": 8.0 / 25.4, "holeAlign": "center",
			"rotDeg": 90.0, "syncStructure": true, "color": 0x8B6914,
		}),
		make_part("r-washer", "washer", "Washer 5/8\"ID 1-5/16\"OD",
			"right", 2, 1, 2, 0.08, {"id": 0.625, "od": 1.3125, "thickness": 0.0625}),
		make_part("r-lock", "lockWasher", "5/16\" Split Lock Washer",
			"right", 3, 1, 2, 0.06, _lock_params()),
		make_part("r-bolt", "bolt", "Inner V-Beam Bolt (8x60mm button)",
			"right", 4, 1, 2, 0.55, _outer_v_bolt_params(), {"flipAxis": true}),
	]
	parts.append_array(default_hbeam_pair_parts())
	parts.append(default_hbeam_gap_washer_part("innerVBeam"))
	return {
		"id": "innerVBeam",
		"label": "Inner V-Beam Assembly",
		"detailed": true,
		"explodeGap": 1.4,
		"detailCam": {"pitchDeg": 8.0, "distMul": 2.0},
		"sandwichPlane": "vertical",
		"parts": parts,
	}


static func _default_h_center() -> Dictionary:
	var parts: Array = default_hbeam_pair_parts()
	parts.append(default_hbeam_gap_washer_part("hCenter"))
	return {
		"id": "hCenter",
		"label": "H-Beam Center Linkage Assembly",
		"detailed": true,
		"explodeGap": 1.4,
		"detailCam": {"pitchDeg": 38.0, "distMul": 2.2},
		"sandwichPlane": "vertical",
		"mirrorPairs": [],
		"parts": parts,
	}


static func _default_v_center() -> Dictionary:
	return {
		"id": "vCenter",
		"label": "V-Beam Center Assembly",
		"detailed": true,
		"explodeGap": 1.4,
		"detailCam": {"pitchDeg": 14.0, "distMul": 1.9},
		"sandwichPlane": "horizontal",
		"mirrorPairs": [],
		"parts": [],
	}


# ---------------------------------------------------------------------------
# Normalization (`ensureHardwareAssemblies`, hardware-detail.js:994)
# ---------------------------------------------------------------------------

## Bring a loaded/legacy `hardwareAssemblies` dict up to the current shape.
## Always returns a fresh deep copy — never aliases `raw`, so a config parsed
## from disk can be discarded afterwards.
static func ensure(raw) -> Dictionary:
	var defaults := default_assemblies()
	if not (raw is Dictionary) or (raw as Dictionary).is_empty():
		return defaults
	var ha: Dictionary = (raw as Dictionary).duplicate(true)
	if not (ha.get("assemblies") is Dictionary):
		ha["assemblies"] = {}
	var asms: Dictionary = ha["assemblies"]
	var def_asms: Dictionary = defaults["assemblies"]
	for key in def_asms:
		if not (asms.get(key) is Dictionary):
			asms[key] = def_asms[key]
	if not (ha.get("activeId") is String) or not asms.has(ha["activeId"]):
		ha["activeId"] = "outerVBeam"
	if not (ha.get("explode") is float or ha.get("explode") is int):
		ha["explode"] = 0.0
	if not (ha.get("snap") is bool):
		ha["snap"] = true
	for key in asms:
		if asms[key] is Dictionary:
			_ensure_assembly(asms[key], key, def_asms.get(key, {}))
	_reconcile_shared_parts(ha)
	return ha


static func _ensure_assembly(asm: Dictionary, key: String, def_asm: Dictionary) -> void:
	asm["id"] = str(asm.get("id", key))
	if not (asm.get("label") is String):
		asm["label"] = str(def_asm.get("label", key))
	if not (asm.get("detailed") is bool):
		asm["detailed"] = bool(def_asm.get("detailed", true))
	if not (asm.get("explodeGap") is float or asm.get("explodeGap") is int):
		asm["explodeGap"] = float(def_asm.get("explodeGap", 1.4))
	if not (asm.get("detailCam") is Dictionary):
		asm["detailCam"] = (def_asm.get("detailCam", {}) as Dictionary).duplicate(true)
	if not (asm.get("sandwichPlane") is String):
		asm["sandwichPlane"] = "horizontal" if key == "vCenter" else "vertical"
	if not (asm.get("parts") is Array):
		asm["parts"] = []
	_ensure_hbeam_sandwich(asm)


## `hwEnsureHBeamSandwichAssembly` (hardware-detail.js:1010): relocate legacy
## brackets off the centre axis, rename the legacy inner washer to the shared
## gap washer, and backfill the H-beam pair.
static func _ensure_hbeam_sandwich(asm: Dictionary) -> void:
	var asm_id := str(asm.get("id", ""))
	if not HBEAM_SANDWICH_ASSEMBLY_IDS.has(asm_id):
		return
	var parts: Array = asm["parts"]

	# The U-bracket belongs in the UP stack (above the top H-beam) in cylinder
	# mode, not on the centre axis. Relocate legacy centre/right brackets once.
	for part in parts:
		if part is Dictionary and str(part.get("type", "")) == "bracket":
			var axis := str(part.get("axis", ""))
			if axis == "center" or axis == "right":
				part["axis"] = "up"

	for part in parts:
		if part is Dictionary and str(part.get("id", "")) == "c-inner-washer":
			part["id"] = "%s-hbeam-gap-washer" % asm_id
			part["sharedKey"] = HBEAM_GAP_WASHER_SHARED_KEY
			part["label"] = "H-Beam Gap Washer 1/2\"ID 2\"OD"
			part["axis"] = "center"
			var old_params: Dictionary = part.get("params", {})
			part["params"] = {
				"id": 0.5, "od": 2.0,
				"thickness": float(old_params.get("thickness", 0.0625)),
			}

	for def_part in default_hbeam_pair_parts():
		var want := str(def_part["id"])
		var found := false
		for part in parts:
			if part is Dictionary and str(part.get("id", "")) == want:
				found = true
				break
		if not found:
			parts.append(def_part)

	var has_gap_washer := false
	for part in parts:
		if part is Dictionary and str(part.get("sharedKey", "")) == HBEAM_GAP_WASHER_SHARED_KEY:
			has_gap_washer = true
			break
	if not has_gap_washer:
		parts.append(default_hbeam_gap_washer_part(asm_id))


## `hwReconcileSharedParts` (hardware-detail.js:108): parts carrying the same
## `sharedKey` are one physical item, so they must agree. The canonical copy is
## the highest-qty one, preferring outerVBeam on a tie.
static func _reconcile_shared_parts(ha: Dictionary) -> void:
	var asms: Dictionary = ha.get("assemblies", {})
	var canonical: Dictionary = {}
	var best_qty := 0
	for key in ASSEMBLY_IDS:
		var asm = asms.get(key)
		if not (asm is Dictionary):
			continue
		for part in (asm as Dictionary).get("parts", []):
			if not (part is Dictionary):
				continue
			if str(part.get("sharedKey", "")) != HBEAM_GAP_WASHER_SHARED_KEY:
				continue
			var qty := part_qty(part)
			if canonical.is_empty() or qty > best_qty \
					or (qty == best_qty and key == "outerVBeam"):
				canonical = part
				best_qty = qty
	if canonical.is_empty():
		return
	for key in asms:
		var asm = asms[key]
		if not (asm is Dictionary):
			continue
		for part in (asm as Dictionary).get("parts", []):
			if not (part is Dictionary):
				continue
			if str(part.get("sharedKey", "")) != HBEAM_GAP_WASHER_SHARED_KEY:
				continue
			if str(part.get("id", "")) == str(canonical.get("id", "")):
				continue
			part["label"] = canonical.get("label", part.get("label", ""))
			part["cost"] = canonical.get("cost", part.get("cost", 0.0))
			part["qty"] = canonical.get("qty", part.get("qty", 1))
			part["params"] = (canonical.get("params", {}) as Dictionary).duplicate(true)


# ---------------------------------------------------------------------------
# Accessors
# ---------------------------------------------------------------------------

static func assembly(ha: Dictionary, id: String) -> Dictionary:
	var asms = ha.get("assemblies")
	if not (asms is Dictionary):
		return {}
	var asm = (asms as Dictionary).get(id)
	return asm if asm is Dictionary else {}


static func assembly_has_parts(ha: Dictionary, id: String) -> bool:
	var asm := assembly(ha, id)
	if asm.is_empty():
		return false
	var parts = asm.get("parts")
	return parts is Array and not (parts as Array).is_empty()


## True when the structure-defining outer V-beam assembly is populated and
## full detail is switched on (`hwUseFullDetailAssemblies`, :1765).
static func use_full_detail(p: LinkageParams) -> bool:
	if not p.show_hardware_full_detail:
		return false
	return assembly_has_parts(p.hardware_assemblies, "outerVBeam")


## The bracket dimensions `LinkageHardwareSpacing.effective_bracket_params`
## substitutes into the solver. Editing one of these on the OUTER assembly's
## bracket moves the structure; editing anything else on it does not.
const SPACING_BRACKET_KEYS: PackedStringArray = [
	"height", "wallThickness", "width", "depth", "holeDiameter",
	"sideHoleFromTop", "innerWidth",
]

## Keys whose value feeds `part_axial_length`, and so the centre-slot span.
const SPACING_LENGTH_KEYS: PackedStringArray = [
	"length", "thickness", "height", "headHeight", "diameter",
	"flangeThickness", "flangeOd", "od", "style",
]


## Whether editing `key` on `part` can move the STRUCTURE — i.e. whether the
## caller owes `LinkageHardwareSpacing` a cache drop and a re-solve.
##
## Almost nothing does. The spacing layer reads exactly three things: the
## sandwich-beam standoffs, the centre-slot span, and the outer bracket's
## dimensions. Everything else — side-axis offsets, cross offsets, exploded
## positions, flips, labels, costs — moves a mesh and nothing more. Treating
## every edit as structural is what made a drag re-solve the whole frame per
## mouse-motion event.
##
## Note this answers "CAN it move the structure", not "will it": the caller must
## still check `show_hardware_full_detail`, because with that off
## `LinkageHardwareSpacing.effective_params` is the identity and the frame
## cannot move at all.
static func edit_requires_respacing(assembly_id: String, part: Dictionary,
		key: String) -> bool:
	if part.is_empty():
		# Structural edits (add / delete / reorder) arrive without a part.
		return true
	var type := str(part.get("type", ""))
	if type == "bracket":
		return assembly_id == "outerVBeam" \
			and (SPACING_BRACKET_KEYS.has(key) or key == "params")
	if key == "posAssembled":
		return is_sandwich_beam_part(part)
	# A centre-slot part's own thickness IS the sandwich gap.
	if str(part.get("axis", "")) == "center" and type != "beam":
		return key == "qty" or SPACING_LENGTH_KEYS.has(key) or key == "params"
	return false


## Any detailed assembly carrying parts (`hwAnyAssemblyEnabled`).
static func any_assembly_has_parts(ha: Dictionary) -> bool:
	for id in ASSEMBLY_IDS:
		if assembly_has_parts(ha, id):
			return true
	return false


## Parts on one axis, seq-ordered. Brackets are excluded because they anchor
## the stack rather than sitting in it (`hwComputeAxisLayout`'s filter, :377).
static func parts_on_axis(asm: Dictionary, axis: String) -> Array:
	var out: Array = []
	for part in asm.get("parts", []):
		if not (part is Dictionary):
			continue
		if str(part.get("type", "")) == "bracket":
			continue
		if str((part as Dictionary).get("axis", "right")) == axis:
			out.append(part)
	out.sort_custom(func(a, b): return int(a.get("seq", 0)) < int(b.get("seq", 0)))
	return out


## The bracket part of an assembly, or {} — brackets are singular per assembly.
static func bracket_part(asm: Dictionary) -> Dictionary:
	for part in asm.get("parts", []):
		if part is Dictionary and str(part.get("type", "")) == "bracket":
			return part
	return {}


static func find_part(asm: Dictionary, part_id: String) -> Dictionary:
	for part in asm.get("parts", []):
		if part is Dictionary and str(part.get("id", "")) == part_id:
			return part
	return {}


## Integer stack count (`hwPartQty`, :57).
static func part_qty(part: Dictionary) -> int:
	return maxi(1, int(roundf(float(part.get("qty", 1)))))


## A beam part on a sandwich side axis — moving one standoff mirrors the other.
static func is_sandwich_beam_part(part: Dictionary) -> bool:
	if str(part.get("type", "")) != "beam":
		return false
	var axis := str(part.get("axis", ""))
	return axis == "up" or axis == "down" or axis == "left" or axis == "right"


## Mirror pairs, preferring the plural form (`hwGetAssemblyMirrorPairs`, :145).
static func mirror_pairs(asm: Dictionary) -> Array:
	var out: Array = []
	var pairs = asm.get("mirrorPairs")
	if pairs is Array:
		for pair in pairs:
			if pair is Dictionary and pair.has("from") and pair.has("to"):
				out.append(pair)
		if not out.is_empty():
			return out
	var single = asm.get("mirror")
	if single is Dictionary and single.has("from") and single.has("to"):
		out.append(single)
	return out


## Stable content key over the assembly graph — used to cache derived results
## (spacing, BOM) without recomputing on every fold tick.
static func hash_key(ha: Dictionary) -> String:
	return str(JSON.stringify(ha).hash())


# ---------------------------------------------------------------------------
# Structure sync (`hwSyncBeamPartFromState` / `hwSyncHBeamPartFromState` :1382)
# ---------------------------------------------------------------------------

## Re-cut every assembly's beam parts from the DESIGN's real members.
##
## This is what makes the hardware preview show a joint in context rather than
## in the abstract: the timber either side of the stack is the actual V-beam or
## H-beam of the structure being edited — its width, thickness, hole spacing
## and bolt diameter — so a bolt that is too short to reach through is
## immediately visible.
##
## A part opts in through `params.syncStructure`: `true` follows the vertical
## members, `"hBeam"` follows the horizontal ring, `false` leaves it alone.
## Mutates in place, as the web app does, so the sync round-trips into a saved
## config rather than being re-derived differently on every load.
static func sync_beams_from_structure(ha: Dictionary, p: LinkageParams) -> void:
	var asms = ha.get("assemblies")
	if not (asms is Dictionary):
		return
	for key in (asms as Dictionary):
		var asm = (asms as Dictionary)[key]
		if not (asm is Dictionary):
			continue
		for part in (asm as Dictionary).get("parts", []):
			if not (part is Dictionary):
				continue
			var d := part as Dictionary
			if str(d.get("type", "")) != "beam" or not (d.get("params") is Dictionary):
				continue
			var pr: Dictionary = d["params"]
			var mode = pr.get("syncStructure", true)
			if mode is String and str(mode) == "hBeam":
				_sync_h_beam(pr, p)
			elif mode is bool and not bool(mode):
				continue
			elif not (mode is String):
				_sync_v_beam(pr, p)


## Vertical members: the design's FULL member, exactly as the web app syncs it
## (`hwSyncBeamPartFromState`) — a near-end-aligned beam anchored on its bolt
## hole with the rest of the timber running off through the joint. It reads as
## overwhelming only when the beam is drawn opaque; the timber material ghosts
## it instead.
static func _sync_v_beam(pr: Dictionary, p: LinkageParams) -> void:
	# The V-beam lies flat across the stack: what the structure calls its
	# THICKNESS is the beam's width in plan, and vice versa.
	pr["width"] = p.v_beam_outer_t if p.v_beam_outer_t > 0.0 else p.v_beam_t
	pr["thickness"] = p.v_beam_outer_w if p.v_beam_outer_w > 0.0 else p.v_beam_w
	pr["length"] = p.v_length_ft * 12.0
	pr["holeOffset"] = p.vert_end_offset
	pr["holeDiameter"] = 8.0 / 25.4


## The web's own H-beam preview rule (`hwSyncHBeamPartFromState`): the ring
## member is shown as a SHORT SEGMENT centred on the pivot. H-beams only —
## V-beams sync full length, also per the web.
static func preview_beam_length(full_length_in: float) -> float:
	return clampf(full_length_in * 0.2, 8.0, 24.0)


static func _sync_h_beam(pr: Dictionary, p: LinkageParams) -> void:
	var seg_len := preview_beam_length(p.h_length_ft * 12.0)
	pr["width"] = p.h_beam_w
	pr["thickness"] = p.h_beam_t
	pr["length"] = seg_len
	pr["holeOffset"] = seg_len / 2.0
	pr["holeDiameter"] = p.bolt_diameter
