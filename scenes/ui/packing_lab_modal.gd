extends CanvasLayer
## Packing Lab — interactive 3D packing ("the Tetris") — PACKING_PLAN.md
## Phase 4, rebuilt on the kit 2026-11-07. The real container stands in a
## StudioViewport with its doors swung back (CargoContainerBuilder's cutaway
## pieces: the roof and whichever walls sit between the camera and the load
## hide themselves), every item is drawn in its PACKED form (PackedFormBuilder:
## crates with battens, strapped bundles, panel stacks, drums), the load
## centre is marked on the floor, and a load sheet of tiles on the right
## reads fill, mass against payload, balance and the axle split live.
##
## Auto-pack seeds the layout from PackSolver, then the player improves it
## by hand — pick an item, aim, R to rotate, click to place; click a placed
## item to take it back out (placement and removal are each other's undo).
## Validity reuses the SOLVER's own primitives (_overlaps_any/_supported),
## so a hand placement is legal exactly when an auto placement would be —
## the modal can never teach a packing the report would reject.
##
## Opened by the Site Report packing card ("Open Packing Lab…"), Q, or the
## --capture=packing harness (which drives open_with_units / autopack /
## _set_container / _yaw + _update_camera / set_load_level / pallet_count /
## export_packing_lists / close — keep those names).

signal closed

const MODAL_NAME := "packing_lab"
const WANT := Vector2(1640, 980)


## Direct entry point (Q / toggle_packing_lab): sweep the site cargo — the
## SAME graph + placed-prop manifest the Site Report card uses — and open the
## Lab preselecting the smallest fitting vehicle.
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
	if _legacy_token_for(tree.current_scene) != _site_token_for(tree.current_scene):
		units.append_array(_load_custom_units(_legacy_token_for(tree.current_scene)))
	var modal: CanvasLayer = load("res://scenes/ui/packing_lab_modal.gd").new()
	tree.root.add_child(modal)
	modal.call("open_with_units", units, "Site cargo (%s)" % UiText.count(units.size(), "unit"),
		preselect)
	modal.connect("closed", Callable(modal, "queue_free"))
const GRID_SNAP := 0.05
## Per-site hand-packed layouts: one JSON, keyed site|container|kit so the
## same truck at the same site reopens exactly as you left it.
const LAYOUTS_PATH := "user://maps/packing_layouts.json"
## Player-entered custom cargo (PACKING_PLAN.md Phase 7): gear the game does
## not model, per site, so the manifest covers the WHOLE load.
const CUSTOM_ITEMS_PATH := "user://maps/packing_custom_items.json"
## Manifest exports land here by default (LinkageBom guide precedent).
const EXPORT_DIR := "user://exports"
## A wall hides when its outward normal points this far toward the camera.
const HIDE_DOT := 0.25
## The roof hides whenever the camera looks down this steeply.
const ROOF_HIDE_PITCH := 0.12
## How far an item's own colour pulls a form's wood / canvas toward it.
const ITEM_TINT := 0.38

var _restoring := false

var _entry: Dictionary = {}          # ContainerCatalog entry
var _units: Array = []               # all solver items (what is being stuffed)
var _raw_units: Array = []           # the source manifest, before palletizing
var _mode := "loose"                 # "loose" | "pallets"
var _pallet_id := "pallet_gma"
var _palletized: Dictionary = {}     # PackPalletizer.palletize result (pallets mode)
var _last_solve: Dictionary = {}     # the last auto-pack's PackSolver result
var _level_combo: OptionButton = null
var _pallet_combo: OptionButton = null
var _remaining: Array = []           # indices into _units, not yet placed
var _placed: Array = []              # {unit_idx, pos, size, mesh (the Node3D)}
var _source_label := ""

var _root: Control = null
var _shell: DesignerShell = null
var _studio: StudioViewport = null
var _host_root: Node3D = null
var _items_node: Node3D = null
var _walls: Array = []               # [{mesh, normal}]
var _roof: Node3D = null
var _com_marker: MeshInstance3D = null
var _hover_label: Label3D = null
var _hover_idx := -1
var _cutaway_mode := "auto"          # auto | open | full
var _container_combo: OptionButton = null
var _host_facts: Label = null
var _kit_combo: OptionButton = null
var _kit_id := ""
var _deliver_btn: Button = null
var _clear_dialog: ConfirmationDialog = null
var _deliver_lbl: Label = null
var _item_list: ItemList = null
var _hint: Label = null
var _warn_box: VBoxContainer = null
var _tiles: Dictionary = {}          # id -> {panel, value, sub, bar}
var _ghost_mat: StandardMaterial3D = null

# Manifest export + custom-item entry (Phase 7).
var _save_dialog: FileDialog = null
var _pending_export := ""
var _custom_popup: Collapsible = null
var _ci_name: LineEdit = null
var _ci_w: SpinBox = null
var _ci_d: SpinBox = null
var _ci_h: SpinBox = null
var _ci_mass: SpinBox = null
var _ci_count: SpinBox = null
var _ci_stackable: CheckBox = null
var _ci_tsu: CheckBox = null

## Orbit (the harness sets _yaw and calls _update_camera).
var _yaw := -0.7
var _pitch := 0.55
var _dist := 8.0
var _open := false

var _ghost: Node3D = null
var _ghost_unit := -1
var _ghost_orients: Array = []
var _ghost_orient := 0
var _ghost_pos := Vector3.ZERO
var _ghost_valid := false
var _last_mouse := Vector2.ZERO


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
	_raw_units = units.duplicate()
	_source_label = source_label
	_rebuild_units(false)
	if not _open:
		_open = true
		visible = true
		HudLayout.claim_modal(MODAL_NAME)
		_shell.open()
	_shell.set_subtitle(source_label)
	_set_container(container_id)
	_update_delivery_ui()


func close() -> void:
	if not _open:
		return
	if _shell.is_open():
		_shell.close()   # emits closed -> _on_shell_closed
	else:
		_on_shell_closed()


func _on_shell_closed() -> void:
	if not _open:
		return
	_open = false
	visible = false
	HudLayout.release(MODAL_NAME)
	closed.emit()


## Solver-seeded layout (also the harness entry point).
func autopack() -> void:
	_clear_placements()
	var res := PackSolver.solve(_entry, _units, solve_opts())
	for pl in res["placements"]:
		var d := pl as Dictionary
		_place(int(d["item_index"]), d["pos"] as Vector3, d["size"] as Vector3)
	_last_solve = res
	_refresh_lists()
	_save_layout()


## Solver options for the current load level and container: a second pass
## for what overflowed, and fork access from the door whenever pallets are
## going in by forklift (a palletized load, or any ISO box).
func solve_opts() -> Dictionary:
	var iso := str(_entry.get("id", "")).begins_with("iso_")
	return {"retry_pass": true, "forks_from_door": _mode == "pallets" or iso}


## Switch between stuffing the loose manifest and palletizing it first.
## Harness entry point too.
func set_load_level(mode: String, pallet_id := "") -> void:
	_mode = "pallets" if mode == "pallets" else "loose"
	if not pallet_id.is_empty():
		_pallet_id = pallet_id
	_sync_level_ui()
	_rebuild_units(true)


func load_level() -> String:
	return _mode


func pallet_count() -> int:
	return (_palletized.get("pallets", []) as Array).size() if _mode == "pallets" else 0


func last_solve() -> Dictionary:
	return _last_solve


## What is placed, for checks: [{label, pos, size}].
func placed_rows() -> Array:
	var out: Array = []
	for p in _placed:
		var d := p as Dictionary
		out.append({"label": str((_units[int(d["unit_idx"])] as Dictionary).get("label", "?")),
			"pos": d["pos"], "size": d["size"]})
	return out


## Which cutaway pieces are hidden right now (for checks).
func hidden_pieces() -> Array:
	var out: Array = []
	for w in _walls:
		var n := (w as Dictionary)["mesh"] as Node3D
		if n != null and not n.visible:
			out.append(n.name)
	if _roof != null and not _roof.visible:
		out.append(_roof.name)
	return out


## `_units` from the source manifest at the current load level.
func _rebuild_units(refresh: bool) -> void:
	_palletized = {}
	if _mode == "pallets":
		var pallet := IntermodalUnits.resolve(_pallet_id)
		_palletized = PackPalletizer.palletize(_raw_units, pallet)
		_units = PackPalletizer.stuffing_items(_raw_units, _palletized)
	else:
		_units = _raw_units.duplicate()
	if refresh:
		_clear_placements()
		_try_restore_layout()
		_refresh_lists()


func _sync_level_ui() -> void:
	if _level_combo != null:
		_level_combo.select(1 if _mode == "pallets" else 0)
	if _pallet_combo != null:
		_pallet_combo.visible = _mode == "pallets"
		for i in _pallet_combo.item_count:
			if str(_pallet_combo.get_item_metadata(i)) == _pallet_id:
				_pallet_combo.select(i)
				break


# ---------------------------------------------------------------------------
# Container / source switching
# ---------------------------------------------------------------------------

func _set_container(container_id: String) -> void:
	var entry := _vehicle_bay_entry(container_id) if container_id.begins_with("vehicle_bay:") \
		else ContainerCatalog.find(container_id)
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
	_refresh_host_facts()
	_update_delivery_ui()


# ---------------------------------------------------------------------------
# Layout persistence (PACKING_PLAN.md Phase 4 deferral, now landed)
# ---------------------------------------------------------------------------

## Site token from the live map (lat/lon), else the scene name — layouts are
## a property of the site, like every other per-site artifact.
func _layout_key() -> String:
	var key := "%s|%s|%s" % [_site_token_for(get_tree().current_scene),
		str(_entry.get("id", "")), _kit_id]
	if _mode == "pallets":
		key += "|pal:" + _pallet_id
	return key


static func _site_token_for(scene: Node) -> String:
	if scene == null:
		return "global"
	var lat: Variant = scene.get("latitude")
	var lon: Variant = scene.get("longitude")
	if lat != null and lon != null:
		return "%s_%s" % [CoordToken.token(float(lat)), CoordToken.token(float(lon))]
	return str(scene.name)


## The key layouts and custom items were saved under before CoordToken
## (read, never written).
static func _legacy_token_for(scene: Node) -> String:
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
	var all := _load_layouts()
	var rows: Variant = all.get(_layout_key())
	if rows == null:
		rows = all.get(_layout_key().replace(_site_token_for(get_tree().current_scene),
			_legacy_token_for(get_tree().current_scene)))
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
	_set_hover(-1)
	for p in _placed:
		var m: Node3D = (p as Dictionary)["mesh"]
		if is_instance_valid(m):
			m.queue_free()
	_placed.clear()
	_last_solve = {}
	_remaining.clear()
	for i in _units.size():
		_remaining.append(i)


func _on_container_selected(idx: int) -> void:
	_set_container(str(_container_combo.get_item_metadata(idx)))


func _refill_container_combo() -> void:
	if _container_combo == null:
		return
	var cur := str(_entry.get("id", ""))
	_container_combo.clear()
	for entry in ContainerCatalog.all_with_intermodal():
		var e := entry as Dictionary
		var id := str(e.get("id", ""))
		_container_combo.add_item("%s %s" % [str(e.get("icon", "")), str(e.get("label", id))])
		_container_combo.set_item_metadata(_container_combo.item_count - 1, id)
		if id == cur:
			_container_combo.select(_container_combo.item_count - 1)
	# The placed living vehicles' cargo bays ("load my van").
	for vb in _vehicle_bays():
		var e2: Dictionary = vb
		_container_combo.add_item("%s %s" % [str(e2.get("icon", "")), str(e2.get("label", ""))])
		_container_combo.set_item_metadata(_container_combo.item_count - 1, str(e2["id"]))
		if str(e2["id"]) == cur:
			_container_combo.select(_container_combo.item_count - 1)


## Every placed living vehicle's cargo bay as a container entry
## (id "vehicle_bay:<prop id>").
func _vehicle_bays() -> Array:
	var out: Array = []
	var loader := _find_loader()
	if loader == null or not loader.has_method("placed_prop_records"):
		return out
	for r in loader.call("placed_prop_records"):
		var rec: Dictionary = r
		if not VehicleBuilder.handles(str(rec.get("model_id", ""))):
			continue
		var b := VehicleCargo.bay(VehicleDesign.solve(VehicleBuilder.spec_for_record(rec)))
		if b.is_empty():
			continue
		b["id"] = "vehicle_bay:%s" % str(rec.get("id", ""))
		out.append(b)
	return out


func _vehicle_bay_entry(id: String) -> Dictionary:
	for b in _vehicle_bays():
		if str((b as Dictionary)["id"]) == id:
			return b
	return {}


func _on_units_pressed() -> void:
	var script: GDScript = load("res://scenes/ui/intermodal_unit_modal.gd")
	var m: Node = script.call("open", get_tree(), str(_entry.get("id", "")))
	if m != null and m.has_signal("closed"):
		m.connect("closed", _refill_container_combo)


func _on_kit_selected(idx: int) -> void:
	var kit_id := str(_kit_combo.get_item_metadata(idx))
	_kit_id = kit_id
	_update_delivery_ui()
	if kit_id.is_empty():
		return
	var flat := PackTree.flatten(PackDefs.realize(kit_id))
	_raw_units = (flat["items"] as Array).duplicate()
	_source_label = str(_kit_combo.get_item_text(idx))
	_shell.set_subtitle(_source_label)
	_rebuild_units(true)


## Delivery scenario for the current kit selection. Mapped through the
## scenario's own pack_kit_id (no kit selected → the starter camp; a kit
## with NO scenario → "" and Deliver disables).
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
	var vid := _bay_vehicle_id()
	if _deliver_btn != null:
		_deliver_btn.disabled = loader == null or sid.is_empty()
		_deliver_btn.text = "Load into %s" % _bay_vehicle_name(vid) if not vid.is_empty() else "Deliver kit to site"
		if loader == null:
			_deliver_btn.tooltip_text = "Needs a generated location map (no TerrainLoader here)"
		elif sid.is_empty():
			_deliver_btn.tooltip_text = "No delivery scenario exists for this kit yet"
		elif not vid.is_empty():
			_deliver_btn.tooltip_text = "Load the kit's crates into this vehicle's cargo bay; the crew unloads them when it is parked"
		else:
			_deliver_btn.tooltip_text = "A container with the kit's crates arrives 14 m ahead of you; the crew unloads it"
	if sid.is_empty():
		_deliver_lbl.text = ""
		return
	var e4 := UnpackScenario.crew_estimate(sid, 20.0, 4)
	var e12 := UnpackScenario.crew_estimate(sid, 20.0, 12)
	if e4.is_empty():
		_deliver_lbl.text = ""
		return
	_deliver_lbl.text = "%s — unloading over 20 m\n4 people: %s, about %.0f s\n12 people: %s, about %.0f s" % [
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


## The placed vehicle whose bay is the selected host ("" = a container).
func _bay_vehicle_id() -> String:
	var id := str(_entry.get("id", ""))
	return id.trim_prefix("vehicle_bay:") if id.begins_with("vehicle_bay:") else ""


func _bay_vehicle_name(vid: String) -> String:
	var loader := _find_loader()
	var rec: Dictionary = loader.call("get_prop_record", vid) if loader != null and loader.has_method("get_prop_record") else {}
	return str(VehicleBuilder.spec_for_record(rec).get("name", "the vehicle")) if not rec.is_empty() else "the vehicle"


func _on_deliver() -> void:
	var loader := _find_loader()
	if loader == null or _scenario_id().is_empty():
		return
	var vid := _bay_vehicle_id()
	if not vid.is_empty():
		# Load: the crates go into this vehicle's bay. The Lab stays open.
		var vres: Dictionary = loader.call("deliver_kit_in_vehicle", _scenario_id(), vid)
		if vres.is_empty():
			_set_hint("Could not load it — does this vehicle have a cargo bay?")
			return
		var nv := (vres.get("crate_ids", []) as Array).size()
		_toast("Loaded %s into %s — the crew unloads it when it is parked" % [UiText.count(nv, "crate"), _bay_vehicle_name(vid)])
		_set_hint("Loaded %s into %s" % [UiText.count(nv, "crate"), _bay_vehicle_name(vid)])
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
		_set_hint("Delivery failed — is this a generated location map?")
		return
	var n_crates := (res.get("crate_ids", []) as Array).size()
	_toast("%s delivered ahead of you — the crew unloads them; Interact on a crate unpacks it" % UiText.count(n_crates, "crate"))
	_set_hint("Delivered %s 14 m ahead of you" % UiText.count(n_crates, "crate"))


func _toast(text: String) -> void:
	var sgv: Node = ServiceLocator.graph()
	if sgv != null and sgv.has_method("_show_toast"):
		sgv.call("_show_toast", text)


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
	var node := _make_item_node(_units[unit_idx] as Dictionary, size, false)
	node.position = pos + Vector3(size.x * 0.5, 0.0, size.z * 0.5)
	_items_node.add_child(node)
	_placed.append({"unit_idx": unit_idx, "pos": pos, "size": size, "mesh": node})
	_remaining.erase(unit_idx)


func _remove_placed(placed_idx: int) -> void:
	_set_hover(-1)
	var d := _placed[placed_idx] as Dictionary
	if is_instance_valid(d["mesh"]):
		(d["mesh"] as Node3D).queue_free()
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
	_set_hover(-1)
	_ghost_unit = unit_idx
	var unit: Dictionary = _units[unit_idx]
	_ghost_orients = PackSolver._orientations(unit)
	_ghost_orient = 0
	_ghost = _make_item_node(unit, _ghost_orients[0] as Vector3, true)
	_items_node.add_child(_ghost)
	_ghost_valid = false
	_tint_ghost(false)
	_shell.set_mode("Placing %s · aim in the box · click to set it down · R turns · right-click cancels" % str(unit.get("label", "?")))
	_update_hint()


func _cancel_ghost() -> void:
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = null
	_ghost_unit = -1
	if _shell != null:
		_shell.set_mode("")
	_update_hint()


func _ghost_size() -> Vector3:
	if _ghost_orients.is_empty():
		return Vector3.ONE * 0.1
	return _ghost_orients[_ghost_orient % _ghost_orients.size()]


func _rotate_ghost() -> void:
	if _ghost_unit < 0:
		return
	_ghost_orient = (_ghost_orient + 1) % _ghost_orients.size()
	var unit: Dictionary = _units[_ghost_unit]
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = _make_item_node(unit, _ghost_size(), true)
	_items_node.add_child(_ghost)
	_update_ghost(_last_mouse)


func _update_ghost(mouse_pos: Vector2) -> void:
	_last_mouse = mouse_pos
	if _ghost_unit < 0 or _studio == null or _ghost == null:
		return
	var size := _ghost_size()
	var ray := _studio.pick_ray(mouse_pos)
	if ray.is_empty():
		return
	var origin: Vector3 = ray["origin"]
	var dir: Vector3 = ray["dir"]
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
	_ghost.position = _ghost_pos + Vector3(size.x * 0.5, 0.0, size.z * 0.5)
	_tint_ghost(_ghost_valid)


func _tint_ghost(valid: bool) -> void:
	if _ghost_mat != null:
		_ghost_mat.albedo_color = Color(0.3, 1.0, 0.45, 0.5) if valid \
			else Color(1.0, 0.25, 0.2, 0.5)


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
	# The next of the same kind, so a row of crates goes in click by click.
	for n in _remaining:
		if str((_units[int(n)] as Dictionary).get("label", "")) == str((_units[idx] as Dictionary).get("label", "?")):
			_begin_ghost(int(n))
			_update_ghost(_last_mouse)
			break


# ---------------------------------------------------------------------------
# Studio input (orbit comes from the kit; place / pick / hover here)
# ---------------------------------------------------------------------------

## Before the studio's own orbit: the ghost follows every motion event (the
## kit's `hovered` fires every fourth), a right-click puts a ghost down.
func _studio_hook(e: InputEvent) -> bool:
	if e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		if _ghost_unit >= 0:
			_update_ghost(mm.position)
		else:
			_hover_placed(mm.position)
		return false
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and _ghost_unit >= 0:
			_cancel_ghost()
			_refresh_lists()
			return true
	return false


func _on_studio_clicked(pos: Vector2, button: int) -> void:
	if button != MOUSE_BUTTON_LEFT:
		return
	if _ghost_unit >= 0:
		_update_ghost(pos)
		_commit_ghost()
		return
	var hit := _pick_placed(pos)
	if hit >= 0:
		_remove_placed(hit)


## R rotates the ghost — handled at the modal level (not the studio's
## gui_input) so it works regardless of which control holds focus, and only
## in one place so it can never double-fire.
func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or _ghost_unit < 0:
		return
	if event is InputEventKey and (event as InputEventKey).pressed \
			and (event as InputEventKey).physical_keycode == KEY_R:
		_rotate_ghost()
		get_viewport().set_input_as_handled()


## Ray-pick the nearest placed box (slab AABB test in container space).
func _pick_placed(mouse_pos: Vector2) -> int:
	var ray := _studio.pick_ray(mouse_pos) if _studio != null else {}
	if ray.is_empty():
		return -1
	var origin: Vector3 = ray["origin"]
	var dir: Vector3 = ray["dir"]
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
	_set_hover(_pick_placed(mouse_pos))


## The hovered item lights up and carries its name; the hint says what a
## click does.
func _set_hover(idx: int) -> void:
	if idx == _hover_idx:
		return
	if _hover_idx >= 0 and _hover_idx < _placed.size():
		_glow(((_placed[_hover_idx] as Dictionary)["mesh"]) as Node3D, false)
	_hover_idx = idx
	if idx >= 0 and idx < _placed.size():
		var d := _placed[idx] as Dictionary
		var unit: Dictionary = _units[int(d["unit_idx"])]
		var node := d["mesh"] as Node3D
		_glow(node, true)
		if _hover_label != null:
			var size: Vector3 = d["size"]
			_hover_label.visible = true
			_hover_label.position = (d["pos"] as Vector3) + Vector3(size.x * 0.5, size.y + 0.18, size.z * 0.5)
			var m := float(unit.get("mass_kg", -1.0))
			_hover_label.text = "%s\n%s%s" % [str(unit.get("label", "?")),
				PackedSpec.format_dims_short(unit),
				(" · %s" % UiText.num(m, "kg", 3)) if m > 0.0 else ""]
		_set_hint("%s — click to take it back out" % str(unit.get("label", "?")))
	else:
		if _hover_label != null:
			_hover_label.visible = false
		_update_hint()


static func _glow(node: Node3D, on: bool) -> void:
	if node == null or not is_instance_valid(node):
		return
	for m in node.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var mat := mi.material_override as StandardMaterial3D
		if mat == null:
			continue
		mat.emission_enabled = on
		if on:
			mat.emission = Color(0.9, 0.95, 1.0)
			mat.emission_energy_multiplier = 0.22


# ---------------------------------------------------------------------------
# Scene building
# ---------------------------------------------------------------------------

func _is_iso_container() -> bool:
	return str(_entry.get("kind", "")) == "container" \
		or str(_entry.get("id", "")).begins_with("iso_") \
		or str(_entry.get("family", "")) == "container"


func _rebuild_container_visual() -> void:
	for c in _host_root.get_children():
		_host_root.remove_child(c)
		c.queue_free()
	_walls.clear()
	_roof = null
	var dims := _interior_dims()
	if _is_iso_container() and _entry.has("exterior"):
		_build_iso_host(dims)
	else:
		_build_generic_host(dims)
	# The load centre, on the floor.
	_com_marker = MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.14
	cm.bottom_radius = 0.14
	cm.height = 0.012
	cm.radial_segments = 24
	_com_marker.mesh = cm
	var cmat := StandardMaterial3D.new()
	cmat.albedo_color = UITheme.C_AMBER
	cmat.emission_enabled = true
	cmat.emission = UITheme.C_AMBER
	cmat.emission_energy_multiplier = 0.6
	_com_marker.material_override = cmat
	_com_marker.visible = false
	_host_root.add_child(_com_marker)
	# The hover tag.
	_hover_label = Label3D.new()
	_hover_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_hover_label.no_depth_test = true
	_hover_label.font_size = 40
	_hover_label.pixel_size = 0.0035
	_hover_label.outline_size = 10
	_hover_label.modulate = UITheme.C_TEXT
	_hover_label.visible = false
	_host_root.add_child(_hover_label)
	_apply_cutaway()


## The real ISO box, doors folded back, in six cutaway pieces; its load
## floor on the solver's y = 0, its front inside face on z = 0.
func _build_iso_host(dims: Vector3) -> void:
	var paint: Variant = _entry.get("paint", (_entry.get("params", {}) as Dictionary).get("paint",
		CargoContainerBuilder.DEFAULT_PAINT))
	var host := CargoContainerBuilder.build_from_entry(_entry, "Host",
		{"cutaway": true, "doors_open_deg": CargoContainerBuilder.DOORS_FOLDED_DEG, "paint": paint})
	var ext: Dictionary = _entry.get("exterior", {})
	var floor_y := float(host.get_meta("floor_y", 0.168))
	var z0 := float(host.get_meta("interior_z0", -float(ext.get("l_m", 6.058)) * 0.5))
	host.position = Vector3(dims.x * 0.5, -floor_y, -z0)
	_host_root.add_child(host)
	for spec in [["WallL", Vector3.LEFT], ["WallR", Vector3.RIGHT], ["WallFront", Vector3.FORWARD]]:
		var n := host.get_node_or_null(str(spec[0])) as Node3D
		if n != null:
			_walls.append({"mesh": n, "normal": spec[1] as Vector3})
	_roof = host.get_node_or_null("Roof") as Node3D
	_hide_studio_ground_under(dims, -floor_y)


## Trucks, trailers, pallets and bins: a plywood deck, a steel edge frame,
## frosted walls that hide toward the camera, an amber door frame where the
## load comes out; a pallet carries its own deck underneath.
func _build_generic_host(dims: Vector3) -> void:
	var wall_t := 0.04
	var kind := str(_entry.get("kind", ""))
	var is_pallet := bool(_entry.get("pallet", false)) or str(_entry.get("family", "")) == "pallet"
	var open_top := _entry.get("door") == null
	if is_pallet:
		var unit := IntermodalUnitBuilder.build_node({"template": str(_entry.get("template", "pallet_gma"))}, "Pallet")
		var deck := float(_entry.get("deck_h_m", 0.144))
		unit.position = Vector3(dims.x * 0.5, -deck, dims.z * 0.5)
		_host_root.add_child(unit)
	else:
		var floor_mesh := _slab(Vector3(dims.x + wall_t * 2.0, wall_t, dims.z + wall_t * 2.0),
			StructureMaterials.make(StructureMaterials.Kind.PLYWOOD, Color(0.50, 0.40, 0.27)))
		floor_mesh.position = Vector3(dims.x * 0.5, -wall_t * 0.5, dims.z * 0.5)
		_host_root.add_child(floor_mesh)
	# Walls (none on a pallet; a bin's are its own height).
	var wall_h := dims.y
	var wall_mat := StandardMaterial3D.new()
	wall_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	wall_mat.albedo_color = Color(0.70, 0.76, 0.84, 0.16)
	wall_mat.roughness = 0.6
	wall_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var frame_mat := StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, Color(0.55, 0.58, 0.62))
	var specs := [
		[Vector3(dims.x * 0.5, wall_h * 0.5, -wall_t * 0.5), Vector3(dims.x, wall_h, wall_t), Vector3.FORWARD],
		[Vector3(dims.x * 0.5, wall_h * 0.5, dims.z + wall_t * 0.5), Vector3(dims.x, wall_h, wall_t), Vector3.BACK],
		[Vector3(-wall_t * 0.5, wall_h * 0.5, dims.z * 0.5), Vector3(wall_t, wall_h, dims.z), Vector3.LEFT],
		[Vector3(dims.x + wall_t * 0.5, wall_h * 0.5, dims.z * 0.5), Vector3(wall_t, wall_h, dims.z), Vector3.RIGHT],
	]
	if not is_pallet:
		for s in specs:
			var w := _slab(s[1] as Vector3, wall_mat)
			w.position = s[0] as Vector3
			_host_root.add_child(w)
			_walls.append({"mesh": w, "normal": s[2] as Vector3})
	# Edge frame: the four uprights and the top rails (a load-height line on
	# a pallet), so the volume reads with its walls hidden.
	var post := 0.05
	var frame := Node3D.new()
	frame.name = "Frame"
	_host_root.add_child(frame)
	for sx in [0.0, 1.0]:
		for sz in [0.0, 1.0]:
			var p := _slab(Vector3(post, wall_h, post), frame_mat)
			p.position = Vector3(float(sx) * dims.x + (float(sx) * 2.0 - 1.0) * post * 0.5, wall_h * 0.5,
				float(sz) * dims.z + (float(sz) * 2.0 - 1.0) * post * 0.5)
			frame.add_child(p)
	for sz in [0.0, 1.0]:
		var r := _slab(Vector3(dims.x + post * 2.0, post, post), frame_mat)
		r.position = Vector3(dims.x * 0.5, wall_h + post * 0.5, float(sz) * dims.z + (float(sz) * 2.0 - 1.0) * post * 0.5)
		frame.add_child(r)
	for sx in [0.0, 1.0]:
		var r2 := _slab(Vector3(post, post, dims.z), frame_mat)
		r2.position = Vector3(float(sx) * dims.x + (float(sx) * 2.0 - 1.0) * post * 0.5, wall_h + post * 0.5, dims.z * 0.5)
		frame.add_child(r2)
	# A truck's cab at the nose, so the load reads front to back.
	if kind == "vehicle":
		var cab := _slab(Vector3(dims.x * 0.96, wall_h * 0.72, 1.5),
			StructureMaterials.make(StructureMaterials.Kind.PAINTED_METAL, Color(0.86, 0.86, 0.84)))
		cab.position = Vector3(dims.x * 0.5, wall_h * 0.36, -0.9 - wall_t)
		_host_root.add_child(cab)
		var glass := _slab(Vector3(dims.x * 0.9, wall_h * 0.28, 0.03),
			StructureMaterials.make(StructureMaterials.Kind.GLAZING, Color(0.2, 0.3, 0.4)))
		glass.position = Vector3(dims.x * 0.5, wall_h * 0.52, -1.66 - wall_t)
		_host_root.add_child(glass)
	elif kind == "trailer":
		var tongue := _slab(Vector3(0.1, 0.1, 1.4), frame_mat)
		tongue.position = Vector3(dims.x * 0.5, -0.1, -0.7 - wall_t)
		_host_root.add_child(tongue)
	# Door aperture marker at the HIGH-z end: the solver fills from z=0 first,
	# so z=0 is the nose and the door is where filling ends.
	var door = _entry.get("door")
	if door != null and not open_top:
		var dd := door as Dictionary
		var dw := float(dd.get("w_m", 0.0))
		var dh := float(dd.get("h_m", 0.0))
		var dmat := StandardMaterial3D.new()
		dmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		dmat.albedo_color = Color(UITheme.C_AMBER, 0.22)
		dmat.emission_enabled = true
		dmat.emission = UITheme.C_AMBER
		dmat.emission_energy_multiplier = 0.3
		var fr := _slab(Vector3(dw, dh, 0.02), dmat)
		fr.position = Vector3(dims.x * 0.5, dh * 0.5, dims.z + 0.03)
		_host_root.add_child(fr)
	_hide_studio_ground_under(dims, -0.05)


## The studio's matte ground sits just under the host's floor.
func _hide_studio_ground_under(_dims: Vector3, floor_y: float) -> void:
	if _studio != null and _studio.ground != null:
		_studio.ground.position.y = floor_y - 0.002


## Hide the roof and whichever walls stand between the camera and the load.
func _apply_cutaway() -> void:
	if _studio == null or _studio.camera == null:
		return
	var to_cam := (_studio.camera.global_position - _studio.target).normalized()
	for w in _walls:
		var wd := w as Dictionary
		var n := wd["mesh"] as Node3D
		if n == null or not is_instance_valid(n):
			continue
		match _cutaway_mode:
			"full":
				n.visible = true
			"open":
				n.visible = true
			_:
				n.visible = (wd["normal"] as Vector3).dot(to_cam) < HIDE_DOT
	if _roof != null and is_instance_valid(_roof):
		_roof.visible = _cutaway_mode == "full" or (_cutaway_mode == "auto" and _studio.pitch < ROOF_HIDE_PITCH)


func _update_camera() -> void:
	if _studio == null:
		return
	var dims := _interior_dims()
	_studio.target = Vector3(dims.x * 0.5, dims.y * 0.35, dims.z * 0.5)
	_studio.set_orbit(_yaw, _pitch, _dist)
	_apply_cutaway()


func _on_view_changed() -> void:
	_yaw = _studio.yaw
	_pitch = _studio.pitch
	_dist = _studio.dist
	_apply_cutaway()


func _frame_camera() -> void:
	var dims := _interior_dims()
	_dist = maxf(dims.length() * 1.25, 3.0)
	_update_camera()


## An item in its packed form (crate / bundle / panel stack / tank / pallet)
## at exactly the placed size, tinted toward its own colour so like items
## read as a set; a ghost is the same shape in one translucent material.
func _make_item_node(unit: Dictionary, size: Vector3, ghost: bool) -> Node3D:
	var spec := unit.duplicate()
	spec["w_m"] = size.x
	spec["h_m"] = size.y
	spec["d_m"] = size.z
	var node := PackedFormBuilder.build_node(spec, "Item")
	if ghost:
		if _ghost_mat == null:
			_ghost_mat = StandardMaterial3D.new()
			_ghost_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			_ghost_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			_ghost_mat.albedo_color = Color(0.3, 1.0, 0.45, 0.5)
		for m in node.find_children("*", "MeshInstance3D", true, false):
			(m as MeshInstance3D).material_override = _ghost_mat
		return node
	var tint := _color_for(str(unit.get("label", "?")))
	for m in node.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		var mat := mi.material_override as StandardMaterial3D
		if mat == null:
			continue
		var own := mat.duplicate() as StandardMaterial3D
		# Straps and battens keep their dark tone; the body takes the tint.
		if own.albedo_color.v > 0.3:
			own.albedo_color = own.albedo_color.lerp(tint, ITEM_TINT)
		mi.material_override = own
	return node


static func _slab(size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
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
	if _units.is_empty():
		_item_list.add_item("Nothing on site is packable yet — place a kit or add an item")
		_item_list.set_item_disabled(0, true)
		_item_list.set_item_selectable(0, false)
	elif _remaining.is_empty():
		_item_list.add_item("Everything is packed")
		_item_list.set_item_disabled(0, true)
		_item_list.set_item_selectable(0, false)
	# Like items grouped: one row per label with its count.
	var groups: Dictionary = {}
	var order: Array = []
	for idx in _remaining:
		var unit: Dictionary = _units[idx]
		var key := str(unit.get("label", "?"))
		if not groups.has(key):
			groups[key] = {"first": idx, "n": 0, "unit": unit}
			order.append(key)
		(groups[key] as Dictionary)["n"] = int((groups[key] as Dictionary)["n"]) + 1
	for key in order:
		var g: Dictionary = groups[key]
		var unit: Dictionary = g["unit"]
		var n := int(g["n"])
		var txt := "%s%s  ·  %s" % [key, ("  ×%d" % n) if n > 1 else "",
			PackedSpec.format_dims_short(unit)]
		var m := float(unit.get("mass_kg", -1.0))
		if m > 0.0:
			txt += "  ·  %s" % UiText.num(m, "kg", 3)
		_item_list.add_item(txt)
		var row := _item_list.item_count - 1
		_item_list.set_item_metadata(row, int(g["first"]))
		_item_list.set_item_icon(row, UiIcons.icon(_icon_for_form(str(unit.get("form", "crate"))), 16))
		_item_list.set_item_icon_modulate(row, _color_for(key))
		if not ContainerCatalog.fits_through_door(_entry, unit):
			_item_list.set_item_custom_fg_color(row, UITheme.C_ERROR)
			_item_list.set_item_tooltip(row, "Won't pass this container's door in any orientation")
	_refresh_stats()
	_update_hint()


static func _icon_for_form(form: String) -> String:
	match form:
		"tank":
			return "droplet"
		"bundle", "roll", "folded":
			return "layers"
		"panel_stack":
			return "layout-grid"
		"pallet":
			return "box"
	return "package"


func _refresh_stats() -> void:
	if _tiles.is_empty():
		return
	var dims := _interior_dims()
	var vol := maxf(dims.x * dims.y * dims.z, 1e-6)
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
	var fill := placed_vol / vol
	_set_tile("fill", "%d%%" % roundi(fill * 100.0),
		"%s of %s placed" % [_placed.size(), _units.size()], fill,
		UITheme.C_PRIMARY if _remaining.is_empty() or _units.is_empty() else UITheme.C_AMBER)
	var over := payload > 0.0 and mass > payload
	var load_sub := "%s lb" % UiText.thousands(roundi(mass * 2.20462))
	if payload > 0.0:
		load_sub += " · payload %s" % UiText.num(payload, "kg", 3)
	if unknown > 0:
		load_sub += " · %s unweighed" % UiText.count(unknown, "item")
	_set_tile("load", UiText.num(mass, "kg", 3), load_sub,
		clampf(mass / payload, 0.0, 1.0) if payload > 0.0 else 0.0,
		UITheme.C_ERROR if over else (UITheme.C_AMBER if payload > 0.0 and mass > payload * 0.85 else UITheme.C_GREEN))
	# Warnings.
	for c in _warn_box.get_children():
		_warn_box.remove_child(c)
		c.queue_free()
	if over:
		_add_warning(UITheme.C_ERROR, "Over the payload by %s" % UiText.num(mass - payload, "kg", 3))
	if mass > 0.0:
		var com := moment / mass
		var frac := clampf(com.z / dims.z, 0.0, 1.0)
		var side := clampf(com.x / maxf(dims.x, 0.001), 0.0, 1.0)
		_set_tile("com", "%d%%" % roundi(frac * 100.0), "toward the door end", frac,
			UITheme.C_WARN if str(_entry.get("kind", "")) == "trailer" and frac > 0.55 else UITheme.C_PRIMARY)
		_set_tile("side", "%d%%" % roundi(side * 100.0), "toward the right wall", side,
			UITheme.C_WARN if absf(side - 0.5) > 0.2 else UITheme.C_PRIMARY)
		if str(_entry.get("kind", "")) == "trailer" and frac > 0.55:
			_add_warning(UITheme.C_WARN, "Tail-heavy — a trailer wants 10–15 % of the load on the tongue; move weight forward")
		if absf(side - 0.5) > 0.2:
			_add_warning(UITheme.C_WARN, "Lopsided — the heavy side will ride low")
		if _com_marker != null:
			_com_marker.visible = true
			_com_marker.position = Vector3(com.x, 0.008, com.z)
	else:
		_set_tile("com", "—", "nothing weighed yet", 0.0, UITheme.C_TEXT_M)
		_set_tile("side", "—", "nothing weighed yet", 0.0, UITheme.C_TEXT_M)
		if _com_marker != null:
			_com_marker.visible = false
	if _mode == "pallets":
		var heavy := 0
		for u: Dictionary in _units:
			if bool(u.get("pallet", false)) and bool(u.get("overweight", false)):
				heavy += 1
		_set_tile("axle", UiText.count(pallet_count(), "pallet"), "palletized, then stuffed", 0.0, UITheme.C_PRIMARY)
		if heavy > 0:
			_add_warning(UITheme.C_WARN, "%s over the pallet's rating" % UiText.count(heavy, "pallet"))
	elif not _last_solve.is_empty() and not (_last_solve.get("axle_split", {}) as Dictionary).is_empty():
		var axle: Dictionary = _last_solve.get("axle_split", {})
		var f := float(axle.get("front", 0.0))
		_set_tile("axle", "%d / %d" % [roundi(f * 100.0), roundi(float(axle.get("rear", 0.0)) * 100.0)],
			"front / rear axle share", f, UITheme.C_PRIMARY)
	else:
		_set_tile("axle", "—", "auto-pack to estimate the axle split", 0.0, UITheme.C_TEXT_M)
	if not _last_solve.is_empty():
		for w: Dictionary in _last_solve.get("warnings", []):
			_add_warning(UITheme.C_WARN, str(w.get("text", "")))
		var left := (_last_solve.get("unplaced", []) as Array).size()
		if left > 0:
			_add_warning(UITheme.C_WARN, "%s did not fit" % UiText.count(left, "item"))


func _add_warning(col: Color, text: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UITheme.SPACE_XS)
	var ic := TextureRect.new()
	ic.texture = UiIcons.icon("triangle-alert", 14)
	ic.modulate = col
	ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	row.add_child(ic)
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_color_override("font_color", col)
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	row.add_child(l)
	_warn_box.add_child(row)


func _refresh_host_facts() -> void:
	if _host_facts == null:
		return
	var dims := _interior_dims()
	var lines: PackedStringArray = []
	lines.append("Inside %.2f × %.2f × %.2f m · %s" % [dims.z, dims.x, dims.y,
		UiText.num(dims.x * dims.y * dims.z, "m³", 3)])
	var door = _entry.get("door")
	if door is Dictionary:
		lines.append("Door %.2f × %.2f m" % [float(door["w_m"]), float(door["h_m"])])
	else:
		lines.append("Open top — loaded from above")
	var payload := float(_entry.get("payload_kg", 0.0))
	if payload > 0.0:
		lines.append("Payload %s" % UiText.num(payload, "kg", 3))
	var notes := str(_entry.get("notes", ""))
	if not notes.is_empty():
		lines.append(notes)
	_host_facts.text = "\n".join(lines)


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
	_set_hint("Manifest saved: %s" % path)


func _on_export_lists() -> void:
	var path := export_packing_lists()
	_set_hint(("Packing lists saved: %s" % ProjectSettings.globalize_path(path)) \
		if not path.is_empty() else "Packing lists could not be written")


## Writes packing_list.csv / .json / .html for the current load and returns
## the folder ("" on failure). Used by the button and the harness.
func export_packing_lists(dir: String = "") -> String:
	var list_name := "%s %s" % [str(_entry.get("label", _entry.get("id", "container"))),
		Time.get_datetime_string_from_system(false, true).replace(":", "-")]
	var doc := PackingList.build(_entry, _units, _placed,
		_raw_units if not _palletized.is_empty() else [], list_name)
	if dir.is_empty():
		dir = PackingList.DEFAULT_DIR.path_join(PackingList.safe_name(list_name))
	return PackingList.write_folder(doc, dir)


# ---------------------------------------------------------------------------
# Custom-item entry (Phase 7) — cover the gear the game doesn't model
# ---------------------------------------------------------------------------

func _on_custom_item_pressed() -> void:
	if _custom_popup != null:
		_custom_popup.set_open(not _custom_popup.is_open())


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
		_set_hint("Custom item needs non-zero dimensions")
		return
	_append_custom_spec(_site_token_for(get_tree().current_scene), label, spec)
	# Join the live session immediately (append-only — _placed references
	# _units by index, so units are never removed mid-session).
	for _i: int in maxi(int(spec.get("count", 1)), 1):
		var unit := spec.duplicate()
		unit["label"] = label
		unit["custom"] = true
		unit["count"] = 1
		_raw_units.append(unit)
		if _mode != "pallets":
			_units.append(unit)
			_remaining.append(_units.size() - 1)
	if _mode == "pallets":
		_rebuild_units(true)
	else:
		_refresh_lists()
	_set_hint("Added %s — saved for this site" % label)


func _on_clear_custom() -> void:
	_clear_custom_specs(_site_token_for(get_tree().current_scene))
	_clear_custom_specs(_legacy_token_for(get_tree().current_scene))
	# Already-placed customs keep their boxes this session (indices stay
	# valid); unplaced ones leave the to-pack list now.
	var keep: Array = []
	for idx: Variant in _remaining:
		if not bool((_units[int(idx)] as Dictionary).get("custom", false)):
			keep.append(idx)
	_remaining = keep
	_refresh_lists()
	_set_hint("Saved custom items cleared for this site")


func _set_hint(text: String) -> void:
	if _hint != null:
		_hint.text = text


func _update_hint() -> void:
	if _hint == null:
		return
	if _ghost_unit >= 0:
		_hint.text = "Aim in the box · click to set it down · R turns it · right-click cancels"
	else:
		_hint.text = "Pick an item on the left to place it · click a placed item to take it out · drag to orbit · wheel zooms"


func _on_item_selected(list_idx: int) -> void:
	var unit_idx := int(_item_list.get_item_metadata(list_idx))
	_begin_ghost(unit_idx)
	_item_list.deselect_all()


# ---------------------------------------------------------------------------
# UI construction
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_shell = DesignerShell.create("Packing Lab", "package", {
		"name_id": MODAL_NAME, "want": WANT, "left_label": "Load",
		"left_w": 300.0, "right_w": 360.0})
	_root.add_child(_shell)
	_shell.closed.connect(_on_shell_closed)
	_build_left()
	_build_centre()
	_build_right()
	for spec2: Array in [
			["CSV", "_on_export_csv", "Save the load order + totals as a printable spreadsheet"],
			["JSON", "_on_export_json", "Save the full manifest data (positions, masses, container)"],
			["Packing lists", "_on_export_lists",
				"Write packing lists for the container, each pallet and each crate, plus printable labels"]]:
		_shell.add_button(str(spec2[0]), DesignerShell.SECONDARY, Callable(self, str(spec2[1])), str(spec2[2]))
	_deliver_btn = _shell.add_button("Deliver kit to site", DesignerShell.PRIMARY, _on_deliver)
	_deliver_btn.icon = UiIcons.icon("truck", 16)
	_deliver_btn.name = "deliver"
	_shell.add_button("Close", DesignerShell.SECONDARY, close)
	_clear_dialog = ConfirmationDialog.new()
	_clear_dialog.title = "Empty the load?"
	_clear_dialog.dialog_text = "Take every placed item back out? The saved layout for this site is replaced."
	_clear_dialog.ok_button_text = "Empty it"
	_clear_dialog.confirmed.connect(_on_clear)
	_root.add_child(_clear_dialog)
	_save_dialog = FileDialog.new()
	_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = FileDialog.ACCESS_USERDATA
	_save_dialog.use_native_dialog = false
	_save_dialog.size = Vector2i(760, 520)
	_save_dialog.file_selected.connect(_on_save_path_chosen)
	add_child(_save_dialog)
	_update_hint()


func _build_left() -> void:
	var box := VBoxContainer.new()
	box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_shell.left.add_child(box)

	box.add_child(SectionHeader.make("Where it goes", "truck", ""))
	_container_combo = OptionButton.new()
	_container_combo.name = "container"
	_container_combo.focus_mode = Control.FOCUS_NONE
	_container_combo.fit_to_longest_item = false
	_container_combo.clip_text = true
	_container_combo.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_refill_container_combo()
	_container_combo.item_selected.connect(_on_container_selected)
	box.add_child(_container_combo)
	_host_facts = Label.new()
	_host_facts.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_host_facts.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_host_facts.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(_host_facts)
	var units_btn := Button.new()
	units_btn.text = "Design units…"
	units_btn.icon = UiIcons.icon("package", 16)
	units_btn.tooltip_text = "Design shipping containers, pallets, totes and other handling units"
	units_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(units_btn)
	units_btn.pressed.connect(_on_units_pressed)
	box.add_child(units_btn)

	box.add_child(SectionHeader.make("What goes in", "box", ""))
	_kit_combo = OptionButton.new()
	_kit_combo.name = "kit"
	_kit_combo.focus_mode = Control.FOCUS_NONE
	_kit_combo.fit_to_longest_item = false
	_kit_combo.clip_text = true
	_kit_combo.add_item("— current cargo —")
	_kit_combo.set_item_metadata(0, "")
	for def in PackDefs.all_defs():
		var dd := def as Dictionary
		_kit_combo.add_item(str(dd.get("label", "?")))
		_kit_combo.set_item_metadata(_kit_combo.item_count - 1, str(dd.get("id", "")))
	_kit_combo.item_selected.connect(_on_kit_selected)
	box.add_child(FormRow.make("Kit", _kit_combo, "A built-in kit instead of the site's own cargo"))
	_level_combo = OptionButton.new()
	_level_combo.name = "load_level"
	_level_combo.focus_mode = Control.FOCUS_NONE
	_level_combo.add_item("Loose items")
	_level_combo.add_item("Palletize, then stuff")
	_level_combo.item_selected.connect(func(i: int) -> void:
		set_load_level("pallets" if i == 1 else "loose", _pallet_id))
	box.add_child(FormRow.make("Load as", _level_combo, "Stuff the loose manifest, or build pallets first"))
	_pallet_combo = OptionButton.new()
	_pallet_combo.name = "pallet"
	_pallet_combo.focus_mode = Control.FOCUS_NONE
	for pid in ["pallet_gma", "pallet_eur1"]:
		var pu: Dictionary = IntermodalUnits.resolve(pid)
		_pallet_combo.add_item(str(pu.get("label", pid)))
		_pallet_combo.set_item_metadata(_pallet_combo.item_count - 1, pid)
	_pallet_combo.item_selected.connect(func(i: int) -> void:
		set_load_level("pallets", str(_pallet_combo.get_item_metadata(i))))
	box.add_child(FormRow.make("Pallet", _pallet_combo, "The pallet the loose items are built onto"))
	_sync_level_ui()
	_build_custom_fold(box)

	box.add_child(SectionHeader.make("Still to pack", "list", "Click an item to place it"))
	_item_list = ItemList.new()
	_item_list.name = "to_pack"
	_item_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_item_list.custom_minimum_size = Vector2(0, 160)
	_item_list.focus_mode = Control.FOCUS_NONE
	_item_list.item_selected.connect(_on_item_selected)
	box.add_child(_item_list)


func _build_centre() -> void:
	_studio = StudioViewport.create({"ground": true, "person": false, "ssao": true, "exposure": 1.0})
	_studio.pitch_min = 0.06
	_studio.set_home(_yaw, _pitch)
	_studio.input_hook = _studio_hook
	_studio.clicked.connect(_on_studio_clicked)
	_studio.view_changed.connect(_on_view_changed)
	_shell.centre.add_child(_studio)
	_host_root = Node3D.new()
	_host_root.name = "Host"
	_studio.holder.add_child(_host_root)
	_items_node = Node3D.new()
	_items_node.name = "Items"
	_studio.holder.add_child(_items_node)
	# The strip under the view: the two big verbs, the view, the hint.
	var auto_btn := Button.new()
	auto_btn.name = "autopack"
	auto_btn.text = "Auto-pack"
	auto_btn.icon = UiIcons.icon("sparkles", 16)
	auto_btn.tooltip_text = "Let the solver load everything that fits (largest first, door last)"
	auto_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(auto_btn)
	auto_btn.add_theme_color_override("font_color", UITheme.C_PRIMARY)
	auto_btn.pressed.connect(_on_autopack)
	_studio.strip.add_child(auto_btn)
	var empty_btn := Button.new()
	empty_btn.name = "empty"
	empty_btn.text = "Empty"
	empty_btn.icon = UiIcons.icon("trash-2", 16)
	empty_btn.tooltip_text = "Take everything out (asks first: the layout is saved at once)"
	empty_btn.focus_mode = Control.FOCUS_NONE
	UITheme.style_button(empty_btn)
	empty_btn.pressed.connect(_ask_clear)
	_studio.strip.add_child(empty_btn)
	var view := OptionButton.new()
	view.name = "cutaway"
	view.focus_mode = Control.FOCUS_NONE
	view.add_item("Cutaway follows the camera")
	view.set_item_metadata(0, "auto")
	view.add_item("Roof off")
	view.set_item_metadata(1, "open")
	view.add_item("Whole box")
	view.set_item_metadata(2, "full")
	view.item_selected.connect(func(i: int) -> void:
		_cutaway_mode = str(view.get_item_metadata(i))
		_apply_cutaway())
	_studio.strip.add_child(view)
	_studio.strip.add_child(IconButton.make("maximize-2", "Frame the load", _frame_camera))
	_hint = Label.new()
	_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hint.clip_text = true
	_hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_studio.strip.add_child(_hint)


func _build_right() -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.SPACE_SM)
	_shell.right.add_child(box)
	box.add_child(SectionHeader.make("Load sheet", "gauge", ""))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", UITheme.SPACE_SM)
	grid.add_theme_constant_override("v_separation", UITheme.SPACE_SM)
	box.add_child(grid)
	grid.add_child(_make_tile("fill", "Fill", "layout-grid"))
	grid.add_child(_make_tile("load", "Load", "gauge"))
	grid.add_child(_make_tile("com", "Load centre", "target"))
	grid.add_child(_make_tile("side", "Side balance", "move"))
	var axle := _make_tile("axle", "Axles", "truck")
	box.add_child(axle)
	_warn_box = VBoxContainer.new()
	_warn_box.add_theme_constant_override("separation", UITheme.SPACE_XS)
	box.add_child(_warn_box)
	box.add_child(SectionHeader.make("Delivery", "truck", "The crew unloads it in the world"))
	_deliver_lbl = Label.new()
	_deliver_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_deliver_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_deliver_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(_deliver_lbl)
	var legend := Label.new()
	legend.text = "Floor dot: the load centre · amber frame: the door · hidden walls come back as you orbit"
	legend.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	legend.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	legend.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	box.add_child(legend)


## A stat tile: a title with an icon, the number, one line under it, a bar.
func _make_tile(id: String, title: String, icon: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = "tile_" + id
	panel.add_theme_stylebox_override("panel", UITheme.card_style())
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	panel.add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", UITheme.SPACE_XS)
	v.add_child(head)
	var ic := TextureRect.new()
	ic.texture = UiIcons.icon(icon, 14)
	ic.modulate = UITheme.C_TEXT_M
	ic.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	head.add_child(ic)
	var t := Label.new()
	t.text = title
	t.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	t.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	head.add_child(t)
	var val := Label.new()
	val.text = "—"
	val.add_theme_font_override("font", UITheme.font("semibold", true))
	val.add_theme_font_size_override("font_size", UITheme.FONT_XL)
	val.add_theme_color_override("font_color", UITheme.C_TEXT)
	v.add_child(val)
	var sub := Label.new()
	sub.text = ""
	sub.clip_text = true
	sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sub.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	sub.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	sub.mouse_filter = Control.MOUSE_FILTER_PASS
	sub.mouse_entered.connect(func() -> void: sub.tooltip_text = sub.text)
	v.add_child(sub)
	var bar := ProgressBar.new()
	bar.min_value = 0.0
	bar.max_value = 1.0
	bar.show_percentage = false
	bar.custom_minimum_size = Vector2(0, 6)
	UITheme.style_progress(bar, UITheme.C_PRIMARY)
	v.add_child(bar)
	_tiles[id] = {"panel": panel, "value": val, "sub": sub, "bar": bar}
	return panel


func _set_tile(id: String, value: String, sub: String, frac: float, col: Color) -> void:
	var t: Dictionary = _tiles.get(id, {})
	if t.is_empty():
		return
	(t["value"] as Label).text = value
	(t["value"] as Label).add_theme_color_override("font_color", col if col != UITheme.C_TEXT_M else UITheme.C_TEXT_S)
	(t["sub"] as Label).text = sub
	var bar := t["bar"] as ProgressBar
	bar.value = clampf(frac, 0.0, 1.0)
	UITheme.style_progress(bar, col)


## "Add an item": the gear the game does not model, saved per site.
func _build_custom_fold(parent: Control) -> void:
	_custom_popup = Collapsible.make("Add an item", false,
		"Cover gear the game does not model — saved for this site")
	parent.add_child(_custom_popup)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_custom_popup.body.add_child(v)
	_ci_name = LineEdit.new()
	_ci_name.placeholder_text = "Name (e.g. Cooler, Toolbox)"
	v.add_child(_ci_name)
	var dims := HBoxContainer.new()
	dims.add_theme_constant_override("separation", UITheme.SPACE_XS)
	v.add_child(dims)
	_ci_w = _ci_spin(dims, "W cm", 60.0, 1.0, 1200.0)
	_ci_d = _ci_spin(dims, "D cm", 40.0, 1.0, 1200.0)
	_ci_h = _ci_spin(dims, "H cm", 40.0, 1.0, 1200.0)
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", UITheme.SPACE_XS)
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
	actions.add_theme_constant_override("separation", UITheme.SPACE_XS)
	v.add_child(actions)
	for spec: Array in [["Add", "_on_add_custom", "plus"], ["Clear saved", "_on_clear_custom", "trash-2"]]:
		var b := Button.new()
		b.text = str(spec[0])
		b.icon = UiIcons.icon(str(spec[2]), 14)
		b.focus_mode = Control.FOCUS_NONE
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UITheme.style_button(b)
		b.pressed.connect(Callable(self, str(spec[1])))
		actions.add_child(b)


func _ci_spin(parent: Control, label: String, value: float, min_v: float,
		max_v: float) -> SpinBox:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
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


func _ask_clear() -> void:
	if _placed.is_empty():
		return
	_clear_dialog.popup_centered()


func _on_clear() -> void:
	_clear_placements()
	_refresh_lists()
	_save_layout()
