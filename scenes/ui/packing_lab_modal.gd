extends CanvasLayer
## Packing Lab — interactive 3D packing ("the Tetris") — PACKING_PLAN.md
## Phase 4 v1. A cutaway container in a SubViewport studio + a manifest
## sidebar: Auto-pack seeds the layout from PackSolver, then the player
## improves it by hand — select an item, aim, R to rotate, click to place;
## click a placed box to take it back out (placement and removal are each
## other's undo). Camera-facing walls hide themselves so the load is always
## readable from any orbit angle.
##
## Validity reuses the SOLVER's own primitives (_overlaps_any/_supported),
## so a hand placement is legal exactly when an auto placement would be —
## the modal can never teach a packing the report would reject.
##
## Opened by the Site Report packing card ("Open Packing Lab…") or the
## --capture=packing harness. v1 scope notes: per-site layout persistence,
## sub-container drill-in (tote interiors), and LIFO unpack-order warnings
## are deferred (see PACKING_PLAN.md Phase 4 status).

signal closed

const MODAL_NAME := "packing_lab"


## Direct entry point (Q / toggle_packing_lab): sweep the site cargo — the
## SAME graph + placed-prop manifest the Site Report card uses — and open the
## Lab preselecting the smallest fitting vehicle. The Site Report path
## (site_report_panel._open_packing_lab) predates this and stays; before the
## hotkey the Lab was three levels deep behind K → packing card → button,
## which is how a whole phase of PACKING_PLAN.md shipped near-undiscoverable.
static func open_site_cargo(tree: SceneTree) -> void:
	if tree == null or tree.root == null:
		return
	var main: Node = tree.get_first_node_in_group("main_scene")
	if main == null:
		main = tree.current_scene
	var lines: Array = []
	var sgv: Node = ServiceLocator.graph()
	if sgv != null and "model" in sgv:
		var model: Object = sgv.get("model")
		if model != null and model.has_method("get_items_in_scope"):
			lines.append_array(CampManifest.from_graph_items(
				GraphNesting.walk_items(model, "root")))
	var loader: Node = main.find_child("TerrainLoader", true, false) \
		if main != null else null
	if loader != null and loader.has_method("placed_prop_records"):
		lines.append_array(CampManifest.from_prop_records(
			loader.call("placed_prop_records")))
	var manifest := CampManifest.merge(lines)
	var units := CampManifest.expand_for_solver(manifest)
	var preselect := "uhaul_15"
	for fr in CampManifest.fleet_report(manifest):
		if bool(((fr as Dictionary)["result"] as Dictionary)["fit"]):
			preselect = str((fr as Dictionary)["id"])
			break
	# Player-entered custom items (gear the game doesn't model) ride along
	# with the site cargo — they are part of what the truck must hold.
	units.append_array(_load_custom_units(_site_token_for(tree.current_scene)))
	var modal: CanvasLayer = load("res://scenes/ui/packing_lab_modal.gd").new()
	tree.root.add_child(modal)
	modal.call("open_with_units", units, "Site cargo (%s)" % UiText.count(units.size(), "unit"),
		preselect)
	modal.connect("closed", Callable(modal, "queue_free"))
const GRID_SNAP := 0.05
const SIDEBAR_W := 360.0
## Per-site hand-packed layouts: one JSON, keyed site|container|kit so the
## same truck at the same site reopens exactly as you left it.
const LAYOUTS_PATH := "user://maps/packing_layouts.json"
## Player-entered custom cargo (PACKING_PLAN.md Phase 7): gear the game does
## not model, per site, so the manifest covers the WHOLE load.
const CUSTOM_ITEMS_PATH := "user://maps/packing_custom_items.json"
## Manifest exports land here by default (LinkageBom guide precedent).
const EXPORT_DIR := "user://exports"

var _restoring := false

var _entry: Dictionary = {}          # ContainerCatalog entry
var _units: Array = []               # all solver items (source manifest)
var _remaining: Array = []           # indices into _units, not yet placed
var _placed: Array = []              # {unit_idx, pos, size, mesh}
var _source_label := ""

var _root: Control = null
var _vp_container: SubViewportContainer = null
var _viewport: SubViewport = null
var _cam: Camera3D = null
var _world_root: Node3D = null
var _container_node: Node3D = null
var _items_node: Node3D = null
var _walls: Array = []               # [{mesh, normal}]
var _container_combo: OptionButton = null
var _kit_combo: OptionButton = null
var _kit_id := ""
var _deliver_btn: Button = null
var _deliver_lbl: Label = null
var _item_list: ItemList = null
var _stats: RichTextLabel = null
var _hint: Label = null

# Manifest export + custom-item entry (Phase 7).
var _save_dialog: FileDialog = null
var _pending_export := ""
var _custom_popup: PanelContainer = null
var _ci_name: LineEdit = null
var _ci_w: SpinBox = null
var _ci_d: SpinBox = null
var _ci_h: SpinBox = null
var _ci_mass: SpinBox = null
var _ci_count: SpinBox = null
var _ci_stackable: CheckBox = null
var _ci_tsu: CheckBox = null

var _yaw := -0.7
var _pitch := -0.55
var _dist := 8.0
var _orbiting := false

var _ghost: MeshInstance3D = null
var _ghost_unit := -1
var _ghost_orients: Array = []
var _ghost_orient := 0
var _ghost_pos := Vector3.ZERO
var _ghost_valid := false


func _ready() -> void:
	layer = UITheme.LAYER_MODAL
	_build_ui()
	visible = false


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Open with pre-expanded solver units (CampManifest.expand_for_solver /
## PackTree.flatten output).
func open_with_units(units: Array, source_label: String,
		container_id := "uhaul_15") -> void:
	_units = units.duplicate()
	_source_label = source_label
	_set_container(container_id)
	_update_delivery_ui()
	visible = true
	CursorController.request_modal(MODAL_NAME, Callable(self, "close"))
	HudLayout.claim_modal(MODAL_NAME)


func close() -> void:
	if not visible:
		return
	visible = false
	CursorController.release_modal(MODAL_NAME)
	HudLayout.release(MODAL_NAME)
	closed.emit()


## Solver-seeded layout (also the harness entry point).
func autopack() -> void:
	_clear_placements()
	var res := PackSolver.solve(_entry, _units)
	for pl in res["placements"]:
		var d := pl as Dictionary
		_place(int(d["item_index"]), d["pos"] as Vector3, d["size"] as Vector3)
	_refresh_lists()
	_save_layout()


# ---------------------------------------------------------------------------
# Container / source switching
# ---------------------------------------------------------------------------

func _set_container(container_id: String) -> void:
	var entry := ContainerCatalog.find(container_id)
	if entry.is_empty():
		entry = ContainerCatalog.find("uhaul_15")
	_entry = entry
	if _container_combo != null:
		for i in _container_combo.item_count:
			if str(_container_combo.get_item_metadata(i)) == str(entry.get("id", "")):
				_container_combo.select(i)
				break
	_clear_placements()
	_rebuild_container_visual()
	_frame_camera()
	_try_restore_layout()
	_refresh_lists()


# ---------------------------------------------------------------------------
# Layout persistence (PACKING_PLAN.md Phase 4 deferral, now landed)
# ---------------------------------------------------------------------------

## Site token from the live map (lat/lon), else the scene name — layouts are
## a property of the site, like every other per-site artifact.
func _layout_key() -> String:
	return "%s|%s|%s" % [_site_token_for(get_tree().current_scene),
		str(_entry.get("id", "")), _kit_id]


static func _site_token_for(scene: Node) -> String:
	if scene == null:
		return "global"
	var lat: Variant = scene.get("latitude")
	var lon: Variant = scene.get("longitude")
	if lat != null and lon != null:
		return "%.4f_%.4f" % [float(lat), float(lon)]
	return str(scene.name)


# ---------------------------------------------------------------------------
# Custom cargo (Phase 7): player-entered items, persisted per site
# ---------------------------------------------------------------------------

static func _load_custom_file() -> Dictionary:
	if not FileAccess.file_exists(CUSTOM_ITEMS_PATH):
		return {"version": 1, "sites": {}}
	var f := FileAccess.open(CUSTOM_ITEMS_PATH, FileAccess.READ)
	if f == null:
		return {"version": 1, "sites": {}}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary and (parsed as Dictionary).has("sites"):
		return parsed as Dictionary
	return {"version": 1, "sites": {}}


## Expanded solver units (one dict per physical box) for a site's saved
## custom items — same shape CampManifest.expand_for_solver emits, plus a
## `custom: true` marker so sessions can tell them apart.
static func _load_custom_units(site: String) -> Array:
	var out: Array = []
	var sites: Dictionary = _load_custom_file().get("sites", {}) as Dictionary
	for entry: Variant in (sites.get(site, []) as Array):
		var e := entry as Dictionary
		var spec := PackedSpec.normalize(e.get("spec", {}) as Dictionary)
		if spec.is_empty():
			continue
		for _i: int in maxi(int(spec.get("count", 1)), 1):
			var unit := spec.duplicate()
			unit["label"] = str(e.get("label", "Custom item"))
			unit["custom"] = true
			unit["count"] = 1
			out.append(unit)
	return out


static func _append_custom_spec(site: String, label: String, spec: Dictionary) -> void:
	var data := _load_custom_file()
	var sites: Dictionary = data.get("sites", {}) as Dictionary
	var list: Array = sites.get(site, []) as Array
	list.append({"label": label, "spec": spec})
	sites[site] = list
	data["sites"] = sites
	DirAccess.make_dir_recursive_absolute("user://maps")
	var f := FileAccess.open(CUSTOM_ITEMS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data, "\t"))
		f.close()


static func _clear_custom_specs(site: String) -> void:
	var data := _load_custom_file()
	var sites: Dictionary = data.get("sites", {}) as Dictionary
	if not sites.has(site):
		return
	sites.erase(site)
	data["sites"] = sites
	var f := FileAccess.open(CUSTOM_ITEMS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data, "\t"))
		f.close()


static func _load_layouts() -> Dictionary:
	if not FileAccess.file_exists(LAYOUTS_PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(LAYOUTS_PATH))
	if parsed is Dictionary and (parsed as Dictionary).get("layouts") is Dictionary:
		return (parsed as Dictionary)["layouts"]
	return {}


func _save_layout() -> void:
	if _restoring:
		return
	var layouts := _load_layouts()
	var rows: Array = []
	for p in _placed:
		var d := p as Dictionary
		var unit: Dictionary = _units[int(d["unit_idx"])]
		var pos: Vector3 = d["pos"]
		var sz: Vector3 = d["size"]
		rows.append({"label": str(unit.get("label", "?")),
			"px": pos.x, "py": pos.y, "pz": pos.z,
			"sx": sz.x, "sy": sz.y, "sz": sz.z})
	layouts[_layout_key()] = rows
	DirAccess.make_dir_recursive_absolute("user://maps")
	var f := FileAccess.open(LAYOUTS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify({"version": 1, "layouts": layouts}, "\t"))


## Replay a saved layout over the CURRENT units: each row claims the first
## remaining unit with a matching label whose orientation set contains the
## saved size, and only lands if the solver's own validity rules still
## agree (manifest changes since the save simply skip the stale rows).
func _try_restore_layout() -> void:
	var rows: Variant = _load_layouts().get(_layout_key())
	if not (rows is Array) or (rows as Array).is_empty():
		return
	_restoring = true
	for row_v in rows as Array:
		if not (row_v is Dictionary):
			continue
		var row := row_v as Dictionary
		var pos := Vector3(float(row.get("px", 0.0)), float(row.get("py", 0.0)),
			float(row.get("pz", 0.0)))
		var size := Vector3(float(row.get("sx", 0.1)), float(row.get("sy", 0.1)),
			float(row.get("sz", 0.1)))
		var label := str(row.get("label", ""))
		for idx in _remaining.duplicate():
			var unit: Dictionary = _units[idx]
			if str(unit.get("label", "?")) != label:
				continue
			var fits := false
			for o: Vector3 in PackSolver._orientations(unit):
				if o.is_equal_approx(size):
					fits = true
					break
			if not fits or not _valid_at(pos, size):
				continue
			_place(idx, pos, size)
			break
	_restoring = false


func _clear_placements() -> void:
	_cancel_ghost()
	for p in _placed:
		var m: MeshInstance3D = (p as Dictionary)["mesh"]
		if is_instance_valid(m):
			m.queue_free()
	_placed.clear()
	_remaining.clear()
	for i in _units.size():
		_remaining.append(i)


func _on_container_selected(idx: int) -> void:
	_set_container(str(_container_combo.get_item_metadata(idx)))


func _on_kit_selected(idx: int) -> void:
	var kit_id := str(_kit_combo.get_item_metadata(idx))
	_kit_id = kit_id
	_update_delivery_ui()
	if kit_id.is_empty():
		return
	var flat := PackTree.flatten(PackDefs.realize(kit_id))
	_units = flat["items"]
	_source_label = str(_kit_combo.get_item_text(idx))
	_clear_placements()
	_refresh_lists()


## Delivery scenario for the current kit selection. Mapped through the
## scenario's own pack_kit_id (no kit selected → the starter camp; a kit
## with NO scenario → "" and Deliver disables). The old fallback silently
## coerced any unmapped kit to starter_camp — selecting the Solar Starter
## Kit and pressing Deliver shipped a camp.
func _scenario_id() -> String:
	if _kit_id.is_empty():
		return "starter_camp"
	return UnpackScenario.scenario_for_kit(_kit_id)


## The crew readout is the emergent-behavior teaser: same goal, two crew
## sizes — the STRATEGY flips from round trips to a bucket brigade purely
## from NpcHaulModel's physical rules, nobody scripted the changeover.
func _update_delivery_ui() -> void:
	if _deliver_lbl == null:
		return
	var sid := _scenario_id()
	var sc := UnpackScenario.find(sid)
	var loader := _find_loader()
	if _deliver_btn != null:
		_deliver_btn.disabled = loader == null or sid.is_empty()
		if loader == null:
			_deliver_btn.tooltip_text = "Needs a generated location map (no TerrainLoader here)"
		elif sid.is_empty():
			_deliver_btn.tooltip_text = "No delivery scenario exists for this kit yet"
		else:
			_deliver_btn.tooltip_text = "Spawns the container + packed crates near you"
	if sid.is_empty():
		_deliver_lbl.text = ""
		return
	var e4 := UnpackScenario.crew_estimate(sid, 20.0, 4)
	var e12 := UnpackScenario.crew_estimate(sid, 20.0, 12)
	if e4.is_empty():
		_deliver_lbl.text = ""
		return
	_deliver_lbl.text = "%s — unload 20 m:\n4 ppl → %s, ~%.0f s · 12 ppl → %s, ~%.0f s" % [
		str(sc.get("label", sid)),
		str(e4["strategy"]).replace("_", " "), float(e4["eta_s"]),
		str(e12["strategy"]).replace("_", " "), float(e12["eta_s"])]


func _find_loader() -> Node:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	var loader := scene.find_child("TerrainLoader", true, false)
	if loader != null and loader.has_method("deliver_packed_kit"):
		return loader
	return null


func _on_deliver() -> void:
	var loader := _find_loader()
	if loader == null or _scenario_id().is_empty():
		return
	var scene := get_tree().current_scene
	var player: Node3D = scene.find_child("Player", true, false) as Node3D
	var px := 0.0
	var pz := 0.0
	var fwd := Vector3.FORWARD
	if player != null:
		px = player.global_position.x
		pz = player.global_position.z
		fwd = -player.global_transform.basis.z
		fwd.y = 0.0
		fwd = fwd.normalized() if fwd.length() > 0.01 else Vector3.FORWARD
	# Container 14 m ahead, door facing back toward the player so the staged
	# crates land between you and the box.
	var cx := px + fwd.x * 14.0
	var cz := pz + fwd.z * 14.0
	var yaw_deg := rad_to_deg(atan2(-fwd.x, -fwd.z))
	var res: Dictionary = loader.call("deliver_packed_kit", _scenario_id(), cx, cz, yaw_deg)
	if res.is_empty():
		_hint.text = "Delivery failed — is this a generated location map?"
		return
	# Same handoff shape as the crew-build queue: close the modal and put
	# the player where the action is — here that's the 3D world (the crates
	# are 14 m in front of them), with the toast noting the crew job.
	var n_crates := (res.get("crate_ids", []) as Array).size()
	close()
	var sgv: Node = ServiceLocator.graph()
	if sgv != null and sgv.has_method("_show_toast"):
		sgv.call("_show_toast",
			"🚚 %s delivered ahead of you — Interact to unpack; the crew's unload job is on the board" % UiText.count(n_crates, "crate"))


# ---------------------------------------------------------------------------
# Placement core (validity = the solver's own rules)
# ---------------------------------------------------------------------------

func _placed_boxes() -> Array:
	var out: Array = []
	for p in _placed:
		var d := p as Dictionary
		var unit: Dictionary = _units[int(d["unit_idx"])]
		out.append({"pos": d["pos"], "size": d["size"],
			"stackable": bool(unit.get("stackable", true)),
			"mass": float(unit.get("mass_kg", 0.0))})
	return out


func _interior_dims() -> Vector3:
	var i: Dictionary = _entry.get("interior", {})
	return Vector3(float(i.get("w_m", 1.0)), float(i.get("h_m", 1.0)),
		float(i.get("l_m", 1.0)))


func _valid_at(pos: Vector3, size: Vector3) -> bool:
	var dims := _interior_dims()
	if pos.x < -0.001 or pos.y < -0.001 or pos.z < -0.001:
		return false
	if pos.x + size.x > dims.x + 0.001 or pos.y + size.y > dims.y + 0.001 \
			or pos.z + size.z > dims.z + 0.001:
		return false
	var boxes := _placed_boxes()
	if PackSolver._overlaps_any(pos, size, boxes):
		return false
	return PackSolver._supported(pos, size, boxes)


func _place(unit_idx: int, pos: Vector3, size: Vector3) -> void:
	var mesh := _make_box_mesh(size, _color_for(str(
		(_units[unit_idx] as Dictionary).get("label", "?"))), false)
	mesh.position = pos + size * 0.5
	_items_node.add_child(mesh)
	_placed.append({"unit_idx": unit_idx, "pos": pos, "size": size, "mesh": mesh})
	_remaining.erase(unit_idx)


func _remove_placed(placed_idx: int) -> void:
	var d := _placed[placed_idx] as Dictionary
	if is_instance_valid(d["mesh"]):
		(d["mesh"] as MeshInstance3D).queue_free()
	_remaining.append(int(d["unit_idx"]))
	_remaining.sort()
	_placed.remove_at(placed_idx)
	_refresh_lists()
	_save_layout()


# ---------------------------------------------------------------------------
# Ghost (manual placement)
# ---------------------------------------------------------------------------

func _begin_ghost(unit_idx: int) -> void:
	_cancel_ghost()
	_ghost_unit = unit_idx
	var unit: Dictionary = _units[unit_idx]
	_ghost_orients = PackSolver._orientations(unit)
	_ghost_orient = 0
	_ghost = _make_box_mesh(_ghost_orients[0] as Vector3, Color(0.3, 1.0, 0.4), true)
	_items_node.add_child(_ghost)
	_update_hint()


func _cancel_ghost() -> void:
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = null
	_ghost_unit = -1
	_update_hint()


func _ghost_size() -> Vector3:
	if _ghost_orients.is_empty():
		return Vector3.ONE * 0.1
	return _ghost_orients[_ghost_orient % _ghost_orients.size()]


func _rotate_ghost() -> void:
	if _ghost_unit < 0:
		return
	_ghost_orient = (_ghost_orient + 1) % _ghost_orients.size()
	var size := _ghost_size()
	_ghost.mesh = _box_mesh_res(size)
	_update_ghost_at_last_mouse()


var _last_mouse := Vector2.ZERO


func _update_ghost(mouse_pos: Vector2) -> void:
	_last_mouse = mouse_pos
	if _ghost_unit < 0 or _cam == null:
		return
	var size := _ghost_size()
	var origin := _cam.project_ray_origin(mouse_pos)
	var dir := _cam.project_ray_normal(mouse_pos)
	# Aim point: ray ∩ floor plane (y=0), clamped into the interior.
	if absf(dir.y) < 0.0001:
		return
	var t := -origin.y / dir.y
	if t <= 0.0:
		return
	var hit := origin + dir * t
	var dims := _interior_dims()
	var px := clampf(snappedf(hit.x - size.x * 0.5, GRID_SNAP), 0.0, maxf(dims.x - size.x, 0.0))
	var pz := clampf(snappedf(hit.z - size.z * 0.5, GRID_SNAP), 0.0, maxf(dims.z - size.z, 0.0))
	# Drop: rest on the highest stack top under the footprint (else floor).
	var py := 0.0
	for b in _placed_boxes():
		var bd := b as Dictionary
		var bp: Vector3 = bd["pos"]
		var bs: Vector3 = bd["size"]
		var ox := minf(px + size.x, bp.x + bs.x) - maxf(px, bp.x)
		var oz := minf(pz + size.z, bp.z + bs.z) - maxf(pz, bp.z)
		if ox > 0.001 and oz > 0.001:
			py = maxf(py, bp.y + bs.y)
	_ghost_pos = Vector3(px, py, pz)
	_ghost_valid = _valid_at(_ghost_pos, size)
	_ghost.position = _ghost_pos + size * 0.5
	_tint_ghost(_ghost_valid)


func _update_ghost_at_last_mouse() -> void:
	_update_ghost(_last_mouse)


func _tint_ghost(valid: bool) -> void:
	if _ghost == null:
		return
	var mat := _ghost.material_override as StandardMaterial3D
	if mat != null:
		mat.albedo_color = Color(0.3, 1.0, 0.4, 0.45) if valid \
			else Color(1.0, 0.25, 0.2, 0.45)


func _commit_ghost() -> void:
	if _ghost_unit < 0 or not _ghost_valid:
		return
	var idx := _ghost_unit
	var size := _ghost_size()
	var pos := _ghost_pos
	_cancel_ghost()
	_place(idx, pos, size)
	_refresh_lists()
	_save_layout()


# ---------------------------------------------------------------------------
# Studio input (orbit / place / remove)
# ---------------------------------------------------------------------------

func _on_studio_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = maxf(_dist * 0.9, 1.5)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = minf(_dist * 1.1, 60.0)
			_update_camera()
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed and _ghost_unit >= 0:
				_cancel_ghost()
				_refresh_lists()
			else:
				_orbiting = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_MIDDLE:
			_orbiting = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			if _ghost_unit >= 0:
				_commit_ghost()
			else:
				var hit := _pick_placed(mb.position)
				if hit >= 0:
					_remove_placed(hit)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _orbiting:
			_yaw -= mm.relative.x * 0.008
			_pitch = clampf(_pitch - mm.relative.y * 0.008, -1.35, -0.05)
			_update_camera()
		elif _ghost_unit >= 0:
			_update_ghost(mm.position)
		else:
			_hover_placed(mm.position)


## R rotates the ghost — handled at the modal level (not the studio's
## gui_input) so it works regardless of which control holds focus, and only
## in one place so it can never double-fire.
func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or _ghost_unit < 0:
		return
	if event is InputEventKey and (event as InputEventKey).pressed \
			and (event as InputEventKey).physical_keycode == KEY_R:
		_rotate_ghost()


## Ray-pick the nearest placed box (slab AABB test in container space).
func _pick_placed(mouse_pos: Vector2) -> int:
	if _cam == null:
		return -1
	var origin := _cam.project_ray_origin(mouse_pos)
	var dir := _cam.project_ray_normal(mouse_pos)
	var best := -1
	var best_t := INF
	for i in _placed.size():
		var d := _placed[i] as Dictionary
		var aabb := AABB(d["pos"] as Vector3, d["size"] as Vector3)
		var hit: Variant = _ray_aabb(origin, dir, aabb)
		if hit != null and float(hit) < best_t:
			best_t = float(hit)
			best = i
	return best


static func _ray_aabb(origin: Vector3, dir: Vector3, aabb: AABB) -> Variant:
	var t_min := 0.0
	var t_max := INF
	for axis in 3:
		var o := origin[axis]
		var dv := dir[axis]
		var lo := aabb.position[axis]
		var hi := lo + aabb.size[axis]
		if absf(dv) < 1e-8:
			if o < lo or o > hi:
				return null
			continue
		var t1 := (lo - o) / dv
		var t2 := (hi - o) / dv
		t_min = maxf(t_min, minf(t1, t2))
		t_max = minf(t_max, maxf(t1, t2))
		if t_min > t_max:
			return null
	return t_min


func _hover_placed(mouse_pos: Vector2) -> void:
	var hit := _pick_placed(mouse_pos)
	if hit >= 0:
		var d := _placed[hit] as Dictionary
		var unit: Dictionary = _units[int(d["unit_idx"])]
		_hint.text = "%s — click to take back out" % str(unit.get("label", "?"))
	else:
		_update_hint()


# ---------------------------------------------------------------------------
# Scene building
# ---------------------------------------------------------------------------

func _rebuild_container_visual() -> void:
	for c in _container_node.get_children():
		c.queue_free()
	_walls.clear()
	var dims := _interior_dims()
	var wall_t := 0.05
	var wall_col := Color(0.45, 0.52, 0.60, 0.35)
	# Floor.
	var floor_mesh := _make_slab(Vector3(dims.x + wall_t * 2.0, wall_t, dims.z + wall_t * 2.0),
		Color(0.35, 0.40, 0.46, 1.0))
	floor_mesh.position = Vector3(dims.x * 0.5, -wall_t * 0.5, dims.z * 0.5)
	_container_node.add_child(floor_mesh)
	# Four walls, each remembering its outward normal for the cutaway hide.
	var specs := [
		[Vector3(dims.x * 0.5, dims.y * 0.5, -wall_t * 0.5),
			Vector3(dims.x, dims.y, wall_t), Vector3.FORWARD],
		[Vector3(dims.x * 0.5, dims.y * 0.5, dims.z + wall_t * 0.5),
			Vector3(dims.x, dims.y, wall_t), Vector3.BACK],
		[Vector3(-wall_t * 0.5, dims.y * 0.5, dims.z * 0.5),
			Vector3(wall_t, dims.y, dims.z), Vector3.LEFT],
		[Vector3(dims.x + wall_t * 0.5, dims.y * 0.5, dims.z * 0.5),
			Vector3(wall_t, dims.y, dims.z), Vector3.RIGHT],
	]
	for s in specs:
		var w := _make_slab(s[1] as Vector3, wall_col)
		w.position = s[0] as Vector3
		_container_node.add_child(w)
		_walls.append({"mesh": w, "normal": s[2] as Vector3})
	# Door aperture marker at the HIGH-z end: the solver fills from z=0 first,
	# so z=0 is the nose and the door is where filling ends — auto-packs then
	# read as loaded nose-first, the way a truck is actually loaded (and the
	# order LIFO unpack warnings will lean on later).
	var door = _entry.get("door")
	if door != null:
		var dd := door as Dictionary
		var dw := float(dd.get("w_m", 0.0))
		var dh := float(dd.get("h_m", 0.0))
		var frame := _make_slab(Vector3(dw, dh, 0.02), Color(1.0, 0.75, 0.25, 0.30))
		frame.position = Vector3(dims.x * 0.5, dh * 0.5, dims.z + 0.02)
		_container_node.add_child(frame)


func _update_camera() -> void:
	if _cam == null:
		return
	var dims := _interior_dims()
	var target := Vector3(dims.x * 0.5, dims.y * 0.35, dims.z * 0.5)
	var rot := Basis(Vector3.UP, _yaw) * Basis(Vector3.RIGHT, _pitch)
	_cam.position = target + (rot * Vector3(0, 0, _dist))
	_cam.look_at(target)
	# Cutaway: hide walls whose outward normal faces the camera.
	var to_cam := (_cam.position - target).normalized()
	for w in _walls:
		var wd := w as Dictionary
		(wd["mesh"] as MeshInstance3D).visible = (wd["normal"] as Vector3).dot(to_cam) < 0.25


func _frame_camera() -> void:
	var dims := _interior_dims()
	_dist = maxf(dims.length() * 1.25, 3.0)
	_update_camera()


static func _box_mesh_res(size: Vector3) -> BoxMesh:
	var bm := BoxMesh.new()
	bm.size = size * 0.985  # slight shrink so adjacent boxes read individually
	return bm


func _make_box_mesh(size: Vector3, col: Color, ghost: bool) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _box_mesh_res(size)
	var mat := StandardMaterial3D.new()
	if ghost:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = Color(col.r, col.g, col.b, 0.45)
	else:
		mat.albedo_color = col
		mat.roughness = 0.8
	mi.material_override = mat
	return mi


static func _make_slab(size: Vector3, col: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	var mat := StandardMaterial3D.new()
	if col.a < 0.999:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = col
	mat.roughness = 0.9
	mi.material_override = mat
	return mi


static func _color_for(label: String) -> Color:
	var h := float(label.hash() % 1000) / 1000.0
	return Color.from_hsv(h, 0.55, 0.85)


# ---------------------------------------------------------------------------
# Sidebar / stats
# ---------------------------------------------------------------------------

func _refresh_lists() -> void:
	if _item_list == null:
		return
	_item_list.clear()
	for idx in _remaining:
		var unit: Dictionary = _units[idx]
		var txt := "%s  (%s)" % [str(unit.get("label", "?")),
			PackedSpec.format_dims_short(unit)]
		_item_list.add_item(txt)
		_item_list.set_item_metadata(_item_list.item_count - 1, idx)
		if not ContainerCatalog.fits_through_door(_entry, unit):
			_item_list.set_item_custom_fg_color(_item_list.item_count - 1,
				UITheme.C_ERROR)
			_item_list.set_item_tooltip(_item_list.item_count - 1,
				"Won't pass this container's door in any orientation")
	_refresh_stats()
	_update_hint()


func _refresh_stats() -> void:
	if _stats == null:
		return
	var dims := _interior_dims()
	var vol := dims.x * dims.y * dims.z
	var placed_vol := 0.0
	var mass := 0.0
	var unknown := 0
	var moment := Vector3.ZERO
	for p in _placed:
		var d := p as Dictionary
		var size: Vector3 = d["size"]
		placed_vol += size.x * size.y * size.z
		var m := float((_units[int(d["unit_idx"])] as Dictionary).get("mass_kg", -1.0))
		if m > 0.0:
			mass += m
			moment += ((d["pos"] as Vector3) + size * 0.5) * m
		else:
			unknown += 1
	var payload := float(_entry.get("payload_kg", 0.0))
	var lines := "[b]%s[/b] — %s\n" % [str(_entry.get("label", "?")), _source_label]
	lines += "Placed [b]%d[/b] / %d · [b]%d%%[/b] full\n" % [
		_placed.size(), _units.size(), roundi(placed_vol / vol * 100.0)]
	lines += "Load [b]%.0f[/b] kg (%.0f lb)" % [mass, mass * 2.20462]
	if payload > 0.0:
		var over := mass > payload
		lines += " / %.0f kg" % payload
		if over:
			lines += "  [color=#%s]⚠ OVER PAYLOAD[/color]" % UITheme.C_ERROR.to_html(false)
	if unknown > 0:
		lines += " · %d unweighed" % unknown
	if mass > 0.0:
		var com := moment / mass
		var frac := clampf(com.z / dims.z, 0.0, 1.0)
		lines += "\nLoad centre [b]%.0f%%[/b] toward the rear" % (frac * 100.0)
		if str(_entry.get("kind", "")) == "trailer":
			# ~10-15% tongue weight ⇒ centre slightly ahead of the axle (mid).
			if frac > 0.55:
				lines += "  [color=#%s]⚠ tail-heavy — sway risk[/color]" \
					% UITheme.C_WARN.to_html(false)
	_stats.text = lines


# ---------------------------------------------------------------------------
# Manifest export (Phase 7) — the printable document a crew loads from
# ---------------------------------------------------------------------------

func _on_export_csv() -> void:
	_begin_export("csv")


func _on_export_json() -> void:
	_begin_export("json")


func _begin_export(kind: String) -> void:
	_pending_export = kind
	DirAccess.make_dir_recursive_absolute(EXPORT_DIR)
	_save_dialog.filters = PackedStringArray(
		["*.csv ; Spreadsheet"] if kind == "csv" else ["*.json ; Manifest JSON"])
	_save_dialog.current_dir = EXPORT_DIR
	_save_dialog.current_file = "packing_manifest_%s.%s" % [
		str(_entry.get("id", "container")), kind]
	_save_dialog.popup_centered()


func _on_save_path_chosen(path: String) -> void:
	var manifest := PackManifestExport.build(_entry, _units, _placed)
	var text := PackManifestExport.to_csv(manifest) if _pending_export == "csv" \
		else JSON.stringify(manifest, "\t")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("Packing manifest export failed: %s" % path)
		return
	f.store_string(text)
	f.close()
	if _hint != null:
		_hint.text = "Manifest saved: %s" % path


# ---------------------------------------------------------------------------
# Custom-item entry (Phase 7) — cover the gear the game doesn't model
# ---------------------------------------------------------------------------

func _on_custom_item_pressed() -> void:
	if _custom_popup != null:
		_custom_popup.visible = not _custom_popup.visible


func _on_add_custom() -> void:
	var label := _ci_name.text.strip_edges()
	if label.is_empty():
		label = "Custom item"
	var mass := float(_ci_mass.value)
	var spec := PackedSpec.normalize({
		"w_m": float(_ci_w.value) / 100.0,
		"d_m": float(_ci_d.value) / 100.0,
		"h_m": float(_ci_h.value) / 100.0,
		"mass_kg": mass if mass > 0.0 else -1.0,
		"form": "crate",
		"stackable": _ci_stackable.button_pressed,
		"this_side_up": _ci_tsu.button_pressed,
		"count": int(_ci_count.value),
		"source": "estimated",
	})
	if spec.is_empty():
		if _hint != null:
			_hint.text = "Custom item needs non-zero dimensions"
		return
	_append_custom_spec(_site_token_for(get_tree().current_scene), label, spec)
	# Join the live session immediately (append-only — _placed references
	# _units by index, so units are never removed mid-session).
	for _i: int in maxi(int(spec.get("count", 1)), 1):
		var unit := spec.duplicate()
		unit["label"] = label
		unit["custom"] = true
		unit["count"] = 1
		_units.append(unit)
		_remaining.append(_units.size() - 1)
	_refresh_lists()
	if _hint != null:
		_hint.text = "Added %s — saved for this site" % label


func _on_clear_custom() -> void:
	_clear_custom_specs(_site_token_for(get_tree().current_scene))
	# Already-placed customs keep their boxes this session (indices stay
	# valid); unplaced ones leave the to-pack list now.
	var keep: Array = []
	for idx: Variant in _remaining:
		if not bool((_units[int(idx)] as Dictionary).get("custom", false)):
			keep.append(idx)
	_remaining = keep
	_refresh_lists()
	if _hint != null:
		_hint.text = "Saved custom items cleared for this site"


func _update_hint() -> void:
	if _hint == null:
		return
	if _ghost_unit >= 0:
		_hint.text = "Aim in the container · LMB place · R rotate · RMB cancel"
	else:
		_hint.text = "Pick an item to place · click a box to take it out · RMB-drag orbit · wheel zoom"


func _on_item_selected(list_idx: int) -> void:
	var unit_idx := int(_item_list.get_item_metadata(list_idx))
	_begin_ghost(unit_idx)


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(UITheme.C_BG, 0.88)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)

	var frame := PanelContainer.new()
	frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	frame.offset_left = 28
	frame.offset_top = 28
	frame.offset_right = -28
	frame.offset_bottom = -28
	frame.add_theme_stylebox_override("panel", UITheme.panel_style())
	_root.add_child(frame)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", UITheme.SPACE_MD)
	frame.add_child(hbox)

	# Studio.
	_vp_container = SubViewportContainer.new()
	_vp_container.stretch = true
	_vp_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vp_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_vp_container.focus_mode = Control.FOCUS_CLICK
	_vp_container.mouse_filter = Control.MOUSE_FILTER_STOP
	_vp_container.gui_input.connect(_on_studio_input)
	hbox.add_child(_vp_container)

	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = false
	_vp_container.add_child(_viewport)

	_world_root = Node3D.new()
	_viewport.add_child(_world_root)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.10, 0.13, 0.18)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.72, 0.75)
	env.ambient_light_energy = 0.7
	var we := WorldEnvironment.new()
	we.environment = env
	_world_root.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48.0, 32.0, 0.0)
	sun.light_energy = 1.1
	_world_root.add_child(sun)
	_container_node = Node3D.new()
	_world_root.add_child(_container_node)
	_items_node = Node3D.new()
	_world_root.add_child(_items_node)
	_cam = Camera3D.new()
	_world_root.add_child(_cam)

	# Sidebar.
	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(SIDEBAR_W, 0)
	side.add_theme_constant_override("separation", UITheme.SPACE_SM)
	hbox.add_child(side)

	var title := Label.new()
	title.text = "📦 Packing Lab"
	title.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	title.add_theme_font_size_override("font_size", UITheme.FONT_LG)
	side.add_child(title)

	side.add_child(_labeled("Container"))
	_container_combo = OptionButton.new()
	_container_combo.focus_mode = Control.FOCUS_NONE
	# Subs are listed too — packing a tote is as real a task as packing a truck.
	for entry in ContainerCatalog.all_containers():
		var e := entry as Dictionary
		_container_combo.add_item("%s %s" % [str(e.get("icon", "")), str(e.get("label", "?"))])
		_container_combo.set_item_metadata(_container_combo.item_count - 1,
			str(e.get("id", "")))
	_container_combo.item_selected.connect(_on_container_selected)
	side.add_child(_container_combo)

	side.add_child(_labeled("Load a kit"))
	_kit_combo = OptionButton.new()
	_kit_combo.focus_mode = Control.FOCUS_NONE
	_kit_combo.add_item("— current cargo —")
	_kit_combo.set_item_metadata(0, "")
	for def in PackDefs.all_defs():
		var dd := def as Dictionary
		_kit_combo.add_item(str(dd.get("label", "?")))
		_kit_combo.set_item_metadata(_kit_combo.item_count - 1, str(dd.get("id", "")))
	_kit_combo.item_selected.connect(_on_kit_selected)
	side.add_child(_kit_combo)

	# Delivery: spawn the scenario's container + packed crates in the world
	# (PACKING_PLAN.md Phase 6) with a crew estimate from NpcHaulModel.
	_deliver_btn = Button.new()
	_deliver_btn.text = "🚚 Deliver kit to site"
	_deliver_btn.focus_mode = Control.FOCUS_NONE
	_deliver_btn.pressed.connect(_on_deliver)
	side.add_child(_deliver_btn)
	_deliver_lbl = Label.new()
	_deliver_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_deliver_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_deliver_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	side.add_child(_deliver_lbl)

	var btns := HBoxContainer.new()
	btns.add_theme_constant_override("separation", UITheme.SPACE_SM)
	side.add_child(btns)
	for spec in [["Auto-pack", "_on_autopack"], ["Empty", "_on_clear"], ["Close", "close"]]:
		var b := Button.new()
		b.text = str(spec[0])
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(Callable(self, str(spec[1])))
		btns.add_child(b)

	# Phase 7 row: the printable manifest + player-entered cargo.
	var btns2 := HBoxContainer.new()
	btns2.add_theme_constant_override("separation", UITheme.SPACE_SM)
	side.add_child(btns2)
	for spec2: Array in [
			["📄 Manifest CSV", "_on_export_csv",
				"Save the load order + totals as a printable spreadsheet"],
			["💾 JSON", "_on_export_json",
				"Save the full manifest data (positions, masses, container)"],
			["➕ Item", "_on_custom_item_pressed",
				"Add a custom item the game doesn't model — saved for this site"]]:
		var b2 := Button.new()
		b2.text = str(spec2[0])
		b2.focus_mode = Control.FOCUS_NONE
		b2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b2.tooltip_text = str(spec2[2])
		b2.pressed.connect(Callable(self, str(spec2[1])))
		btns2.add_child(b2)

	side.add_child(_labeled("Still to pack (click to place)"))
	_item_list = ItemList.new()
	_item_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_item_list.focus_mode = Control.FOCUS_NONE
	_item_list.item_selected.connect(_on_item_selected)
	side.add_child(_item_list)

	_stats = RichTextLabel.new()
	_stats.bbcode_enabled = true
	_stats.fit_content = true
	_stats.scroll_active = false
	_stats.custom_minimum_size = Vector2(0, 96)
	_stats.add_theme_color_override("default_color", UITheme.C_TEXT_S)
	_stats.add_theme_font_size_override("normal_font_size", UITheme.FONT_SM)
	side.add_child(_stats)

	_hint = Label.new()
	_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	side.add_child(_hint)

	_save_dialog = FileDialog.new()
	_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = FileDialog.ACCESS_USERDATA
	_save_dialog.use_native_dialog = false
	_save_dialog.size = Vector2i(760, 520)
	_save_dialog.file_selected.connect(_on_save_path_chosen)
	add_child(_save_dialog)

	_build_custom_popup()


## Small centered form over the studio: name, dims (cm), mass, count, flags.
## Produces an estimated-source PackedSpec; persisted per site so the truck
## manifest covers gear the game does not model.
func _build_custom_popup() -> void:
	_custom_popup = PanelContainer.new()
	_custom_popup.add_theme_stylebox_override("panel", UITheme.panel_style())
	_custom_popup.visible = false
	_custom_popup.set_anchors_preset(Control.PRESET_CENTER)
	_custom_popup.custom_minimum_size = Vector2(330, 0)
	_root.add_child(_custom_popup)

	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_custom_popup.add_child(v)

	var title := Label.new()
	title.text = "➕ Custom item"
	title.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	title.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	v.add_child(title)

	_ci_name = LineEdit.new()
	_ci_name.placeholder_text = "Name (e.g. Cooler, Toolbox)"
	v.add_child(_ci_name)

	var dims := HBoxContainer.new()
	dims.add_theme_constant_override("separation", UITheme.SPACE_SM)
	v.add_child(dims)
	_ci_w = _ci_spin(dims, "W cm", 60.0, 1.0, 1200.0)
	_ci_d = _ci_spin(dims, "D cm", 40.0, 1.0, 1200.0)
	_ci_h = _ci_spin(dims, "H cm", 40.0, 1.0, 1200.0)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", UITheme.SPACE_SM)
	v.add_child(row2)
	_ci_mass = _ci_spin(row2, "Mass kg (0 = ?)", 10.0, 0.0, 2000.0)
	_ci_count = _ci_spin(row2, "Count", 1.0, 1.0, 50.0)

	var flags := HBoxContainer.new()
	flags.add_theme_constant_override("separation", UITheme.SPACE_MD)
	v.add_child(flags)
	_ci_stackable = CheckBox.new()
	_ci_stackable.text = "Stackable"
	_ci_stackable.button_pressed = true
	_ci_stackable.focus_mode = Control.FOCUS_NONE
	flags.add_child(_ci_stackable)
	_ci_tsu = CheckBox.new()
	_ci_tsu.text = "This side up"
	_ci_tsu.focus_mode = Control.FOCUS_NONE
	flags.add_child(_ci_tsu)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", UITheme.SPACE_SM)
	v.add_child(actions)
	for spec: Array in [["Add", "_on_add_custom"],
			["Clear saved", "_on_clear_custom"], ["Close", "_on_custom_item_pressed"]]:
		var b := Button.new()
		b.text = str(spec[0])
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(Callable(self, str(spec[1])))
		actions.add_child(b)


func _ci_spin(parent: Control, label: String, value: float, min_v: float,
		max_v: float) -> SpinBox:
	var box := VBoxContainer.new()
	parent.add_child(box)
	var lbl := Label.new()
	lbl.text = label
	lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(lbl)
	var sb := SpinBox.new()
	sb.min_value = min_v
	sb.max_value = max_v
	sb.step = 1.0
	sb.value = value
	box.add_child(sb)
	return sb


func _on_autopack() -> void:
	autopack()


func _on_clear() -> void:
	_clear_placements()
	_refresh_lists()
	_save_layout()


static func _labeled(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	return l
