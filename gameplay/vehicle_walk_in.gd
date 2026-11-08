class_name VehicleWalkIn
extends Node
## A living vehicle's doors, opened by the player, and the way in.
##
## VehicleBuilder draws every door as its own leaf (node "Doors") and bakes a
## simple walk-in collision (floor, walls with the doorways left open, roof,
## furniture). This node, attached to the placed prop beside PlacedVehicle,
## owns what changes: each doorway's BLOCKER while its door is shut, a RAMP
## from the ground to the sill while it is open (the floor of a bus is a
## metre up and the player has no step-up), the leaf animation, and the pick
## the crosshair asks ("is a door under this ray?").
##
## Aim at a door and Interact: it opens; walk in. Interact anywhere else on
## or in the vehicle still drives it. Doors shut themselves when the vehicle
## is driven, towed or packed up (its prop collision goes off).

const GROUP := "vehicle_walk_in"
const NODE_NAME := "VehicleWalkIn"
## Seconds a door takes to open or shut.
const OPEN_S := 0.6
## How far away a door can be worked from (camera to door).
const REACH_M := 3.4
## The ramp runs at least this far out from the sill.
const RAMP_RUN_M := 1.0
const WALL_T := 0.1

var _prop: Node3D = null
var _root: Node3D = null       # the builder's root: vehicle coordinates
var _gaps: Array = []
var _open: Dictionary = {}     # door index -> wanted open
var _t: Dictionary = {}        # door index -> 0..1 drawn
var _body: StaticBody3D = null
var _blockers: Dictionary = {}
var _ramps: Dictionary = {}
var _active := true
var _poll := 0.0
var _cargo_open := false


## Attach to a placed living vehicle (or trailer) whose model has doors.
static func attach(prop: Node3D, model: Node3D, rec: Dictionary) -> void:
	if prop == null or model == null or bool(rec.get("packed", false)):
		return
	if not VehicleBuilder.handles(str(rec.get("model_id", ""))):
		return
	if prop.get_node_or_null(NODE_NAME) != null:
		return
	var root := VehicleBuilder._wheel_root(model)
	if root == null or not root.has_meta("door_gaps") or root.get_node_or_null("Doors") == null:
		return
	var n := VehicleWalkIn.new()
	n.name = NODE_NAME
	n._prop = prop
	n._root = root
	n._gaps = root.get_meta("door_gaps", [])
	prop.add_child(n)


func _ready() -> void:
	add_to_group(GROUP)
	_build_body()
	_build_lights()
	set_process(true)


## Dome lights along the room's ceiling: a player's world ambient can be
## next to nothing, and a room lit only through its windows reads as a cave.
## No shadows, short range, faded out with distance (a camp of forty
## vehicles costs nothing from across the site).
func _build_lights() -> void:
	if _root == null:
		return
	var house: Dictionary = _root.get_meta("house_box", {})
	if house.is_empty():
		return
	var z0 := float(house["z0"])
	var z1 := float(house["z1"])
	var n := clampi(int(round((z1 - z0) / 2.6)), 1, 3)
	for i in n:
		var l := OmniLight3D.new()
		l.name = "DomeLight%d" % i
		l.position = Vector3(0.0, float(house["ceil_y"]) - 0.12, lerpf(z0, z1, (float(i) + 0.5) / float(n)))
		l.light_color = Color(1.0, 0.94, 0.84)
		l.light_energy = 0.75
		l.omni_range = 3.4
		l.omni_attenuation = 1.3
		l.shadow_enabled = false
		l.light_specular = 0.2
		l.distance_fade_enabled = true
		l.distance_fade_begin = 22.0
		l.distance_fade_length = 8.0
		_root.add_child(l)


func _build_body() -> void:
	if _root == null or _gaps.is_empty():
		return
	_body = StaticBody3D.new()
	_body.name = "DoorBody"
	_body.collision_layer = 1
	_body.collision_mask = 1
	_root.add_child(_body)
	for g0 in _gaps:
		var g: Dictionary = g0
		var door := int(g["door"])
		var a := float(g["a"])
		var b := float(g["b"])
		var sill := float(g["sill"])
		var top := maxf(float(g["y1"]) + 0.4, sill + 2.2)
		var plane := float(g["plane"])
		var side := str(g["where"]) == "side"
		# Shut: a slab filling the doorway.
		var blk := CollisionShape3D.new()
		var box := BoxShape3D.new()
		if side:
			box.size = Vector3(WALL_T, top - sill, b - a)
			blk.position = Vector3(plane - WALL_T * 0.5, (sill + top) * 0.5, (a + b) * 0.5)
		else:
			box.size = Vector3(b - a, top - sill, WALL_T)
			blk.position = Vector3((a + b) * 0.5, (sill + top) * 0.5, plane - WALL_T * 0.5)
		blk.shape = box
		_body.add_child(blk)
		_blockers[door] = blk
		# Open: a ramp from the ground up to the sill.
		var run := maxf(RAMP_RUN_M, sill * 1.25)
		var pts := PackedVector3Array()
		for e in [a, b]:
			var ee := float(e)
			if side:
				pts.append(Vector3(plane - 0.02, sill, ee))
				pts.append(Vector3(plane - 0.02, -0.6, ee))
				pts.append(Vector3(plane + run, -0.04, ee))
				pts.append(Vector3(plane + run, -0.6, ee))
			else:
				pts.append(Vector3(ee, sill, plane - 0.02))
				pts.append(Vector3(ee, -0.6, plane - 0.02))
				pts.append(Vector3(ee, -0.04, plane + run))
				pts.append(Vector3(ee, -0.6, plane + run))
		var ramp := CollisionShape3D.new()
		var hull := ConvexPolygonShape3D.new()
		hull.points = pts
		ramp.shape = hull
		ramp.disabled = true
		_body.add_child(ramp)
		_ramps[door] = ramp
		_open[door] = false
		_t[door] = 0.0


func door_count() -> int:
	return _gaps.size()


func is_open(door: int) -> bool:
	return bool(_open.get(door, false))


## 0 shut … 1 open, as drawn now.
func open_fraction(door: int) -> float:
	return float(_t.get(door, 0.0))


## The gap record of a door index (see VehicleBuilder.door_gaps); {} if none.
func gap(door: int) -> Dictionary:
	for g in _gaps:
		if int((g as Dictionary)["door"]) == door:
			return g
	return {}


## A doorway's middle in WORLD space, on the sill, `out_m` outside the wall
## (negative = inside): where a harness stands the player.
func door_point(door: int, out_m: float) -> Vector3:
	var g := gap(door)
	if g.is_empty() or _root == null:
		return Vector3.ZERO
	var mid := (float(g["a"]) + float(g["b"])) * 0.5
	var local := Vector3(float(g["plane"]) + out_m, float(g["sill"]), mid) if str(g["where"]) == "side" \
		else Vector3(mid, float(g["sill"]), float(g["plane"]) + out_m)
	return _root.global_transform * local


## The door whose leaf the ray (world space) hits within reach, or -1.
func door_at(origin: Vector3, dir: Vector3) -> int:
	if _root == null or not _active:
		return -1
	var holder := _root.get_node_or_null("Doors")
	if holder == null:
		return -1
	var best := -1
	var best_t := REACH_M
	for c in holder.get_children():
		var leaf := c as MeshInstance3D
		if leaf == null or leaf.mesh == null:
			continue
		var inv := leaf.global_transform.affine_inverse()
		var o := inv * origin
		var dv := inv.basis * dir
		var box := leaf.mesh.get_aabb().grow(0.06)
		var hit: Variant = box.intersects_ray(o, dv)
		if hit == null and not box.has_point(o):
			continue
		var t := 0.0
		if hit != null:
			t = (leaf.global_transform * (hit as Vector3)).distance_to(origin)
		if t < best_t:
			best_t = t
			best = int(leaf.get_meta("door", -1))
	return best


func prompt_for(door: int) -> String:
	var g := gap(door)
	var what := "door"
	match str(g.get("kind", "")):
		"roll_up":
			what = "roll-up door"
		"lift":
			what = "lift doors" if str(g.get("where", "")) == "side" else "lift gate"
		"barn":
			what = "rear doors"
		"slider", "sliding_step":
			what = "sliding door"
	return "%s the %s" % ["Shut" if is_open(door) else "Open", what]


func toggle(door: int) -> void:
	set_open(door, not is_open(door))


func set_open(door: int, open: bool) -> void:
	if not _open.has(door) or bool(_open[door]) == open:
		return
	if not open and _someone_in_doorway(door):
		return
	_open[door] = open
	_apply_collision(door)
	set_process(true)


## Open (or shut) the cargo bay's door for a crew: the rear door when there
## is one, else the widest side door.
func set_cargo_open(open: bool) -> void:
	if _cargo_open == open:
		return
	_cargo_open = open
	var pick := -1
	var wide := 0.0
	for g0 in _gaps:
		var g: Dictionary = g0
		if str(g["where"]) == "rear":
			pick = int(g["door"])
			break
		if float(g["b"]) - float(g["a"]) > wide:
			wide = float(g["b"]) - float(g["a"])
			pick = int(g["door"])
	if pick >= 0:
		set_open(pick, open)


func any_open() -> bool:
	for door in _open.keys():
		if bool(_open[door]):
			return true
	return false


func close_all() -> void:
	for door in _open.keys():
		if bool(_open[door]):
			_open[door] = false
			_apply_collision(int(door))
	set_process(true)


func _apply_collision(door: int) -> void:
	var open := bool(_open.get(door, false))
	var blk: CollisionShape3D = _blockers.get(door)
	var ramp: CollisionShape3D = _ramps.get(door)
	if blk != null:
		blk.set_deferred("disabled", open or not _active)
	if ramp != null:
		ramp.set_deferred("disabled", not open or not _active)


## A body standing in the doorway keeps the door open.
func _someone_in_doorway(door: int) -> bool:
	var g := gap(door)
	if g.is_empty() or _root == null:
		return false
	var players := get_tree().get_nodes_in_group("player")
	var inv := _root.global_transform.affine_inverse()
	for p in players:
		if not (p is Node3D):
			continue
		var l: Vector3 = inv * (p as Node3D).global_position
		var along := l.z if str(g["where"]) == "side" else l.x
		var across := (l.x if str(g["where"]) == "side" else l.z) - float(g["plane"])
		if along > float(g["a"]) - 0.2 and along < float(g["b"]) + 0.2 and absf(across) < 0.55:
			return true
	return false


func _process(delta: float) -> void:
	# The prop's own collision going off (driven, towed, on the road in)
	# shuts the doors and takes this body out of the world with it.
	_poll -= delta
	if _poll <= 0.0:
		_poll = 0.25
		var on := _prop_collides()
		if on != _active:
			_active = on
			if not on:
				for door in _open.keys():
					_open[door] = false
				_cargo_open = false
			for door in _open.keys():
				_apply_collision(int(door))
	var moving := false
	for door in _t.keys():
		var want := 1.0 if bool(_open[door]) else 0.0
		var cur := float(_t[door])
		if is_equal_approx(cur, want):
			continue
		cur = move_toward(cur, want, delta / OPEN_S)
		_t[door] = cur
		moving = true
		if _root != null:
			VehicleBuilder.set_doors_open(_root, int(door), cur)
	if not moving and _active:
		# Nothing to animate: poll slowly.
		_poll = minf(_poll, 0.25)


func _prop_collides() -> bool:
	if _prop == null:
		return false
	var body := _prop.get_node_or_null("PropBody") as CollisionObject3D
	return body != null and body.collision_layer != 0
