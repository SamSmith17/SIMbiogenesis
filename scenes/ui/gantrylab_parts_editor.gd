extends RefCounted

## The gantry designer's part editor (the Machine tab): pick a part, slide
## it along what it is fastened to, drag it off onto another feature, drop
## new parts from the palette onto the features they really fasten to — a
## bracket's bolts onto a slot, a NEMA 17 onto its 31 mm hole square, a
## pulley onto a 5 mm shaft — with the T-nuts and bolts made to match, and a
## mirrored twin following every edit until it is unlinked.
##
## The edits live in the spec (GantryLabAssembly's sparse layer), so undo,
## the library, the placed machine and the exports all carry them. The
## modal owns the studio; this script reads its camera and machine and asks
## it to rebuild.

const SEL_COLOR := Color(1.0, 0.72, 0.2, 0.42)
const HOVER_COLOR := Color(0.55, 0.85, 1.0, 0.22)
const TWIN_COLOR := Color(1.0, 0.72, 0.2, 0.18)
const CLASH_COLOR := Color(1.0, 0.25, 0.2, 0.45)
const GHOST_OK := Color(0.35, 1.0, 0.55, 0.45)
const TARGET_COLOR := Color(0.35, 0.8, 1.0, 0.3)
const DRAG_PX := 4.0
const TEAR_PX := 36.0

var m: Control = null
var sel := ""
var hover := ""
var tool_ref := ""
var tool_params := {}
var tool_turn := 0
var tool_mirror := false
var show_clashes := true
var cand := {}
var drag := {}
var res := {}
var palette_box: VBoxContainer = null
var palette_note: Label = null
var card_box: VBoxContainer = null
var _palette_btns: Dictionary = {}
var _mirror_check: CheckBox = null
var _pending := {}
var _pending_t := -1.0
var _last_motion := Vector2.ZERO


func attach(modal: Control) -> void:
	m = modal


func enabled() -> bool:
	return m != null and not m._spec.is_empty() and GantryLabAssembly.uses_assembly(str(m._spec["kinematics"]))


# ---------------------------------------------------------------------------
# UI
# ---------------------------------------------------------------------------

func build_palette(box: VBoxContainer) -> void:
	palette_box = box
	palette_note = Label.new()
	palette_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	palette_note.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	palette_note.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	box.add_child(palette_note)
	for grp in GantryLabCatalog.PALETTE:
		var g: Dictionary = grp
		var lbl := Label.new()
		lbl.text = str(g["label"])
		lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		box.add_child(lbl)
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 2)
		flow.add_theme_constant_override("v_separation", 2)
		box.add_child(flow)
		for r in g["refs"]:
			var ref := str(r)
			var b := Button.new()
			b.text = _short(ref)
			b.toggle_mode = true
			b.tooltip_text = "%s — click, then click where it fastens. R turns it, Shift keeps the tool, Esc stops." % GantryLabCatalog.label_of(ref, GantryLabCatalog.params_of(ref, {}))
			b.custom_minimum_size = Vector2(0, 24)
			UITheme.style_button(b)
			b.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			b.pressed.connect(_on_palette.bind(ref))
			flow.add_child(b)
			_palette_btns[ref] = b
	var row := HBoxContainer.new()
	_mirror_check = CheckBox.new()
	_mirror_check.text = "Add mirrored"
	_mirror_check.tooltip_text = "Place a twin on the other side too, linked so edits follow"
	_mirror_check.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_mirror_check.toggled.connect(func(on: bool): tool_mirror = on)
	row.add_child(_mirror_check)
	var reset := Button.new()
	reset.text = "Reset parts"
	reset.tooltip_text = "Forget every part edit and go back to the preset's parts"
	UITheme.style_button(reset)
	reset.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	reset.pressed.connect(_on_reset)
	row.add_child(reset)
	box.add_child(row)
	var clash := CheckBox.new()
	clash.text = "Show collisions"
	clash.button_pressed = true
	clash.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	clash.toggled.connect(func(on: bool):
		show_clashes = on
		_refresh_marks())
	box.add_child(clash)


func _short(ref: String) -> String:
	match ref:
		"vslot_2020":
			return "2020"
		"vslot_2040":
			return "2040"
		"vslot_2060":
			return "2060"
		"vslot_4040":
			return "4040"
		"corner_bracket":
			return "Corner"
		"inside_corner":
			return "Hidden corner"
		"cube_corner":
			return "Cube corner"
		"corner_3way":
			return "3-way corner"
		"joining_plate_t":
			return "T plate"
		"joining_plate_90":
			return "90° plate"
		"nema17_flat":
			return "NEMA17 flat"
		"nema23_flat":
			return "NEMA23 flat"
		"mini_v_plate":
			return "Mini V plate"
		"coupler_5_6":
			return "Coupler 5×6"
		"nut_block_8":
			return "Acme nut block"
		"nema17_mount":
			return "NEMA17 L"
		"nema23_mount":
			return "NEMA23 L"
		"nema17_plate":
			return "Motor plate"
		"nut_tab":
			return "Nut block"
		"gantry_plate":
			return "Wheel plate"
		"nema17":
			return "NEMA17"
		"nema17_hi":
			return "NEMA17 48"
		"nema17_pancake":
			return "Pancake"
		"nema23":
			return "NEMA23"
		"gt2_pulley":
			return "Pulley"
		"gt2_idler":
			return "Idler"
		"coupler":
			return "Coupler"
		"belt_clamp":
			return "Belt clamp"
		"endstop":
			return "Endstop"
		"foot":
			return "Foot"
	return GantryLabCatalog.label_of(ref, {})


func build_card(box: VBoxContainer) -> void:
	card_box = box


# ---------------------------------------------------------------------------
# After every rebuild
# ---------------------------------------------------------------------------

func on_rebuilt() -> void:
	res = {}
	if m == null or m._design.is_empty():
		return
	var lay: Dictionary = m._design["layout"]
	res = lay.get("assembly", {})
	var on := enabled()
	if palette_note != null:
		palette_note.text = "Click a part to pick it, drag it to slide it along what it is bolted to; drag it well off to move it somewhere else. Click a part below, then click where it goes." if on else \
			"Part editing is for the V-slot machines (bed-slinger first); this pattern is still drawn from its preset."
	for r in _palette_btns:
		(_palette_btns[r] as Button).disabled = not on
		(_palette_btns[r] as Button).button_pressed = (str(r) == tool_ref)
	if not on or res.is_empty() or not res["parts"].has(sel):
		if not sel.is_empty() and (res.is_empty() or not res["parts"].has(sel)):
			sel = ""
	_refresh_marks()
	refresh_card()


func _refresh_marks() -> void:
	var mach: GantryLabBuilder = m._machine
	if mach == null:
		return
	mach.clear_marks()
	if res.is_empty():
		return
	if show_clashes:
		var seen := {}
		for c in m._design.get("checks", []):
			var cd: Dictionary = c
			if str(cd["level"]) != "error":
				continue
			for pid in cd.get("parts", []):
				if not seen.has(pid) and str(pid) != sel:
					seen[pid] = true
					mach.mark_part("clash", str(pid), CLASH_COLOR)
	if not sel.is_empty():
		mach.mark_part("sel", sel, SEL_COLOR)
		var tw := str((res["parts"].get(sel, {}).get("part", {}) as Dictionary).get("twin", ""))
		if not tw.is_empty():
			mach.mark_part("twin", tw, TWIN_COLOR)
	if not hover.is_empty() and hover != sel:
		mach.mark_part("hover", hover, HOVER_COLOR)


# ---------------------------------------------------------------------------
# Input (the studio, Machine tab)
# ---------------------------------------------------------------------------

func _ray(pos: Vector2) -> Array:
	var cam: Camera3D = m._camera
	var vp: SubViewport = m._viewport
	var cont: SubViewportContainer = m._vp_container
	var vs := Vector2(vp.size)
	var cs := cont.size
	var p := pos * (vs / cs) if cs.x > 0.0 and cs.y > 0.0 else pos
	var o := cam.project_ray_origin(p)
	var d := cam.project_ray_normal(p)
	var inv: Transform3D = (m._machine as Node3D).global_transform.affine_inverse()
	return [inv * o, (inv.basis * d).normalized()]


func _offs() -> Dictionary:
	var out := {}
	var mach: GantryLabBuilder = m._machine
	if mach == null:
		return out
	for name in mach.layout()["assemblies"]:
		out[name] = mach.assembly_offset(str(name))
	return out


func _selectable(id: String) -> bool:
	if id.is_empty() or res.is_empty() or not res["parts"].has(id):
		return false
	var p: Dictionary = res["parts"][id]["part"]
	return not bool(p.get("free", false))


func _step(e: InputEvent) -> float:
	if e is InputEventWithModifiers:
		var em := e as InputEventWithModifiers
		if em.alt_pressed:
			return 0.0
		if em.shift_pressed:
			return 0.005
	return 0.001


## true = consumed (the modal does not orbit).
func input(e: InputEvent) -> bool:
	if not enabled() or m._machine == null:
		return false
	if e is InputEventMouseButton:
		var mb := e as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return false
		if mb.pressed:
			if not tool_ref.is_empty():
				_place_tool(mb.shift_pressed)
				return true
			var hit := m._pick_at(mb.position) as Dictionary
			var id := str(hit.get("id", ""))
			if _selectable(id):
				if id != sel:
					sel = id
					_refresh_marks()
					refresh_card()
				drag = {"id": id, "press": mb.position, "moved": false}
				return true
			# Empty space: let the modal orbit; a click without a drag deselects.
			drag = {"id": "", "press": mb.position, "moved": false}
			return false
		# Release.
		var was := drag.duplicate()
		drag = {}
		if not was.is_empty() and str(was["id"]).is_empty() and not bool(was.get("moved", false)) and not sel.is_empty():
			if mb.position.distance_to(was["press"]) < DRAG_PX:
				sel = ""
				_refresh_marks()
				refresh_card()
		if not was.is_empty() and bool(was.get("moved", false)):
			_flush_pending()
		return not was.is_empty() and not str(was["id"]).is_empty()
	if e is InputEventMouseMotion:
		var mm := e as InputEventMouseMotion
		_last_motion = mm.position
		if not drag.is_empty():
			if str(drag["id"]).is_empty():
				if mm.position.distance_to(drag["press"]) > DRAG_PX:
					drag["moved"] = true
				return false
			if not bool(drag["moved"]):
				if mm.position.distance_to(drag["press"]) <= DRAG_PX:
					return true
				drag["moved"] = true
				m._push_undo("")
			_drag_to(mm.position, _step(mm))
			return true
		if not tool_ref.is_empty():
			_update_ghost(mm.position, _step(mm))
			return false
		var hit := m._pick_at(mm.position) as Dictionary
		var hid := str(hit.get("id", ""))
		if not _selectable(hid):
			hid = ""
		if hid != hover:
			hover = hid
			_refresh_marks()
	return false


func key(k: InputEventKey) -> bool:
	if not enabled():
		return false
	match k.keycode:
		KEY_ESCAPE:
			if not tool_ref.is_empty():
				_disarm()
				return true
			if not sel.is_empty():
				sel = ""
				_refresh_marks()
				refresh_card()
				return true
		KEY_R:
			if not tool_ref.is_empty():
				tool_turn = posmod(tool_turn + 1, 4)
				_update_ghost(_last_motion, 0.001)
				return true
			if not sel.is_empty():
				_turn_selected(1)
				return true
		KEY_DELETE, KEY_BACKSPACE:
			if not sel.is_empty():
				_delete_selected()
				return true
		KEY_D:
			if k.ctrl_pressed and not sel.is_empty():
				_duplicate_selected()
				return true
	return false


# ---------------------------------------------------------------------------
# Dragging a placed part
# ---------------------------------------------------------------------------

func _drag_to(pos: Vector2, step: float) -> void:
	var id := str(drag["id"])
	var r := _ray(pos)
	var offs := _offs()
	var sl := GantryLabAssembly.slide(res, offs, id, r[0], r[1], step)
	var cam_d: float = (m._camera as Camera3D).global_position.distance_to((m._machine as Node3D).global_position)
	var tear_m := cam_d * 0.05
	var p: Dictionary = res["parts"][id]["part"]
	var mate: Dictionary = p.get("mate", {})
	if sl.is_empty() or float(sl.get("off", 0.0)) > tear_m:
		# Off its slide: find another spot for the same feature.
		var ex := GantryLabAssembly.subtree(res, id)
		var c := GantryLabAssembly.candidate(res, offs, str(p["ref"]), p.get("params", {}), r[0], r[1], ex, int(mate.get("turn", 0)), step)
		if not c.is_empty():
			var nm: Dictionary = (c["mate"] as Dictionary).duplicate()
			nm["to"] = c["to"]
			nm["tf"] = c["tf"]
			nm["f"] = c["f"]
			_queue_edit(id, {"mate": nm})
			m._hover_lbl.text = "→ %s · %s" % [_target_name(str(c["to"])), str(c["kind"])]
		return
	var nm2: Dictionary = sl["mate"]
	_queue_edit(id, {"mate": {"s": nm2["s"], "lat": nm2.get("lat", 0.0), "turn": nm2.get("turn", 0), "anchor": nm2.get("anchor", "start")}})
	var tf := GantryLabAssembly.feature_of(res["parts"][str(mate["to"])]["part"], str(mate["tf"]))
	m._hover_lbl.text = "%s · %s" % [GantryLabAssembly.label_of(p), _dist_text(tf, nm2)]


func _queue_edit(id: String, patch: Dictionary) -> void:
	_pending = {"id": id, "patch": patch}
	_flush_pending()


func _flush_pending() -> void:
	if _pending.is_empty():
		return
	var id := str(_pending["id"])
	var patch: Dictionary = _pending["patch"]
	_pending = {}
	GantryLabAssembly.edit_part(m._spec, id, patch)
	m._queue_rebuild(0.03)


func _dist_text(tf: Dictionary, mate: Dictionary) -> String:
	var anchor := str(mate.get("anchor", "start"))
	var s := float(mate.get("s", 0.0)) * 1000.0
	match anchor:
		"end":
			return "%.1f mm from the far end" % s
		"centre":
			return "%+.1f mm from the middle" % s
	return "%.1f mm from the near end" % s


func _target_name(id: String) -> String:
	if res.is_empty() or not res["parts"].has(id):
		return id
	return GantryLabAssembly.label_of(res["parts"][id]["part"])


# ---------------------------------------------------------------------------
# The palette
# ---------------------------------------------------------------------------

func _on_palette(ref: String) -> void:
	if tool_ref == ref:
		_disarm()
		return
	tool_ref = ref
	tool_params = GantryLabCatalog.params_of(ref, {})
	if GantryLabCatalog.info(ref).has("profile"):
		tool_params["len"] = 0.2
	if ref == "nema17_plate":
		tool_params["half"] = 0.026
	tool_turn = 0
	sel = ""
	for r in _palette_btns:
		(_palette_btns[r] as Button).button_pressed = (str(r) == ref)
	_refresh_marks()
	refresh_card()
	m._hover_lbl.text = "Place: %s — click where it fastens" % GantryLabCatalog.label_of(ref, tool_params)


func _disarm() -> void:
	tool_ref = ""
	cand = {}
	for r in _palette_btns:
		(_palette_btns[r] as Button).button_pressed = false
	if m._machine != null:
		(m._machine as GantryLabBuilder).clear_marks("ghost")
		(m._machine as GantryLabBuilder).clear_marks("target")
	m._hover_lbl.text = ""


func _update_ghost(pos: Vector2, step: float) -> void:
	var mach: GantryLabBuilder = m._machine
	if mach == null or res.is_empty():
		return
	var r := _ray(pos)
	cand = GantryLabAssembly.candidate(res, _offs(), tool_ref, tool_params, r[0], r[1], {}, tool_turn, step)
	mach.clear_marks("ghost")
	mach.clear_marks("target")
	if cand.is_empty():
		m._hover_lbl.text = "Place: %s — nothing it fastens to under the pointer" % GantryLabCatalog.label_of(tool_ref, tool_params)
		return
	var w: Transform3D = cand["world"]
	var beams: Array = []
	var parts: Array = []
	for dd in GantryLabCatalog.draw(tool_ref, tool_params):
		var d: Dictionary = (dd as Dictionary).duplicate()
		if bool(d.get("beam", false)):
			beams.append({"a": w * (d["a"] as Vector3), "b": w * (d["b"] as Vector3), "profile": d["profile"], "up": (w.basis * (d.get("up", Vector3.UP) as Vector3)).normalized()})
			continue
		d["c"] = w * (d.get("c", Vector3.ZERO) as Vector3)
		d["basis"] = w.basis * (d.get("basis", Basis.IDENTITY) as Basis)
		parts.append(d)
	# The bolts it would get, drawn with it.
	var tp: Dictionary = res["parts"][str(cand["to"])]["part"]
	var tf := GantryLabAssembly.feature_of(tp, str(cand["tf"]))
	var cf := GantryLabCatalog.feature(tool_ref, tool_params, str(cand["f"]))
	var nb := 0
	for fz in GantryLabMates.fasteners(res["parts"][str(cand["to"])]["world"], tf, cf, cand["mate"], {"wheelbase": float(tool_params.get("wheelbase", 0.06)), "wheels": int(tool_params.get("wheels", 4))}):
		var fd: Dictionary = fz
		var k := str(fd["kind"])
		if k.ends_with("_hidden"):
			continue
		nb += 1
		var xf: Transform3D = fd["xf"]
		var pd := {"kind": "fastener_" + k if k in ["bolt", "nut", "tnut", "washer", "spacer"] else k, "c": xf.origin, "basis": xf.basis}
		for kk in ["d", "len", "head", "ecc", "r", "w", "h"]:
			if fd.has(kk):
				pd[kk] = fd[kk]
		parts.append(pd)
	mach.mark_ghost("ghost", beams, parts, str(cand["asm"]), GHOST_OK)
	mach.mark_part("target", str(cand["to"]), TARGET_COLOR)
	var fz_count := GantryLabMates.fasteners(res["parts"][str(cand["to"])]["world"], tf, cf, cand["mate"])
	m._hover_lbl.text = "%s → %s · %s" % [GantryLabCatalog.label_of(tool_ref, tool_params), _target_name(str(cand["to"])), _fastener_summary(fz_count)]


func _fastener_summary(list: Array) -> String:
	var counts := {}
	for fz in list:
		var fd: Dictionary = fz
		if str(fd["kind"]) in ["bolt", "tnut", "spacer", "wheel"]:
			var l := str(fd.get("label", fd["kind"]))
			counts[l] = int(counts.get(l, 0)) + 1
	var bits: Array = []
	for l in counts:
		bits.append("%d× %s" % [counts[l], l])
	return ", ".join(bits) if not bits.is_empty() else "no fasteners"


func _place_tool(keep: bool) -> void:
	if cand.is_empty():
		return
	m._push_undo("")
	var mate: Dictionary = (cand["mate"] as Dictionary).duplicate()
	mate["to"] = cand["to"]
	mate["tf"] = cand["tf"]
	mate["f"] = cand["f"]
	var part := {"ref": tool_ref, "params": tool_params.duplicate(true), "mate": mate}
	var new_id := GantryLabAssembly.add_part(m._spec, part)
	if tool_mirror:
		_add_twin(new_id)
	sel = new_id
	if not keep:
		_disarm()
	m._queue_rebuild(0.0)


func _add_twin(id: String) -> void:
	GantryLabAssembly.add_twin(m._spec, id)


# ---------------------------------------------------------------------------
# Selected-part actions
# ---------------------------------------------------------------------------

func _turn_selected(dt: int) -> void:
	if res.is_empty() or not res["parts"].has(sel):
		return
	var p: Dictionary = res["parts"][sel]["part"]
	var mt: Dictionary = p.get("mate", {})
	if mt.is_empty():
		return
	var to := str(mt["to"])
	var tf := GantryLabAssembly.feature_of(res["parts"][to]["part"], str(mt["tf"]))
	var cf := GantryLabAssembly.feature_of(p, str(mt["f"]))
	for k in range(1, 4):
		var wish := mt.duplicate()
		wish["turn"] = posmod(int(mt.get("turn", 0)) + dt * k, 4)
		var sn := GantryLabMates.snap(tf, cf, wish, 0.0)
		if not sn.is_empty() and int(sn["turn"]) != int(mt.get("turn", 0)):
			m._push_undo("")
			GantryLabAssembly.edit_part(m._spec, sel, {"mate": {"turn": sn["turn"], "lat": sn.get("lat", 0.0), "s": sn["s"]}})
			m._queue_rebuild(0.0)
			return


func _delete_selected() -> void:
	if sel.is_empty():
		return
	m._push_undo("")
	var p: Dictionary = res["parts"][sel]["part"] if res["parts"].has(sel) else {}
	var tw := str(p.get("twin", ""))
	GantryLabAssembly.remove_part(m._spec, sel)
	if not tw.is_empty():
		GantryLabAssembly.remove_part(m._spec, tw)
	sel = ""
	m._queue_rebuild(0.0)


func _duplicate_selected() -> void:
	if sel.is_empty() or not res["parts"].has(sel):
		return
	var p: Dictionary = res["parts"][sel]["part"]
	var mt: Dictionary = (p.get("mate", {}) as Dictionary).duplicate()
	if mt.is_empty():
		return
	mt["s"] = float(mt.get("s", 0.0)) + 0.03
	m._push_undo("")
	sel = GantryLabAssembly.add_part(m._spec, {"ref": str(p["ref"]), "params": (p.get("params", {}) as Dictionary).duplicate(true), "mate": mt})
	m._queue_rebuild(0.0)


func _on_reset() -> void:
	if not GantryLabAssembly.has_edits(m._spec):
		return
	m._push_undo("")
	m._spec.erase("assembly")
	sel = ""
	m._queue_rebuild(0.0)


func _unlink() -> void:
	if sel.is_empty():
		return
	m._push_undo("")
	GantryLabAssembly.unlink(m._spec, sel)
	m._queue_rebuild(0.0)


# ---------------------------------------------------------------------------
# The selected part's card
# ---------------------------------------------------------------------------

func refresh_card() -> void:
	if card_box == null:
		return
	for c in card_box.get_children():
		card_box.remove_child(c)
		c.queue_free()
	if not enabled() or res.is_empty() or sel.is_empty() or not res["parts"].has(sel):
		var hint := Label.new()
		hint.text = "Click a part in the view to see what it is bolted to and move it." if enabled() else "—"
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		hint.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		card_box.add_child(hint)
		return
	var p: Dictionary = res["parts"][sel]["part"]
	var ref := str(p["ref"])
	var params := GantryLabCatalog.params_of(ref, p.get("params", {}))
	var mt: Dictionary = p.get("mate", {})
	var title := Label.new()
	title.text = GantryLabAssembly.label_of(p)
	title.add_theme_font_size_override("font_size", UITheme.FONT_MD)
	title.add_theme_color_override("font_color", UITheme.C_AMBER)
	card_box.add_child(title)
	if not mt.is_empty() and res["parts"].has(str(mt["to"])):
		var tf := GantryLabAssembly.feature_of(res["parts"][str(mt["to"])]["part"], str(mt["tf"]))
		var cf := GantryLabAssembly.feature_of(p, str(mt["f"]))
		var kind := GantryLabMates.mate_type(cf, tf)
		var on := Label.new()
		on.text = "%s %s" % [_kind_verb(kind), _target_name(str(mt["to"]))]
		on.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		on.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		on.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		card_box.add_child(on)
		# Swap within the family.
		var fam := GantryLabCatalog.family_refs(ref)
		if fam.size() > 1:
			var opt := OptionButton.new()
			for i in fam.size():
				opt.add_item(GantryLabCatalog.label_of(str(fam[i]), GantryLabCatalog.params_of(str(fam[i]), {})))
				opt.set_item_metadata(i, str(fam[i]))
				if str(fam[i]) == ref:
					opt.select(i)
			opt.item_selected.connect(func(i: int):
				m._push_undo("")
				GantryLabAssembly.edit_part(m._spec, sel, {"ref": str(opt.get_item_metadata(i))})
				m._queue_rebuild(0.0))
			_row("Part", opt)
		if GantryLabCatalog.info(ref).has("profile"):
			var ln := _spin(20.0, 3000.0, 1.0, " mm", float(params["len"]) * 1000.0, func(v: float):
				m._push_undo("part.len")
				GantryLabAssembly.edit_part(m._spec, sel, {"params": {"len": v * 0.001}})
				m._queue_rebuild())
			_row("Length", ln)
		if ref == "gt2_pulley" or ref == "gt2_idler":
			var tt := _spin(12.0, 40.0, 1.0, " T", float(params["teeth"]), func(v: float):
				m._push_undo("part.teeth")
				GantryLabAssembly.edit_part(m._spec, sel, {"params": {"teeth": int(v)}})
				m._queue_rebuild())
			_row("Teeth", tt)
		if kind in ["slot", "run", "shaft", "idler", "lines"] and str(tf.get("kind", "")) != "grid":
			var L := GantryLabMates.length_of(tf)
			var ds := _spin(-L * 1000.0, L * 1000.0, 0.5, " mm", float(mt.get("s", 0.0)) * 1000.0, func(v: float):
				m._push_undo("part.s")
				GantryLabAssembly.edit_part(m._spec, sel, {"mate": GantryLabMates.snap(tf, cf, mt.merged({"s": v * 0.001}, true), 0.0)})
				m._queue_rebuild())
			_row("Distance", ds, "Along the %s, measured from the end you pick; resizing the machine keeps it" % ("shaft" if kind == "shaft" else "slot"))
			var an := OptionButton.new()
			var anchors := ["start", "centre", "end"]
			for i in 3:
				an.add_item(["from the near end", "from the middle", "from the far end"][i])
				if str(mt.get("anchor", "start")) == anchors[i]:
					an.select(i)
			an.item_selected.connect(func(i: int):
				var sa := GantryLabMates.abs_s(tf, mt)
				m._push_undo("")
				GantryLabAssembly.set_part(m._spec, sel, {"mate": {"anchor": anchors[i], "s": GantryLabMates.rel_s(tf, anchors[i], sa)}})
				m._queue_rebuild(0.0))
			_row("Measured", an)
		if kind in ["grid"] or str(tf.get("kind", "")) == "grid":
			var la := _spin(-200.0, 200.0, 10.0, " mm", float(mt.get("lat", 0.0)) * 1000.0, func(v: float):
				m._push_undo("part.lat")
				GantryLabAssembly.edit_part(m._spec, sel, {"mate": GantryLabMates.snap(tf, cf, mt.merged({"lat": v * 0.001}, true), 0.0)})
				m._queue_rebuild())
			_row("Across", la, "Hole by hole across the plate's grid")
		if bool(cf.get("standoff", false)) or kind == "run" or (kind == "idler" and not bool(mt.get("auto", false))):
			var hh := _spin(0.0, 60.0, 0.5, " mm", float(mt.get("h", 0.0)) * 1000.0, func(v: float):
				m._push_undo("part.h")
				GantryLabAssembly.edit_part(m._spec, sel, {"mate": {"h": v * 0.001}})
				m._queue_rebuild())
			_row("Stand-off", hh, "Spacers between the part and the face; the bolts grow to match")
		if kind == "idler" and bool(mt.get("auto", false)):
			var al := Label.new()
			al.text = "Height: follows the belt's plane (spacer stack set for you)"
			al.add_theme_font_size_override("font_size", UITheme.FONT_XS)
			al.add_theme_color_override("font_color", UITheme.C_TEXT_M)
			card_box.add_child(al)
	# Mirror.
	var tw := str(p.get("twin", ""))
	var mrow := HBoxContainer.new()
	var ml := Label.new()
	ml.text = "Mirrored with the %s" % _target_name(tw).to_lower() if not tw.is_empty() else "Not mirrored"
	ml.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ml.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	ml.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	mrow.add_child(ml)
	if not tw.is_empty():
		var ub := Button.new()
		ub.text = "Unlink"
		ub.tooltip_text = "Edit this side on its own from now on"
		UITheme.style_button(ub)
		ub.pressed.connect(_unlink)
		mrow.add_child(ub)
	card_box.add_child(mrow)
	# Fasteners it adds.
	var fz := GantryLabAssembly.fasteners_of(res, sel)
	if not fz.is_empty():
		var fl := Label.new()
		var bits: Array = []
		for l in fz:
			bits.append("%d × %s" % [int(fz[l]), str(l)])
		fl.text = "Fastened with: " + ", ".join(bits)
		fl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		fl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		fl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		card_box.add_child(fl)
	var btns := HFlowContainer.new()
	btns.add_theme_constant_override("h_separation", UITheme.SPACE_XS)
	for spec_b in [["Turn 90°", "R — the next way round its bolts will still line up", func(): _turn_selected(1)],
			["Duplicate", "Ctrl+D — another one further along", _duplicate_selected],
			["Delete", "Del — and everything bolted to it", _delete_selected]]:
		var b := Button.new()
		b.text = str(spec_b[0])
		b.tooltip_text = str(spec_b[1])
		UITheme.style_button(b)
		b.pressed.connect(spec_b[2])
		btns.add_child(b)
	card_box.add_child(btns)


func _kind_verb(kind: String) -> String:
	match kind:
		"slot":
			return "Bolted with T-nuts into the slot of the"
		"grid":
			return "Bolted through the holes of the"
		"run":
			return "Rolls on V-wheels along the"
		"shaft":
			return "Clamped on the shaft of the"
		"pattern":
			return "Bolted to the"
		"idler":
			return "Turns on a bolt in the"
		"butt":
			return "Butted against the"
		"lines":
			return "Bolted flat to the"
	return "On the"


func _row(label: String, ctl: Control, tip: String = "") -> void:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(90, 0)
	l.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	l.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	row.add_child(l)
	ctl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if not tip.is_empty():
		ctl.tooltip_text = tip
	row.add_child(ctl)
	card_box.add_child(row)


func _spin(lo: float, hi: float, step: float, suffix: String, value: float, cb: Callable) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 0.001
	s.custom_arrow_step = step
	s.suffix = suffix
	s.value = value
	s.value_changed.connect(cb)
	return s
