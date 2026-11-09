extends Control

## The tri-clamp (sanitary) process designer. Pick a clamp size and a part
## from the palette, then click an open end in the sandbox: the part snaps
## on by one of its ends (Tab picks which, R rolls it about the joint) with a
## gasket and a clamp drawn and counted. Click the floor to start a new run.
## Click a part, clamp or open end to select it and edit it on the right;
## drag a part to pull it (and what hangs off it) off and drop it on another
## open end. Loops are checked for closing; a spool with Fit length solves
## itself to close one. Exports a GLB, an STL, the bill of materials and the
## design. Plan: plans/TRICLAMP_DESIGNER_PLAN.md (Phase 3).
##
## Left:   clamp size, the part palette, designs (built-ins + library).
## Centre: the 3D sandbox (ports drawn as rings: cyan open clamp ends,
##         yellow threads and barbs, amber the end a ghost will join).
## Right:  the selection's card, the checks, the summary, the parts list.

const MODAL_NAME := "tclab_designer"
const WANT := Vector2(1640, 980)
const UNDO_LIMIT := 80
const SNAP_PX := 48.0
const DRAG_PX := 6.0
const MM := 0.001
const ProcessPanel := preload("res://scenes/ui/tclab_process_panel.gd")

var _active := false
var _spec: Dictionary = {}
var _design: Dictionary = {}
var _undo: Array = []
var _redo: Array = []
var _size := "1.5"
var _tool: Dictionary = {}          # {type, size, params}
var _ghost_port := 0
var _ghost_roll := 0.0
var _ghost_yaw := 0.0
var _snap: Dictionary = {}          # {ref, xf (mm), ok, why}
var _ghost_xf := Transform3D.IDENTITY
var _sel: Dictionary = {}           # {kind: part|joint|port, id}
var _press: Dictionary = {}         # {id, pos, kind}
var _drag: Dictionary = {}          # live part drag
var _hover_pos := Vector2(-1, -1)
var _library: Array = []
var _design_entries: Array = []
var _last_status := ""
var _cutaway := false
var _bound_prop_id := ""

# UI
var _shell: DesignerShell
var _studio: StudioViewport
var _builder: TcBuilder
var _ghost: MeshInstance3D
var _markers: Node3D
var _size_btns: Dictionary = {}
var _tool_btns: Dictionary = {}
var _design_list: ItemList
var _card: VBoxContainer
var _checks_box: VBoxContainer
var _summary: Label
var _bom_box: VBoxContainer
var _status: Label
var _hover_lbl: Label
var _place_btn: Button
var _apply_btn: Button
var _binds_row: FormRow
var _world_note: Label
var _design_left: VBoxContainer
var _design_right: VBoxContainer
var _proc: Node = null                # the Process mode (tclab_process_panel.gd)
var _proc_mode := false
var _mode_btns := {}


func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_ui()
	set_process(false)


# ---------------------------------------------------------------------------
# Open / close / API
# ---------------------------------------------------------------------------

## opts: {spec, prop_id (edit a placed assembly; Apply writes it back)}
func open(opts: Dictionary = {}) -> void:
	if _active:
		return
	var spec: Dictionary = opts.get("spec", {})
	_bound_prop_id = str(opts.get("prop_id", ""))
	if not _bound_prop_id.is_empty():
		var rec := _prop_record(_bound_prop_id)
		spec = rec.get("tc_spec", {}) as Dictionary if rec.get("tc_spec") is Dictionary else {}
		if spec.is_empty():
			spec = TcBuilder.spec_for_model(str(rec.get("model_id", "")))
		if rec.is_empty():
			_bound_prop_id = ""
	if spec.is_empty():
		spec = TcPresets.builtin("elbow_run")
	_undo.clear()
	_redo.clear()
	_tool = {}
	_sel = {}
	_drag = {}
	_library = TcPresets.load_library()
	if _proc_mode:
		set_run_mode(false)
	_active = true
	visible = true
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_process(true)
	_shell.open()
	_refresh_design_list()
	_set_spec(spec, false)
	_frame()
	_set_status("")
	_apply_btn.visible = not _bound_prop_id.is_empty()
	_place_btn.text = "Place a copy" if not _bound_prop_id.is_empty() else "Place in world"


func close() -> void:
	if not _active:
		return
	if _proc_mode:
		set_run_mode(false)
	_active = false
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(false)
	_disarm()
	_shell.close()


func is_open() -> bool:
	return _active


func bound_prop_id() -> String:
	return _bound_prop_id


func design() -> Dictionary:
	return _design


func spec() -> Dictionary:
	return _spec


func studio() -> StudioViewport:
	return _studio


func tool_id() -> String:
	return str(_tool.get("type", ""))


func selected() -> Dictionary:
	return _sel.duplicate()


func snap_target() -> String:
	return str(_snap.get("ref", ""))


func status_text() -> String:
	return _last_status


## A point in assembly mm as a position in the studio container.
func studio_pos_of(p_mm: Vector3) -> Vector2:
	var vp_px := _studio.camera.unproject_position(p_mm * MM)
	var vs := Vector2(_studio.viewport.size)
	var cs := _studio.container.size
	return vp_px * (cs / vs) if vs.x > 0.0 else vp_px


## An open port's face centre in the studio container ("" = not open).
func port_pos(ref: String) -> Vector2:
	for op in _design["res"]["open"]:
		if str(op["ref"]) == ref:
			return studio_pos_of((op["xf"] as Transform3D).origin)
	return Vector2(-1, -1)


## A part's centre in the studio container.
func part_pos(id: String) -> Vector2:
	var pd: Dictionary = _design["res"]["parts"].get(id, {})
	if pd.is_empty():
		return Vector2(-1, -1)
	var bb: AABB = pd["built"]["bounds"]
	return studio_pos_of((pd["xf"] as Transform3D) * (bb.position + bb.size * 0.5))


func builder() -> TcBuilder:
	return _builder


func process_panel() -> Node:
	return _proc


func is_process_mode() -> bool:
	return _proc_mode


## Design mode (build the assembly) or Process mode (run it).
func set_run_mode(on: bool) -> void:
	if on == _proc_mode:
		return
	_proc_mode = on
	_disarm()
	_drag = {}
	_press = {}
	_design_left.visible = not on
	_design_right.visible = not on
	_markers.visible = not on   # the open-end markers are for building
	for k in _mode_btns.keys():
		(_mode_btns[k] as Button).set_pressed_no_signal((str(k) == "process") == on)
	if on:
		_sel = {}
		_rebuild_studio()
		_proc.call("enter", _design)
		_shell.set_mode("Process")
		_shell.set_hint("Play runs the process · click a part to see what is in it · drag the chart to scrub · Space: play / pause")
	else:
		_proc.call("exit")
		_shell.set_mode("")
		_shell.set_hint("Pick a part, click an open end · Tab: next end · R: roll · drag a part to move it · Del removes")
		_rebuild_studio()
	_shell.scroll_top()


## A new process block from the Process mode (undoable).
func set_process_block(p: Dictionary) -> void:
	var s := _spec.duplicate(true)
	s["process"] = p
	_set_spec(s)


func load_builtin(id: String) -> void:
	var s := TcPresets.builtin(id)
	if s.is_empty():
		return
	_push_undo()
	_disarm()
	_sel = {}
	_set_spec(s, false)
	_frame()
	_set_status("Loaded “%s”." % str(_spec["name"]))


func arm_tool(type: String, size: String = "") -> void:
	if not size.is_empty():
		_pick_size(size)
	_arm(type)


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

func _build_ui() -> void:
	_shell = DesignerShell.create("Tri-clamp designer", "workflow", {
		"name_id": MODAL_NAME, "want": WANT, "name_edit": true, "undo": true,
		"left_label": "Parts & designs", "left_w": 250.0, "right_w": 390.0})
	add_child(_shell)
	_shell.undo_requested.connect(_undo_step)
	_shell.redo_requested.connect(_redo_step)
	_shell.name_submitted.connect(_on_name_submitted)
	_shell.closed.connect(close)
	_build_left()
	_build_centre()
	_build_right()
	_proc = ProcessPanel.new()
	_proc.name = "Process"
	add_child(_proc)
	_proc.call("setup", self, _shell.left, _shell.right, _shell.centre)
	_shell.add_button("Export files", DesignerShell.SECONDARY, _on_export,
		"Write a GLB, an STL (mm), the bill of materials (CSV) and the design (JSON)")
	_apply_btn = _shell.add_button("Apply to placed assembly", DesignerShell.SECONDARY, _on_apply,
		"Rebuild the placed assembly as this design")
	_apply_btn.name = "apply_placed"
	_place_btn = _shell.add_button("Place in world", DesignerShell.PRIMARY, _on_place,
		"Place this assembly on the map as one prop; its labelled ends become pipe ports")
	_place_btn.name = "place_world"
	_shell.add_button("Close", DesignerShell.SECONDARY, close)
	_shell.set_hint("Pick a part, click an open end · Tab: next end · R: roll · drag a part to move it · Del removes")


func _build_left() -> void:
	_design_left = VBoxContainer.new()
	_design_left.name = "design_left"
	_design_left.add_theme_constant_override("separation", 4)
	_shell.left.add_child(_design_left)
	var box := _design_left
	box.add_child(SectionHeader.make("Clamp size", "ruler"))
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 3)
	flow.add_theme_constant_override("v_separation", 3)
	box.add_child(flow)
	for s in TcStandards.SIZES:
		var b := Button.new()
		b.name = "size_%s" % str(s).replace(".", "_")
		b.text = TcStandards.size_label(str(s))
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(44, 28)
		b.tooltip_text = "%s tube (%.1f mm OD, %.1f mm clamp face)" % [TcStandards.size_label(str(s)),
			float(TcStandards.tube(str(s))["od"]), float(TcStandards.tube(str(s))["flange"])]
		b.pressed.connect(_pick_size.bind(str(s)))
		flow.add_child(b)
		_size_btns[str(s)] = b
	for cat in TcParts.CATEGORIES:
		box.add_child(SectionHeader.make(str(cat[1]), str(cat[2])))
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 2)
		box.add_child(col)
		for t in TcParts.types_in(str(cat[0])):
			var b := Button.new()
			b.name = "tool_%s" % t
			b.text = TcParts.label_of(t)
			b.toggle_mode = true
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			b.custom_minimum_size = Vector2(0, 28)
			b.tooltip_text = "%s\n%s\nShift-click the sandbox to place several." % [
				str(TcParts.TYPES[t]["designation"]), str(TcParts.TYPES[t]["why"])]
			b.pressed.connect(_on_tool_pressed.bind(t))
			col.add_child(b)
			_tool_btns[t] = b
	box.add_child(SectionHeader.make("Designs", "layout-grid"))
	_design_list = ItemList.new()
	_design_list.name = "designs"
	_design_list.auto_height = true
	_design_list.custom_minimum_size = Vector2(0, 120)
	_design_list.item_activated.connect(_on_design_picked)
	_design_list.item_selected.connect(_on_design_picked)
	box.add_child(_design_list)
	var lib := HBoxContainer.new()
	var save := Button.new()
	save.text = "Save design"
	save.tooltip_text = "Keep this design in your library (every world), under the name in the header"
	UITheme.style_button(save)
	save.pressed.connect(_on_save_design)
	lib.add_child(save)
	var forget := Button.new()
	forget.text = "Forget"
	forget.tooltip_text = "Remove the selected saved design"
	UITheme.style_button(forget)
	forget.pressed.connect(_on_forget_design)
	lib.add_child(forget)
	var new_btn := Button.new()
	new_btn.text = "New"
	new_btn.tooltip_text = "Start an empty sandbox (Ctrl+Z brings this one back)"
	UITheme.style_button(new_btn)
	new_btn.pressed.connect(_on_new)
	lib.add_child(new_btn)
	box.add_child(lib)
	_pick_size(_size)


func _build_centre() -> void:
	_studio = StudioViewport.create({"ground": true, "person": false})
	_studio.set_home(0.75, 0.42)
	_studio.dist_max = 40.0
	_studio.input_hook = _studio_input
	_studio.clicked.connect(_on_studio_click)
	_shell.centre.add_child(_studio)
	_builder = TcBuilder.new()
	_builder.name = "Assembly"
	_studio.holder.add_child(_builder)
	_markers = Node3D.new()
	_markers.name = "Ports"
	_studio.holder.add_child(_markers)
	for m in [["design", "Design", "Build the assembly"], ["process", "Process", "Run it: heat, boil, react, condense — watch what happens inside"]]:
		var mb := Button.new()
		mb.name = "mode_%s" % str(m[0])
		mb.text = str(m[1])
		mb.toggle_mode = true
		mb.button_pressed = str(m[0]) == "design"
		mb.tooltip_text = str(m[2])
		UITheme.style_button(mb)
		mb.pressed.connect(func() -> void: set_run_mode(str(m[0]) == "process"))
		_studio.strip.add_child(mb)
		_mode_btns[str(m[0])] = mb
	var cut := CheckBox.new()
	cut.name = "cutaway"
	cut.text = "Cutaway"
	cut.tooltip_text = "Cut a quarter out of every vessel to see inside"
	cut.toggled.connect(func(on: bool) -> void:
		_cutaway = on
		_rebuild_studio())
	_studio.strip.add_child(cut)
	for v in [["Frame", "F"], ["Front", ""], ["Top", ""], ["Side", ""]]:
		var b := Button.new()
		b.text = str(v[0])
		b.tooltip_text = "Frame the assembly (F)" if str(v[0]) == "Frame" else "Look from the %s" % str(v[0]).to_lower()
		UITheme.style_button(b)
		b.pressed.connect(_on_view.bind(str(v[0])))
		_studio.strip.add_child(b)
	_hover_lbl = Label.new()
	_hover_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hover_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_hover_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_hover_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_studio.strip.add_child(_hover_lbl)


func _build_right() -> void:
	_design_right = VBoxContainer.new()
	_design_right.name = "design_right"
	_design_right.add_theme_constant_override("separation", 4)
	_shell.right.add_child(_design_right)
	var box := _design_right
	_card = VBoxContainer.new()
	_card.name = "card"
	_card.add_theme_constant_override("separation", 4)
	box.add_child(_card)
	box.add_child(SectionHeader.make("In the world", "globe"))
	var opts: Array = [["", "Nothing (just the assembly)"]]
	for lab in _processor_labels():
		opts.append([lab, lab])
	_binds_row = FormRow.option("On the graph", opts, func(v: Variant) -> void:
		var s := _spec.duplicate(true)
		s["binds"] = str(v)
		_set_spec(s), "Placing it makes this graph node too; its labelled ends become the node's ports where the kinds match", "binds")
	box.add_child(_binds_row)
	_world_note = Label.new()
	_world_note.name = "world_note"
	_world_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_world_note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_world_note.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	box.add_child(_world_note)
	box.add_child(SectionHeader.make("Checks", "shield-check"))
	_checks_box = VBoxContainer.new()
	_checks_box.add_theme_constant_override("separation", 3)
	box.add_child(_checks_box)
	box.add_child(SectionHeader.make("Summary", "info"))
	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_summary.add_theme_font_size_override("font_size", UITheme.FONT_SM)
	box.add_child(_summary)
	box.add_child(SectionHeader.make("Parts list", "list"))
	_bom_box = VBoxContainer.new()
	_bom_box.add_theme_constant_override("separation", 1)
	box.add_child(_bom_box)
	_status = Label.new()
	_status.name = "status"
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_status.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	box.add_child(_status)


# ---------------------------------------------------------------------------
# Spec, undo, rebuild
# ---------------------------------------------------------------------------

func _set_spec(s: Dictionary, push: bool = true) -> void:
	if push:
		_push_undo()
	_spec = TcSpec.resolve(s)
	_design = _solve(_spec)
	if _shell.name_edit != null and _shell.name_edit.text != str(_spec["name"]):
		_shell.name_edit.text = str(_spec["name"])
	if not _sel.is_empty() and not _sel_exists():
		_sel = {}
	_rebuild_studio()
	_seat_ground()
	_refresh_right()
	if _proc_mode and _proc != null:
		_proc.call("design_changed", _design)


## The solved design carrying THIS spec. TcDesign.solve is cached on the
## geometry key, which leaves the process block out, so the cached design's
## own spec can carry an older process (a watts edit, a rule) — the Process
## mode reads the run from design["spec"]. A shallow copy with the live spec.
func _solve(s: Dictionary) -> Dictionary:
	var d := TcDesign.solve(s).duplicate()
	d["spec"] = s
	return d


func _sel_exists() -> bool:
	match str(_sel.get("kind", "")):
		"part":
			return (_design["res"]["parts"] as Dictionary).has(str(_sel["id"]))
		"joint":
			return int(_sel["id"]) < (_design["res"]["joints"] as Array).size()
		"port":
			for op in _design["res"]["open"]:
				if str(op["ref"]) == str(_sel["id"]):
					return true
		"nozzle":
			return not _nozzle(str(_sel["id"])).is_empty()
	return false


func _push_undo() -> void:
	if _spec.is_empty():
		return
	_undo.append(_spec.duplicate(true))
	if _undo.size() > UNDO_LIMIT:
		_undo.pop_front()
	_redo.clear()
	_shell.set_undo_state(true, false)


func _undo_step() -> void:
	if _undo.is_empty():
		return
	_redo.append(_spec.duplicate(true))
	_set_spec(_undo.pop_back(), false)
	_shell.set_undo_state(not _undo.is_empty(), true)


func _redo_step() -> void:
	if _redo.is_empty():
		return
	_undo.append(_spec.duplicate(true))
	_set_spec(_redo.pop_back(), false)
	_shell.set_undo_state(true, not _redo.is_empty())


func _rebuild_studio() -> void:
	var marked: Array = []
	for c in _design.get("clashes", []):
		marked.append(c[0])
		marked.append(c[1])
	var opts := {"marked": marked, "cutaway": _cutaway}
	if str(_sel.get("kind", "")) == "part":
		opts["selected"] = [str(_sel["id"])]
	elif str(_sel.get("kind", "")) == "joint":
		opts["joint_selected"] = int(_sel["id"])
	elif str(_sel.get("kind", "")) == "nozzle":
		opts["selected"] = [str(_sel["id"]).get_slice(":", 0)]
	if not _drag.is_empty() and _drag.has("ids"):
		opts["selected"] = _drag["ids"]
	_builder.build(_design, opts)
	_rebuild_markers()


func _rebuild_markers() -> void:
	for c in _markers.get_children():
		_markers.remove_child(c)
		c.queue_free()
	var target := str(_snap.get("ref", ""))
	var sel_port := str(_sel.get("id", "")) if str(_sel.get("kind", "")) == "port" else ""
	var moving: Array = _drag.get("ids", []) if not _drag.is_empty() else []
	for op in _design["res"]["open"]:
		if str(op["part"]) in moving:
			continue
		var p: Dictionary = op["port"]
		var tc := str(p["kind"]) == "tc"
		var r := float(TcStandards.tube(str(p["size"]))["r_flange"]) if tc else TcStandards.npt_od(str(p["size"])) * 0.5 + 2.0
		var mi := MeshInstance3D.new()
		var tor := TorusMesh.new()
		tor.inner_radius = r * MM * 1.02
		tor.outer_radius = r * MM * 1.02 + maxf(r * MM * 0.07, 0.0015)
		tor.rings = 24
		tor.ring_segments = 6
		mi.mesh = tor
		var col := Color(0.2, 0.9, 1.0) if tc else Color(1.0, 0.85, 0.2)
		if str(op["ref"]) == target:
			col = Color(1.0, 0.65, 0.1)
		elif str(op["ref"]) == sel_port:
			col = Color(1.0, 1.0, 1.0)
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = col
		m.no_depth_test = true
		m.render_priority = 2
		mi.material_override = m
		var xf: Transform3D = op["xf"]
		# A torus lies in its local XZ plane: its axis is local Y.
		mi.transform = Transform3D(Basis(xf.basis.x, xf.basis.z, -xf.basis.y), (xf.origin + xf.basis.z * 1.0) * MM)
		_markers.add_child(mi)


## The studio floor sits under the design's lowest point (a gas line, a
## drain elbow or a unit's feet can hang below the first part's y = 0), so
## nothing is ever drawn below the ground.
func _seat_ground() -> void:
	if _studio == null or _studio.ground == null:
		return
	var bb: AABB = (_design.get("stats", {}) as Dictionary).get("bounds_mm", AABB())
	_studio.ground.position.y = minf(bb.position.y, 0.0) * MM - 0.0005


## Fittings are small: frame on the assembly's own size (the kit's
## frame_sphere adds a metre of air, which left a 1½" run a speck).
func _frame() -> void:
	var bb: AABB = _design["stats"]["bounds_mm"]
	var c := Vector3(0, 0.06, 0)
	var r := 0.12
	if bb.size.length() >= 1.0:
		c = (bb.position + bb.size * 0.5) * MM
		r = maxf(bb.size.length() * 0.5 * MM, 0.05)
	_seat_ground()
	_studio.target = c
	_studio.dist = clampf(r * 2.7, StudioViewport.DIST_MIN, _studio.dist_max)
	_studio.update_camera()


func _on_view(which: String) -> void:
	match which:
		"Front": _studio.set_orbit(0.0, 0.05)
		"Top": _studio.set_orbit(0.0, 1.45)
		"Side": _studio.set_orbit(PI * 0.5, 0.05)
	_frame()


# ---------------------------------------------------------------------------
# Palette
# ---------------------------------------------------------------------------

func _pick_size(s: String) -> void:
	_size = s
	for k in _size_btns:
		(_size_btns[k] as Button).set_pressed_no_signal(str(k) == s)
	if not _tool.is_empty():
		_arm(str(_tool["type"]))


func _on_tool_pressed(t: String) -> void:
	if str(_tool.get("type", "")) == t:
		_disarm()
	else:
		_arm(t)


func _arm(t: String) -> void:
	_disarm()
	_tool = {"type": t, "size": _size, "params": TcParts.default_params(t, _size)}
	_ghost_port = 0
	_ghost_roll = 0.0
	for k in _tool_btns:
		(_tool_btns[k] as Button).set_pressed_no_signal(str(k) == t)
	_ghost = TcBuilder.ghost_node(t, _size, _tool["params"], true)
	_ghost.visible = false
	_studio.holder.add_child(_ghost)
	_update_mode()
	if _hover_pos.x >= 0.0:
		_update_ghost(_hover_pos)


func _disarm() -> void:
	_tool = {}
	_snap = {}
	if is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = null
	for k in _tool_btns:
		(_tool_btns[k] as Button).set_pressed_no_signal(false)
	if _shell != null:
		_shell.set_mode("")
	if _markers != null and _active:
		_rebuild_markers()


func _update_mode() -> void:
	if _tool.is_empty():
		_shell.set_mode("")
		return
	var b := TcParts.build(str(_tool["type"]), str(_tool["size"]), _tool["params"])
	var n := (b["ports"] as Array).size()
	var port: Dictionary = b["ports"][_ghost_port % n]
	_shell.set_mode("Placing %s · joins by its %s end (%s) · Tab: next end · R: roll · Esc" % [
		str(b["label"]), TcParts.kind_word(str(port["kind"])), str(port["id"]).to_upper()])


# ---------------------------------------------------------------------------
# Studio input
# ---------------------------------------------------------------------------

func _studio_input(e: InputEvent) -> bool:
	if _proc_mode:
		return false   # orbit and click only while the process runs
	if e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		_hover_pos = mm.position
		if not _press.is_empty() and _drag.is_empty() and mm.position.distance_to(_press["pos"]) > DRAG_PX:
			if _press.has("nozzle"):
				_drag = {"nozzle": str(_press["nozzle"]), "spec": _spec}
				_select({"kind": "nozzle", "id": str(_press["nozzle"])})
			else:
				_begin_drag()
		if not _drag.is_empty():
			if _drag.has("nozzle"):
				_update_nozzle_drag(mm.position)
			else:
				_update_drag(mm.position)
			return true
		if not _tool.is_empty():
			_update_ghost(mm.position)
		else:
			_update_hover(mm.position)
		return not _press.is_empty()
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if mb.pressed:
			if not _tool.is_empty():
				return false
			var hit := _pick(mb.position)
			var noz := _nozzle_of_hit(hit)
			if not noz.is_empty():
				_press = {"nozzle": noz, "pos": mb.position}
				return true
			if str(hit.get("kind", "")) == "part":
				_press = {"id": str(hit["id"]), "pos": mb.position, "shift": mb.shift_pressed}
				return true
			return false
		else:
			if not _drag.is_empty():
				if _drag.has("nozzle"):
					var s: Dictionary = _drag["spec"]
					var ref := str(_drag["nozzle"])
					_drag = {}
					_set_spec(s)
					_select({"kind": "nozzle", "id": ref})
					_set_status("Moved nozzle %s." % ref.get_slice(":", 1))
				else:
					_end_drag()
				_press = {}
				return true
			if not _press.is_empty():
				if _press.has("nozzle"):
					_select({"kind": "nozzle", "id": str(_press["nozzle"])})
				else:
					_select({"kind": "part", "id": str(_press["id"])})
				_press = {}
				return true
	return false


## A picked open port or clamp joint that sits on a vessel's nozzle: its
## "vessel:nozzle" ref ("" = not a nozzle).
func _nozzle_of_hit(hit: Dictionary) -> String:
	var refs: Array = []
	match str(hit.get("kind", "")):
		"port":
			refs = [str(hit["id"])]
		"joint":
			var jd: Dictionary = _design["res"]["joints"][int(hit["id"])]
			refs = [str(jd["a"]), str(jd["b"])]
	for ref in refs:
		var pd: Dictionary = _design["res"]["parts"].get(str(ref).get_slice(":", 0), {})
		if not pd.is_empty() and str(pd["built"]["type"]) == "vessel":
			return str(ref)
	return ""


func _update_nozzle_drag(pos: Vector2) -> void:
	var ref := str(_drag["nozzle"])
	var vid := ref.get_slice(":", 0)
	var nid := ref.get_slice(":", 1)
	var base := _spec
	var p := TcSpec.part_of(base, vid)
	var pd: Dictionary = TcDesign.solve(base)["res"]["parts"].get(vid, {})
	var r := _ray_mm(pos)
	if p.is_empty() or pd.is_empty() or r.is_empty():
		return
	var inv: Transform3D = (pd["xf"] as Transform3D).affine_inverse()
	var o: Vector3 = inv * (r["origin"] as Vector3)
	var d: Vector3 = (inv.basis * (r["dir"] as Vector3)).normalized()
	var vp: Dictionary = TcVessel.resolve(p["params"])
	var ports: Array = (vp["ports"] as Array).duplicate(true)
	for i in ports.size():
		if str(ports[i]["id"]) == nid:
			ports[i] = TcVessel.surface_hit(vp, ports[i], o, d)
			_hover_lbl.text = "Nozzle %s · %d° · %s" % [nid, roundi(float(ports[i]["angle_deg"])),
				("%d mm up" % roundi(float(ports[i]["h_mm"]))) if str(ports[i]["face"]) == "shell" else ("%d mm out" % roundi(float(ports[i]["r_mm"])))]
	_drag["spec"] = TcAssembly.set_part(base, vid, {"params": {"ports": ports}})
	_design = TcDesign.solve_transient(_drag["spec"])
	_rebuild_studio()


func _on_studio_click(pos: Vector2, button: int) -> void:
	if _proc_mode:
		if button == MOUSE_BUTTON_LEFT:
			_proc.call("on_click", _pick(pos))
		return
	if button != MOUSE_BUTTON_LEFT:
		if button == MOUSE_BUTTON_RIGHT and not _tool.is_empty():
			_disarm()
		return
	if not _tool.is_empty():
		_update_ghost(pos)
		_place(Input.is_key_pressed(KEY_SHIFT))
		return
	var hit := _pick(pos)
	if hit.is_empty():
		_select({})
	else:
		_select({"kind": str(hit["kind"]), "id": hit["id"]})


func _ray_mm(pos: Vector2) -> Dictionary:
	var r := _studio.pick_ray(pos)
	if r.is_empty():
		return {}
	return {"origin": (r["origin"] as Vector3) / MM, "dir": r["dir"]}


func _pick(pos: Vector2) -> Dictionary:
	var r := _ray_mm(pos)
	if r.is_empty():
		return {}
	return TcAssembly.pick(_design["res"], r["origin"], r["dir"])


## The open port whose face is nearest the pointer on screen (container px),
## skipping the parts in `skip`. {} when none is within SNAP_PX.
func _nearest_port(pos: Vector2, skip: Array) -> Dictionary:
	var best := {}
	var best_d := SNAP_PX * (_studio.container.size.x / maxf(float(_studio.viewport.size.x), 1.0)) * 1.0
	best_d = SNAP_PX
	for op in _design["res"]["open"]:
		if str(op["part"]) in skip:
			continue
		var w := (op["xf"] as Transform3D).origin * MM
		if _studio.camera.is_position_behind(w):
			continue
		var d := studio_pos_of((op["xf"] as Transform3D).origin).distance_to(pos)
		if d < best_d:
			best_d = d
			best = op
	return best


func _update_ghost(pos: Vector2) -> void:
	if _tool.is_empty() or not is_instance_valid(_ghost):
		return
	var b := TcParts.build(str(_tool["type"]), str(_tool["size"]), _tool["params"])
	var ports: Array = b["ports"]
	var own: Dictionary = ports[_ghost_port % ports.size()]
	var op := _nearest_port(pos, [])
	if op.is_empty() and str(_sel.get("kind", "")) == "port":
		for o in _design["res"]["open"]:
			if str(o["ref"]) == str(_sel["id"]):
				op = o
	var ok := true
	var why := ""
	if not op.is_empty():
		var m := TcParts.can_mate(op["port"], own)
		ok = bool(m["ok"])
		why = str(m["why"])
		_ghost_xf = TcAssembly.place_on(op["xf"], own, TcParts.joint_gap(op["port"], own), _ghost_roll)
		_snap = {"ref": str(op["ref"]), "ok": ok, "why": why}
	else:
		_snap = {}
		var r := _ray_mm(pos)
		if r.is_empty():
			return
		var o: Vector3 = r["origin"]
		var d: Vector3 = r["dir"]
		if absf(d.y) < 1e-4:
			_ghost.visible = false
			return
		var t := -o.y / d.y
		if t < 0.0:
			_ghost.visible = false
			return
		var hit := o + d * t
		var basis := Basis(Vector3.UP, deg_to_rad(_ghost_yaw))
		var bb: AABB = b["bounds"]
		var lifted: AABB = Transform3D(basis, Vector3.ZERO) * bb
		_ghost_xf = Transform3D(basis, Vector3(hit.x, -lifted.position.y, hit.z))
	_ghost.visible = true
	var want_ok := ok
	if (_ghost.get_meta("ok", true) as bool) != want_ok:
		_ghost.queue_free()
		_ghost = TcBuilder.ghost_node(str(_tool["type"]), str(_tool["size"]), _tool["params"], want_ok)
		_ghost.set_meta("ok", want_ok)
		_studio.holder.add_child(_ghost)
	_ghost.transform = TcBuilder.to_m(_ghost_xf)
	_hover_lbl.text = ("Joins %s" % str(op["ref"]) if ok else "Can't join: %s" % why) if not op.is_empty() \
		else "On the floor: a new run"
	_rebuild_markers()


func _place(keep: bool) -> void:
	if _tool.is_empty():
		return
	if not _snap.is_empty() and not bool(_snap.get("ok", false)):
		_set_status("Can't join here: %s." % str(_snap.get("why", "")))
		return
	var b := TcParts.build(str(_tool["type"]), str(_tool["size"]), _tool["params"])
	var ports: Array = b["ports"]
	var own: Dictionary = ports[_ghost_port % ports.size()]
	var r: Array = []
	if not _snap.is_empty():
		r = TcAssembly.add_part(_spec, str(_tool["type"]), str(_tool["size"]), _tool["params"], Transform3D.IDENTITY,
			{"target": str(_snap["ref"]), "own": str(own["id"]), "roll": _ghost_roll})
	else:
		r = TcAssembly.add_part(_spec, str(_tool["type"]), str(_tool["size"]), _tool["params"], _ghost_xf)
	var t := str(_tool["type"])
	_set_spec(r[0])
	_sel = {"kind": "part", "id": str(r[1])}
	if keep:
		_snap = {}
		_rebuild_studio()
		_refresh_right()
	else:
		_disarm()
		_rebuild_studio()
		_refresh_right()
	_set_status("Placed a %s." % TcParts.label_of(t).to_lower())


func _update_hover(pos: Vector2) -> void:
	var hit := _pick(pos)
	match str(hit.get("kind", "")):
		"part":
			var pd: Dictionary = _design["res"]["parts"][str(hit["id"])]
			_hover_lbl.text = "%s · %s · drag to move" % [str(pd["built"]["label"]), str(pd["built"]["designation"])]
		"port":
			_hover_lbl.text = "Open end %s · click to pick it, then a part to join there" % str(hit["id"])
		"joint":
			var jd: Dictionary = _design["res"]["joints"][int(hit["id"])]
			_hover_lbl.text = "%s clamp joint · roll %d°" % [TcStandards.size_label(str(jd["size"])), roundi(float(jd["roll_deg"]))]
		_:
			_hover_lbl.text = ""


# ---------------------------------------------------------------------------
# Dragging a part (and what hangs off it)
# ---------------------------------------------------------------------------

func _begin_drag() -> void:
	var id := str(_press["id"])
	var res: Dictionary = _design["res"]
	var base := TcAssembly.detach(_spec, res, id)
	var d0 := TcDesign.solve(base)
	var ids := TcAssembly.group_of(d0["res"], id)
	var xf0: Transform3D = d0["res"]["parts"][id]["xf"]
	# The end the part joins by: the one it hung from, else its first open end.
	var own := ""
	var pj: Dictionary = res.get("parent_joint", {})
	if pj.has(id):
		var jd: Dictionary = res["joints"][int(pj[id])]
		var a := TcAssembly.split_ref(str(jd["a"]))
		var bb := TcAssembly.split_ref(str(jd["b"]))
		own = str(a[1]) if str(a[0]) == id else str(bb[1])
	if own.is_empty():
		for op in d0["res"]["open"]:
			if str(op["part"]) == id:
				own = str(op["port"]["id"])
				break
	var r := _ray_mm(_press["pos"])
	var plane_y := xf0.origin.y
	var grab := Vector3.ZERO
	if not r.is_empty() and absf((r["dir"] as Vector3).y) > 1e-4:
		var t := (plane_y - (r["origin"] as Vector3).y) / (r["dir"] as Vector3).y
		grab = (r["origin"] as Vector3) + (r["dir"] as Vector3) * t
	_drag = {"id": id, "base": base, "ids": ids, "xf0": xf0, "own": own, "grab": grab,
		"plane_y": plane_y, "spec": base, "target": "", "ok": true}
	_select({"kind": "part", "id": id})


func _update_drag(pos: Vector2) -> void:
	var id := str(_drag["id"])
	var base: Dictionary = _drag["base"]
	var res0: Dictionary = TcDesign.solve(base)["res"]
	var own_port := {}
	for q in res0["parts"][id]["built"]["ports"]:
		if str(q["id"]) == str(_drag["own"]):
			own_port = q
	var op := _nearest_port(pos, _drag["ids"]) if not own_port.is_empty() else {}
	var xf: Transform3D = _drag["xf0"]
	_drag["target"] = ""
	if not op.is_empty():
		var m := TcParts.can_mate(op["port"], own_port)
		if bool(m["ok"]):
			xf = TcAssembly.place_on(op["xf"], own_port, TcParts.joint_gap(op["port"], own_port), 0.0)
			_drag["target"] = str(op["ref"])
		_snap = {"ref": str(op["ref"]), "ok": bool(m["ok"]), "why": str(m["why"])}
	else:
		_snap = {}
		var r := _ray_mm(pos)
		if not r.is_empty() and absf((r["dir"] as Vector3).y) > 1e-4:
			var t := (float(_drag["plane_y"]) - (r["origin"] as Vector3).y) / (r["dir"] as Vector3).y
			if t > 0.0:
				var hit := (r["origin"] as Vector3) + (r["dir"] as Vector3) * t
				xf.origin = (_drag["xf0"] as Transform3D).origin + (hit - (_drag["grab"] as Vector3))
	_drag["spec"] = TcAssembly.set_root_xf(base, id, xf)
	_design = TcDesign.solve_transient(_drag["spec"])
	_rebuild_studio()
	_hover_lbl.text = ("Drop to join %s" % str(_drag["target"])) if not str(_drag["target"]).is_empty() \
		else ("Can't join: %s" % str(_snap.get("why", ""))) if not _snap.is_empty() else "Moving %s" % \
		UiText.count((_drag["ids"] as Array).size(), "part")


func _end_drag() -> void:
	var id := str(_drag["id"])
	var s: Dictionary = _drag["spec"]
	if not str(_drag["target"]).is_empty():
		var res: Dictionary = TcDesign.solve(s)["res"]
		s = TcAssembly.attach(s, res, id, str(_drag["own"]), str(_drag["target"]), 0.0)
		_set_status("Joined onto %s." % str(_drag["target"]))
	else:
		_set_status("Moved %s." % UiText.count((_drag["ids"] as Array).size(), "part"))
	_drag = {}
	_snap = {}
	_set_spec(s)
	_select({"kind": "part", "id": id})


# ---------------------------------------------------------------------------
# Selection + cards
# ---------------------------------------------------------------------------

func _select(sel: Dictionary) -> void:
	_sel = sel
	_rebuild_studio()
	_refresh_card()


func _refresh_right() -> void:
	_refresh_card()
	_refresh_checks()
	_refresh_summary()


func _clear(box: Node) -> void:
	for c in box.get_children():
		box.remove_child(c)
		c.queue_free()


func _refresh_card() -> void:
	_clear(_card)
	match str(_sel.get("kind", "")):
		"part":
			if str(TcSpec.part_of(_spec, str(_sel["id"])).get("type", "")) == "vessel":
				_vessel_card(str(_sel["id"]))
			else:
				_part_card(str(_sel["id"]))
		"nozzle":
			_nozzle_card(str(_sel["id"]))
		"joint":
			_joint_card(int(_sel["id"]))
		"port":
			_port_card(str(_sel["id"]))
		_:
			_card.add_child(SectionHeader.make("Selection", "mouse-pointer-2"))
			var l := Label.new()
			l.text = "Click a part, a clamp or an open end to edit it. Pick a part on the left and click an open end to add it."
			l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			l.add_theme_color_override("font_color", UITheme.C_TEXT_M)
			_card.add_child(l)


func _part_card(id: String) -> void:
	var pd: Dictionary = _design["res"]["parts"].get(id, {})
	var p := TcSpec.part_of(_spec, id)
	if pd.is_empty() or p.is_empty():
		return
	var b: Dictionary = pd["built"]
	_card.add_child(SectionHeader.make(str(b["label"]), "box", str(b["designation"])))
	var sizes: Array = []
	for s in TcStandards.SIZES:
		sizes.append([str(s), TcStandards.size_label(str(s))])
	var srow := FormRow.option("Size", sizes, func(v: Variant) -> void: _set_spec(TcAssembly.set_part(_spec, id, {"size": str(v)})),
		"Changing the size keeps the joints; a face that no longer matches shows in the checks", "part_size")
	srow.set_value(str(p["size"]))
	_card.add_child(srow)
	var params: Dictionary = p["params"]
	for ps in TcParts.param_specs(str(p["type"])):
		_card.add_child(_param_row(id, ps, params))
	if str(p["type"]) == "spool" and bool(params.get("fit", false)):
		var fitted := float((_design["res"].get("fit", {}) as Dictionary).get(id, params["length_mm"]))
		_card.add_child(FormRow.value("Fitted length", "%.1f mm" % fitted, "What the loop needs this spool to be"))
	_card.add_child(FormRow.value("Mass", "%.2f kg" % float(b["mass_kg"])))
	_card.add_child(FormRow.value("Holds", "%.2f L" % float(b["volume_l"])))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var pj: Dictionary = _design["res"].get("parent_joint", {})
	if pj.has(id):
		for deg in [-90, -15, 15, 90]:
			var rb := Button.new()
			rb.text = "%+d°" % deg
			rb.tooltip_text = "Roll this part (and what hangs off it) about its joint (R / Shift+R = ±15°)"
			UITheme.style_button(rb)
			rb.pressed.connect(_roll_part.bind(id, float(deg)))
			row.add_child(rb)
	else:
		var tb := Button.new()
		tb.text = "Turn 90°"
		tb.tooltip_text = "Turn this group about the vertical (it stands free)"
		UITheme.style_button(tb)
		tb.pressed.connect(_turn_root.bind(id, Vector3.UP))
		row.add_child(tb)
		var tilt := Button.new()
		tilt.text = "Tip 90°"
		tilt.tooltip_text = "Tip this group onto its side"
		UITheme.style_button(tilt)
		tilt.pressed.connect(_turn_root.bind(id, Vector3.RIGHT))
		row.add_child(tilt)
	_card.add_child(row)
	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 4)
	if pj.has(id):
		var det := Button.new()
		det.text = "Detach"
		det.tooltip_text = "Unclamp this part from the run it hangs on (it stays where it is)"
		UITheme.style_button(det)
		det.pressed.connect(func() -> void: _set_spec(TcAssembly.detach(_spec, _design["res"], id)))
		row2.add_child(det)
	var del := Button.new()
	del.text = "Remove"
	del.name = "remove_part"
	del.tooltip_text = "Delete this part (Del)"
	UITheme.style_button(del)
	del.pressed.connect(_remove_selected)
	row2.add_child(del)
	_card.add_child(row2)


func _param_row(id: String, ps: Dictionary, params: Dictionary) -> FormRow:
	var key := str(ps["key"])
	var kind := str(ps["kind"])
	var set_param := func(v: Variant) -> void:
		_set_spec(TcAssembly.set_part(_spec, id, {"params": {key: v}}))
	var r: FormRow = null
	match kind:
		"float":
			r = FormRow.spin(str(ps["label"]), float(ps["min"]), float(ps["max"]), float(ps["step"]), str(ps.get("unit", "")),
				Callable(), str(ps.get("tip", "")), "param_" + key)
			r.set_value(float(params.get(key, 0.0)))
			(r.control as SpinBox).value_changed.connect(func(v: float) -> void: set_param.call(v))
		"bool":
			r = FormRow.check(str(ps["label"]), "On", Callable(), str(ps.get("tip", "")), "param_" + key)
			r.set_value(bool(params.get(key, false)))
			(r.control as CheckBox).toggled.connect(func(v: bool) -> void: set_param.call(v))
		"size":
			var items: Array = []
			for s in TcStandards.SIZES:
				items.append([str(s), TcStandards.size_label(str(s))])
			r = FormRow.option(str(ps["label"]), items, func(v: Variant) -> void: set_param.call(str(v)), str(ps.get("tip", "")), "param_" + key)
			r.set_value(str(params.get(key, "")))
		"choice":
			r = FormRow.option(str(ps["label"]), ps["options"], func(v: Variant) -> void: set_param.call(str(v)), str(ps.get("tip", "")), "param_" + key)
			r.set_value(str(params.get(key, "")))
		"npt", "barb":
			var items2: Array = []
			for s in (TcStandards.NPT_SIZES if kind == "npt" else TcStandards.BARB_SIZES):
				items2.append([str(s), TcStandards.size_label(str(s))])
			r = FormRow.option(str(ps["label"]), items2, func(v: Variant) -> void: set_param.call(str(v)), str(ps.get("tip", "")), "param_" + key)
			r.set_value(str(params.get(key, "")))
	return r


func _joint_card(i: int) -> void:
	var joints: Array = _design["res"]["joints"]
	if i < 0 or i >= joints.size():
		return
	var jd: Dictionary = joints[i]
	var a := str(jd["a"])
	var b := str(jd["b"])
	_card.add_child(SectionHeader.make("%s %s joint" % [TcStandards.size_label(str(jd["size"])),
		"clamp" if str(jd["kind"]) == "tc" else TcParts.kind_word(str(jd["kind"]))], "link", "%s ↔ %s" % [a, b]))
	var roll := FormRow.spin("Roll", -180.0, 180.0, 15.0, "°", Callable(),
		"Turns the far side of this joint about its axis", "joint_roll")
	roll.set_value(float(jd["roll_deg"]))
	(roll.control as SpinBox).value_changed.connect(func(v: float) -> void: _set_spec(TcAssembly.set_joint(_spec, a, b, {"roll_deg": v})))
	_card.add_child(roll)
	if str(jd["kind"]) == "tc":
		var gs: Array = []
		for k in TcStandards.GASKETS:
			gs.append([k, str(TcStandards.GASKETS[k]["label"])])
		var g := FormRow.option("Gasket", gs, func(v: Variant) -> void: _set_spec(TcAssembly.set_joint(_spec, a, b, {"gasket": str(v)})),
			TcStandards.GASKET_SOURCE, "joint_gasket")
		g.set_value(str(jd["gasket"]))
		_card.add_child(g)
		var cs: Array = []
		for k in TcStandards.CLAMPS:
			cs.append([k, str(TcStandards.CLAMPS[k]["label"])])
		var c := FormRow.option("Clamp", cs, func(v: Variant) -> void: _set_spec(TcAssembly.set_joint(_spec, a, b, {"clamp": str(v)})),
			TcStandards.CLAMP_SOURCE, "joint_clamp")
		c.set_value(str(jd["clamp"]))
		_card.add_child(c)
		_card.add_child(FormRow.value("Rated", "about %.0f bar (typical)" % TcStandards.clamp_rating_bar(str(jd["clamp"]), str(jd["size"])),
			TcStandards.CLAMP_SOURCE))
	if bool(jd["closing"]):
		_card.add_child(FormRow.value("Closes a loop", "misses by %.1f mm, %.1f°" % [float(jd["err_mm"]), float(jd["err_deg"])]))
	var sep := Button.new()
	sep.text = "Separate"
	sep.tooltip_text = "Take this joint apart (both sides stay where they are)"
	UITheme.style_button(sep)
	sep.pressed.connect(func() -> void:
		var s := _spec.duplicate(true)
		var keep: Array = []
		for j in s["joints"]:
			if not (str(j["a"]) == a and str(j["b"]) == b):
				keep.append(j)
		s["joints"] = keep
		_sel = {}
		_set_spec(TcAssembly.pin_roots(s, _design["res"])))
	_card.add_child(sep)


func _port_card(ref: String) -> void:
	var op := {}
	for o in _design["res"]["open"]:
		if str(o["ref"]) == ref:
			op = o
	if op.is_empty():
		return
	var p: Dictionary = op["port"]
	_card.add_child(SectionHeader.make("Open end %s" % ref, "circle-dot",
		"%s %s" % [TcStandards.size_label(str(p["size"])), TcParts.kind_word(str(p["kind"]))]))
	var hint := Label.new()
	hint.text = "Pick a part on the left: it will join here. Or label this end so the world can connect to it."
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
	_card.add_child(hint)
	_port_card_rows(ref)


## The label + "carries" rows of an open end.
func _port_card_rows(ref: String) -> void:
	var lab: Dictionary = (_spec.get("labels", {}) as Dictionary).get(ref, {})
	var txt := FormRow.text_edit("Label", "e.g. Woodgas out", Callable(), "What this end is for", "port_label")
	(txt.control as LineEdit).text = str(lab.get("text", ""))
	(txt.control as LineEdit).text_submitted.connect(func(t: String) -> void: _set_label(ref, {"text": t}))
	(txt.control as LineEdit).focus_exited.connect(func() -> void: _set_label(ref, {"text": (txt.control as LineEdit).text}))
	_card.add_child(txt)
	var kinds: Array = [["", "—"]]
	for k in ResourceKinds.all_kinds():
		kinds.append([str(k), ResourceKinds.display_name(str(k))])
	var kr := FormRow.option("Carries", kinds, func(v: Variant) -> void: _set_label(ref, {"kind": str(v)}),
		"The resource this end carries (for linking it to the graph later)", "port_kind")
	kr.set_value(str(lab.get("kind", "")))
	_card.add_child(kr)


# ---------------------------------------------------------------------------
# Vessels
# ---------------------------------------------------------------------------

## A vessel's nozzle dict by "vessel:nozzle" ref ({} = none).
func _nozzle(ref: String) -> Dictionary:
	var p := TcSpec.part_of(_spec, ref.get_slice(":", 0))
	if p.is_empty() or str(p["type"]) != "vessel":
		return {}
	for q in (p["params"] as Dictionary).get("ports", []):
		if str(q["id"]) == ref.get_slice(":", 1):
			return q
	return {}


func _set_vessel(id: String, patch: Dictionary) -> void:
	_set_spec(TcAssembly.pin_roots(TcAssembly.set_part(_spec, id, {"params": patch}), _design["res"]))


func _set_nozzle(ref: String, patch: Dictionary) -> void:
	var vid := ref.get_slice(":", 0)
	var p := TcSpec.part_of(_spec, vid)
	var ports: Array = ((p["params"] as Dictionary)["ports"] as Array).duplicate(true)
	for q in ports:
		if str(q["id"]) == ref.get_slice(":", 1):
			for k in patch:
				q[k] = patch[k]
	_set_vessel(vid, {"ports": ports})


func _vspin(lab: String, v: float, mn: float, mx: float, st: float, cb: Callable, tip: String = "", id: String = "") -> FormRow:
	var r := FormRow.spin(lab, mn, mx, st, "mm", Callable(), tip, id)
	r.set_value(v)
	(r.control as SpinBox).value_changed.connect(cb)
	return r


func _vopt(lab: String, items: Array, v: String, cb: Callable, id: String = "", tip: String = "") -> FormRow:
	var r := FormRow.option(lab, items, cb, tip, id)
	r.set_value(v)
	return r


static func _words(keys: Array) -> Array:
	var out: Array = []
	for k in keys:
		out.append([str(k), str(k).capitalize().replace("_", " ")])
	return out


func _vessel_card(id: String) -> void:
	var p := TcSpec.part_of(_spec, id)
	var pd: Dictionary = _design["res"]["parts"].get(id, {})
	if p.is_empty() or pd.is_empty():
		return
	var v: Dictionary = TcVessel.resolve(p["params"])
	var setv := func(key: String) -> Callable:
		return func(val: Variant) -> void: _set_vessel(id, {key: val})
	_card.add_child(SectionHeader.make(TcVessel.label(v), "package", "%.1f L · %.1f kg" % [float(pd["built"]["volume_l"]), float(pd["built"]["mass_kg"])]))
	var presets: Array = [["", "Start from a preset…"]]
	for k in TcVessel.PRESETS:
		presets.append([k, str(TcVessel.PRESETS[k]["label"])])
	_card.add_child(_vopt("Preset", presets, "", func(k: Variant) -> void:
		if str(k).is_empty():
			return
		# The whole shape from the preset (anything it leaves out goes back
		# to the default); nozzles and internals stay.
		var pp: Dictionary = TcVessel.defaults()
		pp.erase("ports")
		pp.erase("internals")
		pp.erase("cutaway")
		pp.merge((TcVessel.PRESETS[str(k)]["params"] as Dictionary).duplicate(true), true)
		_set_vessel(id, pp), "vessel_preset", "Sets the vessel's shape and keeps its nozzles"))
	_card.add_child(_vspin("Diameter", float(v["od_mm"]), 60.0, 3000.0, 1.0, setv.call("od_mm"), "Shell outside diameter", "v_od"))
	_card.add_child(_vspin("Height", float(v["height_mm"]), 40.0, 5000.0, 1.0, setv.call("height_mm"), "The straight shell, seam to seam", "v_h"))
	_card.add_child(_vspin("Wall", float(v["wall_mm"]), 0.8, 12.0, 0.1, setv.call("wall_mm")))
	_card.add_child(_vopt("Bottom", _words(TcVessel.HEADS), str(v["bottom"]), setv.call("bottom"), "v_bottom"))
	if str(v["bottom"]) != "flat":
		_card.add_child(_vspin("Bottom depth", float(v["bottom_depth_mm"]), 0.0, 3000.0, 1.0, setv.call("bottom_depth_mm"), "0 = the head's usual depth"))
	_card.add_child(_vopt("Top", _words(TcVessel.TOPS), str(v["top"]), setv.call("top"), "v_top"))
	if str(v["top"]) not in ["open", "flat"]:
		_card.add_child(_vspin("Top depth", float(v["top_depth_mm"]), 0.0, 3000.0, 1.0, setv.call("top_depth_mm"), "0 = the head's usual depth"))
	if str(v["top"]) == "open":
		var lid := FormRow.check("Lid", "Removable lid", Callable(), "A dished lid resting on the rim", "v_lid")
		lid.set_value(bool(v["lid"]))
		(lid.control as CheckBox).toggled.connect(setv.call("lid"))
		_card.add_child(lid)
		if bool(v["lid"]):
			_card.add_child(_vspin("Lid diameter", float(v["lid_od_mm"]), 0.0, 4000.0, 1.0, setv.call("lid_od_mm"), "0 = 30 mm over the shell"))
			_card.add_child(_vspin("Lid rise", float(v["lid_depth_mm"]), 0.0, 1000.0, 1.0, setv.call("lid_depth_mm"), "0 = 12 % of its diameter"))
			_card.add_child(_vspin("Lid dome", float(v["lid_dome_od_mm"]), 0.0, 4000.0, 1.0, setv.call("lid_dome_od_mm"),
				"The dome's diameter when it stands on a flat flange ring (0 = the dome is the whole lid)", "v_lid_dome"))
			_card.add_child(_vopt("Lid shape", [["dished", "Dished (flat on top)"], ["cap", "Spherical cap"]], str(v["lid_shape"]),
				setv.call("lid_shape"), "v_lid_shape"))
			var lc := FormRow.check("Lid clamp", "Band clamp", Callable(), "A band clamp round the rim holds the lid down", "v_lid_clamp")
			lc.set_value(bool(v["lid_clamp"]))
			(lc.control as CheckBox).toggled.connect(setv.call("lid_clamp"))
			_card.add_child(lc)
	_card.add_child(_vopt("Jacket", [["none", "None"], ["full", "Full height"], ["band", "Band"]], str(v["jacket"]), setv.call("jacket"), "v_jacket",
		"A steam or water jacket round the shell; nozzles pass through it"))
	if str(v["jacket"]) != "none":
		_card.add_child(_vspin("Jacket gap", float(v["jacket_gap_mm"]), 4.0, 300.0, 1.0, setv.call("jacket_gap_mm")))
		_card.add_child(_vspin("Double bottom", float(v.get("jacket_bottom_mm", 0.0)), 0.0, 600.0, 1.0, setv.call("jacket_bottom_mm")))
		if str(v["jacket"]) == "band":
			_card.add_child(_vspin("Jacket from", float(v["jacket_from_mm"]), 0.0, 5000.0, 1.0, setv.call("jacket_from_mm")))
			_card.add_child(_vspin("Jacket to", float(v["jacket_to_mm"]), 0.0, 5000.0, 1.0, setv.call("jacket_to_mm"), "0 = the top"))
	_card.add_child(_vspin("Insulation", float(v["insulation_mm"]), 0.0, 300.0, 1.0, setv.call("insulation_mm"), "Thickness outside the shell or jacket (0 = none)"))
	_card.add_child(_vopt("Stands on", [["none", "Its bottom"], ["legs", "Legs"], ["skirt", "A skirt"],
		["ring_stand", "A ring stand on casters"], ["casters", "Casters"], ["saddle", "A skid (tank on its side)"]],
		str(v["legs"]), setv.call("legs"), "v_legs",
		"A skid runs along the shell's back: turn the tank on its side so the skid is underneath"))
	if str(v["legs"]) != "none":
		_card.add_child(_vspin("Leg height", float(v["leg_h_mm"]), 10.0, 3000.0, 1.0, setv.call("leg_h_mm")))
	if str(v["legs"]) in ["legs", "ring_stand", "casters"]:
		_card.add_child(_vspin("Legs", float(v["leg_count"]), 3.0, 8.0, 1.0, func(val: Variant) -> void: _set_vessel(id, {"leg_count": int(val)})))
	var hr := FormRow.check("Handle ring", "Ring over the top", Callable(), "A tube ring on three struts over the top: a handle and a roll bar", "v_handle_ring")
	hr.set_value(bool(v["handle_ring"]))
	(hr.control as CheckBox).toggled.connect(setv.call("handle_ring"))
	_card.add_child(hr)
	if bool(v["handle_ring"]):
		_card.add_child(_vspin("Ring diameter", float(v["handle_ring_od_mm"]), 0.0, 4000.0, 1.0, setv.call("handle_ring_od_mm"), "0 = a little wider than the shell"))
		_card.add_child(_vspin("Ring height", float(v["handle_ring_h_mm"]), 0.0, 2000.0, 1.0, setv.call("handle_ring_h_mm"), "Above the shell's top seam (0 = by the shell's size)"))
	# Internals.
	_card.add_child(SectionHeader.make("Inside", "layers"))
	var ints: Array = (v["internals"] as Array).duplicate(true)
	for i in ints.size():
		var it: Dictionary = ints[i]
		var row := HBoxContainer.new()
		var l := Label.new()
		l.text = "%s Ø%d × %d at %d" % [str(TcVessel.INTERNAL_LABELS.get(str(it["kind"]), it["kind"])), roundi(float(it["od_mm"])),
			roundi(float(it["h_mm"])), roundi(float(it["z_mm"]))]
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		row.add_child(l)
		for f in [["od_mm", "Ø"], ["h_mm", "H"], ["z_mm", "at"]]:
			var sb := SpinBox.new()
			sb.min_value = 0.0
			sb.max_value = 5000.0
			sb.step = 1.0
			sb.value = float(it[f[0]])
			sb.tooltip_text = {"od_mm": "Diameter", "h_mm": "Height", "z_mm": "Height above the shell's bottom seam"}[f[0]]
			sb.custom_minimum_size = Vector2(70, 0)
			var key: String = f[0]
			var idx := i
			sb.value_changed.connect(func(val: float) -> void:
				var arr: Array = (TcVessel.resolve(TcSpec.part_of(_spec, id)["params"])["internals"] as Array).duplicate(true)
				arr[idx][key] = val
				_set_vessel(id, {"internals": arr}))
			row.add_child(sb)
		var x := IconButton.make("trash-2", "Remove", func() -> void:
			var arr2: Array = ints.duplicate(true)
			arr2.remove_at(i)
			_set_vessel(id, {"internals": arr2}))
		row.add_child(x)
		_card.add_child(row)
	var add_int := HFlowContainer.new()
	for k in TcVessel.INTERNALS:
		var b := Button.new()
		b.text = "+ " + str(TcVessel.INTERNAL_LABELS[k])
		UITheme.style_button(b)
		var kind: String = k
		b.pressed.connect(func() -> void:
			var arr3: Array = ints.duplicate(true)
			var R := float(v["od_mm"]) * 0.5
			arr3.append({"kind": kind, "od_mm": R * 1.6, "h_mm": float(v["height_mm"]) * (0.6 if kind != "false_bottom" else 0.01), "z_mm": 30.0})
			_set_vessel(id, {"internals": arr3}))
		add_int.add_child(b)
	_card.add_child(add_int)
	# Nozzles.
	_card.add_child(SectionHeader.make("Nozzles", "target", "drag one round the vessel"))
	for q in v["ports"]:
		var b := Button.new()
		var where := "%s %d°" % [str(q["face"]), roundi(float(q["angle_deg"]))]
		if str(q["face"]) == "shell":
			where += " · %d mm up" % roundi(float(q["h_mm"]))
		else:
			where += " · %d mm out" % roundi(float(q["r_mm"]))
		var lab: Dictionary = (_spec.get("labels", {}) as Dictionary).get("%s:%s" % [id, q["id"]], {})
		b.text = "%s  %s %s · %s%s" % [str(q["id"]), TcStandards.size_label(str(q["size"])),
			{"tc": "clamp", "npt": "NPT", "weld": "weld"}[str(q["kind"])], where,
			(" · " + str(lab["text"])) if not str(lab.get("text", "")).is_empty() else ""]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.name = "nozzle_%s" % str(q["id"])
		UITheme.style_button(b)
		b.pressed.connect(_select.bind({"kind": "nozzle", "id": "%s:%s" % [id, q["id"]]}))
		_card.add_child(b)
	var add_n := HBoxContainer.new()
	for spec in [["tc", "+ Clamp nozzle", "1.5"], ["npt", "+ NPT bung", "0.5"], ["weld", "+ Weld stub", "1"]]:
		var b2 := Button.new()
		b2.text = str(spec[1])
		b2.name = "add_nozzle_%s" % str(spec[0])
		UITheme.style_button(b2)
		var k2: String = spec[0]
		var sz: String = spec[2]
		b2.pressed.connect(func() -> void:
			var ports: Array = (v["ports"] as Array).duplicate(true)
			var taken := {}
			for q2 in ports:
				taken[str(q2["id"])] = true
			var nid := TcVessel.new_port_id(taken)
			ports.append({"id": nid, "kind": k2, "size": sz if k2 != "tc" else _size, "face": "shell",
				"angle_deg": 30.0 * float(ports.size() % 12), "h_mm": float(v["height_mm"]) * 0.5,
				"stub_mm": 12.0 if k2 == "npt" else 30.0})
			_set_vessel(id, {"ports": ports})
			_select({"kind": "nozzle", "id": "%s:%s" % [id, nid]})
			_set_status("Added nozzle %s: drag it where it goes." % nid))
		add_n.add_child(b2)
	_card.add_child(add_n)
	var row2 := HBoxContainer.new()
	var tb := Button.new()
	tb.text = "Turn 90°"
	tb.tooltip_text = "Turn the vessel and everything on it about the vertical"
	UITheme.style_button(tb)
	tb.pressed.connect(_turn_root.bind(id, Vector3.UP))
	row2.add_child(tb)
	var del := Button.new()
	del.text = "Remove"
	del.name = "remove_part"
	UITheme.style_button(del)
	del.pressed.connect(_remove_selected)
	row2.add_child(del)
	_card.add_child(row2)


func _nozzle_card(ref: String) -> void:
	var q := _nozzle(ref)
	if q.is_empty():
		return
	var vid := ref.get_slice(":", 0)
	var kind := str(q["kind"])
	_card.add_child(SectionHeader.make("Nozzle %s" % str(q["id"]), "target", "on the vessel · drag its end to move it"))
	var sizes: Array = []
	for s in (TcStandards.NPT_SIZES if kind == "npt" else TcStandards.SIZES):
		sizes.append([str(s), TcStandards.size_label(str(s))])
	_card.add_child(_vopt("Kind", [["tc", "Clamp ferrule"], ["npt", "NPT bung (female)"], ["weld", "Weld stub"]], kind,
		func(k: Variant) -> void: _set_nozzle(ref, {"kind": str(k), "size": "0.5" if str(k) == "npt" else _size}), "noz_kind"))
	_card.add_child(_vopt("Size", sizes, str(q["size"]), func(s: Variant) -> void: _set_nozzle(ref, {"size": str(s)}), "noz_size"))
	_card.add_child(_vopt("On", [["shell", "Shell"], ["top", "Top head"], ["bottom", "Bottom head"], ["lid", "Lid"]], str(q["face"]),
		func(f: Variant) -> void: _set_nozzle(ref, {"face": str(f)}), "noz_face"))
	var ang := FormRow.spin("Angle", 0.0, 359.0, 1.0, "°", Callable(), "Round the axis: 0° faces the front, 90° the right", "noz_angle")
	ang.set_value(float(q["angle_deg"]))
	(ang.control as SpinBox).value_changed.connect(func(val: float) -> void: _set_nozzle(ref, {"angle_deg": val}))
	_card.add_child(ang)
	if str(q["face"]) == "shell":
		_card.add_child(_vspin("Height", float(q["h_mm"]), 0.0, 5000.0, 1.0, func(val: float) -> void: _set_nozzle(ref, {"h_mm": val}),
			"Up the shell from its bottom seam", "noz_h"))
		var tilt := FormRow.spin("Tilt", -80.0, 80.0, 1.0, "°", Callable(), "Down from horizontal", "noz_tilt")
		tilt.set_value(float(q["tilt_deg"]))
		(tilt.control as SpinBox).value_changed.connect(func(val: float) -> void: _set_nozzle(ref, {"tilt_deg": val}))
		_card.add_child(tilt)
	else:
		_card.add_child(_vspin("Out from centre", float(q["r_mm"]), 0.0, 2000.0, 1.0, func(val: float) -> void: _set_nozzle(ref, {"r_mm": val}),
			"", "noz_r"))
	_card.add_child(_vspin("Stands out", float(q["stub_mm"]), 0.0, 1000.0, 1.0, func(val: float) -> void: _set_nozzle(ref, {"stub_mm": val}),
		"From the outermost surface (jacket, insulation) to the face", "noz_stub"))
	var open := false
	for op in _design["res"]["open"]:
		if str(op["ref"]) == ref:
			open = true
	if open:
		_port_card_rows(ref)
	var row := HBoxContainer.new()
	var back := Button.new()
	back.text = "Back to the vessel"
	UITheme.style_button(back)
	back.pressed.connect(_select.bind({"kind": "part", "id": vid}))
	row.add_child(back)
	var rm := Button.new()
	rm.text = "Remove nozzle"
	rm.name = "remove_nozzle"
	UITheme.style_button(rm)
	rm.pressed.connect(func() -> void:
		var p := TcSpec.part_of(_spec, vid)
		var ports: Array = []
		for q2 in (p["params"] as Dictionary)["ports"]:
			if str(q2["id"]) != ref.get_slice(":", 1):
				ports.append(q2)
		_sel = {}
		_set_vessel(vid, {"ports": ports}))
	row.add_child(rm)
	_card.add_child(row)


func _set_label(ref: String, patch: Dictionary) -> void:
	var s := _spec.duplicate(true)
	var labels: Dictionary = s.get("labels", {})
	var cur: Dictionary = labels.get(ref, {"text": "", "kind": ""})
	for k in patch:
		cur[k] = patch[k]
	if str(cur.get("text", "")).is_empty() and str(cur.get("kind", "")).is_empty():
		labels.erase(ref)
	else:
		labels[ref] = cur
	s["labels"] = labels
	if TcSpec.key_of(s) != TcSpec.key_of(_spec):
		_set_spec(s)


func _roll_part(id: String, deg: float) -> void:
	var pj: Dictionary = _design["res"].get("parent_joint", {})
	if not pj.has(id):
		return
	var jd: Dictionary = _design["res"]["joints"][int(pj[id])]
	var v := fposmod(float(jd["roll_deg"]) + deg + 180.0, 360.0) - 180.0
	_set_spec(TcAssembly.set_joint(_spec, str(jd["a"]), str(jd["b"]), {"roll_deg": v}))


func _turn_root(id: String, axis: Vector3) -> void:
	var group := TcAssembly.group_of(_design["res"], id)
	var root := ""
	for p in _spec["parts"]:
		if str(p["id"]) in group and p.has("xf"):
			root = str(p["id"])
	if root.is_empty():
		return
	var xf: Transform3D = _design["res"]["parts"][root]["xf"]
	var bb: AABB = _design["stats"]["bounds_mm"]
	var pivot := xf.origin
	var rot := Basis(axis, PI * 0.5)
	var nx := Transform3D(rot * xf.basis, pivot + rot * (xf.origin - pivot))
	var s := TcAssembly.set_root_xf(_spec, root, nx)
	# Stand it back on the floor.
	var d := TcDesign.solve_transient(s)
	var nb: AABB = d["stats"]["bounds_mm"]
	nx.origin.y -= nb.position.y - bb.position.y if bb.size.length() > 0.0 else 0.0
	_set_spec(TcAssembly.set_root_xf(_spec, root, nx))


func _remove_selected() -> void:
	if str(_sel.get("kind", "")) != "part":
		return
	var id := str(_sel["id"])
	_sel = {}
	_set_spec(TcAssembly.remove_part(_spec, _design["res"], id))
	_set_status("Removed a part.")


func _refresh_checks() -> void:
	_clear(_checks_box)
	var counts := TcDesign.counts(_design)
	var e := int(counts[0])
	var w := int(counts[1])
	if e > 0:
		_shell.set_badge(UiText.count(e, "problem") + " to fix", "error", "Scroll to the checks")
	elif w > 0:
		_shell.set_badge(UiText.count(w, "warning"), "warn", "Scroll to the checks")
	else:
		_shell.set_badge("Checks pass", "ok", "")
	var any := false
	for c in _design["checks"]:
		any = true
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var dot := Label.new()
		dot.text = {"error": "✕", "warn": "!", "info": "·"}.get(str(c["level"]), "·")
		dot.add_theme_color_override("font_color", {"error": UITheme.C_ERROR, "warn": UITheme.C_WARN}.get(str(c["level"]), UITheme.C_TEXT_M))
		row.add_child(dot)
		var l := Label.new()
		l.text = str(c["text"])
		l.tooltip_text = str(c["why"])
		l.mouse_filter = Control.MOUSE_FILTER_PASS
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		row.add_child(l)
		var ids: Array = c.get("ids", [])
		if not ids.is_empty():
			var show := Button.new()
			show.text = "Show"
			show.tooltip_text = "Select it"
			UITheme.style_button(show)
			show.pressed.connect(_select.bind({"kind": "part", "id": str(ids[0])}))
			row.add_child(show)
		_checks_box.add_child(row)
	if not any:
		var l := Label.new()
		l.text = "Nothing to report."
		l.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		_checks_box.add_child(l)


## Every processor preset's label (the graph nodes a design can be).
static func _processor_labels() -> Array:
	var out: Array = []
	for cat in ComponentPresets.CATEGORIES:
		for p in (cat.get("presets", []) as Array):
			if p is Dictionary and str((p as Dictionary).get("type", "")) == "processor":
				var lab := str((p as Dictionary).get("label", ""))
				if not lab.is_empty() and not lab in out:
					out.append(lab)
	out.sort()
	return out


func _refresh_world() -> void:
	if _binds_row == null:
		return
	_binds_row.set_value(str(_spec.get("binds", "")))
	var ports := TcDesign.connection_ports(_design)
	var mapped := 0
	for q in ports:
		if not str(q.get("handle_id", "")).is_empty():
			mapped += 1
	var t := "%s labelled: each becomes a pipe port on the placed assembly." % UiText.count(ports.size(), "end")
	if not str(_spec.get("binds", "")).is_empty():
		t += " %d of them %s the %s node's ports." % [mapped, "is" if mapped == 1 else "are", str(_spec["binds"])]
	_world_note.text = t


func _refresh_summary() -> void:
	_refresh_world()
	var st: Dictionary = _design["stats"]
	var bb: AABB = st["bounds_mm"]
	var bom: Dictionary = _design["bom"]
	_summary.text = "%s · %s · %s open\n%.0f × %.0f × %.0f mm · %.2f kg · holds %.2f L" % [
		UiText.count(int(st["parts"]), "part"), UiText.count(int(bom["clamps"]), "clamp joint"),
		str(int(st["open_ports"])), bb.size.x, bb.size.y, bb.size.z, float(st["mass_kg"]), float(st["volume_l"])]
	_clear(_bom_box)
	for r in bom["rows"]:
		var row := HBoxContainer.new()
		var q := Label.new()
		q.text = "%d ×" % int(r["qty"])
		q.custom_minimum_size = Vector2(36, 0)
		q.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		row.add_child(q)
		var it := Label.new()
		it.text = str(r["item"])
		it.tooltip_text = str(r["spec"])
		it.mouse_filter = Control.MOUSE_FILTER_PASS
		it.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		it.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		it.add_theme_font_size_override("font_size", UITheme.FONT_SM)
		row.add_child(it)
		_bom_box.add_child(row)


func _set_status(t: String) -> void:
	_last_status = t
	if _status != null:
		_status.text = t


# ---------------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------------

## Another designer (the ESP board designer, on a process's controller) is
## open over this one.
func _covered() -> bool:
	var main := get_tree().current_scene if get_tree() != null else null
	if main == null:
		return false
	var esp: Variant = main.get("esplab_ui")
	return esp is Control and is_instance_valid(esp) and (esp as Control).visible


func _input(e: InputEvent) -> void:
	if not _active or not (e is InputEventKey) or _covered():
		return
	var ke := e as InputEventKey
	if not ke.pressed or ke.echo:
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit or focus is SpinBox:
		return
	var handled := true
	if _proc_mode:
		match ke.keycode:
			KEY_SPACE:
				_proc.call("play", not bool(_proc.get("playing")))
			KEY_F:
				_frame()
			_:
				handled = false
		if handled:
			get_viewport().set_input_as_handled()
		return
	match ke.keycode:
		KEY_Z:
			if ke.ctrl_pressed and ke.shift_pressed:
				_redo_step()
			elif ke.ctrl_pressed:
				_undo_step()
			else:
				handled = false
		KEY_Y:
			if ke.ctrl_pressed:
				_redo_step()
			else:
				handled = false
		KEY_TAB:
			if not _tool.is_empty():
				_ghost_port += 1
				_update_mode()
				_update_ghost(_hover_pos)
			else:
				handled = false
		KEY_R:
			var step := -15.0 if ke.shift_pressed else 15.0
			if not _tool.is_empty():
				if _snap.is_empty():
					_ghost_yaw = fposmod(_ghost_yaw + step * 6.0, 360.0)
				else:
					_ghost_roll = fposmod(_ghost_roll + step + 180.0, 360.0) - 180.0
				_update_ghost(_hover_pos)
			elif str(_sel.get("kind", "")) == "part":
				_roll_part(str(_sel["id"]), step)
			elif str(_sel.get("kind", "")) == "joint":
				var jd: Dictionary = _design["res"]["joints"][int(_sel["id"])]
				_set_spec(TcAssembly.set_joint(_spec, str(jd["a"]), str(jd["b"]),
					{"roll_deg": fposmod(float(jd["roll_deg"]) + step + 180.0, 360.0) - 180.0}))
			else:
				handled = false
		KEY_DELETE, KEY_BACKSPACE:
			if str(_sel.get("kind", "")) == "part":
				_remove_selected()
			else:
				handled = false
		KEY_F:
			_frame()
		KEY_ESCAPE:
			if not _drag.is_empty():
				_drag = {}
				_press = {}
				_design = _solve(_spec)
				_rebuild_studio()
			elif not _tool.is_empty():
				_disarm()
			elif not _sel.is_empty():
				_select({})
			else:
				handled = false
		_:
			handled = false
	if handled:
		get_viewport().set_input_as_handled()


# ---------------------------------------------------------------------------
# Designs, files
# ---------------------------------------------------------------------------

func _refresh_design_list() -> void:
	_design_list.clear()
	_design_entries.clear()
	for b in TcPresets.builtins():
		_design_list.add_item(str(b["name"]))
		_design_list.set_item_tooltip(_design_list.item_count - 1, str(b["blurb"]))
		_design_entries.append({"builtin": str(b["id"])})
	for e in _library:
		_design_list.add_item("★ " + str(e["name"]))
		_design_entries.append({"library": str(e["name"]), "spec": e["spec"]})


func _on_design_picked(i: int) -> void:
	if i < 0 or i >= _design_entries.size():
		return
	var e: Dictionary = _design_entries[i]
	_disarm()
	_sel = {}
	if e.has("builtin"):
		load_builtin(str(e["builtin"]))
	else:
		_set_spec(e["spec"])
		_frame()
		_set_status("Loaded “%s”." % str(e["library"]))


func _on_name_submitted(t: String) -> void:
	var s := _spec.duplicate(true)
	s["name"] = t.strip_edges() if not t.strip_edges().is_empty() else "Assembly"
	_set_spec(s)


func _on_save_design() -> void:
	var name := _shell.name_edit.text.strip_edges() if _shell.name_edit != null else str(_spec["name"])
	if name.is_empty():
		name = "Assembly"
	_library = TcPresets.save_design(name, _spec)
	_refresh_design_list()
	_set_status("Saved “%s” to your library." % name)


func _on_forget_design() -> void:
	var sel := _design_list.get_selected_items()
	if sel.is_empty():
		return
	var e: Dictionary = _design_entries[int(sel[0])]
	if not e.has("library"):
		_set_status("Built-in designs stay.")
		return
	_library = TcPresets.forget_design(str(e["library"]))
	_refresh_design_list()
	_set_status("Forgot “%s”." % str(e["library"]))


func _on_new() -> void:
	_disarm()
	_sel = {}
	_set_spec(TcSpec.empty("New assembly"))
	_frame()


func _main_node() -> Node:
	return get_tree().current_scene if get_tree() != null else null


func _prop_record(prop_id: String) -> Dictionary:
	var m := _main_node()
	if m == null or prop_id.is_empty():
		return {}
	return PlacedPropService.get_prop_record(m, prop_id)


## Place this design on the map (the ghost follows the crosshair; click to set).
func _on_place() -> void:
	var m := _main_node()
	if m == null:
		_set_status("Placing needs a world.")
		return
	var r: Dictionary = PlacedPropService.begin_placement(m, TcBuilder.MODEL_ID, {
		"record_extra": {"tc_spec": _spec.duplicate(true), "collision_enabled": true}})
	if not bool(r.get("ok", false)):
		_set_status("Could not start placing: %s" % str(r.get("error", "no props on this map")))
		return
	close()


## Rebuild the placed assembly this designer was opened on.
func _on_apply() -> void:
	var m := _main_node()
	if m == null or _bound_prop_id.is_empty():
		return
	PlacedPropService.update_prop_record(m, _bound_prop_id, {"tc_spec": _spec.duplicate(true),
		"model_id": TcBuilder.MODEL_ID}, true)
	PlacedPropService.seed_tclab(m, _bound_prop_id)
	PlacedPropService.apply_tclab_recipe(m, _bound_prop_id)
	close()


## The design's lab-run recipe onto the placed assembly this designer was
## opened on (its tc_spec and its graph node), without rebuilding it.
## Returns the node's name, "" when not bound / no node.
func write_recipe_to_bound() -> String:
	var m := _main_node()
	if m == null or _bound_prop_id.is_empty():
		return ""
	PlacedPropService.update_prop_record(m, _bound_prop_id, {"tc_spec": _spec.duplicate(true)}, false)
	return PlacedPropService.apply_tclab_recipe(m, _bound_prop_id)


func _on_export() -> void:
	var out := TcExport.write_all(_design)
	if bool(out["ok"]):
		_set_status("Wrote %s to %s" % [UiText.count((out["files"] as Array).size(), "file"),
			ProjectSettings.globalize_path(str(out["dir"]))])
	else:
		_set_status("Export failed: %s" % str(out["error"]))
