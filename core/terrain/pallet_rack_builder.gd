class_name PalletRackBuilder
extends RefCounted

## Parametric industrial pallet-rack structure (uprights + beams + deck boards).
## Used by the pallet-rack builder modal and as a procedural PlacedProp model.

const MODEL_ID := "pallet_rack"


static func default_spec() -> Dictionary:
	return {
		"width_m": 2.4,
		"bay_count": 3,
		"levels": 3,
		"depth_m": 1.1,
		"upright_h_m": 0.0,  # 0 → derived from levels
		"beam_h_m": 0.08,
		"post_w_m": 0.08,
	}


static func resolve_spec(overrides: Dictionary = {}) -> Dictionary:
	var s := default_spec()
	for k in s.keys():
		if overrides.has(k):
			s[k] = overrides[k]
	s["width_m"] = clampf(float(s["width_m"]), 0.8, 6.0)
	s["bay_count"] = clampi(int(s["bay_count"]), 1, 12)
	s["levels"] = clampi(int(s["levels"]), 1, 8)
	s["depth_m"] = clampf(float(s["depth_m"]), 0.6, 3.0)
	s["beam_h_m"] = clampf(float(s["beam_h_m"]), 0.04, 0.2)
	s["post_w_m"] = clampf(float(s["post_w_m"]), 0.04, 0.2)
	var lvl_pitch := 0.55
	var derived_h := float(s["levels"]) * lvl_pitch + 0.35
	if float(s["upright_h_m"]) <= 0.05:
		s["upright_h_m"] = derived_h
	else:
		s["upright_h_m"] = clampf(float(s["upright_h_m"]), 1.0, 8.0)
	s["level_pitch_m"] = lvl_pitch
	return s


static func footprint_xz(spec: Dictionary = {}) -> Vector2:
	var s := resolve_spec(spec)
	return Vector2(float(s["width_m"]) * float(s["bay_count"]), float(s["depth_m"]))


static func build_node(spec: Dictionary = {}, node_name: String = "PalletRack") -> Node3D:
	var s := resolve_spec(spec)
	var root := Node3D.new()
	root.name = node_name
	root.set_meta("rack_spec", s.duplicate(true))

	var width := float(s["width_m"])
	var bays := int(s["bay_count"])
	var levels := int(s["levels"])
	var depth := float(s["depth_m"])
	var height := float(s["upright_h_m"])
	var beam_h := float(s["beam_h_m"])
	var post_w := float(s["post_w_m"])
	var pitch := float(s["level_pitch_m"])
	var steel := _steel_material()
	var deck := _deck_material()

	var total_w := width * float(bays)
	var x0 := -total_w * 0.5
	var z0 := -depth * 0.5

	# Upright posts at each bay column × front/back
	for bi in range(bays + 1):
		var x := x0 + float(bi) * width
		for z in [z0, z0 + depth]:
			_add_box(root, "Post_%d_%d" % [bi, int(z)],
				Vector3(post_w, height, post_w),
				Vector3(x, height * 0.5, z), steel)

	# Horizontal beams + deck boards per level / bay
	for li in range(levels):
		var y := 0.35 + float(li) * pitch
		if y > height - 0.05:
			break
		for bi in range(bays):
			var cx := x0 + (float(bi) + 0.5) * width
			# Front + rear beams
			for z in [z0, z0 + depth]:
				_add_box(root, "Beam_f_%d_%d" % [li, bi],
					Vector3(width - post_w, beam_h, post_w * 0.7),
					Vector3(cx, y, z), steel)
			# Side ties
			for sx in [x0 + float(bi) * width, x0 + float(bi + 1) * width]:
				_add_box(root, "Tie_%d_%d" % [li, bi],
					Vector3(post_w * 0.7, beam_h, depth - post_w),
					Vector3(sx, y, z0 + depth * 0.5), steel)
			# Deck / pallet boards
			_add_box(root, "Deck_%d_%d" % [li, bi],
				Vector3(width - post_w * 1.2, 0.03, depth - post_w * 1.2),
				Vector3(cx, y + beam_h * 0.5 + 0.02, z0 + depth * 0.5), deck)

	# Foot origin on ground centre so PlacedProp footing works (local Y=0).
	return root


static func build_default_node() -> Node3D:
	return build_node(default_spec())


static func _add_box(parent: Node3D, name: String, size: Vector3,
		origin: Vector3, mat: Material) -> void:
	var mi := MeshInstance3D.new()
	mi.name = name
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.material_override = mat
	mi.position = origin
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(mi)


static func _steel_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.22, 0.18)
	mat.metallic = 0.7
	mat.roughness = 0.45
	return mat


static func _deck_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.42, 0.28)
	mat.roughness = 0.85
	return mat
