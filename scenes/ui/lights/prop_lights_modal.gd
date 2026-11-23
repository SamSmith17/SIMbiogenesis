class_name PropLightsModal
extends CanvasLayer

## Standalone 3D studio modal for attaching lights and strings to ANY placed
## model in the world (StarShades, camp kitchens, toilet banks, shipping
## containers, gazebos, mud buildings, imported GLBs, etc.).
##
## Opened from PlacedPropEditUI ("Lights & strings…") or StarShadeEditModal:
## builds the prop's exact 3D model in a StudioViewport, loads all lights
## hosted on it (two-way synced with J Light Studio), lets the player click
## surfaces to place Omni, Spot or String lights, preview in Night mode, and
## Apply straight back to the placed prop.

signal closed

const MODAL_NAME := "prop_lights_studio"
const WANT := Vector2(1380, 860)

var _shell: DesignerShell = null
var _studio: StudioViewport = null
var _light_panel: ModelLightPanel = null
var _col: DesignerColumn = null
var _status: Label = null
var _prop_id := ""
var _model_id := ""
var _spec: Dictionary = {}
var _open := false


static func open(tree: SceneTree, prop_id: String) -> Node:
	var m: Node = load("res://scenes/ui/lights/prop_lights_modal.gd").new()
	tree.root.add_child(m)
	m.call("open_for_prop", prop_id)
	m.connect("closed", Callable(m, "queue_free"))
	return m


func _ready() -> void:
	layer = UITheme.LAYER_MODAL
	_build_ui()


func open_for_prop(prop_id: String) -> void:
	if _open or prop_id.is_empty():
		return
	var main := _main()
	var rec := PlacedPropService.get_prop_record(main, prop_id)
	if rec.is_empty():
		return
	_prop_id = prop_id
	_model_id = str(rec.get("model_id", ""))
	_spec = PropModelLights.spec_of_record(rec)
	_open = true
	visible = true
	HudLayout.claim_modal(MODAL_NAME)
	_shell.open()

	var entry := ModelCatalog.find(_model_id)
	var label := str(rec.get("name", ""))
	if label.is_empty():
		label = str(entry.get("label", UiText.from_id(_model_id)))
	_shell.set_subtitle(label)

	var extras := PlacedPropRuntime.model_extras(rec)
	var model := ModelCatalog.instantiate(_model_id, extras)
	if model == null:
		model = Node3D.new()
		model.name = "EmptyModel"
	var ws := ModelCatalog.resolved_scale(_model_id, float(rec.get("scale", 1.0)))
	model.scale = Vector3.ONE * ws
	model.position.y = -ModelCatalog.foot_local_y(_model_id) * ws
	_studio.show_node(model)
	_light_panel.load_from_context(main, _prop_id, _model_id, _spec)
	_light_panel.attach_preview(model)
	_frame(model)
	_refresh_summary()


func close() -> void:
	if not _open:
		return
	if _shell.is_open():
		_shell.close()
	else:
		_on_shell_closed()


func _on_shell_closed() -> void:
	if not _open:
		return
	_open = false
	visible = false
	HudLayout.release(MODAL_NAME)
	closed.emit()


func is_open() -> bool:
	return _open


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	_shell = DesignerShell.create("Model lights & strings", "sun", {
		"name_id": MODAL_NAME, "want": WANT,
		"left_w": 0.0, "right_w": 400.0})
	root.add_child(_shell)
	_shell.closed.connect(_on_shell_closed)
	if _shell.left != null and _shell.left.get_parent() is Control:
		(_shell.left.get_parent() as Control).visible = false

	_studio = StudioViewport.create({"ground": true, "person": true, "ssao": true})
	_studio.set_home(0.7, 0.35)
	_studio.input_hook = func(e: InputEvent) -> bool:
		var m := _studio.holder.get_child(0) as Node3D if _studio.holder.get_child_count() > 0 else null
		return _light_panel.handle_viewport_event(e, _studio.camera, _studio.container, m)
	_shell.centre.add_child(_studio)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", UITheme.SPACE_XS)
	_shell.right.add_child(box)
	box.add_child(SectionHeader.make("Lighting", ""))
	_light_panel = ModelLightPanel.new()
	_light_panel.lights_changed.connect(_refresh_summary)
	box.add_child(_light_panel)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_status.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	box.add_child(_status)
	_col = DesignerColumn.setup(box, "prop_lights", {"open": ["Lighting"], "finder": false, "tile_cols": 2})

	_studio.strip.add_child(_light_panel.make_night_toggle(_studio))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_studio.strip.add_child(spacer)
	_studio.strip.add_child(IconButton.make("maximize-2", "Frame the model", func() -> void:
		if _studio.holder.get_child_count() > 0:
			_frame(_studio.holder.get_child(0) as Node3D)))

	var apply_btn := _shell.add_button("Apply", DesignerShell.PRIMARY, _on_apply,
		"Attach these lights and strings to the placed prop (they move with it and stay editable with J)")
	apply_btn.name = "apply_lights"
	_shell.add_button("Open in J Studio", DesignerShell.SECONDARY, _on_open_j,
		"Apply, close this window, and open J Light Studio with these lights selected")
	_shell.add_button("Close", DesignerShell.SECONDARY, close)
	_shell.set_hint("Pick + Omni, + Spot or + String and click surfaces on the 3D model · toggle Night to preview · Apply saves onto the prop")


func _frame(model: Node3D) -> void:
	var bb := PropModelLights.model_bounds(model)
	if bb.size.length_squared() < 0.01:
		bb = AABB(Vector3(-1.5, 0.0, -1.5), Vector3(3.0, 2.5, 3.0))
	_studio.reset_orbit()
	_studio.frame_aabb(bb, 0.4, 1.3)
	_studio.place_person(maxf(bb.size.x, bb.size.z) * 0.5 + 1.2)


func _refresh_summary() -> void:
	if _col != null:
		_col.set_tiles([
			{"caption": "Attached", "value": _light_panel.summary_text(), "tip": "Moves with the prop when dragged or turned"},
			{"caption": "World edit", "value": "J Studio", "tip": "Press J in the world to tweak any attached light"},
		])
		_col.set_summary("Lighting", _light_panel.summary_text())


func _on_apply() -> void:
	var main := _main()
	if main == null or _prop_id.is_empty():
		return
	var ids := PropModelLights.sync_prop(main, _prop_id, _light_panel.items())
	_status.text = I18n.f("Saved {ids} onto the prop.", {"ids": UiText.count(ids.size(), "light")})


func _on_open_j() -> void:
	var main := _main()
	if main == null or _prop_id.is_empty():
		return
	var ids := PropModelLights.sync_prop(main, _prop_id, _light_panel.items())
	close()
	if not ids.is_empty():
		PlacedLightService.open_studio_on(main, ids)
	else:
		PlacedLightService.toggle_studio(main)


func _main() -> Node:
	var tree := get_tree()
	var main: Node = tree.get_first_node_in_group("main_scene")
	if main == null:
		main = tree.current_scene
	return main
