class_name LinkageHwLayout
extends RefCounted
## Axis-stack maths for hardware assemblies — where every washer, bushing and
## nut sits along the bolt through a joint (all static, no rendering).
##
## Port of the geometry half of `js/linkage/hardware-detail.js`:
## `hwGetPartAxialLength` (:527), `hwComputeAxisLayout` (:375),
## `hwGetAssemblySandwichGap` (:448), `hwGetSandwichCenterSpan` (:303),
## `hwGetSandwichCenterOffset` (:333), `hwSnapPartAssembledPos` (:677).
##
## Everything is inches along the stack axis; `LinkageHwAssemblyBuilder` turns
## these scalars into transforms and `LinkageHardwareSpacing` reads the sandwich
## gap to drive the solver's stack spacing.
##
## [b]Stack anatomy.[/b] A joint has a CENTRE slot straddling the bolt pivot
## (the washers that set how far apart the two H-beams sit) and SIDE axes that
## grow outward from that slot's outer faces. Positive axes (up / right) grow
## in +dir; negative axes (down / left) grow in −dir, which is why their origin
## is mirrored rather than shared. Chain axes — the V-beam stacks on
## outerVBeam / innerVBeam — instead hang off the bracket wall.

## `front`/`back` are listed because the layout has always understood them —
## AXIS_DIRS, AXIS_CROSS, HORIZONTAL_AXES and `bracket_stack_origin` all carry
## entries — but they were missing from THIS list, which is what the builder and
## the part list iterate. A part authored on either (imported from a web-app
## config, say) was silently invisible and uneditable. An empty axis costs a
## no-op layout, so listing them is free.
const AXES: PackedStringArray = ["up", "down", "right", "left", "center",
	"front", "back"]

const AXIS_DIRS := {
	"right": Vector3.RIGHT,
	"left": Vector3.LEFT,
	"up": Vector3.UP,
	"down": Vector3.DOWN,
	"front": Vector3.BACK,
	"back": Vector3.FORWARD,
}

## Perpendicular used for a part's `crossOffset` (hole alignment).
const AXIS_CROSS := {
	"right": Vector3.UP,
	"left": Vector3.UP,
	"up": Vector3.RIGHT,
	"down": Vector3.RIGHT,
	"front": Vector3.UP,
	"back": Vector3.UP,
}

## Axes that run horizontally, so their chain hangs off a bracket SIDE wall and
## has to be lifted to that wall's bolt hole.
const HORIZONTAL_AXES: PackedStringArray = ["right", "left", "front", "back"]
const SANDWICH_SIDE_AXES: PackedStringArray = ["up", "down", "left", "right"]
const SANDWICH_PAIRS := [
	{"positive": "up", "negative": "down"},
	{"positive": "right", "negative": "left"},
]

## Pull-to-flush distance (inches) when sliding a part near another face.
const SNAP_THRESHOLD := 0.18
## Breathing room between consecutive parts on a chain axis.
const CHAIN_CLEARANCE := 0.04


# ---------------------------------------------------------------------------
# Part extents
# ---------------------------------------------------------------------------

## How much of the stack one part occupies (`hwGetPartAxialLength` :527).
static func part_axial_length(part: Dictionary) -> float:
	var pr: Dictionary = part.get("params", {})
	match str(part.get("type", "")):
		"bolt":
			var head := float(pr.get("headHeight", 0.0))
			if head <= 0.0:
				head = float(pr.get("diameter", 0.25)) * 0.6
			return maxf(0.1, _or(pr, "length", 1.0)) + head
		"bushing":
			var blen := maxf(0.05, _or(pr, "length", 0.5))
			var flange_od := float(pr.get("flangeOd", 0.0))
			var flange_t := float(pr.get("flangeThickness", 0.0))
			if flange_od > 0.0 and flange_t > 0.0 and flange_od > float(pr.get("od", 0.0)):
				blen += flange_t
			return blen
		"washer", "lockWasher":
			return maxf(0.01, _or(pr, "thickness", 0.0625))
		"nut":
			var nlen := maxf(0.01, _or(pr, "height", _or(pr, "length", 0.4375)))
			if str(pr.get("style", "")) == "rivet":
				var fo := float(pr.get("flangeOd", 0.0))
				var ft := float(pr.get("flangeThickness", 0.0))
				if fo > 0.0 and ft > 0.0:
					nlen += ft
			return nlen
		"beam":
			return maxf(0.25, _or(pr, "thickness", 1.5))
		"bracket":
			return maxf(0.2, _or(pr, "height", 3.77))
	return 0.1


## Dictionary lookup that treats 0 / missing / non-numeric as "use the default"
## — the JS `p.length || 1` idiom, which falls through on 0 as well as null.
static func _or(d: Dictionary, key: String, fallback: float) -> float:
	var v = d.get(key)
	if (v is float or v is int) and float(v) != 0.0:
		return float(v)
	return fallback


static func part_qty(part: Dictionary) -> int:
	return LinkageHardware.part_qty(part)


## Total stack length of a part including its qty copies.
static func qty_assembled_span(part: Dictionary) -> float:
	return part_axial_length(part) * part_qty(part)


## Explode spacing between qty copies of the same part (`hwGetQtyExplodeGap`).
static func qty_explode_gap(part: Dictionary) -> float:
	var v = part.get("qtyExplodeGap")
	if (v is float or v is int) and not is_nan(float(v)):
		return maxf(0.0, float(v))
	var type := str(part.get("type", ""))
	if type == "washer" or type == "lockWasher":
		return maxf(0.02, _or(part.get("params", {}), "thickness", 0.0625))
	return 0.04


# ---------------------------------------------------------------------------
# Sandwich geometry
# ---------------------------------------------------------------------------

## Which world axis the centre slot renders along (`hwGetCenterRenderAxis` :583).
static func center_render_axis(asm: Dictionary) -> String:
	var plane := str(asm.get("sandwichPlane", ""))
	if plane == "horizontal":
		return "right"
	if plane == "vertical":
		return "up"
	return "right" if str(asm.get("id", "")) == "vCenter" else "up"


static func is_center_axis(axis_key: String) -> bool:
	return axis_key == "center"


## Side axes belong to the sandwich except the V-beam chains on the two
## V-beam assemblies, which hang off the bracket instead (`hwUsesSandwichAxis`).
static func uses_sandwich_axis(asm: Dictionary, axis_key: String) -> bool:
	if is_center_axis(axis_key):
		return true
	if not SANDWICH_SIDE_AXES.has(axis_key):
		return false
	var id := str(asm.get("id", ""))
	if (id == "outerVBeam" or id == "innerVBeam") \
			and (axis_key == "right" or axis_key == "left"):
		return false
	return true


## Combined thickness of the centre slot — beams and brackets excluded, since
## they bound the slot rather than filling it (`hwGetSandwichCenterSpan` :303).
static func sandwich_center_span(asm: Dictionary) -> float:
	var span := 0.0
	for part in asm.get("parts", []):
		if not (part is Dictionary):
			continue
		var d := part as Dictionary
		if str(d.get("axis", "")) != "center":
			continue
		var type := str(d.get("type", ""))
		if type == "bracket" or type == "beam":
			continue
		span += part_axial_length(d) * part_qty(d)
	return span


static func sandwich_center_half_span(asm: Dictionary) -> float:
	return sandwich_center_span(asm) / 2.0


## Where the bolt pivot sits relative to the assembly origin.
##
## outerVBeam / innerVBeam are placed so the BRACKET's side hole lands on the
## world pivot, and that hole is `bracket_hole_y` above the bracket centre —
## which is the group origin. Every other assembly is anchored at the pivot
## directly, so its offset is zero. (`hwGetSandwichCenterOffset` :333.)
static func sandwich_center_offset(asm: Dictionary) -> float:
	if center_render_axis(asm) != "up":
		return 0.0
	var bracket := LinkageHardware.bracket_part(asm)
	if bracket.is_empty():
		return 0.0
	return bracket_hole_y(bracket)


## Side-wall hole height above the bracket's centre. `cutoffHeight` only clips
## the mesh visually, so the hole never moves with it (`hwGetBracketHoleY` :814).
static func bracket_hole_y(bracket_part: Dictionary) -> float:
	var pr: Dictionary = bracket_part.get("params", {})
	if pr.is_empty():
		return 0.0
	var h := _or(pr, "height", 3.77)
	var from_top := 1.1875
	var v = pr.get("sideHoleFromTop")
	if v is float or v is int:
		from_top = float(v)
	return (h / 2.0) - from_top


## Where a chain axis starts: just clear of the bracket's outer surface
## (`hwGetBracketStackOrigin` :831).
static func bracket_stack_origin(bracket_part: Dictionary, axis_key: String) -> float:
	var pr: Dictionary = bracket_part.get("params", {})
	if pr.is_empty():
		return 0.6
	if axis_key == "right" or axis_key == "left":
		return _or(pr, "width", 2.15) / 2.0 + 0.02
	if axis_key == "front" or axis_key == "back":
		return _or(pr, "depth", 1.57) / 2.0 + 0.02
	if axis_key == "up" or axis_key == "down":
		return _or(pr, "height", 3.77) / 2.0 + 0.02
	return 0.6


## First position on an axis (`hwGetAxisStackOrigin` :343).
static func axis_stack_origin(asm: Dictionary, axis_key: String,
		bracket_part: Dictionary) -> float:
	if is_center_axis(axis_key):
		return sandwich_center_offset(asm) - sandwich_center_half_span(asm)
	if uses_sandwich_axis(asm, axis_key):
		var pivot := sandwich_center_offset(asm)
		var half := sandwich_center_half_span(asm)
		# Negative axes render in −dir, so their local start must be mirrored:
		# world_local = −base_start, and we want the inner face at
		# pivot − half, hence base_start = half − pivot.
		for pair in SANDWICH_PAIRS:
			if str(pair["negative"]) == axis_key:
				return half - pivot
		return pivot + half
	return bracket_stack_origin(bracket_part, axis_key)


## Distance between the two facing beams = centre stack thickness plus any
## standoff the player has dialled into either side beam
## (`hwGetAssemblySandwichGap` :448). This is what drives the solver's stack
## gap when hardware full detail is on.
static func assembly_sandwich_gap(asm: Dictionary) -> float:
	if asm.is_empty():
		return 0.0
	var total := sandwich_center_span(asm)
	var plane := str(asm.get("sandwichPlane", ""))
	if plane == "":
		plane = "horizontal" if str(asm.get("id", "")) == "vCenter" else "vertical"
	var sides: PackedStringArray = ["right", "left"] if plane == "horizontal" else ["up", "down"]
	for axis_key in sides:
		total += sandwich_side_beam_offset(asm, axis_key)
	return total


static func sandwich_side_beam_offset(asm: Dictionary, axis_key: String) -> float:
	for part in asm.get("parts", []):
		if not (part is Dictionary):
			continue
		var d := part as Dictionary
		if str(d.get("axis", "")) == axis_key and LinkageHardware.is_sandwich_beam_part(d):
			return maxf(0.0, float(d.get("posAssembled", 0.0)))
	return 0.0


# ---------------------------------------------------------------------------
# Axis layout (`hwComputeAxisLayout` :375)
# ---------------------------------------------------------------------------

## Sequential layout for one axis. Every item occupies `[base_start,
## base_start + len]`.
##
## Centre axis: parts are flush-stacked symmetrically about the bolt pivot,
## so their combined thickness IS the sandwich gap. Side/chain axes: parts grow
## outward from the origin with a hair of clearance between them. `posAssembled`
## is a per-part fine-tune added on top.
static func compute_axis_layout(asm: Dictionary, axis_key: String) -> Dictionary:
	var bracket := LinkageHardware.bracket_part(asm)
	var parts := LinkageHardware.parts_on_axis(asm, axis_key)
	var items: Array = []
	var rank := 0

	if is_center_axis(axis_key):
		var span := sandwich_center_span(asm)
		var start_pos := sandwich_center_offset(asm) - span / 2.0
		var pos := start_pos
		for part in parts:
			var d := part as Dictionary
			var plen := part_axial_length(d)
			var qty := part_qty(d)
			var pos_asm := float(d.get("posAssembled", 0.0))
			for copy_index in qty:
				items.append({
					"part": d,
					"base_start": pos + pos_asm + plen * copy_index,
					"part_base": pos,
					"len": plen,
					"rank": rank,
					"copy_index": copy_index,
				})
				rank += 1
			pos += plen * qty
		return {"items": items, "origin": start_pos, "span": span, "center": true}

	var origin := axis_stack_origin(asm, axis_key, bracket)
	var cursor := origin
	for part in parts:
		var d := part as Dictionary
		var plen := part_axial_length(d)
		var qty := part_qty(d)
		var part_base := cursor
		var pos_asm := float(d.get("posAssembled", 0.0))
		for copy_index in qty:
			items.append({
				"part": d,
				"base_start": part_base + pos_asm + plen * copy_index,
				"part_base": part_base,
				"len": plen,
				"rank": rank,
				"copy_index": copy_index,
			})
			rank += 1
		cursor = part_base + qty_assembled_span(d) + CHAIN_CLEARANCE
	return {
		"items": items,
		"origin": origin,
		"span": absf(cursor - origin),
		"center": false,
	}


## Layout context for one part: where its stack starts, its rank in the
## explode order, and the render direction (`hwGetPartStackContext` :554).
## Returns {} when the part is not on any axis layout (e.g. a bracket).
##
## `copy_index` selects WHICH body of a qty>1 stack. Each copy has its own rank
## in the explode order, so hardcoding 0 here (as this used to) meant clicking
## the third washer of a stack and dragging it moved the first one's distance.
static func part_stack_context(part: Dictionary, asm: Dictionary,
		explode: float, copy_index: int = 0) -> Dictionary:
	var axis_key := str(part.get("axis", "right"))
	var render_axis := center_render_axis(asm) if is_center_axis(axis_key) else axis_key
	var layout := compute_axis_layout(asm, axis_key)
	var part_id := str(part.get("id", ""))
	for item in layout["items"]:
		var it := item as Dictionary
		if str((it["part"] as Dictionary).get("id", "")) != part_id:
			continue
		if int(it.get("copy_index", 0)) != copy_index:
			continue
		return {
			"stack_base": float(it.get("part_base", it["base_start"])),
			"stack_origin": float(layout["origin"]),
			"rank": int(it["rank"]),
			"copy_index": copy_index,
			"axis_key": axis_key,
			"render_axis": render_axis,
			"dir": AXIS_DIRS.get(render_axis, Vector3.RIGHT),
			"cross": AXIS_CROSS.get(render_axis, Vector3.UP),
			"gap": float(asm.get("explodeGap", 1.4)),
			"pos_exploded": float(part.get("posExploded", 0.0)),
			"explode": explode,
			"center": bool(layout["center"]),
		}
	return {}


## Exploded start position for one part (`hwExplodedAxisPos` :3142).
static func exploded_axis_pos(part: Dictionary, stack_origin: float,
		rank: int, gap: float) -> float:
	var step := maxf(gap * 2.5, 2.2)
	return stack_origin + float(part.get("posExploded", 0.0)) + step * rank


## Blended assembled↔exploded position of a part's axial CENTRE — the quantity
## `LinkageHwAssemblyBuilder.part_transform` actually places the mesh at
## (`hwAxisPosFromPart` :595, which ends in `hwPartAxisPlacementPos`).
##
## Returning the stack START instead — as this used to — is a difference of half
## a part length that nothing notices until something tries to INVERT it, at
## which point every dragged part jumps by half its own length on mouse-down.
## `copy_index` defaults to the one the context was built for — pass it only to
## ask about a different body of the same stack, and never with a rank that
## belongs to another copy.
static func axis_pos_from_part(part: Dictionary, ctx: Dictionary,
		copy_index: int = -1) -> float:
	if ctx.is_empty():
		return 0.0
	var ci := int(ctx.get("copy_index", 0)) if copy_index < 0 else copy_index
	var plen := part_axial_length(part)
	var assembled := float(ctx["stack_base"]) + float(part.get("posAssembled", 0.0)) \
		+ plen * ci
	var exploded := exploded_axis_pos(part, float(ctx["stack_origin"]),
		int(ctx["rank"]), float(ctx["gap"])) + qty_explode_gap(part) * ci
	var t := clampf(float(ctx["explode"]), 0.0, 1.0)
	return lerpf(assembled, exploded, t) + plen / 2.0


## Exact inverse of `axis_pos_from_part`: the `posAssembled` that would place
## this part's centre at `axis_pos` (`hwSetPartAxisPosFromWorld` :600).
##
## Inverting the explode lerp is what lets a part be dragged while the stack is
## fanned out — the pointer moves the EXPLODED body, but what gets stored is the
## assembled offset that produces it. `maxf(1 - explode, 0.001)` guards the
## fully-exploded case, where the assembled position no longer affects the
## rendered one at all and the drag is necessarily a no-op.
##
## Two deliberate divergences from the web, both in the direction of self-
## consistency: the `qty_explode_gap * copy_index` term is included (the web's
## forward path adds it, `hwPartCopyExplodedPos` :3171, and its inverse does
## not, which misplaces copy 1+ of a stack dragged mid-explode), and callers
## derive the cross-axis lift from the RENDER axis rather than the part's stored
## axis (the web tests `ctx.axisKey`, wrong for a centre-axis part whose render
## axis is `right`).
static func pos_assembled_for_axis_pos(part: Dictionary, ctx: Dictionary,
		axis_pos: float) -> float:
	if ctx.is_empty():
		return 0.0
	var plen := part_axial_length(part)
	var ci := int(ctx.get("copy_index", 0))
	var exploded_centre := exploded_axis_pos(part, float(ctx["stack_origin"]),
		int(ctx["rank"]), float(ctx["gap"])) \
		+ qty_explode_gap(part) * ci + plen / 2.0
	var e := clampf(float(ctx["explode"]), 0.0, 1.0)
	var assembled_centre := (axis_pos - e * exploded_centre) / maxf(1.0 - e, 0.001)
	return assembled_centre - plen / 2.0 - float(ctx["stack_base"]) - plen * ci


## Whether a drag or a nudge should snap flush right now (`hwIsSnapActive` :620).
## Snapping is meaningless while the stack is fanned out — the neighbours a part
## would sit flush against are metres away — so it switches off with explode.
static func snap_active(ha: Dictionary) -> bool:
	return bool(ha.get("snap", true)) and float(ha.get("explode", 0.0)) < 0.05


# ---------------------------------------------------------------------------
# Snapping (`hwCollectAxisSnapPlanes` :646 / `hwSnapStartToPlanes` :663)
# ---------------------------------------------------------------------------

## Axis positions a dragged part's faces may sit flush against: the stack
## origin, every other part's two faces, and — for centre-slot parts and
## sandwich beams — the bolt-pivot plane itself.
static func collect_axis_snap_planes(asm: Dictionary, axis_key: String,
		skip_part_id: String = "", skip_copy_index: int = 0,
		editing_part: Dictionary = {}) -> Array[float]:
	var planes: Array[float] = []
	var layout := compute_axis_layout(asm, axis_key)
	planes.append(float(layout["origin"]))
	if is_center_axis(axis_key) \
			or (not editing_part.is_empty()
				and LinkageHardware.is_sandwich_beam_part(editing_part)):
		planes.append(sandwich_center_offset(asm))
	for item in layout["items"]:
		var it := item as Dictionary
		if skip_part_id != "" \
				and str((it["part"] as Dictionary).get("id", "")) == skip_part_id \
				and int(it.get("copy_index", 0)) == skip_copy_index:
			continue
		var start := float(it["base_start"])
		planes.append(start)
		planes.append(start + float(it["len"]))
	return planes


## Soft snap: when either face lands within `threshold` of a plane, sit flush
## on it. Whichever face is closest wins.
static func snap_start_to_planes(start: float, end: float,
		planes: Array[float], threshold: float = SNAP_THRESHOLD) -> float:
	if planes.is_empty() or threshold <= 0.0:
		return start
	var length := end - start
	var best_start := start
	var best_dist := threshold
	for plane in planes:
		var ds := absf(start - plane)
		if ds < best_dist:
			best_dist = ds
			best_start = plane
		var de := absf(end - plane)
		if de < best_dist:
			best_dist = de
			best_start = plane - length
	return best_start


## Snap a proposed `posAssembled` for `part` (`hwSnapPartAssembledPos` :677).
static func snap_part_assembled_pos(part: Dictionary, asm: Dictionary,
		ctx: Dictionary, pos_asm: float, snap_active: bool = true) -> float:
	if not snap_active or part.is_empty() or asm.is_empty() or ctx.is_empty():
		return pos_asm
	var plen := part_axial_length(part)
	var copy_index := int(ctx.get("copy_index", 0))
	var start := float(ctx["stack_base"]) + pos_asm + plen * copy_index
	var planes := collect_axis_snap_planes(asm, str(ctx["axis_key"]),
		str(part.get("id", "")), copy_index, part)
	var snapped := snap_start_to_planes(start, start + plen, planes)
	return snappedf(snapped - float(ctx["stack_base"]) - plen * copy_index, 0.0001)


## Moving one sandwich beam standoff mirrors the opposite beam — the two faces
## of a sandwich are one dimension (`hwApplySandwichBeamCoupling` :434).
## Returns the id of the beam that was moved along with it, or "" — the caller
## needs it to reposition that node too.
static func apply_sandwich_beam_coupling(asm: Dictionary, part: Dictionary,
		new_pos_asm: float) -> String:
	if asm.is_empty() or part.is_empty() or not LinkageHardware.is_sandwich_beam_part(part):
		return ""
	var opposite := sandwich_opposite_axis(str(part.get("axis", "")))
	if opposite == "":
		return ""
	for other in asm.get("parts", []):
		if not (other is Dictionary):
			continue
		var d := other as Dictionary
		if str(d.get("axis", "")) != opposite:
			continue
		if not LinkageHardware.is_sandwich_beam_part(d):
			continue
		if str(d.get("id", "")) == str(part.get("id", "")):
			continue
		d["posAssembled"] = new_pos_asm
		return str(d.get("id", ""))
	return ""


static func sandwich_opposite_axis(axis_key: String) -> String:
	for pair in SANDWICH_PAIRS:
		if str(pair["positive"]) == axis_key:
			return str(pair["negative"])
		if str(pair["negative"]) == axis_key:
			return str(pair["positive"])
	return ""


## A mirrored copy of `part` for the `to` side of a mirror pair. The mirror is
## a RENDER of the source, so it keeps the source's id — editing either side
## writes the same part.
static func mirror_part(part: Dictionary, pair: Dictionary) -> Dictionary:
	var out := part.duplicate(true)
	if str(part.get("axis", "")) == str(pair.get("from", "")):
		out["axis"] = str(pair.get("to", ""))
	out["mirrored_from"] = str(part.get("id", ""))
	return out
