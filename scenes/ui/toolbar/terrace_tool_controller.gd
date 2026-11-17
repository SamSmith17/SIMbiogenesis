extends RefCounted

## The T toolbar's Terrace tool (edit_toolbar_ui delegates to this, as it
## does to the water controller). Two ways to make a field: the Hill shape
## (one click on a slope terraces everything above the click, up to the Hill
## reach) or any drawn outline. A click inside an existing field selects it
## and opens the editor dock instead. While Hill is up, the outline a click
## would make is previewed under the pointer.

const DockScript := preload("res://scenes/ui/terrace_editor_dock.gd")
const HOVER_S := 0.3
const HOVER_MOVE_M := 2.5

var _toolbar: Control = null
var _loader: Node = null
var _state: RefCounted = null
var _status: Callable = Callable()
var _dock: PanelContainer = null
var _hover_t := 0.0
var _hover_at := Vector2(1e9, 1e9)
var _hover_poly := PackedVector2Array()
var _crop_opt: OptionButton = null


func bind(toolbar: Control, loader: Node, state: RefCounted, status: Callable) -> void:
	_toolbar = toolbar
	_loader = loader
	_state = state
	_status = status


func runtime() -> TerraceRuntime:
	if _loader == null or not _loader.has_method("terraces"):
		return null
	return _loader.call("terraces") as TerraceRuntime


func _say(text: String) -> void:
	if _status.is_valid():
		_status.call(text)


func dock() -> PanelContainer:
	return _dock


func selected_id() -> String:
	var rt := runtime()
	return rt.selected if rt != null else ""


## The crop picker and the flooded switch for the NEXT field drawn.
func build_rows(box: Container) -> void:
	_crop_opt = OptionButton.new()
	_crop_opt.focus_mode = Control.FOCUS_NONE
	_crop_opt.tooltip_text = "What a new terrace field grows"
	_crop_opt.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	for c in TerraceField.CROP_ORDER:
		_crop_opt.add_item(TerraceField.crop_label(str(c)))
		_crop_opt.set_item_metadata(_crop_opt.item_count - 1, str(c))
		if str(c) == str(_state.get("terrace_crop")):
			_crop_opt.select(_crop_opt.item_count - 1)
	_crop_opt.item_selected.connect(func(i: int) -> void:
		var crop := str(_crop_opt.get_item_metadata(i))
		_state.set("terrace_crop", crop)
		# A wet crop wants flooded steps; a dry one dry steps.
		_state.set("terrace_flooded", bool(TerraceField.crop_info(crop)["wet"]))
		_toolbar.call("_queue_save_prefs")
		_toolbar.call("_rebuild_options_bar"))
	box.add_child(_crop_opt)
	var fl := CheckBox.new()
	fl.text = "Flooded"
	fl.tooltip_text = "New fields hold standing water behind bunds (paddies)"
	fl.focus_mode = Control.FOCUS_NONE
	fl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	fl.button_pressed = bool(_state.get("terrace_flooded"))
	fl.toggled.connect(func(on: bool) -> void:
		_state.set("terrace_flooded", on)
		_toolbar.call("_queue_save_prefs"))
	box.add_child(fl)
	box.add_child(_pick("terrace_build", TerraceField.BUILD_MODES, TerraceField.BUILD_LABELS,
		"How a new field's steps are cut: dug by a crew of the camp's people, by a mini excavator, or at once"))
	box.add_child(_pick("terrace_labour", TerraceField.LABOUR_MODES, TerraceField.LABOUR_LABELS,
		"Who farms a new field: the camp's crews, small machines, or nobody (free)"))


func _pick(key: String, ids: Array, labels: Dictionary, tip: String) -> OptionButton:
	var o := OptionButton.new()
	o.name = key
	o.focus_mode = Control.FOCUS_NONE
	o.tooltip_text = tip
	o.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	for m in ids:
		o.add_item(str(labels[m]))
		o.set_item_metadata(o.item_count - 1, str(m))
		if str(m) == str(_state.get(key)):
			o.select(o.item_count - 1)
	o.item_selected.connect(func(i: int) -> void:
		_state.set(key, str(o.get_item_metadata(i)))
		_toolbar.call("_queue_save_prefs"))
	return o


## A click with the Terrace tool. True when it is handled here (a field was
## selected, or the Hill shape made one); false lets the toolbar start the
## drawn outline.
func on_click(world: Vector2, shape: String) -> bool:
	var rt := runtime()
	if rt == null:
		return true
	var hit := rt.field_at(world)
	if not hit.is_empty():
		select(hit)
		return true
	if shape != "hill":
		if not rt.selected.is_empty():
			deselect()
		return false
	var poly := rt.hill_outline(world, float(_state.call("get_param", "hill_r_m", 90.0)))
	if poly.size() < 3:
		_say("Nothing to terrace above here — click lower down the slope")
		return true
	create(poly)
	return true


## A drawn outline committed.
func on_region(poly: PackedVector2Array) -> void:
	create(poly)


func create(poly: PackedVector2Array) -> void:
	var rt := runtime()
	if rt == null:
		return
	var crop := str(_state.get("terrace_crop"))
	var step_h := float(_state.call("get_param", "step_h", 0.0))
	if step_h < 0.3:
		# Auto: steps about 7 m wide on this slope.
		step_h = TerraceField.auto_step_h(poly, Callable(_loader, "ground_without_terraces"))
	var id := rt.create(poly, {
		"step_h": step_h,
		"riser_run": float(_state.call("get_param", "riser_run", 0.6)),
		"crop": crop, "flooded": bool(_state.get("terrace_flooded")),
		"labour": str(_state.get("terrace_labour")), "build_mode": str(_state.get("terrace_build")),
	})
	_clear_hover()
	if id.is_empty():
		_say(rt.last_error)
		return
	if str(_state.get("terrace_build")) == "instant":
		_say("Cutting terraces… %s" % TerraceField.crop_label(crop))
	else:
		_say("Terraces marked out — the camp's crew will dig them, top step first")
	select(id)


func select(id: String) -> void:
	var rt := runtime()
	if rt == null:
		return
	rt.set_selected(id)
	if _dock == null or not is_instance_valid(_dock):
		_dock = DockScript.new()
		_toolbar.add_child(_dock)
		_dock.closed.connect(func() -> void:
			if runtime() != null:
				runtime().set_selected(""))
	_dock.call("open_field", rt, id)
	_say("%s selected — change it on the right · Del deletes · Esc deselects" % str(rt.record(id).get("name", "")))


func deselect() -> void:
	var rt := runtime()
	if rt != null:
		rt.set_selected("")
	if _dock != null and is_instance_valid(_dock) and _dock.visible:
		_dock.call("close_dock")


func delete_selected() -> bool:
	var rt := runtime()
	if rt == null or rt.selected.is_empty():
		return false
	var id := rt.selected
	var nm := str(rt.record(id).get("name", "Terraces"))
	deselect()
	rt.delete(id)
	_say("Deleted %s — the hillside is back (Ctrl+Z undoes)" % nm)
	return true


func escape() -> bool:
	if not _hover_poly.is_empty():
		_clear_hover()
	var rt := runtime()
	if rt != null and not rt.selected.is_empty():
		deselect()
		_say("Deselected")
		return true
	return false


func undo() -> bool:
	var rt := runtime()
	if rt == null or not rt.undo():
		return false
	if _dock != null and is_instance_valid(_dock) and _dock.visible:
		if rt.record(str(_dock.get("field_id"))).is_empty():
			deselect()
		else:
			_dock.call("sync_from_record")
	return true


func deactivate() -> void:
	_clear_hover()
	deselect()


## The Hill shape's preview under the pointer (throttled: an outline samples
## a few thousand ground points).
func process(delta: float, hit: Variant, shape: String) -> void:
	if shape != "hill" or not (hit is Vector3):
		if not _hover_poly.is_empty():
			_clear_hover()
		return
	_hover_t -= delta
	var p: Vector3 = hit
	var at := Vector2(p.x, p.z)
	if _hover_t > 0.0 or at.distance_to(_hover_at) < HOVER_MOVE_M:
		return
	_hover_t = HOVER_S
	_hover_at = at
	var rt := runtime()
	if rt == null:
		return
	if not rt.field_at(at).is_empty():
		_clear_hover()
		return
	_hover_poly = rt.hill_outline(at, float(_state.call("get_param", "hill_r_m", 90.0)))
	if _hover_poly.size() >= 3 and _loader.has_method("update_sculpt_selection_highlight"):
		_loader.call("update_sculpt_selection_highlight", _hover_poly)
	else:
		_clear_hover()


func _clear_hover() -> void:
	_hover_poly = PackedVector2Array()
	_hover_at = Vector2(1e9, 1e9)
	if _loader != null and _loader.has_method("clear_sculpt_selection_highlight"):
		_loader.call("clear_sculpt_selection_highlight")
