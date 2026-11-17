class_name PortSuggest
extends RefCounted

## Where a machine's connections would usually be, when nobody has said:
## on the faces of its bounding box, by what each one carries.
##   water / liquids  low on the sides (a tank's outlet, a pump's inlet),
##                    drains on the bottom side face at the very bottom;
##   power            low on the back, power in and out side by side;
##   data             high on the back;
##   gas / exhaust    on top.
## Ports of one group are spread along their face so no two sit together;
## every exit points straight out of its face (an axis of the model). Pure
## static; positions and normals are in the model's own frame.

const LOW := 0.18
const HIGH := 0.82
const DRAIN_FRAC := 0.06
const EDGE := 0.2


## handles: [{id, polarity, resource_kind, direction}], box: the model's local
## AABB. -> [{handle_id, pos: Vector3, normal: Vector3, face}]
static func suggest(handles: Array, box: AABB) -> Array:
	var groups := {"water": [], "drain": [], "power": [], "data": [], "gas": [], "other": []}
	for h: Variant in handles:
		var d: Dictionary = h
		(groups[group_of(d)] as Array).append(d)
	var out: Array = []
	# Water in on the left side, water out on the right; everything on its face.
	var w_in: Array = []
	var w_out: Array = []
	for d: Dictionary in groups["water"]:
		if str(d.get("direction", "")) == "out":
			w_out.append(d)
		else:
			w_in.append(d)
	out.append_array(_spread(w_in, box, Vector3.LEFT, LOW))
	out.append_array(_spread(w_out, box, Vector3.RIGHT, LOW))
	out.append_array(_spread(groups["drain"], box, Vector3.RIGHT, DRAIN_FRAC))
	out.append_array(_spread(groups["power"], box, Vector3.FORWARD, LOW))
	out.append_array(_spread(groups["data"], box, Vector3.FORWARD, HIGH))
	out.append_array(_top(groups["gas"], box))
	out.append_array(_spread(groups["other"], box, Vector3.BACK, 0.5))
	return out


## Which group a handle belongs to.
static func group_of(h: Dictionary) -> String:
	var pol := str(h.get("polarity", ""))
	var rk := str(h.get("resource_kind", "")).to_lower()
	if pol in ["ac", "ac_240", "load", "positive", "negative", "pv", "parallel", "smart_battery"]:
		return "power"
	if pol == "data" or rk == "data":
		return "data"
	if rk in ["blackwater", "greywater", "drain", "urine", "brine"]:
		return "drain"
	if rk in ["woodgas", "biogas", "exhaust", "steam", "air", "co2", "methane", "propane"]:
		return "gas"
	if pol == "resource" or not rk.is_empty():
		return "water"
	return "other"


## Ports spread along one side face at a height share of the box.
static func _spread(list: Array, box: AABB, n: Vector3, h_frac: float) -> Array:
	var out: Array = []
	var cnt := list.size()
	if cnt == 0:
		return out
	var c := box.get_center()
	var e := box.size * 0.5
	var y := box.position.y + box.size.y * h_frac
	# The face's own across direction (horizontal, perpendicular to n).
	var across := Vector3(-n.z, 0.0, n.x)
	var half := absf(across.dot(e)) * (1.0 - EDGE)
	for i: int in range(cnt):
		var t := 0.0 if cnt == 1 else lerpf(-half, half, float(i) / float(cnt - 1))
		var face_pt := c + n * absf(n.dot(e)) + across * t
		out.append({"handle_id": str((list[i] as Dictionary).get("id", "")),
			"pos": Vector3(face_pt.x, y, face_pt.z), "normal": n, "face": _face_name(n)})
	return out


static func _top(list: Array, box: AABB) -> Array:
	var out: Array = []
	var cnt := list.size()
	var c := box.get_center()
	for i: int in range(cnt):
		var t := 0.0 if cnt == 1 else lerpf(-0.3, 0.3, float(i) / float(cnt - 1)) * box.size.x
		out.append({"handle_id": str((list[i] as Dictionary).get("id", "")),
			"pos": Vector3(c.x + t, box.end.y, c.z), "normal": Vector3.UP, "face": "top"})
	return out


static func _face_name(n: Vector3) -> String:
	if n == Vector3.LEFT:
		return "left"
	if n == Vector3.RIGHT:
		return "right"
	if n == Vector3.FORWARD:
		return "back"
	if n == Vector3.BACK:
		return "front"
	return "side"


## A picked surface normal, cleaned: pointing out of the box (an inside-out
## triangle gives the wrong way round), and on the nearest axis when `snap`
## or when it is within `snap_deg` of one.
static func clean_normal(n: Vector3, at: Vector3, box: AABB, snap: bool, snap_deg: float = 12.0) -> Vector3:
	var out := n.normalized() if n.length_squared() > 1e-10 else Vector3.UP
	var from_c := at - box.get_center()
	if from_c.length_squared() > 1e-8 and out.dot(from_c) < 0.0:
		out = -out
	var best := Vector3.UP
	var best_d := -2.0
	for ax: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN, Vector3.BACK, Vector3.FORWARD]:
		var d := out.dot(ax)
		if d > best_d:
			best_d = d
			best = ax
	if snap or rad_to_deg(acos(clampf(best_d, -1.0, 1.0))) <= snap_deg:
		return best
	return out


## Is the straight leg out of a port (`approach_m` long) still inside the box
## at its end? Then the run will have to leave further out.
static func exit_inside(pos: Vector3, n: Vector3, approach_m: float, box: AABB) -> bool:
	var tip := pos + n.normalized() * approach_m
	return box.grow(-0.01).has_point(tip)
