extends SceneTree

## Offline deterministic selftest for `ParametricMaterialLibrary`,
## `ParametricMaterialSynth` and `StructureMaterials`.
##
## Run: Godot.exe.exe --headless --path . --script core/materials/parametric_material_selftest.gd

const EXPECTED_CHECKS := 68

var _fails := 0
var _checks := 0
var _tmp_root := ""


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _initialize() -> void:
	_tmp_root = "user://__pmat_selftest_%d" % Time.get_ticks_usec()
	ParametricMaterialLibrary.set_store_root(_tmp_root)

	_test_builtin_catalog_and_speed()
	_test_kind_mapping_and_invariants()
	_test_cc0_and_procedural_modes()
	_test_live_in_place_updates()
	_test_upload_derive_and_persistence()

	_cleanup_tmp(_tmp_root)
	ParametricMaterialLibrary.set_store_root(ParametricMaterialLibrary.DEFAULT_STORE_ROOT)

	_check("expected check count (%d == %d)" % [_checks, EXPECTED_CHECKS - 1], _checks == EXPECTED_CHECKS - 1)
	if _fails == 0:
		print("PARAMETRIC MATERIAL SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("PARAMETRIC MATERIAL SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


func _test_builtin_catalog_and_speed() -> void:
	var t0 := Time.get_ticks_msec()
	var ids := ParametricMaterialLibrary.all_ids()
	_check("20 built-in reusable materials registered", ids.size() == 20, "got %d" % ids.size())
	for id in ids:
		var m := ParametricMaterialLibrary.make(id, Color(0.7, 0.6, 0.5))
		_check("%s builds StandardMaterial3D with triplanar UVs" % id,
			m != null and m.uv1_triplanar and m.normal_texture != null)
	var dt := Time.get_ticks_msec() - t0
	_check("all 20 materials cold-synthesize under 1500 ms (took %d ms)" % dt, dt < 1500)


func _test_kind_mapping_and_invariants() -> void:
	# Every StructureMaterials.Kind (0..19) maps to a registered material ID.
	for k in 20:
		var mid := StructureMaterials.id_for_kind(k)
		_check("Kind %d -> '%s' exists" % [k, mid], ParametricMaterialLibrary.has_material(mid))

	# Preserve DomeLab / Earthship / VehicleLab selftest invariants:
	var alu := StructureMaterials.make(StructureMaterials.Kind.ALUMINIUM, Color(0.8, 0.82, 0.85))
	_check("aluminium metallic > 0.7", alu.metallic > 0.7)
	var galv := StructureMaterials.make(StructureMaterials.Kind.GALVANISED, Color(0.65, 0.67, 0.7))
	_check("galvanised metallic > 0.5 and roughness > 0.4", galv.metallic > 0.5 and galv.roughness > 0.4)
	var fab := StructureMaterials.make(StructureMaterials.Kind.FABRIC, Color(0.85, 0.82, 0.75))
	_check("fabric roughness > 0.9 and metallic < 0.01", fab.roughness > 0.9 and fab.metallic < 0.01)
	var glz := StructureMaterials.make(StructureMaterials.Kind.GLAZING, Color(0.8, 0.9, 0.95, 0.35))
	_check("glazing roughness < 0.2 and preserves alpha", glz.roughness < 0.2 and is_equal_approx(glz.albedo_color.a, 0.35))
	var pmma := StructureMaterials.make(StructureMaterials.Kind.PMMA, Color(0.85, 0.9, 0.95, 0.4))
	_check("pmma glossy + clearcoated", pmma.roughness < 0.2 and pmma.clearcoat_enabled)
	var cop := StructureMaterials.make(StructureMaterials.Kind.COPPER, Color(0.92, 0.55, 0.38))
	_check("copper high metallic + roughness map", cop.metallic > 0.8 and cop.roughness_texture != null)
	var roof := StructureMaterials.make(StructureMaterials.Kind.CORRUGATED_METAL, Color(0.6, 0.62, 0.65))
	_check("corrugated metal has rib normal + valley AO", roof.normal_enabled and roof.ao_enabled)


func _test_cc0_and_procedural_modes() -> void:
	# Committed CC0 textures (`ground049a` for concrete, `ground088` for corten) resolve in auto mode.
	var cc0_conc := ParametricMaterialLibrary.resolve_cc0_paths("concrete")
	_check("concrete finds committed CC0 ground049a normal", cc0_conc.has("normal"))
	_check("concrete active source is cc0 in auto mode", ParametricMaterialLibrary.active_source_kind("concrete") == "cc0")

	# Tint-neutral grain keeps exact `albedo_color` even when backed by a CC0 texture!
	var blue_tint := Color(0.18, 0.45, 0.78)
	var m_conc := ParametricMaterialLibrary.make("concrete", blue_tint)
	_check("tint-neutral grain preserves exact albedo_color", m_conc.albedo_color.is_equal_approx(blue_tint))

	# Switching to `procedural` mode forces procedural maps cleanly.
	ParametricMaterialLibrary.set_override("concrete", "texture_mode", "procedural")
	_check("procedural override switches active_source_kind", ParametricMaterialLibrary.active_source_kind("concrete") == "procedural")
	ParametricMaterialLibrary.reset_material("concrete")


func _test_live_in_place_updates() -> void:
	var c1 := Color(0.20, 0.44, 0.52)
	var m_opaque := ParametricMaterialLibrary.make("powder_coat", c1)
	var m_vcol := ParametricMaterialLibrary.make("powder_coat", Color(1.0, 1.0, 1.0, 0.45), {
		"vertex_color": true,
		"cull_mode": BaseMaterial3D.CULL_BACK,
		"transparency": BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS,
	})
	ParametricMaterialLibrary.set_override("powder_coat", "roughness", 0.19)
	ParametricMaterialLibrary.set_override("powder_coat", "normal_scale", 1.15)
	_check("live opaque material updated roughness in place", is_equal_approx(m_opaque.roughness, 0.19))
	_check("live opaque material updated normal_scale in place", is_equal_approx(m_opaque.normal_scale, 1.15))
	_check("live vcol material updated roughness while keeping vertex_color + alpha + cull_mode",
		is_equal_approx(m_vcol.roughness, 0.19)
		and m_vcol.vertex_color_use_as_albedo
		and is_equal_approx(m_vcol.albedo_color.a, 0.45)
		and m_vcol.cull_mode == BaseMaterial3D.CULL_BACK)
	ParametricMaterialLibrary.reset_material("powder_coat")
	_check("reset_material restores default roughness on live instance",
		is_equal_approx(m_opaque.roughness, float(ParametricMaterialLibrary.BUILTIN_SPECS["powder_coat"]["roughness"])))


func _test_upload_derive_and_persistence() -> void:
	# Synthesize a 64×64 test image in the temp folder and upload as custom albedo ONLY.
	var abs_tmp := ProjectSettings.globalize_path(_tmp_root)
	DirAccess.make_dir_recursive_absolute(abs_tmp)
	var src_png := abs_tmp.path_join("sample_upload.png")
	var img := Image.create(64, 64, false, Image.FORMAT_RGB8)
	for y in 64:
		for x in 64:
			var stripe := 0.35 + 0.50 * (0.5 + 0.5 * sin(float(x) * 0.45))
			img.set_pixel(x, y, Color(stripe, stripe * 0.8, stripe * 0.6, 1.0))
	img.save_png(src_png)

	var ply_mat := ParametricMaterialLibrary.make("plywood", Color(0.82, 0.68, 0.45))
	var res := ParametricMaterialLibrary.upload_texture("plywood", "albedo", src_png)
	_check("upload_texture succeeds", bool(res.get("ok", false)))
	_check("active_source_kind becomes custom", ParametricMaterialLibrary.active_source_kind("plywood") == "custom")
	_check("single-image upload auto-derives normal + roughness on live material",
		ply_mat.albedo_texture != null and ply_mat.normal_texture != null and ply_mat.roughness_texture != null)

	# Full-RGB mode sets albedo_color to WHITE so raw photo RGB displays untinted.
	ParametricMaterialLibrary.set_override("plywood", "full_color_albedo", true)
	_check("full_color_albedo switches albedo_color to WHITE", ply_mat.albedo_color.is_equal_approx(Color.WHITE))

	# Custom user-added material + persistence reload round-trip.
	var custom_id := ParametricMaterialLibrary.add_custom_material("Brushed Brass Trim", "brass_bronze")
	_check("add_custom_material mints user_* id", custom_id.begins_with("user_") and ParametricMaterialLibrary.is_custom_material(custom_id))

	# Reload from disk into a fresh state!
	ParametricMaterialLibrary.set_store_root(_tmp_root)
	_check("reloaded library keeps custom ply upload", ParametricMaterialLibrary.active_source_kind("plywood") == "custom")
	_check("reloaded library keeps full_color_albedo override",
		bool(ParametricMaterialLibrary.resolved_spec("plywood").get("full_color_albedo", false)))
	_check("reloaded library keeps user-added custom material", ParametricMaterialLibrary.has_material(custom_id))

	ParametricMaterialLibrary.clear_uploaded_texture("plywood", "albedo")
	_check("clearing last custom slot reverts texture_mode from custom to auto",
		ParametricMaterialLibrary.active_source_kind("plywood") != "custom")
	_check("remove_custom_material deletes custom entry",
		ParametricMaterialLibrary.remove_custom_material(custom_id) and not ParametricMaterialLibrary.has_material(custom_id))
	ParametricMaterialLibrary.reset_all()


func _cleanup_tmp(user_dir: String) -> void:
	var abs_p := ProjectSettings.globalize_path(user_dir)
	_rm_recursive(abs_p)


func _rm_recursive(abs_dir: String) -> void:
	var d := DirAccess.open(abs_dir)
	if d == null:
		return
	d.list_dir_begin()
	while true:
		var fn := d.get_next()
		if fn.is_empty():
			break
		if fn == "." or fn == "..":
			continue
		var p := abs_dir.path_join(fn)
		if d.current_is_dir():
			_rm_recursive(p)
		else:
			DirAccess.remove_absolute(p)
	d.list_dir_end()
	DirAccess.remove_absolute(abs_dir)
