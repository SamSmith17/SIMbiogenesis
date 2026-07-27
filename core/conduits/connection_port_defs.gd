class_name ConnectionPortDefs
extends RefCounted

## Catalog defaults + per-prop overrides for 3D connection ports on models.
## Ports are local to ModelRoot space and bind to graph handle ids.

const CATALOG_DIR := "user://models/"
const CATALOG_PREFIX := "port_defs_"
const PORT_GROUP := "connection_port"
const ANCHOR_GROUP := "conduit_anchor"
## Default stub length: port → approach waypoint along socket outward.
const DEFAULT_APPROACH_M := 0.45
const MIN_APPROACH_M := 0.05


static func catalog_path(model_id: String) -> String:
	var safe := model_id.replace("/", "_").replace(":", "_").replace("\\", "_")
	return CATALOG_DIR + CATALOG_PREFIX + safe + ".json"


static func load_catalog_ports(model_id: String) -> Array:
	if model_id.is_empty():
		return []
	var from_file := _load_catalog_file(model_id)
	if not from_file.is_empty():
		return from_file
	return default_ports_for_model(model_id)


static func _load_catalog_file(model_id: String) -> Array:
	var path := catalog_path(model_id)
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var text := f.get_as_text()
	f.close()
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return (parsed.get("ports", []) as Array).duplicate(true)
	if parsed is Array:
		return (parsed as Array).duplicate(true)
	return []


## Built-in inlet/outlet ports for procedural twins (catalog file may override).
static func default_ports_for_model(model_id: String, dims: Dictionary = {}) -> Array:
	if model_id.is_empty():
		return []
	var w := maxf(float(dims.get("w_m", 1.0)), 0.2)
	var d := maxf(float(dims.get("d_m", w)), 0.2)
	var h := maxf(float(dims.get("h_m", 1.2)), 0.3)
	if model_id == ModelCatalog.GENERIC_TANK_ID:
		var r := maxf(w, d) * 0.5
		return _normalize_ports([
			make_port("inlet", "Inlet",
				Vector3(0.0, h * 0.82, r * 0.92), Vector3(0, 0, 1), "input"),
			make_port("outlet", "Outlet",
				Vector3(0.0, h * 0.22, -r * 0.92), Vector3(0, 0, -1), "output"),
		])
	if model_id == ModelCatalog.GENERIC_BOX_ID:
		return _normalize_ports([
			make_port("inlet", "Inlet",
				Vector3(0.0, h * 0.7, d * 0.5), Vector3(0, 0, 1), "input"),
			make_port("outlet", "Outlet",
				Vector3(0.0, h * 0.3, -d * 0.5), Vector3(0, 0, -1), "output"),
		])
	# HomeBiogas — approximate plugs; player refines in the Connection Ports modal.
	# Outward = socket into free space (hose attaches from this side).
	if model_id == "home_biogas_2":
		return _normalize_ports([
			make_port("funnel", "Food / waste funnel",
				Vector3(0.0, 1.05, 0.15), Vector3(0, 1, 0), "res_in_0",
				"input", "food_waste", "", DEFAULT_APPROACH_M),
			make_port("water_in", "Water inlet",
				Vector3(-0.25, 0.85, 0.2), Vector3(0, 1, 0), "res_in_1",
				"input", "water", "", DEFAULT_APPROACH_M),
			make_port("biogas_tee", "Biogas outlet tee",
				Vector3(0.35, 0.95, 0.0), Vector3(1, 0, 0), "res_out_0",
				"output", "biogas", "", DEFAULT_APPROACH_M),
			make_port("effluent", "Effluent / overflow",
				Vector3(0.0, 0.35, -0.4), Vector3(0, -1, 0), "res_out_1",
				"output", "liquid_fertilizer", "", 0.5),
		])
	return []


static func save_catalog_ports(model_id: String, ports: Array) -> bool:
	if model_id.is_empty():
		return false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CATALOG_DIR))
	var path := catalog_path(model_id)
	var payload := {"version": 2, "model_id": model_id, "ports": _normalize_ports(ports)}
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(payload, "\t"))
	f.close()
	return true


## Resolve ports for a placed prop: instance overrides win, else catalog defaults.
## `prop_record` optional — pass when available to avoid service lookups.
static func resolve_ports_for_prop(main: Node, prop_id: String, model_id: String = "",
		prop_record: Dictionary = {}) -> Array:
	var mid := model_id
	var rec: Dictionary = prop_record
	if rec.is_empty() and not prop_id.is_empty() and main != null:
		rec = _read_prop_record(main, prop_id)
	var dims: Dictionary = {}
	if not rec.is_empty():
		if mid.is_empty():
			mid = str(rec.get("model_id", ""))
		var inst: Array = rec.get("connection_ports", []) as Array
		if not inst.is_empty():
			return _normalize_ports(inst)
		if rec.has("box_spec"):
			dims = rec.get("box_spec", {}) as Dictionary
		elif rec.has("tank_spec"):
			dims = rec.get("tank_spec", {}) as Dictionary
	var from_file := _load_catalog_file(mid)
	if not from_file.is_empty():
		return _normalize_ports(from_file)
	return default_ports_for_model(mid, dims)


## Ports for a graph item (bound prop → instance/catalog, else catalog by model_id).
static func resolve_ports_for_item(item: Dictionary, main: Node) -> Array:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var prop_id := str(specs.get("bound_prop_id", ""))
	var model_id := str(specs.get("model_id", ""))
	if not prop_id.is_empty():
		return resolve_ports_for_prop(main, prop_id, model_id)
	return _normalize_ports(load_catalog_ports(model_id))


## Soft lookup so this class_name stays compilable in headless selftests
## (PlacedPropService references MultiplayerSession autoload).
static func _read_prop_record(main: Node, prop_id: String) -> Dictionary:
	if main == null or prop_id.is_empty():
		return {}
	var script: Variant = load("res://core/placed_models/placed_prop_service.gd")
	if script == null:
		return {}
	if script.has_method("get_prop_record"):
		return script.call("get_prop_record", main, prop_id) as Dictionary
	return {}


static func find_port_for_handle(ports: Array, handle_id: String) -> Dictionary:
	if handle_id.is_empty():
		return {}
	for p: Variant in ports:
		if p is Dictionary and str((p as Dictionary).get("handle_id", "")) == handle_id:
			return (p as Dictionary).duplicate(true)
	return {}


static func port_local_transform(port: Dictionary) -> Transform3D:
	var pos := Vector3(
		float(port.get("x", 0.0)),
		float(port.get("y", 0.0)),
		float(port.get("z", 0.0)))
	var n := Vector3(
		float(port.get("nx", 0.0)),
		float(port.get("ny", 1.0)),
		float(port.get("nz", 0.0)))
	if n.length_squared() < 1e-8:
		n = Vector3.UP
	else:
		n = n.normalized()
	var basis := Basis.looking_at(n, Vector3.UP if absf(n.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT)
	return Transform3D(basis, pos)


static func world_pos_for_port(port: Dictionary, model_root: Node3D) -> Vector3:
	if model_root == null or port.is_empty():
		return Vector3.INF
	var local := Vector3(
		float(port.get("x", 0.0)),
		float(port.get("y", 0.0)),
		float(port.get("z", 0.0)))
	var xf := _node_xform(model_root)
	return xf * local


static func world_normal_for_port(port: Dictionary, model_root: Node3D) -> Vector3:
	return world_outward_for_port(port, model_root)


## Socket outward in world space (into free space along the nozzle).
static func world_outward_for_port(port: Dictionary, model_root: Node3D) -> Vector3:
	if model_root == null or port.is_empty():
		return Vector3.UP
	var n := local_outward(port)
	return (_node_xform(model_root).basis * n).normalized()


static func local_outward(port: Dictionary) -> Vector3:
	var n := Vector3(
		float(port.get("nx", 0.0)),
		float(port.get("ny", 1.0)),
		float(port.get("nz", 0.0)))
	if n.length_squared() < 1e-8:
		return Vector3.UP
	return n.normalized()


static func approach_m_for_port(port: Dictionary) -> float:
	var m := float(port.get("approach_m", DEFAULT_APPROACH_M))
	if m < MIN_APPROACH_M:
		return 0.0
	return clampf(m, MIN_APPROACH_M, 2.0)


## Near-port waypoint: port + outward * approach_m (pipe arrives along −outward).
static func world_approach_point(port: Dictionary, model_root: Node3D) -> Vector3:
	var pos := world_pos_for_port(port, model_root)
	if not is_finite(pos.x):
		return Vector3.INF
	var m := approach_m_for_port(port)
	if m < MIN_APPROACH_M:
		return pos
	return pos + world_outward_for_port(port, model_root) * m


## Prefer global_transform when in-tree; otherwise compose local transforms.
static func _node_xform(node: Node3D) -> Transform3D:
	if node == null:
		return Transform3D.IDENTITY
	if node.is_inside_tree():
		return node.global_transform
	var xf := node.transform
	var p := node.get_parent()
	while p is Node3D:
		xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf


static func make_port(id: String, label: String, local_pos: Vector3, local_normal: Vector3,
		handle_id: String = "", polarity: String = "", resource_kind: String = "",
		node_path: String = "", approach_m: float = DEFAULT_APPROACH_M,
		preferred_conduit_type: String = "",
		preferred_conduit_style: Dictionary = {}) -> Dictionary:
	var n := local_normal
	if n.length_squared() < 1e-8:
		n = Vector3.UP
	else:
		n = n.normalized()
	var am := approach_m if approach_m >= MIN_APPROACH_M else DEFAULT_APPROACH_M
	var out := {
		"id": id if not id.is_empty() else _new_port_id(),
		"label": label,
		"handle_id": handle_id,
		"polarity": polarity,
		"resource_kind": resource_kind,
		"node_path": node_path,
		"x": local_pos.x,
		"y": local_pos.y,
		"z": local_pos.z,
		"nx": n.x,
		"ny": n.y,
		"nz": n.z,
		"approach_m": clampf(am, MIN_APPROACH_M, 2.0),
	}
	if not preferred_conduit_type.is_empty():
		out["preferred_conduit_type"] = preferred_conduit_type
	if not preferred_conduit_style.is_empty():
		out["preferred_conduit_style"] = preferred_conduit_style.duplicate(true)
	return out


static func normalize_ports(ports: Array) -> Array:
	return _normalize_ports(ports)


static func _normalize_ports(ports: Array) -> Array:
	var out: Array = []
	for p: Variant in ports:
		if not (p is Dictionary):
			continue
		var d: Dictionary = p as Dictionary
		var id := str(d.get("id", ""))
		if id.is_empty():
			id = _new_port_id()
		var style: Dictionary = {}
		if d.get("preferred_conduit_style", null) is Dictionary:
			style = (d.get("preferred_conduit_style", {}) as Dictionary).duplicate(true)
		var port := make_port(
			id,
			str(d.get("label", "Port")),
			Vector3(float(d.get("x", 0.0)), float(d.get("y", 0.0)), float(d.get("z", 0.0))),
			Vector3(float(d.get("nx", 0.0)), float(d.get("ny", 1.0)), float(d.get("nz", 0.0))),
			str(d.get("handle_id", "")),
			str(d.get("polarity", "")),
			str(d.get("resource_kind", "")),
			str(d.get("node_path", "")),
			float(d.get("approach_m", DEFAULT_APPROACH_M)),
			str(d.get("preferred_conduit_type", "")),
			style,
		)
		out.append(port)
	return out



static func _new_port_id() -> String:
	return "port_%d" % Time.get_ticks_usec()


## Spawn / refresh Marker3D children under a prop for each port (conduit_anchor group).
static func sync_port_markers(prop: Node3D, ports: Array) -> void:
	if prop == null:
		return
	var model := prop.get_node_or_null("ModelRoot") as Node3D
	var parent: Node3D = model if model != null else prop
	# Clear previous markers.
	for child in parent.get_children():
		if child is Node3D and (child as Node3D).is_in_group(PORT_GROUP):
			child.queue_free()
	for p: Variant in ports:
		if not (p is Dictionary):
			continue
		var d: Dictionary = p as Dictionary
		var marker := Marker3D.new()
		marker.name = "ConnPort_%s" % str(d.get("id", "x"))
		marker.add_to_group(PORT_GROUP)
		marker.add_to_group(ANCHOR_GROUP)
		marker.set_meta("port_id", str(d.get("id", "")))
		marker.set_meta("handle_id", str(d.get("handle_id", "")))
		marker.position = Vector3(
			float(d.get("x", 0.0)),
			float(d.get("y", 0.0)),
			float(d.get("z", 0.0)))
		parent.add_child(marker)


## Look up a port marker under a node by handle_id (or first port marker / conduit_anchor).
static func find_anchor_node(node: Node, handle_id: String = "") -> Node3D:
	if node == null:
		return null
	var model := node.get_node_or_null("ModelRoot") if node is Node3D else null
	var roots: Array = []
	if model != null:
		roots.append(model)
	roots.append(node)
	if not handle_id.is_empty():
		for root: Node in roots:
			for child in root.get_children():
				if child is Node3D and (child as Node3D).is_in_group(PORT_GROUP):
					if str(child.get_meta("handle_id", "")) == handle_id:
						return child as Node3D
	for root2: Node in roots:
		for child2 in root2.get_children():
			if child2 is Node3D and (child2 as Node3D).is_in_group(PORT_GROUP):
				return child2 as Node3D
	for root3: Node in roots:
		for child3 in root3.get_children():
			if child3 is Node3D and (child3 as Node3D).is_in_group(ANCHOR_GROUP):
				return child3 as Node3D
	return null
