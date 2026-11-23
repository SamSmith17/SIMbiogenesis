class_name MaterialLibraryModal
extends Control

## Parametric Materials Studio (`Library → Designers → Parametric materials` or
## `Settings → Lighting → Parametric materials…`).
##
## Lets the player inspect, fine-tune and upload custom PBR textures for the
## shared reusable materials (`ParametricMaterialLibrary`) used across all
## parametric designers and world structures — updating every live model in the
## 3D world in place.

const MODAL_NAME := "material_library"

var _shell: DesignerShell = null
var _studio: StudioViewport = null
var _col: DesignerColumn = null
var _search_edit: LineEdit = null
var _list_box: VBoxContainer = null
var _new_name_edit: LineEdit = null
var _delete_custom_btn: Button = null
var _status_lbl: Label = null

var _selected_id: String = "plywood"
var _preview_tint_override: Variant = null # null = material's default_color, else Color
var _lighting_mode: String = "day"
var _suppress_ui: bool = false

# 3D test rig
var _rig_root: Node3D = null
var _rig_meshes: Array[MeshInstance3D] = []
var _rig_mat: StandardMaterial3D = null

# Form controls
var _r_mode: FormRow = null
var _r_rough: FormRow = null
var _r_rough_c: FormRow = null
var _r_metal: FormRow = null
var _r_spec: FormRow = null
var _r_normal: FormRow = null
var _r_grain: FormRow = null
var _r_ao: FormRow = null
var _r_clearcoat: FormRow = null
var _r_cc_rough: FormRow = null
var _r_scale: FormRow = null
var _r_derive: FormRow = null
var _r_full_rgb: FormRow = null

var _slot_labels: Dictionary = {}
var _slot_clear_btns: Dictionary = {}
var _file_dialog: FileDialog = null
var _pending_upload_slot: String = "albedo"


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	_build_ui()


func is_open() -> bool:
	return _shell != null and _shell.is_open()


func open(opts: Dictionary = {}) -> void:
	if _shell == null:
		_build_ui()
	ParametricMaterialLibrary.refresh_cc0_discovery()
	var want_id := str(opts.get("material_id", _selected_id))
	if not ParametricMaterialLibrary.has_material(want_id):
		want_id = "plywood"
	_selected_id = want_id
	_preview_tint_override = null
	visible = true
	_shell.open()
	_connect_drop(true)
	_rebuild_material_list()
	_select_material(_selected_id)
	if _studio != null:
		_studio.frame_sphere(Vector3(0.0, 0.42, 0.0), 0.95)


func close() -> void:
	if _shell != null and _shell.is_open():
		_shell.close()
	else:
		_on_shell_closed()


func _on_shell_closed() -> void:
	_connect_drop(false)
	visible = false


func _connect_drop(on: bool) -> void:
	var win := get_window()
	if win == null:
		return
	var cb := Callable(self, "_on_files_dropped")
	if on and not win.files_dropped.is_connected(cb):
		win.files_dropped.connect(cb)
	elif not on and win.files_dropped.is_connected(cb):
		win.files_dropped.disconnect(cb)


func _build_ui() -> void:
	_shell = DesignerShell.create("Parametric Materials", "layers", {
		"name_id": MODAL_NAME,
		"left_label": "Materials",
		"want": Vector2(1520, 920),
	})
	add_child(_shell)
	_shell.closed.connect(_on_shell_closed)
	_shell.set_hint("Drag to orbit · wheel to zoom · drop PNG/JPG/WebP files onto window to upload")

	_build_left_column(_shell.left)
	_build_centre_studio(_shell.centre)
	_build_right_column(_shell.right)

	_shell.add_button("Reset material", DesignerShell.SECONDARY, _on_reset_current)
	_shell.add_button("Reset all", DesignerShell.SECONDARY, _on_reset_all)
	_shell.add_button("Done", DesignerShell.PRIMARY, close)

	_file_dialog = FileDialog.new()
	_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_file_dialog.filters = PackedStringArray([
		"*.png, *.jpg, *.jpeg, *.webp ; Image Textures (PNG, JPG, WebP)",
	])
	_file_dialog.file_selected.connect(_on_file_dialog_selected)
	add_child(_file_dialog)


func _build_left_column(box: VBoxContainer) -> void:
	_search_edit = LineEdit.new()
	_search_edit.name = "material_search"
	_search_edit.placeholder_text = "Filter materials…"
	_search_edit.clear_button_enabled = true
	_search_edit.text_changed.connect(func(_t: String) -> void: _rebuild_material_list())
	box.add_child(_search_edit)

	_list_box = VBoxContainer.new()
	_list_box.add_theme_constant_override("separation", 3)
	_list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_list_box)

	box.add_child(HSeparator.new())
	var add_row := HBoxContainer.new()
	add_row.add_theme_constant_override("separation", 4)
	_new_name_edit = LineEdit.new()
	_new_name_edit.name = "new_material_name"
	_new_name_edit.placeholder_text = "New material name…"
	_new_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_row.add_child(_new_name_edit)
	var add_btn := Button.new()
	add_btn.name = "add_custom_material"
	add_btn.text = "+ Add"
	UITheme.style_button(add_btn)
	add_btn.pressed.connect(_on_add_custom)
	add_row.add_child(add_btn)
	box.add_child(add_row)

	_delete_custom_btn = Button.new()
	_delete_custom_btn.name = "delete_custom_material"
	_delete_custom_btn.text = "Delete custom material"
	UITheme.style_button(_delete_custom_btn)
	_delete_custom_btn.visible = false
	_delete_custom_btn.pressed.connect(_on_delete_custom)
	box.add_child(_delete_custom_btn)


func _build_centre_studio(centre: VBoxContainer) -> void:
	_studio = StudioViewport.create({
		"ground": true,
		"person": false,
		"ssao": true,
		"msaa": Viewport.MSAA_4X,
	})
	_studio.size_flags_vertical = Control.SIZE_EXPAND_FILL
	centre.add_child(_studio)
	_build_test_rig(_studio.holder)

	# Bottom strip: lighting rig switcher + tint test swatches + status readout.
	var strip := _studio.strip
	var light_lbl := Label.new()
	light_lbl.text = "Light:"
	light_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	light_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	strip.add_child(light_lbl)
	for pair in [["day", "Daylight"], ["golden", "Golden"], ["contrast", "Grazing"]]:
		var lb := Button.new()
		lb.text = str(pair[1])
		lb.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		UITheme.style_button(lb)
		var mode_key := str(pair[0])
		lb.pressed.connect(func() -> void: _apply_studio_lighting(mode_key))
		strip.add_child(lb)

	var sep := VSeparator.new()
	strip.add_child(sep)

	var tint_lbl := Label.new()
	tint_lbl.text = "Swatch:"
	tint_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	tint_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	strip.add_child(tint_lbl)

	var swatches := [
		["Natural", null],
		["Teal", Color(0.18, 0.45, 0.52)],
		["Oxide", Color(0.78, 0.34, 0.16)],
		["Birch", Color(0.82, 0.69, 0.48)],
		["Charcoal", Color(0.18, 0.19, 0.22)],
	]
	for sw in swatches:
		var sb := Button.new()
		sb.text = str(sw[0])
		sb.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		UITheme.style_button(sb)
		var sw_col: Variant = sw[1]
		sb.pressed.connect(func() -> void:
			_preview_tint_override = sw_col
			_refresh_rig_material())
		strip.add_child(sb)

	_status_lbl = Label.new()
	_status_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status_lbl.clip_text = true
	_status_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
	_status_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
	strip.add_child(_status_lbl)


func _build_test_rig(holder: Node3D) -> void:
	_rig_root = Node3D.new()
	_rig_root.name = "MaterialTestRig"
	holder.add_child(_rig_root)
	_rig_meshes.clear()

	# 1) Smooth PBR sphere (shows specular lobe, roughness map, clearcoat & sky reflection)
	var sph_mi := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.32
	sph.height = 0.64
	sph.radial_segments = 48
	sph.rings = 24
	sph_mi.mesh = sph
	sph_mi.position = Vector3(-0.46, 0.36, 0.12)
	_rig_root.add_child(sph_mi)
	_rig_meshes.append(sph_mi)

	# 2) Tilted architectural sheet / panel (shows grain, corrugation & normal relief)
	var plate_mi := MeshInstance3D.new()
	var plate := BoxMesh.new()
	plate.size = Vector3(0.76, 0.58, 0.035)
	plate_mi.mesh = plate
	plate_mi.position = Vector3(0.32, 0.36, -0.08)
	plate_mi.rotation_degrees = Vector3(-24.0, -18.0, 0.0)
	_rig_root.add_child(plate_mi)
	_rig_meshes.append(plate_mi)

	# 3) 90° structural L-angle + tube (verifies distortion-free triplanar wrap across bends)
	var leg_a := MeshInstance3D.new()
	var ba := BoxMesh.new()
	ba.size = Vector3(0.50, 0.025, 0.22)
	leg_a.mesh = ba
	leg_a.position = Vector3(-0.08, 0.03, 0.44)
	_rig_root.add_child(leg_a)
	_rig_meshes.append(leg_a)

	var leg_b := MeshInstance3D.new()
	var bb := BoxMesh.new()
	bb.size = Vector3(0.50, 0.20, 0.025)
	leg_b.mesh = bb
	leg_b.position = Vector3(-0.08, 0.13, 0.34)
	_rig_root.add_child(leg_b)
	_rig_meshes.append(leg_b)

	var tube_mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.055
	cyl.bottom_radius = 0.055
	cyl.height = 0.62
	cyl.radial_segments = 28
	tube_mi.mesh = cyl
	tube_mi.position = Vector3(0.42, 0.10, 0.38)
	tube_mi.rotation_degrees = Vector3(0.0, 22.0, 90.0)
	_rig_root.add_child(tube_mi)
	_rig_meshes.append(tube_mi)


func _build_right_column(right: VBoxContainer) -> void:
	right.add_child(SectionHeader.make("Surface & Finish"))
	_r_rough = FormRow.slider("Roughness", 0.02, 1.0, 0.5, 0.01, "",
		func(v: float) -> void: _set_param("roughness", v),
		"Base surface micro-roughness (0.02 mirror/glass .. 1.0 matte chalk)", "pmat_roughness")
	right.add_child(_r_rough)

	_r_rough_c = FormRow.slider("Roughness map", 0.0, 1.0, 0.4, 0.02, "",
		func(v: float) -> void: _set_param("rough_contrast", v),
		"Strength of micro-roughness variation across grain, pores or spangle", "pmat_rough_contrast")
	right.add_child(_r_rough_c)

	_r_metal = FormRow.slider("Metallic", 0.0, 1.0, 0.0, 0.02, "",
		func(v: float) -> void: _set_param("metallic", v),
		"0 for dielectrics (wood, plastic, powder coat, glass); 0.6–0.95 for bare metals", "pmat_metallic")
	right.add_child(_r_metal)

	_r_spec = FormRow.slider("Specular", 0.0, 1.0, 0.5, 0.02, "",
		func(v: float) -> void: _set_param("specular", v),
		"Dielectric Fresnel F0 reflectance", "pmat_specular")
	right.add_child(_r_spec)

	_r_normal = FormRow.slider("Normal relief", 0.0, 2.0, 0.35, 0.02, "",
		func(v: float) -> void: _set_param("normal_scale", v),
		"Depth of surface grain, ribs, weave or rust pits under directional & SDFGI light", "pmat_normal_scale")
	right.add_child(_r_normal)

	_r_grain = FormRow.slider("Surface grain", 0.0, 1.0, 0.35, 0.02, "",
		func(v: float) -> void: _set_param("grain_strength", v),
		"Albedo micro-variation intensity (normalized so part tint colors stay true)", "pmat_grain_strength")
	right.add_child(_r_grain)

	_r_ao = FormRow.slider("Cavity AO", 0.0, 1.0, 0.0, 0.02, "",
		func(v: float) -> void: _set_param("ao_strength", v),
		"Self-shadowing in corrugation valleys, weave crossings and rust pits", "pmat_ao_strength")
	right.add_child(_r_ao)

	_r_clearcoat = FormRow.slider("Clearcoat", 0.0, 1.0, 0.0, 0.02, "",
		func(v: float) -> void: _set_param("clearcoat", v),
		"Secondary glossy lacquer / clear-coat layer (automotive paint, satin powder coat, glazing)", "pmat_clearcoat")
	right.add_child(_r_clearcoat)

	_r_cc_rough = FormRow.slider("Coat roughness", 0.02, 1.0, 0.15, 0.02, "",
		func(v: float) -> void: _set_param("clearcoat_roughness", v),
		"Sharpness of the clearcoat reflection", "pmat_clearcoat_roughness")
	right.add_child(_r_cc_rough)

	_r_scale = FormRow.slider("Tile scale", 0.08, 6.0, 0.50, 0.02, "m",
		func(v: float) -> void: _set_param("scale_m", v),
		"Physical world/object size of one texture repeat in metres", "pmat_scale_m")
	right.add_child(_r_scale)

	right.add_child(SectionHeader.make("Textures & Upload"))
	_r_mode = FormRow.option("Texture mode", [
		["auto", "Auto (CC0 if present, else procedural)"],
		["procedural", "Procedural PBR only"],
		["custom", "Custom uploaded textures"],
	], func(v: Variant) -> void: _set_param("texture_mode", str(v)),
		"Choose between shipped CC0 / procedural textures or your own uploaded image maps", "pmat_texture_mode")
	right.add_child(_r_mode)

	_r_derive = FormRow.check("Single-image", "Auto normal & roughness from color",
		func(on: bool) -> void: _set_param("derive_maps", on),
		"When uploading only a color photo, automatically synthesize matching normal & roughness maps", "pmat_derive_maps")
	right.add_child(_r_derive)

	_r_full_rgb = FormRow.check("Color mode", "Use full RGB photo (override tint)",
		func(on: bool) -> void: _set_param("full_color_albedo", on),
		"Off: normalizes texture luminance so parts keep their designer colors. On: displays the raw RGB photo.", "pmat_full_rgb")
	right.add_child(_r_full_rgb)

	var slots := [
		["albedo", "Albedo / Grain"],
		["normal", "Normal (GL)"],
		["roughness", "Roughness"],
		["ao", "Ambient Occl."],
	]
	for s in slots:
		var slot_id := str(s[0])
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var nl := Label.new()
		nl.text = str(s[1])
		nl.custom_minimum_size = Vector2(110, 0)
		nl.clip_text = true
		nl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		nl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		nl.add_theme_color_override("font_color", UITheme.C_TEXT_S)
		row.add_child(nl)

		var st_lbl := Label.new()
		st_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		st_lbl.clip_text = true
		st_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		st_lbl.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		st_lbl.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		row.add_child(st_lbl)
		_slot_labels[slot_id] = st_lbl

		var up_btn := Button.new()
		up_btn.name = "upload_" + slot_id
		up_btn.text = "Upload…"
		up_btn.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		UITheme.style_button(up_btn)
		up_btn.pressed.connect(func() -> void: _open_upload_dialog(slot_id))
		row.add_child(up_btn)

		var clr_btn := Button.new()
		clr_btn.name = "clear_" + slot_id
		clr_btn.text = "×"
		clr_btn.tooltip_text = "Remove uploaded %s map" % slot_id
		clr_btn.add_theme_font_size_override("font_size", UITheme.FONT_XS)
		UITheme.style_button(clr_btn)
		clr_btn.pressed.connect(func() -> void: _clear_slot(slot_id))
		row.add_child(clr_btn)
		_slot_clear_btns[slot_id] = clr_btn

		right.add_child(row)

	_col = DesignerColumn.setup(right, MODAL_NAME, {
		"open": ["Surface & Finish", "Textures & Upload"],
		"tiles": true,
		"tile_cols": 3,
	})


func _rebuild_material_list() -> void:
	if _list_box == null:
		return
	for ch in _list_box.get_children():
		_list_box.remove_child(ch)
		ch.queue_free()

	var q := _search_edit.text.strip_edges().to_lower() if _search_edit != null else ""
	var by_cat: Dictionary = {}
	var cat_order: Array[String] = []
	for id in ParametricMaterialLibrary.all_ids():
		var spec := ParametricMaterialLibrary.resolved_spec(id)
		var label := str(spec.get("label", id))
		var cat := str(spec.get("category", "Other"))
		if not q.is_empty() and not label.to_lower().contains(q) and not id.to_lower().contains(q) and not cat.to_lower().contains(q):
			continue
		if not by_cat.has(cat):
			by_cat[cat] = []
			cat_order.append(cat)
		(by_cat[cat] as Array).append([id, spec])

	for cat in cat_order:
		var hdr := Label.new()
		hdr.text = cat.to_upper()
		hdr.add_theme_font_size_override("font_size", 10)
		hdr.add_theme_color_override("font_color", UITheme.C_TEXT_M)
		_list_box.add_child(hdr)

		for entry in (by_cat[cat] as Array):
			var mid := str(entry[0])
			var spec: Dictionary = entry[1]
			var btn := Button.new()
			btn.name = "mat_item_" + mid
			var src := ParametricMaterialLibrary.active_source_kind(mid)
			var tag := ""
			if src == "custom":
				tag = "  [Custom]"
			elif src == "cc0":
				tag = "  [CC0]"
			if ParametricMaterialLibrary.is_modified(mid) and src != "custom":
				tag += " ●"
			btn.text = str(spec.get("label", mid)) + tag
			btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
			btn.clip_text = true
			btn.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			if mid == _selected_id:
				UITheme.style_primary_button(btn)
			else:
				UITheme.style_button(btn)
			btn.pressed.connect(func() -> void: _select_material(mid))
			_list_box.add_child(btn)


func _select_material(mat_id: String) -> void:
	_selected_id = mat_id
	_preview_tint_override = null
	if _delete_custom_btn != null:
		_delete_custom_btn.visible = ParametricMaterialLibrary.is_custom_material(mat_id)
	_rebuild_material_list()
	_sync_controls_from_spec()
	_refresh_rig_material()


func _sync_controls_from_spec() -> void:
	_suppress_ui = true
	var spec := ParametricMaterialLibrary.resolved_spec(_selected_id)
	if _shell != null and _shell.subtitle != null:
		var live_n := ParametricMaterialLibrary.live_instance_count(_selected_id)
		_shell.subtitle.text = "%s  ·  %d live surface%s in world" % [
			str(spec.get("label", _selected_id)), live_n, "" if live_n == 1 else "s"]

	_r_rough.set_value(float(spec.get("roughness", 0.5)))
	_r_rough_c.set_value(float(spec.get("rough_contrast", 0.4)))
	_r_metal.set_value(float(spec.get("metallic", 0.0)))
	_r_spec.set_value(float(spec.get("specular", 0.5)))
	_r_normal.set_value(float(spec.get("normal_scale", 0.3)))
	_r_grain.set_value(float(spec.get("grain_strength", 0.3)))
	_r_ao.set_value(float(spec.get("ao_strength", 0.0)))
	_r_clearcoat.set_value(float(spec.get("clearcoat", 0.0)))
	_r_cc_rough.set_value(float(spec.get("clearcoat_roughness", 0.15)))
	_r_scale.set_value(float(spec.get("scale_m", 0.5)))
	_r_mode.set_value(str(spec.get("texture_mode", "auto")))
	_r_derive.set_value(bool(spec.get("derive_maps", true)))
	_r_full_rgb.set_value(bool(spec.get("full_color_albedo", false)))

	var cc0 := ParametricMaterialLibrary.resolve_cc0_paths(_selected_id)
	var ctex: Dictionary = spec.get("custom_textures", {})
	var mode := str(spec.get("texture_mode", "auto"))
	var derive := bool(spec.get("derive_maps", true)) and ctex.has("albedo")
	for slot in ParametricMaterialLibrary.MAP_SLOTS:
		var lbl := _slot_labels.get(slot) as Label
		var clr := _slot_clear_btns.get(slot) as Button
		var has_usr := ctex.has(slot)
		if clr != null:
			clr.disabled = not has_usr
		if lbl == null:
			continue
		if mode == "custom" and has_usr:
			lbl.text = str(ctex[slot]).get_file()
		elif mode == "custom" and derive and slot in ["normal", "roughness"]:
			lbl.text = "Derived from albedo"
		elif mode != "procedural" and cc0.has(slot):
			lbl.text = "CC0 (" + str(cc0[slot]).get_file() + ")"
		else:
			lbl.text = "Procedural (" + str(spec.get("pattern", "pbr")) + ")"

	if _col != null:
		var src_kind := ParametricMaterialLibrary.active_source_kind(_selected_id)
		var src_cap := "CC0 PBR" if src_kind == "cc0" else ("Custom" if src_kind == "custom" else "Procedural")
		var fin_cap := "Metal %.0f%%" % (float(spec.get("metallic", 0.0)) * 100.0) \
			if float(spec.get("metallic", 0.0)) >= 0.4 else ("Rough %.2f" % float(spec.get("roughness", 0.5)))
		_col.set_tiles([
			{"caption": "Textures", "value": src_cap},
			{"caption": "Finish", "value": fin_cap},
			{"caption": "Tile size", "value": "%.2f m" % float(spec.get("scale_m", 0.5))},
		])
	_suppress_ui = false


func _refresh_rig_material() -> void:
	if _rig_meshes.is_empty():
		return
	var spec := ParametricMaterialLibrary.resolved_spec(_selected_id)
	var col: Color = _preview_tint_override if _preview_tint_override is Color else spec.get("default_color", Color.GRAY)
	_rig_mat = ParametricMaterialLibrary.make(_selected_id, col)
	for mi in _rig_meshes:
		if is_instance_valid(mi):
			mi.material_override = _rig_mat
	if _shell != null and _shell.subtitle != null:
		var live_n := ParametricMaterialLibrary.live_instance_count(_selected_id)
		_shell.subtitle.text = "%s  ·  %d live surface%s" % [
			str(spec.get("label", _selected_id)), live_n, "" if live_n == 1 else "s"]


func _set_param(key: String, value: Variant) -> void:
	if _suppress_ui:
		return
	ParametricMaterialLibrary.set_override(_selected_id, key, value, true)
	_sync_controls_from_spec()
	_rebuild_material_list()


func _open_upload_dialog(slot: String) -> void:
	_pending_upload_slot = slot
	if _file_dialog != null:
		_file_dialog.title = "Upload %s texture for %s" % [slot.capitalize(), _selected_id]
		_file_dialog.popup_centered(Vector2i(860, 560))


func _on_file_dialog_selected(path: String) -> void:
	_apply_upload(_pending_upload_slot, path)


func _apply_upload(slot: String, path: String) -> void:
	var res := ParametricMaterialLibrary.upload_texture(_selected_id, slot, path)
	if bool(res.get("ok", false)):
		var sz: Vector2i = res.get("size", Vector2i.ZERO)
		_set_status("Uploaded %s (%dx%d)" % [slot, sz.x, sz.y])
	else:
		_set_status(str(res.get("error", "Upload failed")))
	_sync_controls_from_spec()
	_rebuild_material_list()


func _on_files_dropped(files: PackedStringArray) -> void:
	if not is_open():
		return
	var count := 0
	for fp in files:
		var ext := fp.get_extension().to_lower()
		if not ParametricMaterialLibrary.IMAGE_EXTS.has(ext):
			continue
		var stem := fp.get_file().get_basename().to_lower()
		var slot := "albedo"
		if stem.contains("normal") or stem.ends_with("_nrm"):
			slot = "normal"
		elif stem.contains("rough") or stem.ends_with("_rgh"):
			slot = "roughness"
		elif stem.contains("ambientocclusion") or stem.ends_with("_ao") or stem == "ao":
			slot = "ao"
		var res := ParametricMaterialLibrary.upload_texture(_selected_id, slot, fp)
		if bool(res.get("ok", false)):
			count += 1
	if count > 0:
		_set_status("Imported %d dropped texture map%s" % [count, "" if count == 1 else "s"])
		_sync_controls_from_spec()
		_rebuild_material_list()


func _clear_slot(slot: String) -> void:
	ParametricMaterialLibrary.clear_uploaded_texture(_selected_id, slot)
	_set_status("Cleared custom %s map" % slot)
	_sync_controls_from_spec()
	_rebuild_material_list()


func _on_reset_current() -> void:
	ParametricMaterialLibrary.reset_material(_selected_id)
	_set_status("Reset '%s' to default" % _selected_id)
	_sync_controls_from_spec()
	_rebuild_material_list()


func _on_reset_all() -> void:
	ParametricMaterialLibrary.reset_all()
	_set_status("Reset all materials to defaults")
	_sync_controls_from_spec()
	_rebuild_material_list()


func _on_add_custom() -> void:
	var nm := _new_name_edit.text.strip_edges() if _new_name_edit != null else ""
	if nm.is_empty():
		nm = "Custom Material"
	var new_id := ParametricMaterialLibrary.add_custom_material(nm, _selected_id)
	if _new_name_edit != null:
		_new_name_edit.text = ""
	_set_status("Created '%s'" % nm)
	_select_material(new_id)


func _on_delete_custom() -> void:
	if not ParametricMaterialLibrary.is_custom_material(_selected_id):
		return
	var old_id := _selected_id
	if ParametricMaterialLibrary.remove_custom_material(old_id):
		_set_status("Deleted '%s'" % old_id)
		_select_material("plywood")


func _apply_studio_lighting(mode: String) -> void:
	_lighting_mode = mode
	if _studio == null:
		return
	match mode:
		"golden":
			if _studio.key_light != null:
				_studio.key_light.light_color = Color(1.0, 0.76, 0.52)
				_studio.key_light.light_energy = 1.65
				_studio.key_light.rotation_degrees = Vector3(-18.0, 42.0, 0.0)
			if _studio.environment != null:
				_studio.environment.ambient_light_energy = 0.55
		"contrast":
			if _studio.key_light != null:
				_studio.key_light.light_color = Color(0.98, 0.98, 1.0)
				_studio.key_light.light_energy = 2.1
				_studio.key_light.rotation_degrees = Vector3(-22.0, -55.0, 0.0)
			if _studio.environment != null:
				_studio.environment.ambient_light_energy = 0.35
		_:
			if _studio.key_light != null:
				_studio.key_light.light_color = Color(1.0, 0.98, 0.94)
				_studio.key_light.light_energy = 1.35
				_studio.key_light.rotation_degrees = Vector3(-42.0, 35.0, 0.0)
			if _studio.environment != null:
				_studio.environment.ambient_light_energy = 0.85


func _set_status(msg: String) -> void:
	if _status_lbl != null:
		_status_lbl.text = msg
