class_name GraphSystemsOutliner
extends VBoxContainer
## The systems outliner (plans/GRAPH_SYSTEMS_UX_PLAN.md Phase 1), at the top
## of the graph view's left sidebar. A festival site has dozens of power
## systems (the player's own, every camp, every vehicle) and hundreds of
## nodes; nothing used to find one. This is:
##   - a tree: Site ▸ Camps / Vehicles / Groups / Nodes ▸ … ▸ every node,
##     each system row with a status (GraphSystems.status);
##   - search (Ctrl+F): every word matched against node names, types and the
##     system a node sits in; Enter flies to the first result;
##   - filter chips: All · Needs attention · Camps · Vehicles.
## Click = fly to it (entering the scopes it sits in); double-click = open
## it. The tree is rebuilt only when the graph's structure or names change
## (struct_rev / user_rev); status text is refreshed twice a second in place.

const REFRESH_S := 0.5
const TREE_H := 300.0
const MAX_RESULTS := 200

const C_OK := Color(0.45, 0.85, 0.55)
const C_WARN := Color(0.98, 0.75, 0.3)
const C_CRIT := Color(1.0, 0.42, 0.38)
const C_IDLE := Color(0.6, 0.64, 0.7)

const TYPE_ICON := {
	"panel": "☀", "battery": "🔋", "smartbattery": "🔋", "controller": "🎛",
	"appliance": "💡", "acload": "💡", "resource": "🛢", "processor": "⚙",
	"wind": "🌬", "hydro": "💧", "compound": "📦",
}

var _view: Node = null
var _search: LineEdit = null
var _tree: Tree = null
var _chips: Array[Button] = []
var _filter := "all"
var _sig := ""
var _status_rows: Dictionary = {}   # compound id -> TreeItem (system rows)
var _acc := 0.0
var _building := false


func bind(view: Node) -> void:
	_view = view


func _ready() -> void:
	name = "SystemsOutliner"
	add_theme_constant_override("separation", 4)
	var hdr_m := MarginContainer.new()
	for side in ["left", "right"]:
		hdr_m.add_theme_constant_override("margin_" + side, 12)
	hdr_m.add_theme_constant_override("margin_top", 8)
	hdr_m.add_child(SectionHeader.make("SYSTEMS", "", "Ctrl+F to search"))
	add_child(hdr_m)

	var body := MarginContainer.new()
	for side in ["left", "right"]:
		body.add_theme_constant_override("margin_" + side, 10)
	add_child(body)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	body.add_child(col)

	_search = LineEdit.new()
	_search.name = "SystemsSearch"
	_search.placeholder_text = "Search nodes, camps, vehicles…"
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t: String): _rebuild(true))
	_search.text_submitted.connect(func(_t: String): _activate_first())
	_search.gui_input.connect(_on_search_input)
	col.add_child(_search)

	var chip_row := HBoxContainer.new()
	chip_row.add_theme_constant_override("separation", 3)
	col.add_child(chip_row)
	for f in [["all", "All"], ["attention", "Attention"], ["camp", "Camps"], ["vehicle", "Vehicles"]]:
		var b := Button.new()
		b.name = "Chip_" + str(f[0])
		b.text = str(f[1])
		b.toggle_mode = true
		b.button_pressed = f[0] == _filter
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 11)
		var key := str(f[0])
		b.pressed.connect(func(): _set_filter(key))
		chip_row.add_child(b)
		_chips.append(b)

	_tree = Tree.new()
	_tree.name = "SystemsTree"
	_tree.columns = 2
	_tree.hide_root = true
	_tree.custom_minimum_size = Vector2(0, TREE_H)
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.set_column_expand(0, true)
	_tree.set_column_expand(1, false)
	_tree.set_column_custom_minimum_width(1, 74)
	_tree.select_mode = Tree.SELECT_ROW
	_tree.add_theme_font_size_override("font_size", 12)
	_tree.item_selected.connect(_on_selected)
	_tree.item_activated.connect(_on_activated)
	col.add_child(_tree)


func _process(delta: float) -> void:
	if not is_visible_in_tree() or _view == null:
		return
	_acc += delta
	if _acc < REFRESH_S:
		return
	_acc = 0.0
	_rebuild(false)
	_refresh_status()


## Focus the search box (Ctrl+F) and select its text.
func focus_search() -> void:
	if _search == null:
		return
	_search.grab_focus()
	_search.select_all()


func search(text: String) -> void:
	if _search == null:
		return
	_search.text = text
	_rebuild(true)


func set_filter(key: String) -> void:
	_set_filter(key)


## Harness: the ids the tree shows right now, in order.
func shown_ids() -> Array:
	var out: Array = []
	if _tree == null or _tree.get_root() == null:
		return out
	var stack: Array = [_tree.get_root()]
	while not stack.is_empty():
		var ti: TreeItem = stack.pop_front()
		var meta: Variant = ti.get_metadata(0)
		if meta is String and not str(meta).is_empty():
			out.append(str(meta))
		var ch := ti.get_first_child()
		var kids: Array = []
		while ch != null:
			kids.append(ch)
			ch = ch.get_next()
		stack = kids + stack
	return out


## Harness / keyboard: fly to an id as a click on its row would.
func activate_id(id: String, enter: bool = false) -> void:
	if _view != null and _view.has_method("focus_graph_item"):
		_view.call("focus_graph_item", id, enter)


func tree() -> Tree:
	return _tree


# ---------------------------------------------------------------------------

func _model() -> GraphModel:
	return _view.get("model") as GraphModel if _view != null else null


func _set_filter(key: String) -> void:
	_filter = key
	for b in _chips:
		b.set_pressed_no_signal(b.name == "Chip_" + key)
	_rebuild(true)


func _power_states() -> Dictionary:
	if _view != null and _view.has_method("vehicle_power_states"):
		return _view.call("vehicle_power_states")
	return {}


static func _name_of(d: Dictionary) -> String:
	var sp: Dictionary = d.get("specs", {}) as Dictionary
	var n := str(sp.get("name", d.get("label", "")))
	if n.is_empty():
		n = UiText.from_id(str(d.get("type", "node")))
	return n


static func _icon_of(d: Dictionary) -> String:
	match GraphSystems.island_kind(d):
		GraphSystems.KIND_CAMP:
			return "⛺"
		GraphSystems.KIND_VEHICLE:
			return "🚐"
	return str(TYPE_ICON.get(str(d.get("type", "")), "•"))


func _rebuild(force: bool) -> void:
	var model := _model()
	if model == null or _tree == null:
		return
	var q := _search.text.strip_edges().to_lower() if _search != null else ""
	var sig := "%d|%d|%d|%s|%s" % [model.struct_rev, model.user_rev, model.items.size(), q, _filter]
	if not force and sig == _sig:
		return
	if _filter == "attention":
		# Status moves without a model revision: rebuild with it.
		sig += "|" + _attention_sig(model)
		if not force and sig == _sig:
			return
	_sig = sig
	_building = true
	_tree.clear()
	_status_rows.clear()
	var root := _tree.create_item()
	if not q.is_empty():
		_build_results(model, root, q)
	else:
		_build_tree(model, root)
	_building = false
	_refresh_status()


func _attention_sig(model: GraphModel) -> String:
	var ids := PackedStringArray()
	var power := _power_states()
	for sysd in GraphSystems.list(model):
		var it := model.get_item(str((sysd as Dictionary)["id"]))
		var st := GraphSystems.status(model, it, power.get(str(it.get("id", "")), {}) as Dictionary)
		if str(st["level"]) in ["warn", "crit"]:
			ids.append(str(it.get("id", "")))
	return ",".join(ids)


func _row(parent: TreeItem, d: Dictionary, collapsed: bool = true) -> TreeItem:
	var ti := _tree.create_item(parent)
	ti.set_text(0, "%s  %s" % [_icon_of(d), _name_of(d)])
	ti.set_metadata(0, str(d.get("id", "")))
	ti.set_tooltip_text(0, "%s — click to go to it, double-click to open it" % _name_of(d)
		if str(d.get("type", "")) == "compound" else "%s — click to go to it" % _name_of(d))
	ti.collapsed = collapsed
	if GraphSystems.is_power_island(d):
		_status_rows[str(d.get("id", ""))] = ti
	return ti


func _section(parent: TreeItem, title: String, n: int, collapsed: bool) -> TreeItem:
	var ti := _tree.create_item(parent)
	ti.set_text(0, "%s (%d)" % [title, n])
	ti.set_metadata(0, "")
	ti.set_selectable(0, false)
	ti.set_selectable(1, false)
	ti.set_custom_color(0, C_IDLE)
	ti.collapsed = collapsed
	return ti


## The site's tree: systems first (camps, vehicles), then the player's groups
## and the nodes at the top level. A compound's row holds what is inside it.
func _build_tree(model: GraphModel, root: TreeItem) -> void:
	var camps: Array = []
	var vehicles: Array = []
	var groups: Array = []
	var nodes: Array = []
	var power := _power_states()
	for it in model.get_items_in_scope("root"):
		var d: Dictionary = it
		if bool(d.get("is_virtual", false)):
			continue
		var kind := GraphSystems.island_kind(d) if str(d.get("type", "")) == "compound" else ""
		if _filter == "attention":
			if kind.is_empty():
				continue
			var st := GraphSystems.status(model, d, power.get(str(d.get("id", "")), {}) as Dictionary)
			if not str(st["level"]) in ["warn", "crit"]:
				continue
		elif _filter == "camp" and kind != GraphSystems.KIND_CAMP:
			continue
		elif _filter == "vehicle" and kind != GraphSystems.KIND_VEHICLE:
			continue
		match kind:
			GraphSystems.KIND_CAMP:
				camps.append(d)
			GraphSystems.KIND_VEHICLE:
				vehicles.append(d)
			_:
				if str(d.get("type", "")) == "compound":
					groups.append(d)
				else:
					nodes.append(d)
	var by_name := func(a: Dictionary, b: Dictionary) -> bool:
		return _name_of(a).naturalnocasecmp_to(_name_of(b)) < 0
	for arr: Array in [camps, vehicles, groups, nodes]:
		arr.sort_custom(by_name)
	var site := _tree.create_item(root)
	site.set_text(0, "🏠  Site")
	site.set_metadata(0, "@root")
	site.set_tooltip_text(0, "The whole site — click to go back to the top level")
	if camps.is_empty() and vehicles.is_empty() and groups.is_empty() and nodes.is_empty():
		var none := _tree.create_item(site)
		none.set_text(0, "Nothing here" if _filter != "attention" else "Nothing needs attention")
		none.set_selectable(0, false)
		none.set_custom_color(0, C_IDLE)
		return
	var lists := [["Camps", camps, false], ["Vehicles", vehicles, false],
		["Groups & structures", groups, false], ["Nodes", nodes, true]]
	for entry in lists:
		var arr: Array = entry[1]
		if arr.is_empty():
			continue
		var sec := _section(site, str(entry[0]), arr.size(), bool(entry[2]) and _filter == "all")
		for d: Dictionary in arr:
			var ti := _row(sec, d)
			if str(d.get("type", "")) == "compound":
				_build_children(model, ti, str(d.get("child_scope_id", "")), 1)


func _build_children(model: GraphModel, parent: TreeItem, scope: String, depth: int) -> void:
	if scope.is_empty() or depth > 8:
		return
	var kids: Array = []
	for it in model.get_items_in_scope(scope):
		var d: Dictionary = it
		if not bool(d.get("is_virtual", false)):
			kids.append(d)
	kids.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ac := str(a.get("type", "")) == "compound"
		var bc := str(b.get("type", "")) == "compound"
		if ac != bc:
			return ac
		return _name_of(a).naturalnocasecmp_to(_name_of(b)) < 0)
	for d: Dictionary in kids:
		var ti := _row(parent, d)
		if str(d.get("type", "")) == "compound":
			_build_children(model, ti, str(d.get("child_scope_id", "")), depth + 1)


## Search: every item anywhere whose name, type or system matches every
## word; a flat list ("Battery — in ⛺ Camp Seven").
func _build_results(model: GraphModel, root: TreeItem, q: String) -> void:
	var words := q.split(" ", false)
	var owner_name := {}   # scope id -> display name of its system / group
	for it in model.items:
		var d: Dictionary = it
		var cs := str(d.get("child_scope_id", ""))
		if not cs.is_empty():
			owner_name[cs] = "%s %s" % [_icon_of(d), _name_of(d)]
	var hits: Array = []
	for it in model.items:
		var d: Dictionary = it
		if bool(d.get("is_virtual", false)):
			continue
		var where := str(owner_name.get(str(d.get("scope_id", "root")), ""))
		var hay := ("%s %s %s" % [_name_of(d), str(d.get("type", "")), where]).to_lower()
		var ok := true
		for w in words:
			if not hay.contains(w):
				ok = false
				break
		if ok:
			hits.append([d, where])
		if hits.size() >= MAX_RESULTS:
			break
	hits.sort_custom(func(a: Array, b: Array) -> bool:
		# Systems first, then by name.
		var ai := GraphSystems.is_power_island(a[0] as Dictionary)
		var bi := GraphSystems.is_power_island(b[0] as Dictionary)
		if ai != bi:
			return ai
		return _name_of(a[0] as Dictionary).naturalnocasecmp_to(_name_of(b[0] as Dictionary)) < 0)
	if hits.is_empty():
		var none := _tree.create_item(root)
		none.set_text(0, "No match")
		none.set_selectable(0, false)
		none.set_custom_color(0, C_IDLE)
		return
	for h: Array in hits:
		var d: Dictionary = h[0]
		var ti := _row(root, d)
		var where := str(h[1])
		if not where.is_empty():
			ti.set_text(0, "%s  %s  — in %s" % [_icon_of(d), _name_of(d), where])


func _refresh_status() -> void:
	var model := _model()
	if model == null:
		return
	var power := _power_states()
	for id: String in _status_rows.keys():
		var ti: TreeItem = _status_rows[id]
		if ti == null:
			continue
		var it := model.get_item(id)
		if it.is_empty():
			continue
		var st := GraphSystems.status(model, it, power.get(id, {}) as Dictionary)
		var level := str(st["level"])
		var col := C_OK if level == "ok" else C_WARN if level == "warn" \
			else C_CRIT if level == "crit" else C_IDLE
		ti.set_text(1, "● %s" % str(st["text"]))
		ti.set_custom_color(1, col)
		ti.set_text_alignment(1, HORIZONTAL_ALIGNMENT_RIGHT)


func _on_selected() -> void:
	if _building:
		return
	var ti := _tree.get_selected()
	if ti == null:
		return
	var id := str(ti.get_metadata(0))
	if id == "@root":
		if _view != null and _view.has_method("_jump_to_scope_index"):
			_view.call("_jump_to_scope_index", 0)
		return
	if not id.is_empty():
		activate_id(id, false)


func _on_activated() -> void:
	var ti := _tree.get_selected()
	if ti == null:
		return
	var id := str(ti.get_metadata(0))
	if not id.is_empty() and id != "@root":
		activate_id(id, true)


func _activate_first() -> void:
	var ids := shown_ids()
	for id: String in ids:
		if id != "@root":
			activate_id(id, false)
			return


func _on_search_input(ev: InputEvent) -> void:
	if ev is InputEventKey and (ev as InputEventKey).pressed \
			and (ev as InputEventKey).keycode == KEY_DOWN and _tree != null:
		_tree.grab_focus()
		var first := _tree.get_root().get_first_child() if _tree.get_root() != null else null
		if first != null:
			first.select(0)
		_search.accept_event()
