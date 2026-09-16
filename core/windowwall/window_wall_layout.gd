class_name WindowWallLayout
extends RefCounted

## Pure geometry for the Window Wall (multi-monitor viewport) mode.
##
## The wall frame: the EYE is the origin, +X runs right along the wall, +Y is
## up, and a flat wall sits at z = -eye_distance_m. A Godot camera whose basis is
## the identity in this frame looks straight along -Z at the wall, so every flat
## panel shares ONE orientation and differs only in its off-axis frustum.
##
## Frustum contract (pinned by window_wall_selftest): the camera runs
## PROJECTION_FRUSTUM with keep_aspect = KEEP_WIDTH, so `size` is the near-plane
## WIDTH and `offset` is the near-plane centre, both in metres. Godot builds
##   Projection.create_frustum_aspect(size, aspect, offset, near, far, flip_fov)
## with flip_fov = (keep_aspect == KEEP_WIDTH); with flip_fov FALSE the engine
## multiplies size by the aspect first, i.e. size would be the HEIGHT. The
## selftest carries a negative pin for exactly that so the decision cannot drift.
##
## Everything here is static and allocation-light so it runs headless.

const INCH_M := 0.0254
const MAX_SLOTS := 6
const MIN_EYE_DISTANCE_M := 0.05


## Physical panel size from a diagonal and the pixel aspect.
## 27" 16:9 -> (0.5977, 0.3362) m.
static func monitor_size_m(diag_in: float, aspect_w: float = 16.0, aspect_h: float = 9.0) -> Vector2:
	var diag := maxf(diag_in, 1.0) * INCH_M
	var k := diag / sqrt(aspect_w * aspect_w + aspect_h * aspect_h)
	return Vector2(aspect_w * k, aspect_h * k)


## Lay the monitors out along the wall.
##
## `cfg` is WindowWallPrefs.snapshot(): {monitor_count, gap_m, eye_distance_m,
## eye_height_offset_m, slots: [{diag_in, width_m, height_m, portrait, yaw_deg,
## pitch_deg, screen}, ...]}. Returns one dict per slot, in left-to-right order:
## {index, w_m, h_m, centre: Vector3 (wall frame), yaw_deg, pitch_deg, screen}.
##
## Slot centres: with span S = sum(w_i) + (N-1)*gap, slot i sits at
## x_i = -S/2 + sum_{j<i}(w_j + gap) + w_i/2, so the row is centred on the eye's
## X. y = -eye_height_offset_m (the eye sits `offset` ABOVE the row centre, so
## the row centre is that far BELOW the eye), z = -eye_distance_m.
static func build_slots(cfg: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var n: int = clampi(int(cfg.get("monitor_count", 3)), 1, MAX_SLOTS)
	var gap: float = maxf(float(cfg.get("gap_m", 0.1016)), 0.0)
	var d: float = maxf(float(cfg.get("eye_distance_m", 0.9)), MIN_EYE_DISTANCE_M)
	var y: float = -float(cfg.get("eye_height_offset_m", 0.0))
	var slot_cfgs: Array = cfg.get("slots", [])
	var sizes: Array[Vector2] = []
	for i in n:
		var sc: Dictionary = slot_cfgs[i] if i < slot_cfgs.size() and slot_cfgs[i] is Dictionary else {}
		sizes.append(slot_size_m(sc))
	var span := gap * float(n - 1)
	for s in sizes:
		span += s.x
	var x := -span * 0.5
	for i in n:
		var sc: Dictionary = slot_cfgs[i] if i < slot_cfgs.size() and slot_cfgs[i] is Dictionary else {}
		var s := sizes[i]
		out.append({
			"index": i,
			"w_m": s.x,
			"h_m": s.y,
			"centre": Vector3(x + s.x * 0.5, y, -d),
			"yaw_deg": float(sc.get("yaw_deg", 0.0)),
			"pitch_deg": float(sc.get("pitch_deg", 0.0)),
			"screen": int(sc.get("screen", -1)),
		})
		x += s.x + gap
	return out


## One slot's physical (width, height) in metres: explicit width_m/height_m
## when both are positive, else derived from the diagonal at 16:9; portrait
## swaps the two.
static func slot_size_m(sc: Dictionary) -> Vector2:
	var w := float(sc.get("width_m", 0.0))
	var h := float(sc.get("height_m", 0.0))
	var s: Vector2
	if w > 0.0 and h > 0.0:
		s = Vector2(w, h)
	else:
		s = monitor_size_m(float(sc.get("diag_in", 27.0)))
	if bool(sc.get("portrait", false)):
		s = Vector2(s.y, s.x)
	return s


## The panel's orientation as a basis in the wall frame. Identity for a flat
## panel; yaw turns the panel about vertical, pitch tips it about its own X.
static func slot_basis(slot: Dictionary) -> Basis:
	var yaw := deg_to_rad(float(slot.get("yaw_deg", 0.0)))
	var pitch := deg_to_rad(float(slot.get("pitch_deg", 0.0)))
	if is_zero_approx(yaw) and is_zero_approx(pitch):
		return Basis.IDENTITY
	return Basis.from_euler(Vector3(pitch, yaw, 0.0))


## Off-axis frustum for one slot, for a camera whose near plane is `near`.
##
## Returns {} (and logs) when the eye is not in front of the panel. Otherwise:
##   size        near-plane WIDTH (KEEP_WIDTH)
##   offset      near-plane centre (x, y)
##   h_near      near-plane height the PHYSICAL rectangle needs
##   aspect_phys w/h of the panel
##   d           perpendicular eye->panel-plane distance
##   basis       camera basis in the wall frame (identity when flat)
##   w_m, h_m, centre  echoed from the slot
##
## Derivation: in the panel's own frame (R = slot_basis, origin at the panel
## centre) the eye sits at e' = R^T * (-centre). The camera looks along the
## panel frame's -Z from e', so the panel plane is d = e'.z ahead of it and the
## rectangle's centre is at (-e'.x, -e'.y) across. Similar triangles onto the
## near plane give size = w*near/d and offset = (-e'.x, -e'.y)*near/d. For a
## flat panel that collapses to size = w*near/d, offset = (cx, cy)*near/d.
static func frustum_for(slot: Dictionary, near: float) -> Dictionary:
	var c: Vector3 = slot.get("centre", Vector3(0, 0, -0.9))
	var w := float(slot.get("w_m", 0.5977))
	var h := float(slot.get("h_m", 0.3362))
	var R := slot_basis(slot)
	var e_local := R.transposed() * (-c)
	var d := e_local.z
	if d < MIN_EYE_DISTANCE_M or near <= 0.0:
		push_error("WindowWallLayout: eye is not in front of slot %d (d=%.3f)" % [int(slot.get("index", -1)), d])
		return {}
	var k := near / d
	return {
		"size": w * k,
		"offset": Vector2(-e_local.x, -e_local.y) * k,
		"h_near": h * k,
		"aspect_phys": w / h,
		"d": d,
		"basis": R,
		"near": near,
		"w_m": w,
		"h_m": h,
		"centre": c,
	}


## The four near-plane corners pushed out to the panel plane, in the WALL
## frame (eye at origin). For a flat panel these are exactly
## (cx +- w/2, cy +- h/2, -d); for a tilted one, centre + R*(+-w/2, +-h/2, 0).
## Order: bottom-left, bottom-right, top-right, top-left.
static func corner_hits(f: Dictionary) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if f.is_empty():
		return out
	var scale := float(f["d"]) / float(f["near"])
	var off: Vector2 = f["offset"]
	var hw := float(f["size"]) * 0.5
	var hh := float(f["h_near"]) * 0.5
	var R: Basis = f["basis"]
	for sgn in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
		var p_cam := Vector3(off.x + sgn.x * hw, off.y + sgn.y * hh, -float(f["near"])) * scale
		out.append(R * p_cam)
	return out


## Mirror of what Camera3D builds internally for this frustum at a viewport
## with pixel aspect `aspect_px`; the selftest inverts it.
static func projection_for(f: Dictionary, aspect_px: float, near: float, far: float) -> Projection:
	return Projection.create_frustum_aspect(float(f["size"]), aspect_px, f["offset"], near, far, true)


## Unproject a normalised device coordinate (x, y in -1..1) through `proj` and
## scale the resulting view-space ray to the plane z = -d. Camera frame.
static func unproject_to_plane(proj: Projection, ndc: Vector2, d: float) -> Vector3:
	var v: Vector4 = proj.inverse() * Vector4(ndc.x, ndc.y, -1.0, 1.0)
	var p := Vector3(v.x, v.y, v.z) / v.w
	if p.z >= 0.0:
		return Vector3.INF
	return p * (d / -p.z)


## Project a camera-frame point to NDC (x, y). Vector2.INF when behind the eye.
static func project_to_ndc(proj: Projection, p_cam: Vector3) -> Vector2:
	var v: Vector4 = proj * Vector4(p_cam.x, p_cam.y, p_cam.z, 1.0)
	if v.w <= 0.0:
		return Vector2.INF
	return Vector2(v.x / v.w, v.y / v.w)


## Relative disagreement between the panel's physical aspect and the pixel
## aspect the viewport will render with. The projection's vertical extent is
## size/aspect_px, so when this exceeds ~1 % the image is stretched by that
## much vertically (a 16:10 panel configured as 16:9, say).
static func aspect_mismatch(f: Dictionary, aspect_px: float) -> float:
	if f.is_empty() or aspect_px <= 0.0:
		return 0.0
	var want := float(f["h_near"])
	var got := float(f["size"]) / aspect_px
	return absf(want - got) / maxf(got, 1e-9)


## Slot -> OS screen index.
##
## `screens` is one dict per OS screen: {index, x, y, w, h}. An explicit
## `screen` on a slot wins (when that screen exists); the remaining slots take
## the remaining screens ordered by their X position, left to right, so a
## three-monitor row auto-arranges the way it is physically hung. With fewer
## screens than slots the leftovers share screen 0 (overlapping fullscreen
## windows, which still proves creation on a single-screen machine).
static func assign_screens(slots: Array[Dictionary], screens: Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(slots.size())
	out.fill(-1)
	var n_screens := screens.size()
	var used: Dictionary = {}
	for i in slots.size():
		var want := int(slots[i].get("screen", -1))
		if want >= 0 and want < n_screens:
			out[i] = want
			used[want] = true
	var order: Array = []
	for s in screens:
		var idx := int(s.get("index", 0))
		if not used.has(idx):
			order.append(idx)
	order.sort_custom(func(a, b) -> bool:
		var sa: Dictionary = _screen_by_index(screens, a)
		var sb: Dictionary = _screen_by_index(screens, b)
		if int(sa.get("x", 0)) != int(sb.get("x", 0)):
			return int(sa.get("x", 0)) < int(sb.get("x", 0))
		return int(sa.get("y", 0)) < int(sb.get("y", 0)))
	var next := 0
	for i in slots.size():
		if out[i] >= 0:
			continue
		if next < order.size():
			out[i] = int(order[next])
			next += 1
		else:
			out[i] = 0
	return out


static func _screen_by_index(screens: Array, idx: int) -> Dictionary:
	for s in screens:
		if int(s.get("index", -1)) == idx:
			return s
	return {}


## Horizontal field of view one slot covers, degrees — for the settings tab's
## readout and the harness dump.
static func slot_hfov_deg(f: Dictionary) -> float:
	if f.is_empty():
		return 0.0
	var w := float(f["w_m"])
	var d := float(f["d"])
	return rad_to_deg(2.0 * atan(w * 0.5 / d))
