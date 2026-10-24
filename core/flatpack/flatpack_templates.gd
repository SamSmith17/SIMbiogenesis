class_name FlatpackTemplates
extends RefCounted

## The furniture generators. Each turns a resolved FlatpackSpec into parts
## (planar slabs: a straight-edged base polygon, fillet radii and a frame in
## inches) and the joints between them; FlatpackJoints then derives every
## slot, mortise and wedge from that assembly.
##
## Furniture frame (inches): X = length (left to right), Y = up, Z = depth
## with the FRONT at +Z (a sitter faces +Z). The floor is y = 0. Parts lie
## with their mid-plane on the frame's xy plane; `thickness` is the actual
## (measured) sheet thickness, so stacked parts sit exactly on each other.
##
## The sofa reproduces the sample (Playa Tech.glb): three long rails and
## three cross rails in an egg-crate, an arm at each end, a deck slotted into
## the arms, and a back that stands upright or reclined on two braces, or lies
## flat behind the deck as a daybed — every pose's slots are cut, so one set
## of parts does all three.

const X := Vector3(1, 0, 0)
const Y := Vector3(0, 1, 0)
const Z := Vector3(0, 0, 1)

## Tab past the far face of the part it passes through (non-wedged tabs).
const TAB_PROUD := 0.25
## Stretcher run-out past a leg for a wedge: the hole plus room beyond it.
const WEDGE_RUNOUT := 2.75


static func generate(spec: Dictionary) -> Dictionary:
	var s := FlatpackSpec.resolve(spec)
	match str(s["type"]):
		"sofa":
			return _sofa(s)
		"bench", "stool", "table", "coffee_table":
			return _table_like(s)
		"chair", "lounger":
			return _chair(s)
	return _sofa(s)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

static func frame_of(origin: Vector3, xdir: Vector3, ydir: Vector3) -> Transform3D:
	var xa := xdir.normalized()
	var ya := ydir.normalized()
	return Transform3D(Basis(xa, ya, xa.cross(ya)), origin)


static func _part(id: String, name: String, group: String, base: PackedVector2Array,
		radii: Array, frame: Transform3D, role: String, t: float, extra: Dictionary = {}) -> Dictionary:
	var cr := PackedFloat64Array()
	for i in base.size():
		cr.append(float(radii[i]) if i < radii.size() else 0.0)
	var p := {"id": id, "name": name, "group": group, "match": str(extra.get("match", "")),
		"role": role, "base": base, "corner_r": cr, "frame": frame, "thickness": t,
		"grain": str(extra.get("grain", "any")), "notches": [], "holes": []}
	for k in extra:
		if not p.has(k) or k == "notches":
			p[k] = extra[k]
	return p


static func rect(w: float, h: float, x0: float = 0.0, y0: float = 0.0) -> PackedVector2Array:
	return PackedVector2Array([Vector2(x0, y0), Vector2(x0 + w, y0), Vector2(x0 + w, y0 + h),
		Vector2(x0, y0 + h)])


static func _joint(id: String, a: String, b: String, kind: String, extra: Dictionary = {}) -> Dictionary:
	var j := {"id": id, "a": a, "b": b, "kind": kind, "open": Y, "ratio": 0.5, "wedge": false, "pose": ""}
	j.merge(extra, true)
	return j


## A foot arch in edge `edge`, centred `at` along it.
static func _arch(edge: int, at: float, width: float, depth: float) -> Dictionary:
	return FlatpackProfile.make_notch(edge, at, width, depth, Vector2.ZERO,
		{"inner_r": minf(depth * 0.95, width * 0.45), "entry_r": 0.5, "arch": true})


## A leg panel w wide with its body up to `hb` and tabs of `tab_h` rising from
## the top edge at the centres in `tabs` (an Array of x). CCW.
static func leg_poly(w: float, hb: float, tabs: Array, tab_w: float, tab_h: float,
		post: Dictionary = {}) -> Dictionary:
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(w, 0), Vector2(w, hb)])
	var radii: Array = [0.375, 0.375, 0.5]
	var sorted_tabs := tabs.duplicate()
	sorted_tabs.sort()
	sorted_tabs.reverse()
	for c in sorted_tabs:
		pts.append(Vector2(float(c) + tab_w * 0.5, hb))
		pts.append(Vector2(float(c) + tab_w * 0.5, hb + tab_h))
		pts.append(Vector2(float(c) - tab_w * 0.5, hb + tab_h))
		pts.append(Vector2(float(c) - tab_w * 0.5, hb))
		radii.append_array([0.0, 0.0, 0.0, 0.0])
	if not post.is_empty():
		var pw := float(post["w"])
		var ph := float(post["h"])
		pts.append(Vector2(pw, hb))
		pts.append(Vector2(pw, ph))
		pts.append(Vector2(0, ph))
		radii.append_array([0.0, 0.75, 0.75])
	else:
		pts.append(Vector2(0, hb))
		radii.append(0.5)
	return {"base": pts, "radii": radii}


## A panel `w` across (x) and `d` deep (y) with tabs of length `e` on both
## x ends at the y centres in `tabs`. CCW.
static func tabbed_panel(w: float, d: float, tabs: Array, tab_w: float, e: float,
		corner: float) -> Dictionary:
	var ts := tabs.duplicate()
	ts.sort()
	var pts := PackedVector2Array([Vector2(0, 0), Vector2(w, 0)])
	var radii: Array = [corner, corner]
	for c in ts:
		pts.append_array(PackedVector2Array([Vector2(w, float(c) - tab_w * 0.5),
			Vector2(w + e, float(c) - tab_w * 0.5), Vector2(w + e, float(c) + tab_w * 0.5),
			Vector2(w, float(c) + tab_w * 0.5)]))
		radii.append_array([0.0, 0.1, 0.1, 0.0])
	pts.append(Vector2(w, d))
	pts.append(Vector2(0, d))
	radii.append_array([corner, corner])
	ts.reverse()
	for c in ts:
		pts.append_array(PackedVector2Array([Vector2(0, float(c) + tab_w * 0.5),
			Vector2(-e, float(c) + tab_w * 0.5), Vector2(-e, float(c) - tab_w * 0.5),
			Vector2(0, float(c) - tab_w * 0.5)]))
		radii.append_array([0.0, 0.1, 0.1, 0.0])
	return {"base": pts, "radii": radii}


# ---------------------------------------------------------------------------
# Sofa / daybed (the sample)
# ---------------------------------------------------------------------------

static func _sofa(s: Dictionary) -> Dictionary:
	var p: Dictionary = s["params"]
	var t := float(s["material"]["thickness"])
	var R := float(s["style"]["corner_r"])
	var L := float(p["length"])
	var D := float(p["depth"])
	var hf := float(p["frame_h"])
	var dd := float(p["deck_depth"])
	var ov := float(p["deck_overhang"])
	var ha := maxf(float(p["arm_h"]), hf + 2.0)
	var ai := float(p["arm_inset"])
	var nr := int(p["rails"])
	var nc := int(p["cross_rails"])
	var hb := float(p["back_h"])
	var parts: Array = []
	var joints: Array = []
	var warnings: Array = []

	# Long rails (along X, on edge), slotted from the top.
	var rail_z: Array = []
	for i in nr:
		var f := float(i) / float(maxi(nr - 1, 1))
		rail_z.append(lerpf(4.0 + t * 0.5, D - 4.0 - t * 0.5, f) if nr > 1 else D * 0.5)
	for i in nr:
		parts.append(_part("long_rail_%d" % i, "Long rail", "Long rail", rect(L, hf),
			[R * 0.33, R * 0.33, R * 0.33, R * 0.33], frame_of(Vector3(0, 0, rail_z[i]), X, Y),
			"rail", t, {"match": "long_rail", "grain": "x"}))
	# Cross rails (along Z): the outer ones put their outer face on the
	# quarter lines, the way the sample is laid out.
	var cross_x: Array = []
	for i in nc:
		var x := L * float(i + 1) / float(nc + 1)
		if absf(x - L * 0.5) > 0.01:
			x += t * 0.5 * signf(L * 0.5 - x)
		cross_x.append(x)
	for i in nc:
		parts.append(_part("cross_rail_%d" % i, "Cross rail", "Cross rail", rect(D, hf),
			[R * 0.33, R * 0.33, R * 0.33, R * 0.33], frame_of(Vector3(cross_x[i], 0, 0), Z, Y),
			"rail", t, {"match": "cross_rail", "grain": "x"}))
		for r in nr:
			joints.append(_joint("lr%d_cr%d" % [r, i], "long_rail_%d" % r, "cross_rail_%d" % i,
				"cross_lap", {"open": Y}))
	# Arms, with foot arches between the rails.
	var arm_x := [ai + t * 0.5, L - ai - t * 0.5]
	var arm_notches: Array = []
	if bool(s["style"]["foot_arch"]):
		for i in range(nr - 1):
			var z0 := float(rail_z[i]) + t * 0.5 + 2.0
			var z1 := float(rail_z[i + 1]) - t * 0.5 - 2.0
			var w := z1 - z0
			if w >= 4.0:
				arm_notches.append(_arch(0, (z0 + z1) * 0.5, w, minf(3.0, hf * 0.25)))
	for k in 2:
		parts.append(_part("arm_%d" % k, "Arm", "Arm", rect(D, ha),
			[0.5, 0.5, maxf(R * 1.6, 0.5), maxf(R * 1.6, 0.5)],
			frame_of(Vector3(arm_x[k], 0, 0), Z, Y), "arm", t,
			{"match": "arm", "grain": "x", "notches": arm_notches.duplicate(true)}))
		for r in nr:
			joints.append(_joint("lr%d_arm%d" % [r, k], "long_rail_%d" % r, "arm_%d" % k,
				"cross_lap", {"open": Y}))
	# Deck: lies on the rails, slotted into the arms (the arms from the front,
	# the deck from its back edge).
	var deck_z0 := D + ov - dd
	var deck_y := hf + t * 0.5
	parts.append(_part("deck", "Deck", "Deck", rect(L, dd), [R, R, R, R],
		frame_of(Vector3(0, deck_y, deck_z0), X, Z), "deck", t,
		{"grain": "x", "seat": true}))
	for k in 2:
		joints.append(_joint("arm%d_deck" % k, "arm_%d" % k, "deck", "cross_lap",
			{"open": Z, "ratio": float(p["deck_share"])}))
	# Back panel + braces, per pose.
	var poses: Array = []
	var back_radii: Array = [0.5, 0.5, R, R]
	var brace_len := float(p["brace_len"])
	var brace_w := float(p["brace_w"])
	var pose_defs: Array = [["upright", float(p["upright_deg"])], ["recline", float(p["recline_deg"])]]
	var seats: Array = []
	var first_frames := {}
	for pd in pose_defs:
		var pid := str(pd[0])
		var a := deg_to_rad(float(pd[1]))
		# The upright brace stands further forward than the reclined one, so
		# their slots in the cross rails sit apart (the sample: ~9"); never so
		# far forward that it reaches the deck.
		var shift := 7.0 if pid == "upright" else 0.0
		var sol := {}
		while shift >= 0.0:
			sol = _sofa_back_pose(a, t, hf, hb, brace_len, rail_z, shift)
			if sol.is_empty() or float(sol["deck_cross"]) <= deck_z0 - 1.0:
				break
			shift -= 1.0
		if sol.is_empty():
			warnings.append("the back cannot reach its braces at %d°" % int(pd[1]))
			continue
		var frames := {}
		frames["back"] = sol["back"]
		var bx := [cross_x[0], cross_x[nc - 1]] if nc > 1 else [cross_x[0]]
		for bi in bx.size():
			var bf: Transform3D = sol["brace"]
			bf.origin.x = float(bx[bi]) - brace_w * 0.5
			frames["brace_%d" % bi] = bf
			var ci := 0 if bi == 0 else nc - 1
			joints.append(_joint("brace%d_cr_%s" % [bi, pid], "brace_%d" % bi, "cross_rail_%d" % ci,
				"cross_lap", {"open": -Y, "pose": pid}))
		for k in 2:
			joints.append(_joint("back_arm%d_%s" % [k, pid], "back", "arm_%d" % k, "cross_lap",
				{"open": -Y, "pose": pid}))
		var zp := float(sol["zp"])
		if zp < deck_z0 + 1.0 or zp > deck_z0 + dd - 12.0:
			warnings.append("at %d° the back stands %s from the deck's back edge" % [
				int(pd[1]), FlatpackSpec.fmt_in(zp - deck_z0)])
		poses.append({"id": pid, "label": FlatpackSpec.POSE_LABELS[pid], "frames": frames,
			"hidden": [], "seat_depth": D + ov - zp})
		if first_frames.is_empty():
			first_frames = frames
		var sz := (zp + D + ov) * 0.5
		var n_sit := maxi(1, int(floor((L - 2.0 * ai) / 24.0)))
		for i in n_sit:
			var x := ai + (L - 2.0 * ai) * (float(i) + 0.5) / float(n_sit)
			seats.append({"pose": pid, "kind": "sit", "pos": Vector3(x, hf + t, sz), "face": Z})
	if bool(p["daybed"]):
		var frames := {"back": frame_of(Vector3(0, deck_y, deck_z0), X, -Z)}
		for k in 2:
			joints.append(_joint("arm%d_back_daybed" % k, "arm_%d" % k, "back", "cross_lap",
				{"open": -Z, "pose": "daybed"}))
		var nb := 2 if nc > 1 else 1
		var hidden: Array = []
		for bi in nb:
			hidden.append("brace_%d" % bi)
		poses.append({"id": "daybed", "label": FlatpackSpec.POSE_LABELS["daybed"], "frames": frames,
			"hidden": hidden})
		var bed_len := L - 2.0 * ai - 2.0 * t
		# Lying along the length, side by side across the depth (~28" each).
		var n_lie := maxi(1, int(floor((dd + hb) / 28.0)))
		for i in n_lie:
			var z := deck_z0 - hb + (dd + hb) * (float(i) + 0.5) / float(n_lie)
			seats.append({"pose": "daybed", "kind": "lie", "pos": Vector3(L * 0.5, hf + t, z),
				"face": X, "length": bed_len})
	parts.append(_part("back", "Back", "Back", rect(L, hb), back_radii,
		first_frames.get("back", frame_of(Vector3(0, deck_y, deck_z0), X, -Z)), "back", t,
		{"grain": "x"}))
	var nbr := 2 if nc > 1 else 1
	for bi in nbr:
		var bf: Transform3D = first_frames.get("brace_%d" % bi, Transform3D.IDENTITY)
		parts.append(_part("brace_%d" % bi, "Back brace", "Back brace", rect(brace_len, brace_w),
			[0.5, 0.5, 0.5, 0.5], bf, "brace", t, {"match": "brace", "grain": "x",
			"poses": ["upright", "recline"]}))
	return {"spec": s, "parts": parts, "joints": joints, "poses": poses, "warnings": warnings,
		"seats": seats}


## Where the back stands at angle `a` (radians from vertical): its frame, a
## brace frame (x origin set by the caller) and the back's foot `zp`.
## The brace runs from inside the back cross rail's top up to the back's rear
## face; the back's foot slides forward on the deck until the brace fits.
## `shift` moves the brace's foot forward along the rail.
static func _sofa_back_pose(a: float, t: float, hf: float, hb: float, brace_len: float,
		rail_z: Array, shift: float = 0.0) -> Dictionary:
	var sa := sin(a)
	var ca := cos(a)
	var z0 := float(rail_z[0]) + t * 0.5 + 1.75 + shift
	var y0 := hf * 0.58
	var yb := hf + t + t * 0.5 * sa + 0.02
	var h := 0.62 * hb
	var cy := 0.0
	for _i in 12:
		cy = yb + h * ca - t * sa
		if cy - y0 < brace_len * 0.97:
			break
		h *= 0.85
	if cy - y0 >= brace_len * 0.97 or cy <= y0:
		return {}
	var dz := sqrt(brace_len * brace_len - (cy - y0) * (cy - y0))
	var cz := z0 + dz
	var zp := cz + h * sa + t * ca
	var back := frame_of(Vector3(0, yb, zp), X, Vector3(0, ca, -sa))
	var v := Vector3(0, cy - y0, cz - z0).normalized()
	var brace := frame_of(Vector3(0, y0, z0), v, X)
	# Where the brace passes the deck's plane (it must stay behind the deck).
	var deck_mid := hf + t * 0.5
	var cross := z0 + (deck_mid - y0) / maxf(cy - y0, 0.01) * dz
	return {"back": back, "brace": brace, "zp": zp, "deck_cross": cross}


# ---------------------------------------------------------------------------
# Bench, stool, table, coffee table
# ---------------------------------------------------------------------------

static func _table_like(s: Dictionary) -> Dictionary:
	var type := str(s["type"])
	var p: Dictionary = s["params"]
	var t := float(s["material"]["thickness"])
	var R := float(s["style"]["corner_r"])
	var arches := bool(s["style"]["foot_arch"])
	var wedges := bool(s["joinery"]["wedges"])
	var parts: Array = []
	var joints: Array = []
	var warnings: Array = []
	var seats: Array = []

	var L := 0.0
	var W := 0.0
	var H := float(p["height"])
	var x_legs := false
	var round_top := false
	var tab_w := float(p["tab_w"])
	if type == "stool":
		L = float(p["top"])
		W = L
		x_legs = true
		round_top = bool(p["round"])
	else:
		L = float(p["length"])
		W = float(p["width"])
		x_legs = bool(p.get("x_legs", false))
	var hb := H - t           # top of the leg bodies (the underside of the top)
	var top_y := H - t * 0.5

	# The top.
	var top_extra := {"grain": "x"}
	if type == "bench" or type == "stool":
		top_extra["seat"] = true
	if round_top:
		top_extra["circle"] = {"c": Vector2(L * 0.5, W * 0.5), "r": L * 0.5}
		parts.append(_part("top", "Seat", "Seat", rect(L, W), [0, 0, 0, 0],
			frame_of(Vector3(0, top_y, 0), X, Z), "top", t, top_extra))
	else:
		var top_name := "Seat" if type == "bench" or type == "stool" else "Top"
		parts.append(_part("top", top_name, top_name, rect(L, W), [R, R, R, R],
			frame_of(Vector3(0, top_y, 0), X, Z), "top", t, top_extra))

	if x_legs:
		var inset := float(p["leg_inset"])
		var la := L - 2.0 * inset     # leg along X
		var lb := W - 2.0 * minf(inset, W * 0.2)   # leg along Z
		if type == "stool":
			# Crossed legs on a round top: keep the tab ends inside the circle.
			la = L - 2.0 * inset
			lb = la
		var tabs_a := [la * 0.18, la * 0.82]
		var tabs_b := [lb * 0.18, lb * 0.82]
		var pa := leg_poly(la, hb, tabs_a, tab_w, t)
		var pb := leg_poly(lb, hb, tabs_b, tab_w, t)
		var na: Array = []
		var nb: Array = []
		if arches:
			var da := minf(2.5, H * 0.12)
			na.append(_arch(0, la * 0.27, la * 0.24, da))
			na.append(_arch(0, la * 0.73, la * 0.24, da))
			nb.append(_arch(0, lb * 0.27, lb * 0.24, da))
			nb.append(_arch(0, lb * 0.73, lb * 0.24, da))
		parts.append(_part("leg_a", "Leg", "Leg (long)", pa["base"], pa["radii"],
			frame_of(Vector3((L - la) * 0.5, 0, W * 0.5), X, Y), "leg", t,
			{"grain": "y", "notches": na}))
		parts.append(_part("leg_b", "Leg", "Leg (short)" if absf(la - lb) > 0.01 else "Leg (long)",
			pb["base"], pb["radii"], frame_of(Vector3(L * 0.5, 0, (W - lb) * 0.5), Z, Y), "leg", t,
			{"grain": "y", "notches": nb}))
		if absf(la - lb) < 0.01:
			parts[parts.size() - 1]["group"] = "Leg (long)"
		joints.append(_joint("legs_x", "leg_a", "leg_b", "cross_lap", {"open": Y}))
		joints.append(_joint("leg_a_top", "leg_a", "top", "tenon"))
		joints.append(_joint("leg_b_top", "leg_b", "top", "tenon"))
	else:
		var inset := float(p["leg_inset"])
		var n := int(p.get("legs", 2))
		var side_in := 0.5 if type == "bench" else 1.0
		var lw := W - 2.0 * side_in
		var back := bool(p.get("back", false)) and type == "bench"
		var post := {}
		var tabs := [lw * 0.25, lw * 0.75]
		if back:
			post = {"w": 2.5, "h": H + float(p["back_h"])}
			tabs = [lw * 0.5, lw * 0.82]
		var lp := leg_poly(lw, hb, tabs, tab_w, t, post)
		var sy := float(p["stretcher_y"])
		var sh := float(p["stretcher_h"])
		var notches: Array = []
		if arches:
			var depth := minf(2.5, sy - 1.25)
			if depth >= 0.75:
				notches.append(_arch(0, lw * 0.5, lw * 0.4, depth))
		var leg_x: Array = []
		for i in n:
			leg_x.append(lerpf(inset + t * 0.5, L - inset - t * 0.5, float(i) / float(maxi(n - 1, 1))))
		for i in n:
			parts.append(_part("leg_%d" % i, "Leg", "Leg", lp["base"], lp["radii"],
				frame_of(Vector3(float(leg_x[i]), 0, side_in), Z, Y), "leg", t,
				{"match": "leg", "grain": "y", "notches": notches.duplicate(true)}))
			joints.append(_joint("leg%d_top" % i, "leg_%d" % i, "top", "tenon"))
		# The stretcher: through every leg, wedged outside the end legs.
		var run := WEDGE_RUNOUT if wedges else t * 0.5 + 0.75
		var x0 := float(leg_x[0]) - run
		var x1 := float(leg_x[n - 1]) + run
		parts.append(_part("stretcher", "Stretcher", "Stretcher", rect(x1 - x0, sh),
			[0.5, 0.5, 0.5, 0.5], frame_of(Vector3(x0, sy, W * 0.5), X, Y), "stretcher", t,
			{"grain": "x"}))
		for i in n:
			var end_leg := i == 0 or i == n - 1
			joints.append(_joint("stretcher_leg%d" % i, "stretcher", "leg_%d" % i, "tenon",
				{"wedge": wedges and end_leg}))
		if back:
			var bh := float(p["back_h"]) - 3.0
			parts.append(_part("back", "Back rest", "Back rest", rect(L, bh), [0.5, 0.5, R, R],
				frame_of(Vector3(0, H + 2.5, side_in + 1.25), X, Y), "back", t, {"grain": "x"}))
			for i in n:
				joints.append(_joint("back_leg%d" % i, "back", "leg_%d" % i, "cross_lap", {"open": -Y}))
	if type == "bench":
		var n_sit := maxi(1, int(floor(L / 22.0)))
		for i in n_sit:
			seats.append({"pose": "", "kind": "sit",
				"pos": Vector3(L * (float(i) + 0.5) / float(n_sit), H, W * 0.5), "face": Z})
	elif type == "stool":
		seats.append({"pose": "", "kind": "sit", "pos": Vector3(L * 0.5, H, W * 0.5), "face": Z})
	return {"spec": s, "parts": parts, "joints": joints, "poses": [], "warnings": warnings,
		"seats": seats}


# ---------------------------------------------------------------------------
# Chair, lounger
# ---------------------------------------------------------------------------

## The side profile's control points (z, y), in CCW order, before the player's
## offsets. Keys name them for the profile editor.
const PROFILE_KEYS := ["rear_foot", "front_foot", "front_top", "seat_back", "back_front", "back_rear"]
const PROFILE_LABELS := {"rear_foot": "Rear foot", "front_foot": "Front foot", "front_top": "Front top",
	"seat_back": "Seat / back corner", "back_front": "Back top (front)", "back_rear": "Back top (rear)"}


static func _line_hit(p: Vector2, u: Vector2, q: Vector2, v: Vector2) -> Vector2:
	var den := u.x * v.y - u.y * v.x
	if absf(den) < 1e-6:
		return (p + q) * 0.5
	var k := ((q.x - p.x) * v.y - (q.y - p.y) * v.x) / den
	return p + u * k


## The chair's geometry in side coordinates (z forward, y up): seat and back
## lines and the profile points, front of the seat at z = 0 (shifted later).
static func chair_geometry(s: Dictionary) -> Dictionary:
	var p: Dictionary = s["params"]
	var t := float(s["material"]["thickness"])
	var hs := float(p["seat_h"])
	var ds := float(p["seat_depth"])
	var tilt := deg_to_rad(float(p["seat_tilt"]))
	var a := deg_to_rad(float(p["back_deg"]))
	var hbk := float(p["back_h"])
	var rise := float(p["rise"])
	var s0 := Vector2(0.0, hs)
	var sd := Vector2(-cos(tilt), -sin(tilt))
	var sn := Vector2(-sin(tilt), cos(tilt))
	var s1 := s0 + sd * ds
	var bd := Vector2(-sin(a), cos(a))
	var bn := Vector2(cos(a), sin(a))      # forward face of the back
	var b0 := s1 + sn * (t * 0.5 + 0.1)
	var b1 := b0 + bd * hbk
	var pts := {}
	pts["front_foot"] = Vector2(s0.x + 1.0, 0.0)
	pts["front_top"] = Vector2(s0.x + 1.0, hs + rise)
	pts["seat_back"] = _line_hit(s0 + sn * rise, sd, b0 + bn * rise, bd)
	pts["back_front"] = b1 + bd * 0.75 + bn * rise
	pts["back_rear"] = b1 + bd * 0.75 - bn * rise
	var zr := minf((pts["back_rear"] as Vector2).x, b0.x - rise) - 1.5
	pts["rear_foot"] = Vector2(zr, 0.0)
	var off: Dictionary = s.get("profile_offsets", {})
	for k in PROFILE_KEYS:
		if off.has(k):
			pts[k] = (pts[k] as Vector2) + (off[k] as Vector2)
	return {"s0": s0, "s1": s1, "sd": sd, "sn": sn, "b0": b0, "b1": b1, "bd": bd, "bn": bn,
		"pts": pts, "zr": zr}


static func _chair(s: Dictionary) -> Dictionary:
	var p: Dictionary = s["params"]
	var t := float(s["material"]["thickness"])
	var R := float(s["style"]["corner_r"])
	var wedges := bool(s["joinery"]["wedges"])
	var W := float(p["width"])
	var tab_w := float(p["tab_w"])
	var hbk := float(p["back_h"])
	var ds := float(p["seat_depth"])
	var parts: Array = []
	var joints: Array = []
	var warnings: Array = []
	var g := chair_geometry(s)
	var pts: Dictionary = g["pts"]
	# Shift so the rear foot sits at z = 0.
	var shift := -float((pts["rear_foot"] as Vector2).x)
	var base := PackedVector2Array()
	for k in PROFILE_KEYS:
		base.append((pts[k] as Vector2) + Vector2(shift, 0.0))
	if not FlatpackProfile.is_ccw(base):
		warnings.append("the side profile turned inside out; the control points were reset")
		var s2 := s.duplicate(true)
		s2["profile_offsets"] = {}
		g = chair_geometry(s2)
		pts = g["pts"]
		shift = -float((pts["rear_foot"] as Vector2).x)
		base = PackedVector2Array()
		for k in PROFILE_KEYS:
			base.append((pts[k] as Vector2) + Vector2(shift, 0.0))
	var radii := [0.5, 0.5, 1.0, 1.5, 1.0, 1.0]
	var zf := base[1].x
	var zr := base[0].x
	var sy := 3.0 if float(p["seat_h"]) >= 12.0 else 2.25
	var sh := 3.0 if float(p["seat_h"]) >= 12.0 else 2.5
	var z_front := zf - 3.0
	var z_rear := zr + 3.0
	var notches: Array = []
	if bool(s["style"]["foot_arch"]):
		var a0 := z_rear + t * 0.5 + 1.75
		var a1 := z_front - t * 0.5 - 1.75
		var depth := minf(sy - 0.75, 2.5)
		if a1 - a0 >= 4.0 and depth >= 0.75:
			notches.append(_arch(0, (a0 + a1) * 0.5, a1 - a0, depth))
	var side_x := [-t * 0.5, W + t * 0.5]
	for k in 2:
		parts.append(_part("side_%d" % k, "Side", "Side", base, radii,
			frame_of(Vector3(float(side_x[k]), 0, 0), Z, Y), "side", t,
			{"match": "side", "grain": "x", "notches": notches.duplicate(true)}))
	var e := t + TAB_PROUD
	# Seat: from its front edge back along the seat line.
	var s0: Vector2 = g["s0"]
	var sd: Vector2 = g["sd"]
	var seat_poly := tabbed_panel(W, ds, [ds * 0.25, ds * 0.75], tab_w, e, minf(R, 1.0))
	parts.append(_part("seat", "Seat", "Seat", seat_poly["base"], seat_poly["radii"],
		frame_of(Vector3(0, s0.y, s0.x + shift), X, Vector3(0, sd.y, sd.x)), "seat", t,
		{"grain": "x", "seat": true}))
	var b0: Vector2 = g["b0"]
	var bd: Vector2 = g["bd"]
	var back_poly := tabbed_panel(W, hbk, [hbk * 0.25, hbk * 0.75], tab_w, e, minf(R, 1.0))
	parts.append(_part("back", "Back", "Back", back_poly["base"], back_poly["radii"],
		frame_of(Vector3(0, b0.y, b0.x + shift), X, Vector3(0, bd.y, bd.x)), "back", t,
		{"grain": "x"}))
	for k in 2:
		joints.append(_joint("seat_side%d" % k, "seat", "side_%d" % k, "tenon"))
		joints.append(_joint("back_side%d" % k, "back", "side_%d" % k, "tenon"))
	var run := WEDGE_RUNOUT if wedges else t * 0.5 + 0.75
	for si in 2:
		var zc := z_front if si == 0 else z_rear
		var sid := "stretcher_%d" % si
		parts.append(_part(sid, "Stretcher", "Stretcher", rect(W + t * 2.0 + run * 2.0 - t, sh),
			[0.5, 0.5, 0.5, 0.5], frame_of(Vector3(-t * 0.5 - run, sy, zc), X, Y), "stretcher", t,
			{"match": "stretcher", "grain": "x"}))
		for k in 2:
			joints.append(_joint("%s_side%d" % [sid, k], sid, "side_%d" % k, "tenon", {"wedge": wedges}))
	var seat_mid := s0 + sd * (ds * 0.45)
	var seats := [{"pose": "", "kind": "sit", "pos": Vector3(W * 0.5, seat_mid.y + t * 0.5,
		seat_mid.x + shift), "face": Z}]
	return {"spec": s, "parts": parts, "joints": joints, "poses": [], "warnings": warnings,
		"seats": seats}
