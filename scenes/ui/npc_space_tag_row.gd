class_name NpcSpaceTagRow
extends VBoxContainer

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
##
## VENUES get a second line: how the crowd stands (round it like a fire, or
## in a cone on ONE side facing it, like speakers), which way it faces
## (compass degrees, or "Toward me" — point the speakers at where you are
## standing), and for a stage the height of the deck its DJ stands on. While
## a directional prop venue is being edited an arrow on the ground shows the
## way it faces.

const C_TEXT := Color(0.886, 0.910, 0.941, 1.0)
const C_ARROW := Color(1.0, 0.72, 0.2, 0.9)

signal space_changed(space_type: String)

var _loader: Node = null
## Set before the row enters the tree to sit in a label/value form: the label
## gets this width (matching the form's other labels) and the type picker
## fills the rest. 0 = the compact inline look.
var form_label_w := 0.0
var _target: Dictionary = {}
var _line1: HBoxContainer
var _option: OptionButton
var _capacity: SpinBox
var _assigned: OptionButton
## Venue line.
var _line2: HBoxContainer
var _layout: OptionButton
var _facing: SpinBox
var _toward: Button
var _deck_row: HBoxContainer
var _deck_auto: CheckBox
var _deck: SpinBox
## The venue's track (record `music`, a file in StageMusic.DIR): plays from
## its speakers while its set is on.
var _music_row: HBoxContainer
var _music: OptionButton
var _music_files := PackedStringArray()
var _music_dialog: FileDialog = null
## How far off the venue's edge its crowd starts (record `crowd_gap_m`).
var _gap_row: HBoxContainer
var _gap_auto: CheckBox
var _gap: SpinBox
## A line on the ground where the front row will stand, while this row shows.
var _gap_line: MeshInstance3D = null
## ...or, round a ROUND venue, a ring where the crowd's front stands.
var _ring: MeshInstance3D = null
var _arrow: MeshInstance3D = null
var _syncing := false

const LAYOUT_ITEMS: Array = ["", SpaceRegistry.LAYOUT_RING, SpaceRegistry.LAYOUT_DIRECTIONAL]


func _ready() -> void:
	add_theme_constant_override("separation", 4)
	_build()
	# Hidden until bound to something: several hosts (the pallet-rack modal, for
	# one) also open for a NOT-yet-placed prop, where there is nothing to tag.
	visible = false


func _exit_tree() -> void:
	_free_arrow()


func _notification(what: int) -> void:
	if what == NOTIFICATION_VISIBILITY_CHANGED and is_inside_tree():
		_refresh_arrow()


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
	_line1 = HBoxContainer.new()
	_line1.add_theme_constant_override("separation", 6)
	add_child(_line1)
	var lbl := Label.new()
	lbl.text = "NPC space"
	lbl.add_theme_color_override("font_color", C_TEXT)
	lbl.add_theme_font_size_override("font_size", 11)
	if form_label_w > 0.0:
		lbl.custom_minimum_size.x = form_label_w
		lbl.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	_line1.add_child(lbl)

	_option = OptionButton.new()
	_option.tooltip_text = "Tag this as a place people go — they will wayfind to it to meet that need"
	_option.add_item("None", 0)
	for i in SpaceTypes.TYPES.size():
		_option.add_item(SpaceTypes.label(SpaceTypes.TYPES[i]), i + 1)
	_option.add_theme_color_override("font_color", C_TEXT)
	_option.item_selected.connect(_on_type_selected)
	if form_label_w > 0.0:
		_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_option.fit_to_longest_item = false
		_option.clip_text = true
	_line1.add_child(_option)

	_capacity = SpinBox.new()
	_capacity.min_value = 0.0
	_capacity.max_value = 5000.0
	_capacity.step = 1.0
	_capacity.value = float(SpaceRegistry.CAPACITY_AUTO)
	_capacity.tooltip_text = "How many people can use this space at once. 0 = Auto: never fills; people share the type's spaces by distance and crowding."
	_capacity.custom_minimum_size.x = 60.0
	_capacity.value_changed.connect(_on_capacity_changed)
	_capacity.visible = false
	_line1.add_child(_capacity)

	# Sleep spaces only: reserve this spot for one person ("Devi's bed").
	# The same assignment is editable from the Routines roster row.
	_assigned = OptionButton.new()
	_assigned.tooltip_text = "Reserve this sleeping spot for one person — Anyone means first come"
	_assigned.add_theme_color_override("font_color", C_TEXT)
	_assigned.custom_minimum_size.x = 110.0
	_assigned.item_selected.connect(_on_assigned_selected)
	_assigned.visible = false
	_line1.add_child(_assigned)

	# --- venue line -------------------------------------------------------
	_line2 = HBoxContainer.new()
	_line2.add_theme_constant_override("separation", 6)
	_line2.visible = false
	add_child(_line2)
	_layout = OptionButton.new()
	_layout.tooltip_text = "How the crowd stands: round it (a fire, an art piece) or in a cone on one side, facing it (speakers, a screen)"
	_layout.add_item("Crowd: by type", 0)
	_layout.add_item("Crowd: around it", 1)
	_layout.add_item("Crowd: facing one way", 2)
	_layout.add_theme_color_override("font_color", C_TEXT)
	_layout.item_selected.connect(_on_layout_selected)
	_line2.add_child(_layout)
	_facing = SpinBox.new()
	_facing.min_value = 0.0
	_facing.max_value = 359.0
	_facing.step = 1.0
	_facing.suffix = "°"
	_facing.custom_minimum_size.x = 70.0
	_facing.tooltip_text = "The way it faces — where its speakers point — as a compass bearing (0 = north, 90 = east). The DJ faces this way; the crowd stands in front, facing back."
	_facing.value_changed.connect(_on_facing_changed)
	_line2.add_child(_facing)
	_toward = Button.new()
	_toward.text = "Toward me"
	_toward.tooltip_text = "Point it at where you are standing (stand where the crowd should be)"
	_toward.pressed.connect(_on_toward_me)
	_line2.add_child(_toward)

	_deck_row = HBoxContainer.new()
	_deck_row.add_theme_constant_override("separation", 6)
	_deck_row.visible = false
	add_child(_deck_row)
	var dl := Label.new()
	dl.text = "DJ deck"
	dl.add_theme_color_override("font_color", C_TEXT)
	dl.add_theme_font_size_override("font_size", 11)
	_deck_row.add_child(dl)
	_deck_auto = CheckBox.new()
	_deck_auto.text = "Auto"
	_deck_auto.tooltip_text = "Measure the stage's deck height from its model"
	_deck_auto.toggled.connect(_on_deck_auto)
	_deck_row.add_child(_deck_auto)
	_deck = SpinBox.new()
	_deck.min_value = 0.0
	_deck.max_value = 8.0
	_deck.step = 0.05
	_deck.suffix = "m"
	_deck.custom_minimum_size.x = 70.0
	_deck.tooltip_text = "How high the DJ stands above the ground"
	_deck.value_changed.connect(_on_deck_changed)
	_deck_row.add_child(_deck)

	_gap_row = HBoxContainer.new()
	_gap_row.add_theme_constant_override("separation", 6)
	_gap_row.visible = false
	add_child(_gap_row)
	var gl := Label.new()
	gl.text = "Crowd distance"
	gl.add_theme_color_override("font_color", C_TEXT)
	gl.add_theme_font_size_override("font_size", 11)
	_gap_row.add_child(gl)
	_gap_auto = CheckBox.new()
	_gap_auto.text = "Auto"
	_gap_auto.tooltip_text = "Auto: the front row %.1f m off a directional venue's front edge, %.1f m off a fire's pit. The green line / ring on the ground shows where it stands." \
		% [VenueCrowd.STAGE_FAN_GAP_M, VenueCrowd.FIRE_RING_GAP_M]
	_gap_auto.toggled.connect(_on_gap_auto)
	_gap_row.add_child(_gap_auto)
	_gap = SpinBox.new()
	_gap.min_value = 0.0
	_gap.max_value = VenueCrowd.STAGE_FAN_GAP_MAX_M
	_gap.step = 0.25
	_gap.suffix = "m"
	_gap.custom_minimum_size.x = 70.0
	_gap.tooltip_text = "How far from the speakers (the front edge) the front row of the crowd stands. The green line on the ground shows it."
	_gap.value_changed.connect(_on_gap_changed)
	_gap_row.add_child(_gap)

	_music_row = HBoxContainer.new()
	_music_row.add_theme_constant_override("separation", 6)
	_music_row.visible = false
	add_child(_music_row)
	var ml := Label.new()
	ml.text = "Music"
	ml.add_theme_color_override("font_color", C_TEXT)
	ml.add_theme_font_size_override("font_size", 11)
	_music_row.add_child(ml)
	_music = OptionButton.new()
	_music.tooltip_text = "A track this venue plays from its speakers while its set is on — louder near the stage, quieter and muffled with distance and behind it. Volume: Settings → NPCs."
	_music.add_theme_color_override("font_color", C_TEXT)
	_music.custom_minimum_size.x = 170.0
	_music.item_selected.connect(_on_music_selected)
	_music_row.add_child(_music)


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
		_free_arrow()
		return
	_syncing = true
	var rec := reg.space_for_target(_target)
	var idx := SpaceTypes.TYPES.find(str(rec.get("space_type", ""))) if not rec.is_empty() else -1
	_option.selected = idx + 1  # 0 = None
	_capacity.visible = idx >= 0
	if idx >= 0:
		_capacity.set_value_no_signal(
			float(int(rec.get("capacity", SpaceRegistry.DEFAULT_CAPACITY))))
	var stype := str(SpaceTypes.TYPES[idx]) if idx >= 0 else ""
	var is_sleep := stype == "sleep"
	_assigned.visible = is_sleep
	if is_sleep:
		_populate_assigned(rec)
	# Venue line.
	var venue := idx >= 0 and SpaceTypes.is_venue(stype) and stype != "effigy"
	_line2.visible = venue
	_deck_row.visible = venue and stype == "stage"
	_gap_row.visible = venue
	_music_row.visible = venue
	if venue:
		var lay := str(rec.get("layout", ""))
		_layout.selected = maxi(LAYOUT_ITEMS.find(lay), 0)
		var directional := VenueCrowd.layout_of(stype, lay) == SpaceRegistry.LAYOUT_DIRECTIONAL
		_facing.editable = directional
		_toward.disabled = not directional
		var deg := float(rec.get("facing_deg", -1.0))
		if deg < 0.0:
			deg = _auto_facing_deg(str(rec.get("id", "")))
		_facing.set_value_no_signal(round(deg))
		var deck := float(rec.get("perform_h_m", -1.0))
		_deck_auto.set_pressed_no_signal(deck < 0.0)
		_deck.editable = deck >= 0.0
		_deck.set_value_no_signal(deck if deck >= 0.0 else maxf(_measured_deck(), 0.0))
		_populate_music(str(rec.get("music", "")))
		var gap := float(rec.get("crowd_gap_m", -1.0))
		_gap_auto.set_pressed_no_signal(gap < 0.0)
		_gap.editable = gap >= 0.0
		_gap.set_value_no_signal(gap if gap >= 0.0 else (VenueCrowd.STAGE_FAN_GAP_M if directional
			else VenueCrowd.round_gap(stype, {})))
	_syncing = false
	_refresh_arrow()


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


func _patch(fields: Dictionary) -> void:
	var reg := _registry()
	if reg == null or _target.is_empty():
		return
	var rec := reg.space_for_target(_target)
	if rec.is_empty():
		return
	reg.set_space_fields(str(rec.get("id", "")), fields)
	_save()


func _on_layout_selected(i: int) -> void:
	if _syncing:
		return
	_patch({"layout": str(LAYOUT_ITEMS[clampi(i, 0, LAYOUT_ITEMS.size() - 1)])})
	_sync()


func _on_facing_changed(v: float) -> void:
	if _syncing:
		return
	_patch({"facing_deg": fposmod(v, 360.0)})
	_refresh_arrow()


func _on_toward_me() -> void:
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	var c: Variant = _target_centre()
	if cam == null or not (c is Vector3):
		return
	var d := Vector2(cam.global_position.x - (c as Vector3).x, cam.global_position.z - (c as Vector3).z)
	if d.length() < 0.5:
		return
	var deg := VenueCrowd.deg_from_fwd(d.normalized())
	_patch({"facing_deg": deg})
	_syncing = true
	_facing.set_value_no_signal(round(deg))
	_syncing = false
	_refresh_arrow()


func _on_deck_auto(on: bool) -> void:
	if _syncing:
		return
	_patch({"perform_h_m": -1.0 if on else maxf(_deck.value, 0.0)})
	_sync()


func _on_deck_changed(v: float) -> void:
	if _syncing or _deck_auto.button_pressed:
		return
	_patch({"perform_h_m": maxf(v, 0.0)})


## "No music", every track in StageMusic.DIR, then "Add file…".
func _populate_music(current: String) -> void:
	_music.clear()
	_music_files = StageMusic.list_tracks()
	if not current.is_empty() and not _music_files.has(current):
		_music_files.append(current)   # missing on disk: still shown, so it can be cleared
	_music.add_item("No music", 0)
	for i in _music_files.size():
		_music.add_item(_music_files[i].get_basename(), i + 1)
	_music.add_item("Add file…", 9999)
	var sel := _music_files.find(current)
	_music.select(sel + 1 if sel >= 0 else 0)


func _on_music_selected(i: int) -> void:
	if _syncing:
		return
	var id := _music.get_item_id(i)
	if id == 9999:
		_open_music_dialog()
		return
	_patch({"music": "" if id == 0 else _music_files[id - 1]})


func _open_music_dialog() -> void:
	if _music_dialog == null:
		_music_dialog = FileDialog.new()
		_music_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
		_music_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_music_dialog.use_native_dialog = true
		_music_dialog.filters = PackedStringArray(["*.mp3, *.ogg, *.wav ; Audio"])
		_music_dialog.title = "Add a track for this venue"
		_music_dialog.file_selected.connect(_on_music_file)
		_music_dialog.canceled.connect(func() -> void: _sync())
		add_child(_music_dialog)
	_music_dialog.popup_centered_ratio(0.6)


func _on_music_file(path: String) -> void:
	var name := StageMusic.import_track(path)
	if not name.is_empty():
		_patch({"music": name})
	_sync()


func _on_gap_auto(on: bool) -> void:
	if _syncing:
		return
	_patch({"crowd_gap_m": -1.0 if on else maxf(_gap.value, 0.0)})
	_sync()
	_refresh_arrow()


func _on_gap_changed(v: float) -> void:
	if _syncing or _gap_auto.button_pressed:
		return
	_patch({"crowd_gap_m": clampf(v, 0.0, VenueCrowd.STAGE_FAN_GAP_MAX_M)})
	_refresh_arrow()


## The live bridge (for auto facing / measured deck), or null.
func _bridge() -> Object:
	if not is_inside_tree():
		return null
	var sgv := get_tree().root.find_child("SystemGraphView", true, false)
	if sgv == null or not sgv.has_method("npc_population_bridge"):
		return null
	return sgv.call("npc_population_bridge")


func _auto_facing_deg(sid: String) -> float:
	var b := _bridge()
	if b != null and b.has_method("venue_front"):
		var fr: Dictionary = b.call("venue_front", sid)
		if fr.get("fwd") is Vector2:
			return VenueCrowd.deg_from_fwd(fr["fwd"])
	return 180.0


func _measured_deck() -> float:
	var b := _bridge()
	if b == null or not b.has_method("stage_deck_m") or str(_target.get("kind", "")) != "prop":
		return 0.0
	return float(b.call("stage_deck_m", _main(), str(_target.get("prop_id", ""))))


func _main() -> Node:
	return _loader.get_parent() if _loader != null and is_instance_valid(_loader) else null


## World position of the tagged prop's footprint middle, or null.
func _target_centre() -> Variant:
	if str(_target.get("kind", "")) != "prop":
		return null
	var prop := PlacedPropRuntime.find_by_prop_id(_main(), str(_target.get("prop_id", "")))
	if prop == null:
		return null
	var bb := prop.get_world_pick_aabb()
	return Vector3(bb.get_center().x, bb.position.y, bb.get_center().z) if bb.size.length_squared() > 0.01 \
		else prop.global_position


# --- facing arrow ---------------------------------------------------------------

## An amber arrow on the ground in front of a DIRECTIONAL prop venue, pointing
## the way it faces, while this row is showing it.
func _refresh_arrow() -> void:
	# A visibility change can arrive before _ready has built the row (a host
	# that shows its panel while the row is being added).
	if _line2 == null:
		return
	if not is_inside_tree() or not is_visible_in_tree() or not _line2.visible:
		_free_arrow()
		return
	if not _facing.editable:
		# A ROUND venue: no arrow; a green ring where its crowd's front stands.
		_refresh_front_ring()
		return
	_free_ring()
	var c: Variant = _target_centre()
	if not (c is Vector3):
		_free_arrow()
		return
	var prop := PlacedPropRuntime.find_by_prop_id(_main(), str(_target.get("prop_id", "")))
	var bb := prop.get_world_pick_aabb() if prop != null else AABB()
	var reach := maxf(bb.size.x, bb.size.z) * 0.5 + 1.0
	if _arrow == null:
		_arrow = MeshInstance3D.new()
		_arrow.name = "VenueFacingArrow"
		_arrow.top_level = true
		_arrow.mesh = _arrow_mesh()
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = C_ARROW
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.no_depth_test = true
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_arrow.material_override = m
		_arrow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var host := _main()
		if host == null:
			_arrow.free()
			_arrow = null
			return
		host.add_child(_arrow)
	var fwd := VenueCrowd.fwd_from_deg(_facing.value)
	var p := c as Vector3
	var at := Vector3(p.x + fwd.x * reach, p.y + 0.15, p.z + fwd.y * reach)
	# Mesh points along local -Z; yaw so -Z maps onto fwd (x, z).
	_arrow.global_transform = Transform3D(Basis(Vector3.UP, atan2(-fwd.x, -fwd.y)), at)
	# The crowd line: the front edge along the facing (as VenueCrowd.
	# stage_front measures it, from the pick box) plus the crowd distance.
	if _gap_line == null:
		_gap_line = MeshInstance3D.new()
		_gap_line.name = "VenueCrowdLine"
		_gap_line.top_level = true
		var q := QuadMesh.new()
		q.size = Vector2(6.0, 0.18)
		q.orientation = PlaneMesh.FACE_Y
		_gap_line.mesh = q
		var lm := StandardMaterial3D.new()
		lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		lm.albedo_color = Color(0.45, 1.0, 0.55, 0.85)
		lm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		lm.no_depth_test = true
		lm.cull_mode = BaseMaterial3D.CULL_DISABLED
		_gap_line.material_override = lm
		_gap_line.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_main().add_child(_gap_line)
	var corners := PackedVector2Array()
	for i in 4:
		var x := bb.position.x + (bb.size.x if i == 1 or i == 2 else 0.0)
		var z := bb.position.z + (bb.size.z if i >= 2 else 0.0)
		corners.append(Vector2(x, z))
	var cc := Vector2(p.x, p.z)
	var front := VenueCrowd.stage_front(cc, corners, fwd) if bb.size.length_squared() > 0.01 else cc
	var gap := _gap.value if not _gap_auto.button_pressed else VenueCrowd.STAGE_FAN_GAP_M
	var lp := front + fwd * gap
	_gap_line.global_transform = Transform3D(Basis(Vector3.UP, atan2(-fwd.x, -fwd.y)),
		Vector3(lp.x, p.y + 0.12, lp.y))


## The front-row ring round a ROUND venue (a fire's dance ring, a round
## stage, an art piece's groups), sized from the same rule the crowd uses.
func _refresh_front_ring() -> void:
	if _arrow != null and is_instance_valid(_arrow):
		_arrow.queue_free()
	_arrow = null
	if _gap_line != null and is_instance_valid(_gap_line):
		_gap_line.queue_free()
	_gap_line = null
	var c: Variant = _target_centre()
	var host := _main()
	if not (c is Vector3) or host == null:
		_free_ring()
		return
	var prop := PlacedPropRuntime.find_by_prop_id(host, str(_target.get("prop_id", "")))
	var bb := prop.get_world_pick_aabb() if prop != null else AABB()
	var fr := maxf(bb.size.x, bb.size.z) * 0.5
	var stype := current_type()
	var extra := {"gap": -1.0 if _gap_auto.button_pressed else _gap.value}
	var r := VenueCrowd.front_ring_r(stype, fr, extra)
	if _ring == null:
		_ring = MeshInstance3D.new()
		_ring.name = "VenueCrowdRing"
		_ring.top_level = true
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = Color(0.45, 1.0, 0.55, 0.8)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.no_depth_test = true
		m.cull_mode = BaseMaterial3D.CULL_DISABLED
		_ring.material_override = m
		_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		host.add_child(_ring)
	var tm := TorusMesh.new()
	tm.inner_radius = maxf(r - 0.07, 0.05)
	tm.outer_radius = r + 0.07
	tm.rings = 64
	tm.ring_segments = 4
	_ring.mesh = tm
	var p := c as Vector3
	_ring.global_transform = Transform3D(Basis.from_scale(Vector3(1.0, 0.15, 1.0)), Vector3(p.x, p.y + 0.1, p.z))


func _free_ring() -> void:
	if _ring != null and is_instance_valid(_ring):
		_ring.queue_free()
	_ring = null


func _free_arrow() -> void:
	_free_ring()
	if _arrow != null and is_instance_valid(_arrow):
		_arrow.queue_free()
	_arrow = null
	if _gap_line != null and is_instance_valid(_gap_line):
		_gap_line.queue_free()
	_gap_line = null


static func _arrow_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# A flat arrow on the ground pointing along -Z: shaft 0.5 m wide x 3 m,
	# head 1.6 m wide x 1.4 m.
	var pts: Array = [
		Vector3(-0.25, 0.0, 0.0), Vector3(0.25, 0.0, 0.0), Vector3(0.25, 0.0, -3.0),
		Vector3(-0.25, 0.0, 0.0), Vector3(0.25, 0.0, -3.0), Vector3(-0.25, 0.0, -3.0),
		Vector3(-0.8, 0.0, -3.0), Vector3(0.8, 0.0, -3.0), Vector3(0.0, 0.0, -4.4),
	]
	for p in pts:
		st.add_vertex(p)
	return st.commit()


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
