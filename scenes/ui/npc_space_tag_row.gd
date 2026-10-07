class_name NpcSpaceTagRow
extends HBoxContainer

## Reusable "tag this thing as an NPC space" control: a type dropdown plus a
## capacity spinner, writing straight to `SpaceRegistry`.
##
## It exists because tagging used to live only in `placed_prop_edit_ui`, and
## `InteractionFocus.open_prop_edit_ui` routes props with their own editor —
## StarShades, pallet racks, additive printers — to those modals and returns
## before the drawer is ever reached. The result was that exactly the props
## with the richest editors were the ones that could never be tagged.
##
## One widget rather than four copies of the same dropdown: the next prop that
## earns a bespoke modal only has to add a row, and the registry semantics
## (upsert, "" = untag, capacity clamped, save through the loader) stay in a
## single place.
##
## Works for any `SpaceRegistry` target — props, buildings, and drawn areas —
## since it only ever handles the target dictionary it is handed.

const C_TEXT := Color(0.886, 0.910, 0.941, 1.0)

signal space_changed(space_type: String)

var _loader: Node = null
var _target: Dictionary = {}
var _option: OptionButton
var _capacity: SpinBox
var _assigned: OptionButton
var _syncing := false


func _ready() -> void:
	add_theme_constant_override("separation", 6)
	_build()
	# Hidden until bound to something: several hosts (the pallet-rack modal, for
	# one) also open for a NOT-yet-placed prop, where there is nothing to tag.
	visible = false


## `target` is a SpaceRegistry target dict, e.g. {"kind":"prop","prop_id":…}.
## Passing an empty target hides the row.
func bind_target(loader: Node, target: Dictionary) -> void:
	_loader = loader
	_target = target
	_build()
	_sync()


func bind_prop(loader: Node, prop_id: String) -> void:
	if prop_id.is_empty():
		bind_target(loader, {})
		return
	bind_target(loader, {"kind": "prop", "prop_id": prop_id})


func bind_building(loader: Node, building_tag: String) -> void:
	if building_tag.is_empty():
		bind_target(loader, {})
		return
	bind_target(loader, {"kind": "building", "building_tag": building_tag})


## Current tag, or "" when untagged.
func current_type() -> String:
	var reg := _registry()
	if reg == null or _target.is_empty():
		return ""
	return str(reg.space_for_target(_target).get("space_type", ""))


func _build() -> void:
	if _option != null:
		return
	var lbl := Label.new()
	lbl.text = "NPC space"
	lbl.add_theme_color_override("font_color", C_TEXT)
	lbl.add_theme_font_size_override("font_size", 11)
	add_child(lbl)

	_option = OptionButton.new()
	_option.tooltip_text = "Tag this as a place people go — they will wayfind to it to meet that need"
	_option.add_item("None", 0)
	for i in SpaceTypes.TYPES.size():
		_option.add_item(SpaceTypes.label(SpaceTypes.TYPES[i]), i + 1)
	_option.add_theme_color_override("font_color", C_TEXT)
	_option.item_selected.connect(_on_type_selected)
	add_child(_option)

	_capacity = SpinBox.new()
	_capacity.min_value = 0.0
	_capacity.max_value = 5000.0
	_capacity.step = 1.0
	_capacity.value = float(SpaceRegistry.CAPACITY_AUTO)
	_capacity.tooltip_text = "How many people can use this space at once. 0 = Auto: never fills; people share the type's spaces by distance and crowding."
	_capacity.custom_minimum_size.x = 60.0
	_capacity.value_changed.connect(_on_capacity_changed)
	_capacity.visible = false
	add_child(_capacity)

	# Sleep spaces only: reserve this spot for one person ("Devi's bed").
	# The same assignment is editable from the Routines roster row.
	_assigned = OptionButton.new()
	_assigned.tooltip_text = "Reserve this sleeping spot for one person — Anyone means first come"
	_assigned.add_theme_color_override("font_color", C_TEXT)
	_assigned.custom_minimum_size.x = 110.0
	_assigned.item_selected.connect(_on_assigned_selected)
	_assigned.visible = false
	add_child(_assigned)


func _registry() -> SpaceRegistry:
	if _loader == null or not is_instance_valid(_loader):
		return null
	var reg: Variant = _loader.get("npc_spaces")
	return reg as SpaceRegistry if reg is SpaceRegistry else null


func _sync() -> void:
	if _option == null:
		return
	var reg := _registry()
	# No registry means a scene with no TerrainLoader — hide rather than offer a
	# control that cannot persist anything.
	visible = reg != null and not _target.is_empty()
	if not visible:
		return
	_syncing = true
	var rec := reg.space_for_target(_target)
	var idx := SpaceTypes.TYPES.find(str(rec.get("space_type", ""))) if not rec.is_empty() else -1
	_option.selected = idx + 1  # 0 = None
	_capacity.visible = idx >= 0
	if idx >= 0:
		_capacity.set_value_no_signal(
			float(int(rec.get("capacity", SpaceRegistry.DEFAULT_CAPACITY))))
	var is_sleep := idx >= 0 and str(SpaceTypes.TYPES[idx]) == "sleep"
	_assigned.visible = is_sleep
	if is_sleep:
		_populate_assigned(rec)
	_syncing = false


func _on_type_selected(idx: int) -> void:
	if _syncing:
		return
	var reg := _registry()
	if reg == null or _target.is_empty():
		return
	var space_type: String = "" if idx <= 0 else str(SpaceTypes.TYPES[idx - 1])
	reg.set_space_type(_target, space_type, int(_capacity.value))
	_save()
	_sync()
	space_changed.emit(space_type)


func _on_capacity_changed(v: float) -> void:
	if _syncing:
		return
	var reg := _registry()
	if reg == null or _target.is_empty():
		return
	var rec := reg.space_for_target(_target)
	if rec.is_empty():
		return
	reg.set_space_type(_target, str(rec.get("space_type", "")), int(v))
	_save()


func _populate_assigned(rec: Dictionary) -> void:
	_assigned.clear()
	_assigned.add_item("Anyone")
	_assigned.set_item_metadata(0, "")
	var cur := str(rec.get("assigned", ""))
	var found := cur.is_empty()
	for a in _roster_agents():
		var agent: NpcAgent = a
		_assigned.add_item(agent.display_name)
		_assigned.set_item_metadata(_assigned.item_count - 1, agent.id)
		if agent.id == cur:
			_assigned.select(_assigned.item_count - 1)
			found = true
	if not found:
		# Assigned to someone no longer on the roster. Shown honestly — the
		# sim already treats a stale assignment as open, so this is a label,
		# not a lock.
		_assigned.add_item("%s (gone)" % NpcAgent.name_for(cur))
		_assigned.set_item_metadata(_assigned.item_count - 1, cur)
		_assigned.select(_assigned.item_count - 1)


## Everyone across every pop-driven habitat — the picker should offer the
## whole settlement, not one board's roster.
func _roster_agents() -> Array:
	var out: Array = []
	var tree := get_tree()
	if tree == null:
		return out
	var sgv := tree.root.find_child("SystemGraphView", true, false)
	if sgv == null or not sgv.has_method("npc_population_bridge"):
		return out
	var bridge: Variant = sgv.call("npc_population_bridge")
	if bridge == null or not bridge.has_method("pop_driven_item_ids"):
		return out
	for iid in (bridge.call("pop_driven_item_ids") as Array):
		for a in (bridge.call("roster_for", str(iid)) as Array):
			out.append(a)
	return out


func _on_assigned_selected(i: int) -> void:
	if _syncing:
		return
	var reg := _registry()
	if reg == null or _target.is_empty():
		return
	var rec := reg.space_for_target(_target)
	if rec.is_empty():
		return
	reg.assign_agent(str(rec.get("id", "")), str(_assigned.get_item_metadata(i)))
	_save()


func _save() -> void:
	if _loader != null and _loader.has_method("save_npc_spaces"):
		_loader.call("save_npc_spaces")
