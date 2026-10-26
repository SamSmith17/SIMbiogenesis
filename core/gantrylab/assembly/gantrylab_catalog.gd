class_name GantryLabCatalog
extends RefCounted

## The standard parts a V-slot machine is built from, each with the FEATURES
## it fastens by — the slots of an extrusion's faces, a bracket's M5 holes,
## a NEMA motor's 31 mm hole square and 5 mm shaft, a gantry plate's wheel
## run and hole grid, a pulley's bore. GantryLabMates mates a part's feature
## to a compatible feature on another part; nothing is placed by a bare
## offset any more.
##
## A part is `ref` + `params`. Everything is in the part's LOCAL frame
## (metres); the frames match GantryLabDetail's emitters where a part is
## drawn by one (motor face at the origin with the shaft up +Y, a pulley's
## hub bottom at the origin, a bracket's inside corner at the origin…).
##
## A feature: {id, kind, cls, xf (Transform3D: origin on the contact face,
## +Y = the face's OUTWARD normal, +X = the slide / pattern reference), …}
##   kind  "face"  a slotted extrusion face: `lines` (feature-z of each slot),
##                 `len` (x extent), `width`, `depth` (slot centre below the
##                 face on the side faces — where V-wheels run)
##         "grid"  a plate's hole grid: `pitch`, `rect` (x/z extent)
##         "holes" a fixed pattern (`holes`, feature x/z) — a child's bolt
##                 pattern or a target's tapped / through pattern
##         "axis"  a shaft or bolt axis along +Y: `len`, slide along y
##         "bore"  a child's bore that seats on an axis
##         "end"   a beam end (`holes` = the cell centres)
##         "run"   a gantry plate's wheel side (`across` it can straddle)
##   `t`  material thickness at the holes (bolt length), `standoff` = the
##   child may sit off the face on spacers, `ext` = the child's footprint in
##   feature x/z (slide limits).
##
## Sources: OpenBuilds V-slot drawings (20 mm pitch, 6.2 mm slot opening, the
## slot centre 10 mm in from each edge, M5 drop-in T-nuts), OpenBuilds solid
## V-wheel (Ø23.9 × 10.23 mm, two 625 bearings, 5 mm bore) and 6 mm
## eccentric spacer, NEMA ICS 16 (size 17: 31.0 mm hole square, M3, Ø22 mm
## pilot; size 23: 47.14 mm, Ø5 through holes, Ø38.1 mm pilot), HIWIN MGN
## catalogue (MGN12: rail 12 × 8, M3 at 25 mm pitch, block holes 20 × 20),
## GT2 (2 mm pitch: pitch Ø = teeth × 2 / π).
##
## The joining plates, cube / 3-way / inside corner connectors, the flat
## NEMA 17 / 23 motor plates, the 8 mm Acme anti-backlash nut block, the mini
## V gantry and the 5 × 6 mm flexible coupler are measured off the player's
## own reference model ("additional 3d printer parts", 2026-10-26): outlines
## and hole positions to the 0.2 mm the top view resolves, everything else
## simplified to blocks.

const SLOT := 0.0062
const CELL := 0.02
const SLOT_DEPTH_SIDE := 0.01   # a side face's slot centre, from the face it is beside
const WHEEL_R := 0.012
const WHEEL_W := 0.0102
const WHEEL_IN := 0.0025        # how far the wheel's rim sinks into the slot
const ECC_SPACER := 0.006
const GRID := 0.01
const SPRING_H := 0.02
const MINI_WHEEL_R := 0.0076   # mini V-wheel Ø15.2 × 8.8 (the reference model)
const MINI_WHEEL_W := 0.0088
const HOLE_R := 0.0026         # an M5 clearance hole, drawn

const PROFILE_REFS := {"2020": "vslot_2020", "2040": "vslot_2040", "2060": "vslot_2060", "4040": "vslot_4040"}

## ref → {label, cat (palette), family (swap group), kg, usd, params}
const PARTS := {
	"vslot_2020": {"label": "V-slot 2020", "cat": "frame", "family": "vslot", "profile": "2020", "params": {"len": 0.3}},
	"vslot_2040": {"label": "V-slot 2040", "cat": "frame", "family": "vslot", "profile": "2040", "params": {"len": 0.3}},
	"vslot_2060": {"label": "V-slot 2060", "cat": "frame", "family": "vslot", "profile": "2060", "params": {"len": 0.3}},
	"vslot_4040": {"label": "V-slot 4040", "cat": "frame", "family": "vslot", "profile": "4040", "params": {"len": 0.3}},
	"corner_bracket": {"label": "Cast corner bracket", "cat": "bracket", "family": "corner", "kg": 0.02, "usd": 1.6, "params": {}},
	"nema17_mount": {"label": "NEMA 17 L mount", "cat": "bracket", "family": "motor_mount", "kg": 0.07, "usd": 4.0,
		"params": {"a": 0.046, "b": 0.052, "w": 0.046, "t": 0.003, "pat": 0.031, "cls": "nema17"}},
	"nema23_mount": {"label": "NEMA 23 L mount", "cat": "bracket", "family": "motor_mount", "kg": 0.16, "usd": 9.0,
		"params": {"a": 0.06, "b": 0.07, "w": 0.06, "t": 0.005, "pat": 0.04714, "cls": "nema23"}},
	"nema17_plate": {"label": "NEMA 17 standoff plate", "cat": "bracket", "family": "motor_mount", "kg": 0.05, "usd": 5.0,
		"params": {"t": 0.004, "reach": 0.045, "pat": 0.031, "cls": "nema17", "half": 0.026}},
	"gantry_plate": {"label": "V-slot gantry plate", "cat": "motion", "family": "gantry_plate", "kg": 0.15, "usd": 18.0,
		"params": {"w": 0.088, "d": 0.088, "t": 0.006, "off": 0.0, "wheels": 4, "gap": 0.0011, "wheelbase": 0.06, "tool": false,
			"across": [0.02, 0.04, 0.06, 0.08], "wheel_r": WHEEL_R, "wheel_w": WHEEL_W}},
	"mini_v_plate": {"label": "Mini V gantry plate", "cat": "motion", "family": "mini_plate", "kg": 0.04, "usd": 12.0,
		"params": {"w": 0.05, "d": 0.05, "t": 0.0064, "off": 0.0, "wheels": 4, "gap": 0.0011, "wheelbase": 0.03, "tool": false,
			"across": [0.02], "wheel_r": MINI_WHEEL_R, "wheel_w": MINI_WHEEL_W}},
	"joining_plate_t": {"label": "T joining plate", "cat": "bracket", "family": "joining_plate", "kg": 0.03, "usd": 2.0, "params": {"t": 0.0039}},
	"joining_plate_90": {"label": "90° joining plate", "cat": "bracket", "family": "joining_plate", "kg": 0.03, "usd": 2.0, "params": {"t": 0.0039}},
	"cube_corner": {"label": "Cube corner connector", "cat": "bracket", "family": "cube_corner", "kg": 0.02, "usd": 2.5, "params": {}},
	"corner_3way": {"label": "3-way corner connector", "cat": "bracket", "family": "corner_3way", "kg": 0.03, "usd": 2.0, "params": {}},
	"inside_corner": {"label": "Inside hidden corner bracket", "cat": "bracket", "family": "inside_corner", "kg": 0.01, "usd": 1.0, "params": {}},
	"nema17_flat": {"label": "NEMA 17 flat motor plate", "cat": "bracket", "family": "flat_motor", "kg": 0.03, "usd": 4.0,
		"params": {"t": 0.0031, "cls": "nema17"}},
	"nema23_flat": {"label": "NEMA 23 flat motor plate", "cat": "bracket", "family": "flat_motor", "kg": 0.05, "usd": 7.0,
		"params": {"t": 0.0031, "cls": "nema23"}},
	"nut_block_8": {"label": "8 mm Acme anti-backlash nut block", "cat": "drive", "family": "nut_block", "kg": 0.02, "usd": 6.0, "params": {}},
	"nut_tab": {"label": "Lead-screw nut block", "cat": "bracket", "family": "nut_tab", "kg": 0.03, "usd": 4.0,
		"params": {"t": 0.005, "reach": 0.02}},
	"bed_plate": {"label": "Y carriage plate", "cat": "bed", "family": "bed_plate", "kg": 0.4, "usd": 22.0,
		"params": {"w": 0.24, "d": 0.24, "t": 0.006, "mount_x": 0.1, "bed": Vector2(0.23, 0.23)}},
	"belt_clamp": {"label": "Belt clamp", "cat": "drive", "family": "belt_clamp", "kg": 0.01, "usd": 1.0,
		"params": {"h": 0.02, "w": 0.012, "d": 0.012, "grip": Vector2.ZERO}},
	"nema17_pancake": {"label": "NEMA 17 pancake", "cat": "drive", "family": "nema17", "motor": true, "params": {"shaft": 0.02}},
	"nema17": {"label": "NEMA 17 (40 mm)", "cat": "drive", "family": "nema17", "motor": true, "params": {"shaft": 0.024}},
	"nema17_hi": {"label": "NEMA 17 (48 mm)", "cat": "drive", "family": "nema17", "motor": true, "params": {"shaft": 0.024}},
	"nema17_09": {"label": "NEMA 17 0.9°", "cat": "drive", "family": "nema17", "motor": true, "params": {"shaft": 0.024}},
	"nema23": {"label": "NEMA 23 (76 mm)", "cat": "drive", "family": "nema23", "motor": true, "params": {"shaft": 0.021}},
	"nema23_hi": {"label": "NEMA 23 (112 mm)", "cat": "drive", "family": "nema23", "motor": true, "params": {"shaft": 0.021}},
	"gt2_pulley": {"label": "GT2 pulley", "cat": "drive", "family": "pulley", "kg": 0.01, "usd": 3.5,
		"params": {"teeth": 20, "bore": 0.005, "belt_w": 0.006}},
	"gt2_idler": {"label": "GT2 idler", "cat": "drive", "family": "idler", "kg": 0.01, "usd": 2.5,
		"params": {"teeth": 20, "belt_w": 0.006}},
	"coupler": {"label": "Shaft coupler", "cat": "drive", "family": "coupler", "kg": 0.02, "usd": 3.0, "params": {"len": 0.025, "bore": 0.005, "bore2": 0.008}},
	"coupler_5_6": {"label": "Flexible coupler 5 × 6 mm", "cat": "drive", "family": "coupler", "kg": 0.01, "usd": 2.0, "params": {"len": 0.025, "bore": 0.005, "bore2": 0.006}},
	"tr8_screw": {"label": "Tr8 lead screw", "cat": "drive", "family": "screw", "params": {"len": 0.3, "lead": 0.008, "d": 0.008}},
	"tr8_nut": {"label": "Tr8 anti-backlash nut", "cat": "drive", "family": "nut", "kg": 0.02, "usd": 5.0, "params": {}},
	"endstop": {"label": "Microswitch endstop", "cat": "electronics", "family": "endstop", "kg": 0.01, "usd": 1.5, "params": {}},
	"foot": {"label": "Rubber foot", "cat": "frame", "family": "foot", "kg": 0.01, "usd": 0.6, "params": {"h": 0.011}},
	"tool": {"label": "Tool", "cat": "tool", "family": "tool", "params": {"id": "hotend_04"}},
	"bed": {"label": "Bed", "cat": "bed", "family": "bed", "params": {"kind": "heated_pcb", "size": Vector2(0.23, 0.23)}},
}

## The palette: what the player can drop in, by tab.
const PALETTE := [
	{"cat": "frame", "label": "Extrusion", "refs": ["vslot_2020", "vslot_2040", "vslot_2060", "vslot_4040"]},
	{"cat": "bracket", "label": "Brackets & plates", "refs": ["corner_bracket", "inside_corner", "cube_corner", "corner_3way", "joining_plate_t", "joining_plate_90",
		"nema17_mount", "nema23_mount", "nema17_plate", "nema17_flat", "nema23_flat", "nut_tab"]},
	{"cat": "motion", "label": "Motion", "refs": ["gantry_plate", "mini_v_plate"]},
	{"cat": "drive", "label": "Drive", "refs": ["nema17", "nema17_hi", "nema17_pancake", "nema23", "gt2_pulley", "gt2_idler", "coupler", "coupler_5_6", "nut_block_8", "belt_clamp"]},
	{"cat": "electronics", "label": "Other", "refs": ["endstop", "foot"]},
]

## Fasteners and generated parts (drawn and counted; never in the palette).
## Stock bolt lengths (mm), ISO 4762 / ISO 7380 common stock.
const STOCK_LEN := [4, 5, 6, 8, 10, 12, 14, 16, 18, 20, 25, 30, 35, 40, 45, 50, 55, 60, 70, 80, 90, 100]

const FASTENER_PRICES := {"bolt_m3": 0.06, "bolt_m5": 0.12, "tnut_m5": 0.25, "tnut_m3": 0.2, "nut_m5": 0.05, "nut_m3": 0.03,
	"washer_m5": 0.02, "spacer": 0.4, "ecc_spacer": 1.2, "wheel": 3.5, "grub": 0.05, "spring": 0.3, "knob": 0.5}

static var _cache := {}


static func has(ref: String) -> bool:
	return PARTS.has(ref)


static func info(ref: String) -> Dictionary:
	return PARTS.get(ref, {"label": ref, "cat": "", "family": ref, "params": {}})


static func label_of(ref: String, params: Dictionary = {}) -> String:
	var d := info(ref)
	match ref:
		"gt2_pulley", "gt2_idler":
			return "%s %dT" % [str(d["label"]), int(params.get("teeth", 20))]
		"tool":
			return str(GantryLabParts.tool(str(params.get("id", "hotend_04")))["label"])
		"bed":
			return str(GantryLabParts.bed(str(params.get("kind", "heated_pcb")))["label"])
	if bool(d.get("motor", false)):
		return str(GantryLabParts.motor(ref)["label"])
	if d.has("profile"):
		return "%s, %.0f mm" % [str(d["label"]), float(params.get("len", 0.3)) * 1000.0]
	return str(d["label"])


## The params with the part's defaults filled in.
static func params_of(ref: String, params: Dictionary) -> Dictionary:
	var out: Dictionary = (info(ref).get("params", {}) as Dictionary).duplicate(true)
	for k in params:
		out[k] = params[k]
	return out


## Parts the player can swap this one for (same family).
static func family_refs(ref: String) -> Array:
	var fam := str(info(ref).get("family", ref))
	var out: Array = []
	for r in PARTS:
		if str((PARTS[r] as Dictionary).get("family", r)) == fam:
			out.append(r)
	if fam == "nema17" or fam == "nema23":
		out = []
		for r in PARTS:
			if bool((PARTS[r] as Dictionary).get("motor", false)) and str((PARTS[r] as Dictionary)["family"]) == fam:
				out.append(r)
	return out


static func mass_kg(ref: String, params: Dictionary) -> float:
	var d := info(ref)
	if d.has("profile"):
		return float(params.get("len", 0.3)) * float(GantryLabParts.profile(str(d["profile"]))["kg_m"])
	if bool(d.get("motor", false)):
		return float(GantryLabParts.motor(ref)["kg"])
	match ref:
		"tr8_screw":
			return float(params.get("len", 0.3)) * 0.32
		"tool":
			return float(GantryLabParts.tool(str(params.get("id", "hotend_04")))["kg"])
		"bed":
			var sz: Vector2 = params.get("size", Vector2(0.23, 0.23))
			return float(GantryLabParts.bed(str(params.get("kind", "heated_pcb")))["kg_m2"]) * sz.x * sz.y
		"bed_plate":
			return float(params["w"]) * float(params["d"]) * float(params["t"]) * GantryLabParts.ALU_DENSITY
		"gantry_plate", "mini_v_plate":
			return float(params["w"]) * float(params["d"]) * float(params["t"]) * GantryLabParts.ALU_DENSITY
	return float(d.get("kg", 0.0))


static func price_usd(ref: String, params: Dictionary) -> float:
	var d := info(ref)
	if d.has("profile"):
		return float(params.get("len", 0.3)) * float(GantryLabParts.profile(str(d["profile"]))["usd_m"])
	if bool(d.get("motor", false)):
		return float(GantryLabParts.motor(ref)["usd"])
	match ref:
		"tr8_screw":
			return float(params.get("len", 0.3)) * 9.0 + 3.0
		"tool":
			return float(GantryLabParts.tool(str(params.get("id", "hotend_04")))["usd"])
		"bed":
			var sz: Vector2 = params.get("size", Vector2(0.23, 0.23))
			return float(GantryLabParts.bed(str(params.get("kind", "heated_pcb")))["usd_m2"]) * sz.x * sz.y
	return float(d.get("usd", 0.0))


## A feature frame: origin, outward normal (+Y), slide / reference (+X).
static func ff(origin: Vector3, normal: Vector3, ref: Vector3) -> Transform3D:
	var y := normal.normalized()
	var x := (ref - y * ref.dot(y)).normalized()
	return Transform3D(Basis(x, y, x.cross(y)), origin)


static func gt2_r(teeth: int) -> float:
	return float(teeth) * 0.002 / TAU


static func motor_frame(ref: String) -> float:
	return float(GantryLabParts.motor(ref)["frame_mm"]) * 0.001


static func nema_pattern(cls: String) -> float:
	return 0.031 if cls == "nema17" else 0.04714


static func nema_cls(ref: String) -> String:
	return "nema23" if motor_frame(ref) > 0.05 else "nema17"


static func shaft_d(ref: String) -> float:
	return 0.00635 if motor_frame(ref) > 0.05 else 0.005


## d → the class an axis / bore of that diameter carries.
static func d_cls(d: float) -> String:
	if d < 0.0055:
		return "d5"
	if d < 0.007:
		return "d635"
	return "d8"


# ---------------------------------------------------------------------------
# Features
# ---------------------------------------------------------------------------

static func features(ref: String, params: Dictionary) -> Array:
	var p := params_of(ref, params)
	var key := "%s|%s" % [ref, var_to_str(p)]
	if _cache.has(key):
		return _cache[key]
	var out := _features(ref, p)
	if _cache.size() > 4000:
		_cache.clear()
	_cache[key] = out
	return out


static func feature(ref: String, params: Dictionary, id: String) -> Dictionary:
	for f in features(ref, params):
		if str((f as Dictionary)["id"]) == id:
			return f
	return {}


static func _f(id: String, kind: String, cls: String, xf: Transform3D, extra: Dictionary = {}) -> Dictionary:
	var d := {"id": id, "kind": kind, "cls": cls, "xf": xf}
	for k in extra:
		d[k] = extra[k]
	return d


static func _cells(n_mm: float) -> PackedFloat32Array:
	var n := maxi(1, int(round(n_mm / CELL)))
	var out := PackedFloat32Array()
	for i in n:
		out.append(-n_mm * 0.5 + CELL * (float(i) + 0.5))
	return out


static func profile_wh(ref: String) -> Vector2:
	var pr := GantryLabParts.profile(str(info(ref).get("profile", "2020")))
	return Vector2(float(pr["w_mm"]), float(pr["h_mm"])) * 0.001


static func _features(ref: String, p: Dictionary) -> Array:
	var out: Array = []
	var d := info(ref)
	if d.has("profile"):
		# Local: X along the length 0..L, Y across the h side, Z across the w side.
		var wh := profile_wh(ref)
		var w := wh.x
		var h := wh.y
		var L := float(p["len"])
		var ys := _cells(h)
		var zs := _cells(w)
		# Faces ±Y: slot lines are the z cells; feature z = X × n.
		for sg in [1.0, -1.0]:
			var n := Vector3(0, sg, 0)
			var xf := ff(Vector3(0, sg * h * 0.5, 0), n, Vector3.RIGHT)
			var lines := PackedFloat32Array()
			for z in zs:
				lines.append(Vector3(0, 0, z).dot(xf.basis.z))
			out.append(_f("%sy" % ("+" if sg > 0 else "-"), "face", "s20", xf, {"lines": lines, "len": L, "width": w, "depth": SLOT_DEPTH_SIDE}))
		for sg in [1.0, -1.0]:
			var n := Vector3(0, 0, sg)
			var xf := ff(Vector3(0, 0, sg * w * 0.5), n, Vector3.RIGHT)
			var lines := PackedFloat32Array()
			for y in ys:
				lines.append(Vector3(0, y, 0).dot(xf.basis.z))
			out.append(_f("%sz" % ("+" if sg > 0 else "-"), "face", "s20", xf, {"lines": lines, "len": L, "width": h, "depth": SLOT_DEPTH_SIDE}))
		# Ends: the cell centres in the end feature's frame.
		for e in 2:
			var n := Vector3(-1, 0, 0) if e == 0 else Vector3(1, 0, 0)
			var xf := ff(Vector3(0 if e == 0 else L, 0, 0), n, Vector3.UP)
			var holes := PackedVector2Array()
			for y in ys:
				for z in zs:
					var q := Vector3(0, y, z)
					holes.append(Vector2(q.dot(xf.basis.x), q.dot(xf.basis.z)))
			out.append(_f("e%d" % e, "end", "end20", xf, {"holes": holes, "ext": Rect2(-h * 0.5, -w * 0.5, h, w), "t": 0.0}))
		return out
	match ref:
		"corner_bracket":
			var size := 0.02
			var t := 0.0035
			out.append(_f("a", "holes", "m5", ff(Vector3(size * 0.65, 0, 0), Vector3.DOWN, Vector3.RIGHT),
				{"holes": PackedVector2Array([Vector2.ZERO]), "t": t, "ext": Rect2(-size * 0.65, -size * 0.5, size, size), "leg": true}))
			out.append(_f("b", "holes", "m5", ff(Vector3(0, size * 0.65, 0), Vector3.LEFT, Vector3.UP),
				{"holes": PackedVector2Array([Vector2.ZERO]), "t": t, "ext": Rect2(-size * 0.65, -size * 0.5, size, size), "leg": true}))
		"inside_corner":
			# Hidden inside the slots: leg a in beam A's slot under beam B,
			# leg b up inside beam B; each held by a set screw. The body lies
			# ALONG each feature's normal (inside the beam), not behind it.
			var ext := Rect2(-0.013, -0.0052, 0.026, 0.0104)
			out.append(_f("a", "holes", "hid", ff(Vector3(-0.013, 0, 0), Vector3.DOWN, Vector3.RIGHT),
				{"holes": PackedVector2Array([Vector2.ZERO]), "t": 0.0, "ext": ext, "leg": true}))
			out.append(_f("b", "holes", "hid", ff(Vector3(0, 0.013, 0), Vector3.LEFT, Vector3.UP),
				{"holes": PackedVector2Array([Vector2.ZERO]), "t": 0.0, "ext": ext, "leg": true}))
		"cube_corner":
			# A 20 mm cube: an M5 from inside through each of three faces into
			# a beam's tapped end, and the other three faces take beam ends.
			var ext := Rect2(-0.01, -0.01, 0.02, 0.02)
			var one := PackedVector2Array([Vector2.ZERO])
			out.append(_f("a", "holes", "tap5", ff(Vector3(-0.01, 0, 0), Vector3.LEFT, Vector3.UP), {"holes": one, "t": 0.012, "ext": ext, "leg": true}))
			out.append(_f("b", "holes", "tap5", ff(Vector3(0, -0.01, 0), Vector3.DOWN, Vector3.RIGHT), {"holes": one, "t": 0.012, "ext": ext, "leg": true}))
			out.append(_f("c", "holes", "tap5", ff(Vector3(0, 0, -0.01), Vector3.FORWARD, Vector3.UP), {"holes": one, "t": 0.012, "ext": ext, "leg": true}))
			for fd in [["pa", Vector3.RIGHT, Vector3.UP], ["pb", Vector3.UP, Vector3.RIGHT], ["pc", Vector3.BACK, Vector3.UP]]:
				var nv: Vector3 = fd[1]
				out.append(_f(str(fd[0]), "grid", "m5grid", ff(nv * 0.01, nv, fd[2]), {"pitch": GRID, "rect": Rect2(-0.0005, -0.0005, 0.001, 0.001), "t": 0.008}))
		"corner_3way":
			# A cube with two spigots that push into two beam ends (a set screw
			# each) and a top and bottom face a third beam end bolts to.
			var ext := Rect2(-0.01, -0.01, 0.02, 0.02)
			var one := PackedVector2Array([Vector2.ZERO])
			out.append(_f("a", "holes", "tap5", ff(Vector3(-0.01, 0, 0), Vector3.LEFT, Vector3.UP), {"holes": one, "t": 0.0, "grub": true, "ext": ext, "leg": true}))
			out.append(_f("b", "holes", "tap5", ff(Vector3(0, 0, -0.01), Vector3.FORWARD, Vector3.UP), {"holes": one, "t": 0.0, "grub": true, "ext": ext, "leg": true}))
			out.append(_f("top", "grid", "m5grid", ff(Vector3(0, 0.011, 0), Vector3.UP, Vector3.RIGHT), {"pitch": GRID, "rect": Rect2(-0.0005, -0.0005, 0.001, 0.001), "t": 0.008}))
			out.append(_f("bottom", "grid", "m5grid", ff(Vector3(0, -0.01, 0), Vector3.DOWN, Vector3.RIGHT), {"pitch": GRID, "rect": Rect2(-0.0005, -0.0005, 0.001, 0.001), "t": 0.008}))
		"joining_plate_t", "joining_plate_90":
			var t := float(p["t"])
			var outline := plate_outline(ref)
			var la: Transform3D
			var lb: Transform3D
			var ha: Array = []
			var hb: Array = []
			if ref == "joining_plate_t":
				# The bar along one beam (3 holes), the stem down the beam that
				# butts into it (2 holes).
				la = ff(Vector3(0, 0, 0.02), Vector3.DOWN, Vector3.RIGHT)
				lb = ff(Vector3(0, 0, -0.01), Vector3.DOWN, Vector3.BACK)
				ha = [Vector2(-0.02, 0.02), Vector2(0, 0.02), Vector2(0.02, 0.02)]
				hb = [Vector2(0, -0.02), Vector2(0, 0)]
			else:
				# A gusset: the column with the corner hole (3), the row (2).
				la = ff(Vector3(-0.02, 0, 0), Vector3.DOWN, Vector3.BACK)
				lb = ff(Vector3(0.01, 0, 0.02), Vector3.DOWN, Vector3.RIGHT)
				ha = [Vector2(-0.02, -0.02), Vector2(-0.02, 0), Vector2(-0.02, 0.02)]
				hb = [Vector2(0, 0.02), Vector2(0.02, 0.02)]
			out.append(_f("a", "holes", "m5", la, {"holes": _fh(la, ha), "t": t, "ext": _fext(la, outline), "leg": true}))
			out.append(_f("b", "holes", "m5", lb, {"holes": _fh(lb, hb), "t": t, "ext": _fext(lb, outline), "leg": true}))
		"nema17_flat", "nema23_flat":
			# A flat plate along a beam, the motor hanging past it: the mount
			# holes along the slot (`mount`), or one each side on a 2040
			# (`wide`); the motor on either face.
			var t := float(p["t"])
			var g := flat_plate_geom(ref)
			var outline := rect_xz(float(g["w"]), float(g["d"]))
			var lm := ff(Vector3(0, 0, float(g["mz"])), Vector3.DOWN, Vector3.BACK)
			out.append(_f("mount", "holes", "m5", lm, {"holes": _fh(lm, g["mount"]), "t": t, "standoff": true, "ext": _fext(lm, outline)}))
			out.append(_f("wide", "holes", "m5", lm, {"holes": _fh(lm, g["wide"]), "t": t, "standoff": true, "ext": _fext(lm, outline)}))
			var hp := nema_pattern(str(p["cls"])) * 0.5
			out.append(_f("motor", "holes", str(p["cls"]), ff(Vector3(0, t, float(g["pz"])), Vector3.UP, Vector3.RIGHT), {"holes": _square(hp), "t": t, "target": true}))
			out.append(_f("motor_b", "holes", str(p["cls"]), ff(Vector3(0, 0, float(g["pz"])), Vector3.DOWN, Vector3.RIGHT), {"holes": _square(hp), "t": t, "target": true}))
		"nut_block_8":
			# Bolted flat to a gantry plate by two M5 20 mm apart; the lead
			# screw runs through it PARALLEL to the plate, 6.3 mm off the
			# bolt line's other side, 6 mm up (the reference model).
			var lb := ff(Vector3(-0.0065, 0, 0), Vector3.DOWN, Vector3.BACK)
			out.append(_f("base", "holes", "m5", lb, {"holes": _fh(lb, [Vector2(-0.0065, -0.01), Vector2(-0.0065, 0.01)]), "t": 0.012, "standoff": true,
				"ext": _fext(lb, rect_xz(0.033, 0.034))}))
			out.append(_f("lead", "axis", "d8", ff(Vector3(0.0063, 0.006, -0.017), Vector3.BACK, Vector3.UP), {"len": 0.034}))
		"nema17_mount", "nema23_mount":
			var a := float(p["a"])
			var b := float(p["b"])
			var w := float(p["w"])
			var t := float(p["t"])
			var hp := float(p["pat"]) * 0.5
			var hz := w * 0.33
			# Base leg on a face: the bolt pair along the slot (bracket Z).
			out.append(_f("base", "holes", "m5", ff(Vector3(a * 0.5, -t, 0), Vector3.DOWN, Vector3.BACK),
				{"holes": PackedVector2Array([Vector2(-hz, 0), Vector2(hz, 0)]), "t": t, "ext": Rect2(-w * 0.5, -a * 0.5, w, a)}))
			# The motor face: on leg B's inside (+X), the pilot at b / 2.
			out.append(_f("motor", "holes", str(p["cls"]), ff(Vector3(0, b * 0.5, 0), Vector3.RIGHT, Vector3.UP),
				{"holes": _square(hp), "t": t, "target": true}))
			# Leg B's other side: a hole grid round the motor (the other
			# belt's idler sits here on a CoreXY).
			out.append(_f("leg", "grid", "m5grid", ff(Vector3(-t, b * 0.5, 0), Vector3.LEFT, Vector3.UP),
				{"pitch": GRID, "rect": Rect2(-b * 0.5 + 0.004, -w * 0.5 + 0.002, b - 0.008, w - 0.004), "t": t}))
		"nema17_plate":
			var t := float(p["t"])
			var reach := float(p["reach"])
			var hp := float(p["pat"]) * 0.5
			# Flat plate in XZ: the motor on top (+Y) at the origin, the bolt
			# pair to the face at x = -reach underneath, on standoffs.
			var hf := float(p["half"])
			# Two bolts along the slot, the far one 20 mm from the motor's.
			out.append(_f("mount", "holes", "m5", ff(Vector3(-reach, 0, 0), Vector3.DOWN, Vector3.RIGHT),
				{"holes": PackedVector2Array([Vector2(0, 0.0), Vector2(-0.02, 0)]), "t": t, "standoff": true,
				"ext": Rect2(-0.03, -hf, reach + 0.03 + hf, hf * 2.0)}))
			out.append(_f("motor", "holes", str(p["cls"]), ff(Vector3(0, t, 0), Vector3.UP, Vector3.RIGHT),
				{"holes": _square(hp), "t": t, "target": true}))
		"gantry_plate", "mini_v_plate":
			var w := float(p["w"])
			var dd := float(p["d"])
			var t := float(p["t"])
			var off := float(p["off"])
			out.append(_f("run", "run", "run", ff(Vector3.ZERO, Vector3.DOWN, Vector3.RIGHT),
				{"across": p.get("across", [0.02, 0.04, 0.06, 0.08]), "gap": float(p["gap"]), "t": t, "wheelbase": float(p["wheelbase"]),
				"ext": Rect2(-w * 0.5, -off - dd * 0.5, w, dd)}))
			out.append(_f("top", "grid", "m5grid", ff(Vector3(0, t, off), Vector3.UP, Vector3.RIGHT),
				{"pitch": GRID, "rect": Rect2(-w * 0.5 + 0.006, -dd * 0.5 + 0.006, w - 0.012, dd - 0.012), "t": t}))
			out.append(_f("back", "grid", "m5grid", ff(Vector3(0, 0, off), Vector3.DOWN, Vector3.RIGHT),
				{"pitch": GRID, "rect": Rect2(-w * 0.5 + 0.006, -dd * 0.5 + 0.006, w - 0.012, dd - 0.012), "t": t}))
			if bool(p.get("tool", false)):
				out.append(_f("tool", "holes", "tool", ff(Vector3(0, t, 0), Vector3.UP, Vector3.RIGHT),
					{"holes": PackedVector2Array([Vector2(-0.01, 0), Vector2(0.01, 0)]), "t": t, "target": true}))
		"nut_tab":
			var t := float(p["t"])
			var reach := float(p["reach"])
			# A block: the back (z = 0 plane, normal -Z) bolts to a plate, the
			# tab (y in [-t, 0]) sticks out along +Z with the nut on top.
			out.append(_f("base", "holes", "m5", ff(Vector3(0, -0.01, 0), Vector3.BACK * -1.0, Vector3.RIGHT),
				{"holes": PackedVector2Array([Vector2(-0.01, 0), Vector2(0.01, 0)]), "t": t, "ext": Rect2(-0.02, -0.012, 0.04, 0.024)}))
			out.append(_f("nut", "holes", "tr8", ff(Vector3(0, 0, reach), Vector3.UP, Vector3.RIGHT),
				{"holes": _ring4(0.008), "t": t, "target": true}))
		"bed_plate":
			var w := float(p["w"])
			var dd := float(p["d"])
			var t := float(p["t"])
			var mx := float(p["mount_x"])
			out.append(_f("mount", "holes", "m5", ff(Vector3(-mx, 0, 0), Vector3.DOWN, Vector3.RIGHT),
				{"holes": PackedVector2Array([Vector2(0, -0.01), Vector2(0, 0.01)]), "t": t, "ext": Rect2(-w * 0.5 + mx, -dd * 0.5, w, dd)}))
			out.append(_f("mount_r", "holes", "m5", ff(Vector3(mx, 0, 0), Vector3.DOWN, Vector3.RIGHT),
				{"holes": PackedVector2Array([Vector2(0, -0.01), Vector2(0, 0.01)]), "t": t}))
			out.append(_f("under", "grid", "m5grid", ff(Vector3.ZERO, Vector3.DOWN, Vector3.RIGHT),
				{"pitch": GRID, "rect": Rect2(-w * 0.5 + 0.006, -dd * 0.5 + 0.006, w - 0.012, dd - 0.012), "t": t}))
			var bs: Vector2 = p["bed"]
			out.append(_f("springs", "holes", "springs", ff(Vector3(0, t + SPRING_H, 0), Vector3.UP, Vector3.RIGHT),
				{"holes": _rect4(bs.x * 0.5 - 0.012, bs.y * 0.5 - 0.012), "t": t, "target": true}))
		"belt_clamp":
			var h := float(p["h"])
			out.append(_f("mount", "holes", "m5", ff(Vector3.ZERO, Vector3.DOWN, Vector3.RIGHT),
				{"holes": PackedVector2Array([Vector2.ZERO]), "t": 0.004, "standoff": false, "ext": Rect2(-0.006, -0.006, 0.012, 0.012)}))
			var grip: Vector2 = p.get("grip", Vector2.ZERO)
			out.append(_f("belt", "point", "belt", Transform3D(Basis.IDENTITY, Vector3(grip.x, h - 0.003, grip.y))))
		"gt2_pulley":
			var bw := float(p["belt_w"])
			out.append(_f("bore", "bore", d_cls(float(p["bore"])), ff(Vector3.ZERO, Vector3.DOWN, Vector3.RIGHT), {"depth": 0.007}))
			out.append(_f("belt", "point", "belt", Transform3D(Basis.IDENTITY, Vector3(0, pulley_band_y(bw), 0)), {"r": gt2_r(int(p["teeth"]))}))
		"gt2_idler":
			var bw := float(p["belt_w"])
			out.append(_f("bore", "bore", "b5", ff(Vector3.ZERO, Vector3.DOWN, Vector3.RIGHT), {"depth": bw + 0.004}))
			out.append(_f("belt", "point", "belt", Transform3D(Basis.IDENTITY, Vector3(0, idler_band_y(bw), 0)), {"r": gt2_r(int(p["teeth"]))}))
		"coupler", "coupler_5_6":
			var L := float(p["len"])
			out.append(_f("bore", "bore", d_cls(float(p["bore"])), ff(Vector3.ZERO, Vector3.DOWN, Vector3.RIGHT), {"depth": L * 0.5}))
			out.append(_f("top", "axis", d_cls(float(p.get("bore2", 0.008))), ff(Vector3(0, L * 0.5, 0), Vector3.UP, Vector3.RIGHT), {"len": 0.0}))
		"tr8_screw":
			out.append(_f("bore", "bore", "d8", ff(Vector3.ZERO, Vector3.DOWN, Vector3.RIGHT), {"depth": 0.012}))
		"tr8_nut":
			out.append(_f("flange", "holes", "tr8", ff(Vector3.ZERO, Vector3.DOWN, Vector3.RIGHT), {"holes": _ring4(0.008), "t": 0.0035}))
		"endstop":
			out.append(_f("mount", "holes", "m5", ff(Vector3.ZERO, Vector3.DOWN, Vector3.RIGHT),
				{"holes": PackedVector2Array([Vector2.ZERO]), "t": 0.005, "ext": Rect2(-0.01, -0.0075, 0.02, 0.015)}))
		"foot":
			out.append(_f("mount", "holes", "m5", ff(Vector3.ZERO, Vector3.UP, Vector3.RIGHT),
				{"holes": PackedVector2Array([Vector2.ZERO]), "t": 0.0, "ext": Rect2(-0.013, -0.013, 0.026, 0.026)}))
		"tool":
			var mh := GantryLabFrame.tool_mount_h(str(p["id"]))
			out.append(_f("mount", "holes", "tool", ff(Vector3(0, mh, 0.0135), Vector3.BACK, Vector3.RIGHT),
				{"holes": PackedVector2Array([Vector2(-0.01, 0), Vector2(0.01, 0)]), "t": 0.0}))
		"bed":
			var bs: Vector2 = p["size"]
			var stack := float(GantryLabFrame.BED_STACK.get(str(p["kind"]), 0.01))
			out.append(_f("springs", "holes", "springs", ff(Vector3(0, -stack, 0), Vector3.DOWN, Vector3.RIGHT),
				{"holes": _rect4(bs.x * 0.5 - 0.012, bs.y * 0.5 - 0.012), "t": stack}))
	if bool(d.get("motor", false)):
		var f := motor_frame(ref)
		var cls := nema_cls(ref)
		out.append(_f("face", "holes", cls, ff(Vector3.ZERO, Vector3.UP, Vector3.RIGHT), {"holes": _square(nema_pattern(cls) * 0.5), "t": 0.0}))
		out.append(_f("shaft", "axis", d_cls(shaft_d(ref)), ff(Vector3(0, 0.002, 0), Vector3.UP, Vector3.RIGHT), {"len": float(p["shaft"]) - 0.002}))
		var _unused := f
	return out


static func _square(hp: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(-hp, -hp), Vector2(hp, -hp), Vector2(hp, hp), Vector2(-hp, hp)])


static func _rect4(hx: float, hz: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(-hx, -hz), Vector2(hx, -hz), Vector2(hx, hz), Vector2(-hx, hz)])


static func _ring4(r: float) -> PackedVector2Array:
	var k := r * 0.70710678
	return _square(k)


## Part-local (x, z) points on the y = feature-origin plane → feature (x, z).
static func _fh(xf: Transform3D, pts: Array) -> PackedVector2Array:
	var inv := xf.affine_inverse()
	var out := PackedVector2Array()
	for v in pts:
		var q: Vector2 = v
		var l := inv * Vector3(q.x, xf.origin.y, q.y)
		out.append(Vector2(l.x, l.z))
	return out


## A part-local outline's bounds in a feature's (x, z).
static func _fext(xf: Transform3D, outline: PackedVector2Array) -> Rect2:
	var pts := _fh(xf, Array(outline))
	var r := Rect2(pts[0], Vector2.ZERO)
	for q in pts:
		r = r.expand(q)
	return r


static func rect_xz(w: float, d: float) -> PackedVector2Array:
	return PackedVector2Array([Vector2(-w * 0.5, -d * 0.5), Vector2(w * 0.5, -d * 0.5), Vector2(w * 0.5, d * 0.5), Vector2(-w * 0.5, d * 0.5)])


## The joining plates' outlines (part-local x, z; 60 × 60 mm, holes on a
## 20 mm grid 10 mm in from the edges).
static func plate_outline(ref: String) -> PackedVector2Array:
	if ref == "joining_plate_t":
		return PackedVector2Array([Vector2(-0.01, -0.03), Vector2(0.01, -0.03), Vector2(0.03, 0.01), Vector2(0.03, 0.03), Vector2(-0.03, 0.03), Vector2(-0.03, 0.01)])
	return PackedVector2Array([Vector2(-0.03, -0.03), Vector2(-0.01, -0.03), Vector2(0.03, 0.01), Vector2(0.03, 0.03), Vector2(-0.03, 0.03)])


static func plate_holes(ref: String) -> PackedVector2Array:
	if ref == "joining_plate_t":
		return PackedVector2Array([Vector2(-0.02, 0.02), Vector2(0, 0.02), Vector2(0.02, 0.02), Vector2(0, -0.02), Vector2(0, 0)])
	return PackedVector2Array([Vector2(-0.02, -0.02), Vector2(-0.02, 0), Vector2(-0.02, 0.02), Vector2(0, 0.02), Vector2(0.02, 0.02)])


## The flat motor plates (part-local x, z): size, the motor pattern's centre
## `pz`, the mount holes along the slot and the 2040 pair, the slots drawn.
static func flat_plate_geom(ref: String) -> Dictionary:
	if ref == "nema23_flat":
		return {"w": 0.06, "d": 0.0965, "pz": -0.0188, "mz": 0.0296, "pilot": 0.01905,
			"mount": [Vector2(0, 0.0198), Vector2(0, 0.0394)], "wide": [Vector2(-0.01, 0.0296), Vector2(0.01, 0.0296)],
			"holes": [], "slots": [Vector2(-0.02, 0.0296), Vector2(-0.01, 0.0296), Vector2(0, 0.0296), Vector2(0.01, 0.0296), Vector2(0.02, 0.0296)], "slot_len": 0.0248}
	return {"w": 0.0395, "d": 0.082, "pz": -0.02, "mz": 0.0226, "pilot": 0.011,
		"mount": [Vector2(0, 0.0126), Vector2(0, 0.0326)], "wide": [Vector2(-0.01, 0.0126), Vector2(0.01, 0.0126), Vector2(-0.01, 0.0326), Vector2(0.01, 0.0326)],
		"holes": [Vector2(-0.01, 0.0126), Vector2(0, 0.0126), Vector2(0.01, 0.0126), Vector2(-0.01, 0.0326), Vector2(0, 0.0326), Vector2(0.01, 0.0326)], "slots": [], "slot_len": 0.0}


## Where a GT2 pulley's tooth band is centred, from its hub bottom (bore).
## The M5 grid holes inside a w × d rectangle, 10 mm pitch, drawn.
static func _grid_holes(w: float, d: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var nx := floori(w * 0.5 / GRID + 0.001)
	var nz := floori(d * 0.5 / GRID + 0.001)
	for ix in range(-nx, nx + 1):
		for iz in range(-nz, nz + 1):
			if (ix + iz) % 2 == 0:
				out.append(Vector2(ix * GRID, iz * GRID))
	return out


static func pulley_band_y(belt_w: float) -> float:
	return 0.007 + 0.001 + (belt_w + 0.002) * 0.5


static func idler_band_y(belt_w: float) -> float:
	return 0.001 + (belt_w + 0.002) * 0.5


# ---------------------------------------------------------------------------
# Solid volumes (clash boxes, local): [{c, s, b?}]
# ---------------------------------------------------------------------------

static func boxes(ref: String, params: Dictionary) -> Array:
	var p := params_of(ref, params)
	var d := info(ref)
	if d.has("profile"):
		var wh := profile_wh(ref)
		var L := float(p["len"])
		return [{"c": Vector3(L * 0.5, 0, 0), "s": Vector3(L, wh.y, wh.x)}]
	if bool(d.get("motor", false)):
		var f := motor_frame(ref)
		var ln := float(GantryLabParts.motor(ref)["len_mm"]) * 0.001
		var sd := shaft_d(ref)
		return [{"c": Vector3(0, -ln * 0.5, 0), "s": Vector3(f, ln, f)},
			{"c": Vector3(0, float(p["shaft"]) * 0.5, 0), "s": Vector3(sd, float(p["shaft"]), sd), "thin": true}]
	match ref:
		"corner_bracket":
			return [{"c": Vector3(0.01, 0.00175, 0), "s": Vector3(0.02, 0.0035, 0.02)}, {"c": Vector3(0.00175, 0.01, 0), "s": Vector3(0.0035, 0.02, 0.02)}]
		"nema17_mount", "nema23_mount":
			var a := float(p["a"])
			var b := float(p["b"])
			var w := float(p["w"])
			var t := float(p["t"])
			return [{"c": Vector3(a * 0.5, -t * 0.5, 0), "s": Vector3(a, t, w)}, {"c": Vector3(-t * 0.5, b * 0.5, 0), "s": Vector3(t, b, w)}]
		"nema17_plate":
			var t := float(p["t"])
			var reach := float(p["reach"])
			var hf := float(p["half"])
			return [{"c": Vector3((-reach - 0.03 + hf) * 0.5, t * 0.5, 0), "s": Vector3(reach + 0.03 + hf, t, hf * 2.0), "holed": true}]
		"gantry_plate", "mini_v_plate":
			return [{"c": Vector3(0, float(p["t"]) * 0.5, float(p["off"])), "s": Vector3(float(p["w"]), float(p["t"]), float(p["d"]))}]
		"inside_corner":
			return [{"c": Vector3(-0.013, -0.0025, 0), "s": Vector3(0.026, 0.005, 0.0104)}, {"c": Vector3(-0.0025, 0.013, 0), "s": Vector3(0.005, 0.026, 0.0104)}]
		"cube_corner":
			return [{"c": Vector3.ZERO, "s": Vector3(0.02, 0.02, 0.02)}]
		"corner_3way":
			return [{"c": Vector3(0, 0.0005, 0), "s": Vector3(0.02, 0.021, 0.02)},
				{"c": Vector3(-0.016, 0, 0), "s": Vector3(0.012, 0.0087, 0.0087)}, {"c": Vector3(0, 0, -0.016), "s": Vector3(0.0087, 0.0087, 0.012)}]
		"joining_plate_t":
			var t := float(p["t"])
			return [{"c": Vector3(0, t * 0.5, 0.02), "s": Vector3(0.06, t, 0.02)}, {"c": Vector3(0, t * 0.5, -0.01), "s": Vector3(0.02, t, 0.04)}]
		"joining_plate_90":
			var t := float(p["t"])
			return [{"c": Vector3(-0.02, t * 0.5, 0), "s": Vector3(0.02, t, 0.06)}, {"c": Vector3(0.01, t * 0.5, 0.02), "s": Vector3(0.04, t, 0.02)}]
		"nema17_flat", "nema23_flat":
			var g := flat_plate_geom(ref)
			return [{"c": Vector3(0, float(p["t"]) * 0.5, 0), "s": Vector3(float(g["w"]), float(p["t"]), float(g["d"])), "holed": true}]
		"nut_block_8":
			return [{"c": Vector3(0, 0.006, 0), "s": Vector3(0.033, 0.012, 0.034), "holed": true}]
		"nut_tab":
			var t := float(p["t"])
			var reach := float(p["reach"])
			return [{"c": Vector3(0, -0.01, t * 0.5), "s": Vector3(0.04, 0.02, t)}, {"c": Vector3(0, -t * 0.5, (reach + 0.012 + t) * 0.5), "s": Vector3(0.03, t, reach + 0.012 - t), "holed": true}]
		"bed_plate":
			return [{"c": Vector3(0, float(p["t"]) * 0.5, 0), "s": Vector3(float(p["w"]), float(p["t"]), float(p["d"]))}]
		"belt_clamp":
			var h := float(p["h"])
			return [{"c": Vector3(0, h * 0.5, 0), "s": Vector3(float(p["w"]), h, float(p["d"]))}]
		"gt2_pulley":
			var r := gt2_r(int(p["teeth"]))
			var bw := float(p["belt_w"])
			return [{"c": Vector3(0, 0.0035, 0), "s": Vector3(0.0124, 0.007, 0.0124)},
				{"c": Vector3(0, pulley_band_y(bw), 0), "s": Vector3((r + 0.0018) * 2.0, bw + 0.004, (r + 0.0018) * 2.0)}]
		"gt2_idler":
			var r := gt2_r(int(p["teeth"]))
			var bw := float(p["belt_w"])
			return [{"c": Vector3(0, idler_band_y(bw), 0), "s": Vector3((r + 0.0018) * 2.0, bw + 0.004, (r + 0.0018) * 2.0)}]
		"coupler", "coupler_5_6":
			return [{"c": Vector3(0, float(p["len"]) * 0.5, 0), "s": Vector3(0.019, float(p["len"]), 0.019)}]
		"tr8_screw":
			return [{"c": Vector3(0, float(p["len"]) * 0.5, 0), "s": Vector3(0.008, float(p["len"]), 0.008), "thin": true}]
		"tr8_nut":
			return [{"c": Vector3(0, 0.00175, 0), "s": Vector3(0.022, 0.0035, 0.022)}, {"c": Vector3(0, -0.006, 0), "s": Vector3(0.0102, 0.012, 0.0102)}]
		"endstop":
			return [{"c": Vector3(0, 0.004, 0), "s": Vector3(0.02, 0.008, 0.015)}]
		"foot":
			var fh := float(p["h"])
			return [{"c": Vector3(0, -fh * 0.5, 0), "s": Vector3(0.026, fh, 0.026)}]
		"tool":
			var mh := GantryLabFrame.tool_mount_h(str(p["id"]))
			return [{"c": Vector3(0, (mh + 0.02) * 0.5 + 0.004, 0), "s": Vector3(0.032, mh + 0.02, 0.026)}]
		"bed":
			var bs: Vector2 = p["size"]
			var stack := float(GantryLabFrame.BED_STACK.get(str(p["kind"]), 0.01))
			return [{"c": Vector3(0, -stack * 0.5, 0), "s": Vector3(bs.x, stack, bs.y)}]
	return []


# ---------------------------------------------------------------------------
# Drawing: the GantryLabDetail part dicts in the part's local frame
# (c, basis, kind…). A beam returns {"beam": true, a, b, profile, up}.
# ---------------------------------------------------------------------------

static func draw(ref: String, params: Dictionary) -> Array:
	var p := params_of(ref, params)
	var d := info(ref)
	if d.has("profile"):
		return [{"beam": true, "a": Vector3.ZERO, "b": Vector3(float(p["len"]), 0, 0), "profile": str(d["profile"]), "up": Vector3.UP}]
	if bool(d.get("motor", false)):
		var ms := GantryLabParts.motor(ref)
		var f := float(ms["frame_mm"]) * 0.001
		return [{"kind": "motor", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "frame": f, "len": float(ms["len_mm"]) * 0.001, "shaft": float(p["shaft"]), "bolts": false, "s": Vector3(f, f, f)}]
	match ref:
		"corner_bracket":
			return [{"kind": "corner_bracket", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "bolts": false, "s": Vector3(0.02, 0.02, 0.02)}]
		"nema17_mount", "nema23_mount":
			return [{"kind": "bracket_l", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "a": float(p["a"]), "b": float(p["b"]), "w": float(p["w"]), "t": float(p["t"]), "bolts": false, "s": Vector3(0.04, 0.04, 0.04)}]
		"nema17_plate":
			var t := float(p["t"])
			var reach := float(p["reach"])
			var hf := float(p["half"])
			var len := reach + 0.03 + hf
			return [{"kind": "plate", "c": Vector3((-reach - 0.03 + hf) * 0.5, t * 0.5, 0), "basis": Basis.IDENTITY, "s": Vector3(len, t, hf * 2.0), "mat": "black", "chamfer": 0.004}]
		"gantry_plate":
			return [{"kind": "plate", "c": Vector3(0, float(p["t"]) * 0.5, float(p["off"])), "basis": Basis.IDENTITY, "s": Vector3(float(p["w"]), float(p["t"]), float(p["d"])), "chamfer": 0.006}]
		"mini_v_plate":
			return [{"kind": "outline_plate", "c": Vector3(0, 0, float(p["off"])), "basis": Basis.IDENTITY, "outline": GantryLabDetail.rect_outline(float(p["w"]), float(p["d"]), 0.004),
				"t": float(p["t"]), "holes": _grid_holes(float(p["w"]) - 0.012, float(p["d"]) - 0.012), "hole_r": 0.0026, "s": Vector3(float(p["w"]), float(p["t"]), float(p["d"]))}]
		"inside_corner":
			return [{"kind": "box", "c": Vector3(-0.013, -0.0025, 0), "basis": Basis.IDENTITY, "s": Vector3(0.026, 0.005, 0.0104), "mat": "black"},
				{"kind": "box", "c": Vector3(-0.0025, 0.013, 0), "basis": Basis.IDENTITY, "s": Vector3(0.005, 0.026, 0.0104), "mat": "black"}]
		"cube_corner":
			return [{"kind": "outline_plate", "c": Vector3(0, -0.01, 0), "basis": Basis.IDENTITY, "outline": rect_xz(0.02, 0.02), "t": 0.02,
				"holes": PackedVector2Array([Vector2.ZERO]), "hole_r": HOLE_R, "mat": "plate", "s": Vector3(0.02, 0.02, 0.02),
				"bores": [[Vector3(-0.0102, 0.01, 0), Vector3(0.0102, 0.01, 0), HOLE_R], [Vector3(0, 0.01, -0.0102), Vector3(0, 0.01, 0.0102), HOLE_R]]}]
		"corner_3way":
			return [{"kind": "box", "c": Vector3(0, 0.0005, 0), "basis": Basis.IDENTITY, "s": Vector3(0.02, 0.021, 0.02), "mat": "black"},
				{"kind": "box", "c": Vector3(-0.016, 0, 0), "basis": Basis.IDENTITY, "s": Vector3(0.012, 0.0087, 0.0087), "mat": "black"},
				{"kind": "box", "c": Vector3(0, 0, -0.016), "basis": Basis.IDENTITY, "s": Vector3(0.0087, 0.0087, 0.012), "mat": "black"}]
		"joining_plate_t", "joining_plate_90":
			var t := float(p["t"])
			return [{"kind": "outline_plate", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "outline": plate_outline(ref), "t": t,
				"holes": plate_holes(ref), "hole_r": HOLE_R, "s": Vector3(0.06, t, 0.06)}]
		"nema17_flat", "nema23_flat":
			var g := flat_plate_geom(ref)
			var t := float(p["t"])
			var hp := nema_pattern(str(p["cls"])) * 0.5
			var hs: PackedVector2Array = PackedVector2Array(g["holes"])
			for q in _square(hp):
				hs.append(q + Vector2(0, float(g["pz"])))
			var slots: Array = []
			for sv in g["slots"]:
				slots.append([sv, Vector2(0.0052, float(g["slot_len"]))])
			return [{"kind": "outline_plate", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "outline": GantryLabDetail.rect_outline(float(g["w"]), float(g["d"]), 0.003), "t": t,
				"holes": hs, "hole_r": 0.0017 if str(p["cls"]) == "nema17" else HOLE_R, "pilot": Vector3(0, float(g["pz"]), float(g["pilot"])), "slots": slots,
				"s": Vector3(float(g["w"]), t, float(g["d"]))}]
		"nut_block_8":
			return [{"kind": "outline_plate", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "outline": rect_xz(0.033, 0.034), "t": 0.012, "mat": "black",
				"holes": PackedVector2Array([Vector2(-0.0065, -0.01), Vector2(-0.0065, 0.01)]), "hole_r": HOLE_R,
				"slots": [[Vector2(0.0063, 0.0025), Vector2(0.0015, 0.029)]], "bores": [[Vector3(0.0063, 0.006, -0.0172), Vector3(0.0063, 0.006, 0.0172), 0.004]],
				"s": Vector3(0.033, 0.012, 0.034)}]
		"nut_tab":
			var t := float(p["t"])
			var reach := float(p["reach"])
			return [{"kind": "box", "c": Vector3(0, -0.01, t * 0.5), "basis": Basis.IDENTITY, "s": Vector3(0.04, 0.02, t), "mat": "plate"},
				{"kind": "box", "c": Vector3(0, -t * 0.5, (reach + 0.012 + t) * 0.5), "basis": Basis.IDENTITY, "s": Vector3(0.03, t, reach + 0.012 - t), "mat": "plate"}]
		"bed_plate":
			return [{"kind": "plate", "c": Vector3(0, float(p["t"]) * 0.5, 0), "basis": Basis.IDENTITY, "s": Vector3(float(p["w"]), float(p["t"]), float(p["d"])), "chamfer": 0.01}]
		"belt_clamp":
			var h := float(p["h"])
			return [{"kind": "box", "c": Vector3(0, h * 0.5, 0), "basis": Basis.IDENTITY, "s": Vector3(float(p["w"]), h, float(p["d"])), "mat": "black"}]
		"gt2_pulley":
			return [{"kind": "pulley", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "teeth": int(p["teeth"]), "belt_w": float(p["belt_w"]), "y0": 0.007, "s": Vector3(0.016, 0.02, 0.016)}]
		"gt2_idler":
			return [{"kind": "idler", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "r": gt2_r(int(p["teeth"])), "belt_w": float(p["belt_w"]), "y0": 0.0, "no_bolt": true, "s": Vector3(0.016, 0.014, 0.016)}]
		"coupler", "coupler_5_6":
			return [{"kind": "coupler", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "len": float(p["len"]), "s": Vector3(0.02, 0.025, 0.02)}]
		"tr8_screw":
			return [{"kind": "screw", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "len": float(p["len"]), "d_mm": float(p["d"]) * 1000.0, "lead_mm": float(p["lead"]) * 1000.0,
				"starts": maxi(1, int(round(float(p["lead"]) * 1000.0 / 2.0))), "s": Vector3(0.01, float(p["len"]), 0.01)}]
		"tr8_nut":
			return [{"kind": "nut_tr8", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "no_bolts": true, "s": Vector3(0.022, 0.015, 0.022)}]
		"endstop":
			return [{"kind": "endstop", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "s": Vector3(0.02, 0.012, 0.015)}]
		"foot":
			return [{"kind": "foot", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "h": float(p["h"]), "s": Vector3(0.026, float(p["h"]), 0.026)}]
		"tool":
			var tool_id := str(p["id"])
			var kind := str(GantryLabFrame.TOOL_KINDS.get(tool_id, "tool"))
			var mh := GantryLabFrame.tool_mount_h(tool_id)
			return [{"kind": kind, "c": Vector3.ZERO, "basis": Basis.IDENTITY, "tool": tool_id, "volcano": tool_id == "hotend_08", "s": Vector3(0.05, mh + 0.03, 0.05)}]
		"bed":
			return [{"kind": "bed", "c": Vector3.ZERO, "basis": Basis.IDENTITY, "size": p["size"], "bed_kind": str(p["kind"]), "s": Vector3((p["size"] as Vector2).x, 0.012, (p["size"] as Vector2).y)}]
	return []
