class_name GraphHubPorts
extends RefCounted

## Circular hub port helpers for resource (and catchment) containers.
## Ports live on the perimeter via angle_rad ∈ [0, TAU); tangent is radial outward.

const ROLE_IN := "in"
const ROLE_OUT := "out"
const ROLE_HUB := "hub"


## Derive angle from legacy rx/ry edge ports (left=π, right=0, top=−π/2, bottom=π/2).
static func angle_from_rx_ry(rx: float, ry: float) -> float:
	if rx <= 0.01:
		return PI
	if rx >= 0.99:
		return 0.0
	if ry <= 0.01:
		return -PI * 0.5
	if ry >= 0.99:
		return PI * 0.5
	# Interior → direction from center
	var dx := (rx - 0.5) * 2.0
	var dy := (ry - 0.5) * 2.0
	if absf(dx) < 0.001 and absf(dy) < 0.001:
		return 0.0
	return atan2(dy, dx)


static func normalize_angle(a: float) -> float:
	var t := fposmod(a, TAU)
	if t < 0.0:
		t += TAU
	return t


## rx/ry on the unit square that approximate a perimeter angle (for legacy callers).
static func rx_ry_from_angle(angle_rad: float) -> Vector2:
	var a := normalize_angle(angle_rad)
	return Vector2(0.5 + 0.5 * cos(a), 0.5 + 0.5 * sin(a))


static func outward_tangent(angle_rad: float) -> Vector2:
	var a := normalize_angle(angle_rad)
	return Vector2(cos(a), sin(a))


static func angle_from_center_to_point(center: Vector2, point: Vector2) -> float:
	var d := point - center
	if d.length_squared() < 0.0001:
		return 0.0
	return normalize_angle(atan2(d.y, d.x))


## True when this item type uses circular hub ports.
static func is_hub_type(itype: String) -> bool:
	return itype == "resource" or itype == "catchment" or itype == "pbi"


## Ensure handle dict has angle_rad (migrate from rx/ry if needed). Mutates h.
static func migrate_handle(h: Dictionary) -> void:
	if h.has("angle_rad"):
		h["angle_rad"] = normalize_angle(float(h["angle_rad"]))
		if not h.has("rx"):
			var rr := rx_ry_from_angle(float(h["angle_rad"]))
			h["rx"] = rr.x
			h["ry"] = rr.y
		return
	var rx := float(h.get("rx", 0.5))
	var ry := float(h.get("ry", 0.5))
	if not h.has("rx") and h.has("x"):
		# Legacy pixel offsets — treat as left/right if extreme
		rx = 0.0 if float(h.get("x", 0.0)) < 1.0 else 1.0
		ry = 0.5
	var ang := angle_from_rx_ry(rx, ry)
	h["angle_rad"] = ang
	var rr2 := rx_ry_from_angle(ang)
	h["rx"] = rr2.x
	h["ry"] = rr2.y
	if not h.has("role"):
		if str(h.get("id", "")).begins_with("hub_in") or str(h.get("id", "")) == "input":
			h["role"] = ROLE_IN
		elif str(h.get("id", "")).begins_with("hub_out") or str(h.get("id", "")) == "output":
			h["role"] = ROLE_OUT
		else:
			h["role"] = ROLE_HUB


static func migrate_handles_array(handles: Array) -> void:
	for h: Variant in handles:
		if h is Dictionary:
			migrate_handle(h as Dictionary)


## Default hub ports for a resource tank of the given kind. "dc_electricity"
## is a DC bus/battery-style tank — it gets a +/- pair (same polarity a
## panel/battery/controller uses, so it wires straight into them) instead of
## the generic single in/out pair every other resource kind gets.
static func default_resource_handles(kind: String) -> Array:
	if kind == "dc_electricity":
		var pos_ang := normalize_angle(PI * 0.5 - 0.45)
		var neg_ang := normalize_angle(PI * 0.5 + 0.45)
		var pos_rr := rx_ry_from_angle(pos_ang)
		var neg_rr := rx_ry_from_angle(neg_ang)
		return [
			{
				"id": "positive",
				"polarity": "positive",
				"resource_kind": kind,
				"role": ROLE_HUB,
				"angle_rad": pos_ang,
				"rx": pos_rr.x,
				"ry": pos_rr.y,
			},
			{
				"id": "negative",
				"polarity": "negative",
				"resource_kind": kind,
				"role": ROLE_HUB,
				"angle_rad": neg_ang,
				"rx": neg_rr.x,
				"ry": neg_rr.y,
			},
		]
	return [
		{
			"id": "input",
			"polarity": "resource",
			"resource_kind": kind,
			"role": ROLE_IN,
			"angle_rad": -PI/2.0,
			"rx": 0.5,
			"ry": 0.0,
		},
		{
			"id": "output",
			"polarity": "resource",
			"resource_kind": kind,
			"role": ROLE_OUT,
			"angle_rad": PI/2.0,
			"rx": 0.5,
			"ry": 1.0,
		},
	]


static func default_catchment_handles(kind: String) -> Array:
	# Input accepts Rain PBI (same resource_kind); output feeds water/biomass tanks.
	return [
		{
			"id": "input",
			"polarity": "resource",
			"resource_kind": kind,
			"role": ROLE_IN,
			"angle_rad": -PI / 2.0,
			"rx": 0.5,
			"ry": 0.0,
		},
		{
			"id": "output",
			"polarity": "resource",
			"resource_kind": kind,
			"role": ROLE_OUT,
			"angle_rad": PI / 2.0,
			"rx": 0.5,
			"ry": 1.0,
		},
	]


static func default_pbi_handles(kind: String) -> Array:
	return [
		{
			"id": "output",
			"polarity": "resource",
			"resource_kind": kind,
			"role": ROLE_OUT,
			"angle_rad": PI / 2.0,
			"rx": 0.5,
			"ry": 1.0,
		},
	]


## Screen position on the circle inscribed in the node rect.
static func screen_pos_on_circle(tl: Vector2, sz: Vector2, angle_rad: float) -> Vector2:
	var center := tl + sz * 0.5
	var r := minf(sz.x, sz.y) * 0.5
	var a := normalize_angle(angle_rad)
	return center + Vector2(cos(a), sin(a)) * r


static func circle_center(tl: Vector2, sz: Vector2) -> Vector2:
	return tl + sz * 0.5


static func circle_radius(sz: Vector2) -> float:
	return minf(sz.x, sz.y) * 0.5


## True if screen_pos is inside the inscribed circle (with optional padding).
static func point_in_hub_body(tl: Vector2, sz: Vector2, screen_pos: Vector2,
		pad_frac: float = 0.08) -> bool:
	var c := circle_center(tl, sz)
	var r := circle_radius(sz) * (1.0 - pad_frac)
	return screen_pos.distance_to(c) <= r


## Next unique hub handle id for the given role.
static func next_hub_id(handles: Array, role: String) -> String:
	var prefix := "hub_in_" if role == ROLE_IN else "hub_out_"
	var used: Dictionary = {}
	for h: Variant in handles:
		if h is Dictionary:
			used[str((h as Dictionary).get("id", ""))] = true
	var i := 0
	while used.has(prefix + str(i)):
		i += 1
	return prefix + str(i)


## Find an unused default port matching role, or null.
static func find_free_default(handles: Array, role: String, wired_ids: Dictionary) -> Dictionary:
	var want_id := "input" if role == ROLE_IN else "output"
	for h: Variant in handles:
		if h is Dictionary:
			var hd: Dictionary = h as Dictionary
			if str(hd.get("id", "")) == want_id and not wired_ids.has(want_id):
				return hd
	return {}


## Ensure item.handles is a mutable hub list (defaults if empty). Returns the array.
static func ensure_hub_handles(item: Dictionary, kind: String) -> Array:
	var handles: Array = item.get("handles", []) as Array
	var ity := str(item.get("type", ""))
	if handles.is_empty():
		if ity == "catchment":
			handles = default_catchment_handles(kind)
		elif ity == "pbi":
			handles = default_pbi_handles(kind)
		else:
			handles = default_resource_handles(kind)
		item["handles"] = handles
	else:
		migrate_handles_array(handles)
		# Older rain catchments only persisted an output hub — add input if missing.
		if ity == "catchment":
			var has_in := false
			for h: Variant in handles:
				if h is Dictionary and str((h as Dictionary).get("id", "")) == "input":
					has_in = true
					break
			if not has_in:
				handles.insert(0, {
					"id": "input",
					"polarity": "resource",
					"resource_kind": kind,
					"role": ROLE_IN,
					"angle_rad": -PI / 2.0,
					"rx": 0.5,
					"ry": 0.0,
				})
				item["handles"] = handles
	return handles


## Create or retarget a hub port at angle for a drop-to-body connect.
## role: "in" when wire ends on this tank, "out" when wire starts from this tank.
## Returns the handle dict (already in item.handles).
static func acquire_hub_port(item: Dictionary, kind: String, angle_rad: float,
		role: String, wired_ids: Dictionary) -> Dictionary:
	var handles := ensure_hub_handles(item, kind)
	var free := find_free_default(handles, role, wired_ids)
	if not free.is_empty():
		free["angle_rad"] = normalize_angle(angle_rad)
		var rr := rx_ry_from_angle(float(free["angle_rad"]))
		free["rx"] = rr.x
		free["ry"] = rr.y
		free["role"] = role
		free["resource_kind"] = kind
		return free
	var hid := next_hub_id(handles, role)
	var ang := normalize_angle(angle_rad)
	var rr2 := rx_ry_from_angle(ang)
	var neu := {
		"id": hid,
		"polarity": "resource",
		"resource_kind": kind,
		"role": role,
		"angle_rad": ang,
		"rx": rr2.x,
		"ry": rr2.y,
		"connected_to": [],
	}
	handles.append(neu)
	return neu


## Update angle_rad on an existing handle (port rotation).
static func set_handle_angle(item: Dictionary, handle_id: String, angle_rad: float) -> bool:
	var handles: Array = item.get("handles", []) as Array
	if handles.is_empty():
		return false
	for h: Variant in handles:
		if h is Dictionary and str((h as Dictionary).get("id", "")) == handle_id:
			var hd: Dictionary = h as Dictionary
			hd["angle_rad"] = normalize_angle(angle_rad)
			var rr := rx_ry_from_angle(float(hd["angle_rad"]))
			hd["rx"] = rr.x
			hd["ry"] = rr.y
			return true
	return false
