class_name ModelCatalog
extends RefCounted

## Shipped + user GLB catalog for placed props.

const USER_DIR := "user://models/"
const CATALOG_PATH := "user://models/catalog.json"
const DEFAULT_TARGET_HEIGHT_M := 3.0
const MAX_WORLD_SCALE := 50.0
## Procedural gray-box placeholder for abstract graph nodes (PBIs, monitors,
## breakers, spiderboxes…) that have no bespoke GLB. Sized from the preset
## footprint via a `box_spec` extra; falls back to a 1 m cube.
const GENERIC_BOX_ID := "generic_box"
## Procedural tank silhouette for resource / catchment site twins (cylinder
## from `box_spec` / `tank_spec` w_m×d_m×h_m).
const GENERIC_TANK_ID := "generic_tank"
## LinkageLab GLB meshes use inch coordinates (see bundle translations ~40–300).
const LINKAGELAB_INCHES_TO_M := 0.0254

static var _fit_cache: Dictionary = {}
static var _user_catalog: Array = []
static var _user_packed: Dictionary = {}
static var _catalog_loaded := false


static func all_models() -> Array[Dictionary]:
	_ensure_user_catalog()
	var out: Array[Dictionary] = []
	out.append_array(_shipped_models())
	out.append_array(_user_catalog)
	return out


static func find(model_id: String) -> Dictionary:
	for m in all_models():
		if str(m.get("id", "")) == model_id:
			return m
	return {}


## True for the shipped StarShade or any LinkageLab bundle import (user_* ids).
static func is_starshade_model(model_id: String) -> bool:
	if model_id.is_empty():
		return false
	if model_id == "starshade" or model_id.begins_with("starshade_"):
		return true
	var entry := find(model_id)
	if entry.is_empty():
		return false
	if str(entry.get("family", "")) == "starshade":
		return true
	if str(entry.get("source", "")) == "linkagelab":
		return true
	var label := str(entry.get("label", "")).to_lower()
	if label.contains("starshade") or label.contains("linkagelab"):
		return true
	var path := str(entry.get("path", "")).to_lower()
	if path.contains("starshades"):
		return true
	return false


## True for any hydro-turbine model (siphon hydroturbine, PowerSpout PLT, …).
## Several subsystems used to hardcode the literal "hydroturbine" — the CT
## midplane clip, the Lab's section yaw, the prop-edit "Open Hydro Lab" button —
## so every hydro model must answer here or it silently loses those behaviours.
static func is_hydro_turbine(model_id: String) -> bool:
	if model_id.is_empty():
		return false
	if model_id == "hydroturbine":
		return true
	return bool(find(model_id).get("hydro_turbine", false))


## The spinning-runner node name authored on a model entry ("" = let the spin
## runtime fall back to its name/size heuristic).
static func turbine_node_for(model_id: String) -> String:
	return str(find(model_id).get("turbine_node", ""))


## Explicit runner spin axis ("x" | "y" | "z"), or "" to measure it from the
## runner mesh geometry.
static func spin_axis_for(model_id: String) -> String:
	return str(find(model_id).get("spin_axis", ""))


## The modelled NOZZLE node of a hydro turbine GLB ("" = none modelled; the
## close-up then hangs a procedural nozzle off the inlet port instead).
static func nozzle_node_for(model_id: String) -> String:
	return str(find(model_id).get("nozzle_node", ""))


## The nozzle node's own local axis that points down the jet ("x"|"y"|"z";
## the sign is resolved toward the runner by whoever measures it).
static func nozzle_axis_for(model_id: String) -> String:
	return str(find(model_id).get("nozzle_axis", "z"))


## Child nodes to FREE on every instantiate (exporter leftovers: scale
## figures, camera markers). Exact names, searched recursively.
static func strip_nodes_for(model_id: String) -> Array:
	return find(model_id).get("strip_nodes", []) as Array


## Designs offered by the StarShade editor (family + path heuristic).
static func starshade_designs() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var seen: Dictionary = {}
	for m in all_models():
		var mid := str(m.get("id", ""))
		if mid.is_empty() or seen.has(mid):
			continue
		if is_starshade_model(mid):
			seen[mid] = true
			out.append(m)
	return out


## Shipped models filtered by their "category" key ("structures", "nature", …).
static func models_in_category(category: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for m in all_models():
		if str(m.get("category", "")) == category:
			out.append(m)
	return out


static func load_scene(model_id: String) -> PackedScene:
	var entry := find(model_id)
	var path := str(entry.get("path", ""))
	if path.is_empty():
		return null
	if path.begins_with("user://"):
		return _packed_scene_for_user(path)
	if not ResourceLoader.exists(path):
		return null
	var res: Resource = ResourceLoader.load(path)
	if res is PackedScene:
		return res as PackedScene
	return null


static func instantiate(model_id: String, extras: Dictionary = {}) -> Node3D:
	if model_id == PalletRackBuilder.MODEL_ID:
		var rack_spec: Dictionary = extras.get("rack_spec", extras) as Dictionary
		return PalletRackBuilder.build_node(rack_spec)
	if model_id == FlatpackBuilder.MODEL_ID:
		var fp_spec: Dictionary = extras.get("flatpack_spec", extras) as Dictionary
		return FlatpackBuilder.build_node(fp_spec)
	if model_id == LinkageStructureBuilder.MODEL_ID:
		var linkage_spec: Dictionary = extras.get("linkage_spec", extras) as Dictionary
		return LinkageStructureBuilder.build_node(linkage_spec)
	if model_id == GrowBed.MODEL_ID:
		var bed_spec: Dictionary = extras.get("grow_bed_spec", extras) as Dictionary
		return GrowBed.build_node(bed_spec)
	if model_id == GeodesicDomeBuilder.MODEL_ID:
		var dome_spec: Dictionary = extras.get("dome_spec", extras) as Dictionary
		return GeodesicDomeBuilder.build_node(dome_spec)
	if model_id == MudBuildingStructureBuilder.MODEL_ID:
		var mud_spec: Dictionary = extras.get("mud_spec", extras) as Dictionary
		return MudBuildingStructureBuilder.build_node(mud_spec)
	if model_id == ScadPartBuilder.MODEL_ID:
		var scad_spec: Dictionary = extras.get("scad_spec", extras) as Dictionary
		return ScadPartBuilder.build_node(scad_spec)
	if model_id == CargoContainerBuilder.MODEL_ID:
		var container_spec: Dictionary = extras.get("container_spec", extras) as Dictionary
		return CargoContainerBuilder.build_node(container_spec)
	if model_id == PvArrayBuilder.MODEL_ID:
		var pv_spec: Dictionary = extras.get("pv_array_spec", extras) as Dictionary
		return PvArrayBuilder.build_node(pv_spec)
	if model_id == BedBuilder.MODEL_ID:
		return BedBuilder.build_node(extras)
	if model_id == StreamIntakeBuilder.MODEL_ID:
		return StreamIntakeBuilder.build_node(extras)
	if model_id == FirepitBuilder.MODEL_ID:
		return FirepitBuilder.build_node(extras)
	if VehicleModelBuilder.handles(model_id):
		return VehicleModelBuilder.build_node(model_id)
	if model_id == GENERIC_BOX_ID:
		var box_spec: Dictionary = extras.get("box_spec", extras) as Dictionary
		return _build_generic_box(box_spec)
	if model_id == GENERIC_TANK_ID:
		var tank_spec: Dictionary = extras.get("tank_spec",
			extras.get("box_spec", extras)) as Dictionary
		return _build_generic_tank(tank_spec)
	var ps := load_scene(model_id)
	if ps == null:
		return null
	var inst := ps.instantiate() as Node3D
	# A vehicle's root sits AT the vehicle, as the scene instances have it
	# (appa.tscn's own root offset is overridden there): the rider, the seat
	# offset and the chase camera are all measured from it.
	if inst != null and find(model_id).has("vehicle"):
		inst.position = Vector3.ZERO
	# Exporter leftovers (SketchUp scale figures, camera markers) are freed
	# HERE so mesh_metrics, the foot, the pick AABB and every studio see the
	# same machine. free() not queue_free(): callers measure synchronously.
	if inst != null:
		for nm in strip_nodes_for(model_id):
			var junk := inst.find_child(str(nm), true, false)
			if junk != null and junk != inst:
				junk.get_parent().remove_child(junk)
				junk.free()
	return inst


## Build a gray box placeholder Node3D whose BASE sits at local y=0 (so it
## grounds like any other prop). Dimensions (metres) come from `box_spec`
## (w_m/d_m/h_m); missing values fall back to a 1 m cube.
static func _build_generic_box(box_spec: Dictionary) -> Node3D:
	var w := maxf(float(box_spec.get("w_m", 1.0)), 0.1)
	var d := maxf(float(box_spec.get("d_m", 1.0)), 0.1)
	var h := maxf(float(box_spec.get("h_m", 1.0)), 0.1)
	var root := Node3D.new()
	root.name = "GenericBox"
	var mi := MeshInstance3D.new()
	mi.name = "BoxMesh"
	var bm := BoxMesh.new()
	bm.size = Vector3(w, h, d)
	mi.mesh = bm
	# Base on the ground: box centre lifted half its height.
	mi.position = Vector3(0.0, h * 0.5, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.58, 0.62)
	mat.roughness = 0.85
	mat.metallic = 0.0
	mi.material_override = mat
	root.add_child(mi)
	return root


## Vertical cylinder tank; BASE at local y=0. Diameter from max(w_m, d_m).
static func _build_generic_tank(tank_spec: Dictionary) -> Node3D:
	var w := maxf(float(tank_spec.get("w_m", 1.2)), 0.2)
	var d := maxf(float(tank_spec.get("d_m", w)), 0.2)
	var h := maxf(float(tank_spec.get("h_m", 1.5)), 0.3)
	var radius := maxf(w, d) * 0.5
	var root := Node3D.new()
	root.name = "GenericTank"
	var mi := MeshInstance3D.new()
	mi.name = "TankMesh"
	var cm := CylinderMesh.new()
	cm.top_radius = radius
	cm.bottom_radius = radius
	cm.height = h
	cm.radial_segments = 20
	mi.mesh = cm
	mi.position = Vector3(0.0, h * 0.5, 0.0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.52, 0.58)
	mat.roughness = 0.55
	mat.metallic = 0.15
	mi.material_override = mat
	root.add_child(mi)
	return root


## Default procedural twin model for a site-placed graph item with no model_id.
static func default_twin_model_id(item: Dictionary) -> String:
	var specs: Dictionary = item.get("specs", {}) as Dictionary
	var mid := str(specs.get("model_id", ""))
	if not mid.is_empty():
		return mid
	var itype := str(item.get("type", ""))
	if GraphSiteLayout.is_circular_node(itype):
		return GENERIC_TANK_ID
	return GENERIC_BOX_ID


## Footprint / height dict for procedural twins (metres).
static func twin_box_spec_for_item(item: Dictionary) -> Dictionary:
	var fp := GraphSiteLayout.physical_footprint_m(item)
	var side := maxf(fp.x, fp.y)
	var h := clampf(side * 0.85, 0.8, 3.0)
	var itype := str(item.get("type", ""))
	if itype == "catchment":
		h = clampf(side * 0.25, 0.4, 1.2)
	return {"w_m": maxf(fp.x, 0.5), "d_m": maxf(fp.y, 0.5), "h_m": h}


static func register_user(entry: Dictionary) -> void:
	_ensure_user_catalog()
	var id := str(entry.get("id", ""))
	if id.is_empty():
		return
	invalidate_metrics(id)
	for i in _user_catalog.size():
		if str(_user_catalog[i].get("id", "")) == id:
			_user_catalog[i] = entry
			_save_user_catalog()
			return
	_user_catalog.append(entry)
	_save_user_catalog()


static func mesh_metrics(model_id: String) -> Dictionary:
	if _fit_cache.has(model_id):
		return _fit_cache[model_id]
	var inst := instantiate(model_id)
	if inst == null:
		return {"unit_height": 1.0, "foot_local_y": 0.0, "width": 1.0, "depth": 1.0}
	# Measure the combined AABB in the instance ROOT's local space. Each mesh's
	# transform is composed up the node chain to `inst` (NOT just mi.transform),
	# so a GLB authored under scaled/translated parent nodes is measured at its
	# true size. Using mi.transform alone summed un-hierarchied boxes and produced
	# a hugely inflated AABB, which made the heightM-fit scale come out far too
	# small. (No tree insertion needed — this is pure local-transform math.)
	var aabb := AABB()
	var found := false
	for node in inst.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var box: AABB = _xform_relative_to(inst, mi) * mi.mesh.get_aabb()
		if not found:
			aabb = box
			found = true
		else:
			aabb = aabb.merge(box)
	inst.free()
	if aabb.size.length_squared() < 0.0001:
		return {"unit_height": 1.0, "foot_local_y": 0.0, "width": 1.0, "depth": 1.0}
	var metrics := {
		"unit_height": maxf(aabb.size.y, 0.01),
		"foot_local_y": aabb.position.y,
		"width": maxf(aabb.size.x, 0.01),
		"depth": maxf(aabb.size.z, 0.01),
	}
	_fit_cache[model_id] = metrics
	return metrics


static func invalidate_metrics(model_id: String) -> void:
	_fit_cache.erase(model_id)


## Transform of `descendant`'s local space expressed in `ancestor`'s local space,
## composed from local transforms up the chain (excludes ancestor's own transform).
## Pure math — valid before the node enters the tree.
static func _xform_relative_to(ancestor: Node3D, descendant: Node3D) -> Transform3D:
	var t := descendant.transform
	var p := descendant.get_parent()
	while p != null and p != ancestor and p is Node3D:
		t = (p as Node3D).transform * t
		p = p.get_parent()
	return t


static func resolved_scale(model_id: String, user_scale: float) -> float:
	var entry := find(model_id)
	var us := maxf(user_scale, 0.05)
	if bool(entry.get("preserve_scale", false)):
		# Height-driven fit wins: scale so the measured mesh AABB height equals the
		# bundle's declared real-world height. This is unit-agnostic — it produces a
		# correct world size whether the GLB vertex coords are inches, meters, mm, or
		# anything else, so it never depends on a guessed units multiplier.
		var ref_h := float(entry.get("reference_height_m", 0.0))
		if ref_h > 0.0:
			var metrics := mesh_metrics(model_id)
			var unit_h := maxf(metrics.unit_height, 0.01)
			return minf((ref_h / unit_h) * us, MAX_WORLD_SCALE)
		# Fallback only when no reference height was supplied: apply the declared
		# file-units→meters multiplier (see GlbDecoder for how units are resolved).
		var file_um := float(entry.get("file_units_to_meters", 1.0))
		if absf(file_um - 1.0) > 0.0001:
			return minf(file_um * us, MAX_WORLD_SCALE)
		return minf(us, MAX_WORLD_SCALE)
	var metrics := mesh_metrics(model_id)
	var target := float(entry.get("target_height_m", DEFAULT_TARGET_HEIGHT_M))
	var mesh_mult := float(entry.get("mesh_scale", 1.0))
	if target <= 0.0:
		return us
	return minf((target / metrics.unit_height) * mesh_mult * us, MAX_WORLD_SCALE)


static func foot_local_y(model_id: String) -> float:
	return float(mesh_metrics(model_id).foot_local_y)


## Fixed yaw (degrees) some models declare to align their own mesh axes onto
## world cardinal directions (e.g. the CSP trough's N-S pivot). Applied to
## BOTH the placement ghost and the real placed prop so confirming never
## visibly rotates the model out from under the player.
static func forced_yaw_deg(model_id: String) -> float:
	return float(find(model_id).get("forced_yaw_deg", 0.0))


static func scale_to_footprint(model_id: String, width_m: float, depth_m: float,
		height_m: float, user_scale: float = 1.0) -> float:
	var metrics := mesh_metrics(model_id)
	var sx: float = width_m / metrics.width
	var sz: float = depth_m / metrics.depth
	var sy: float = height_m / metrics.unit_height
	var fit: float = minf(minf(sx, sz), sy)
	return fit * maxf(user_scale, 0.05)


static func _shipped_models() -> Array[Dictionary]:
	return [
		# Procedural gray-box placeholder (no `category` → not listed as a
		# structure; used only as the default 3D form for abstract graph nodes).
		{"id": GENERIC_BOX_ID, "label": "Placeholder box", "procedural": true,
			"preserve_scale": true},
		{"id": GENERIC_TANK_ID, "label": "Placeholder tank", "procedural": true,
			"preserve_scale": true},
		{"id": "shiftpod", "label": "Shiftpod", "path": "res://Imported Models/Soak Terrain/Camps/Camp Components/Shiftpod.glb",
			"target_height_m": 2.5, "mesh_scale": 1.0, "category": "structures"},
		{"id": "carport", "label": "Carport", "path": "res://Imported Models/Soak Terrain/Camps/Camp Components/Carport.glb",
			"target_height_m": 3.5, "mesh_scale": 1.0, "category": "structures"},
		{"id": "ez_up", "label": "10x10 EZ-UP", "path": "res://Imported Models/Soak Terrain/Camps/Camp Components/10 x 10 EZ-UP 2.glb",
			"target_height_m": 3.0, "mesh_scale": 1.0, "category": "structures"},
		# This LinkageLab export is metre-unit (AABB height ≈ 2.4 — unlike the
		# inch-unit GLB bundles), so preserve_scale alone keeps true size.
		{"id": "starshade", "label": "StarShade", "path": "res://Imported Models/StarShades/LinkageLab_Export_1777324209080.gltf",
			"preserve_scale": true, "category": "structures", "family": "starshade"},
		{"id": "starshade_center_camp", "label": "StarShade Center Camp",
			"path": "res://Imported Models/StarShades/Center Camp.glb",
			"preserve_scale": true, "category": "structures", "family": "starshade"},
		{"id": "starshade_man_effigy", "label": "StarShade Man Effigy",
			"path": "res://Imported Models/StarShades/Man Effigy.glb",
			"preserve_scale": true, "category": "structures", "family": "starshade"},
		# Procedural — instantiate() builds via PalletRackBuilder.
		{"id": "pallet_rack", "label": "Pallet Rack (parametric)",
			"procedural": true, "preserve_scale": true, "category": "structures",
			"target_height_m": 2.0},
		# Procedural slotted-plywood furniture (FlatpackBuilder): the flat-pack
		# designer's sofa / bench / stool / table / chair, cut on a CNC router.
		{"id": "flatpack_furniture", "label": "Flat-pack furniture (parametric)",
			"procedural": true, "preserve_scale": true, "category": "structures",
			"target_height_m": 0.9},
		# Procedural ground-mount PV array (PvArrayBuilder): cols × rows modules
		# on a tilted rack facing local +Z (south at yaw 0). Bound to a graph
		# array node; its facing drives that array's tilt / azimuth.
		{"id": "pv_array", "label": "Solar Array (ground mount)",
			"procedural": true, "preserve_scale": true, "category": "structures",
			"target_height_m": 1.6},
		# Procedural ISO shipping container (PACKING_PLAN.md Phase 1) — dims
		# from ContainerCatalog via `container_spec.container_id` (default 20').
		{"id": "cargo_container", "label": "Shipping Container",
			"procedural": true, "preserve_scale": true, "category": "structures",
			"target_height_m": 2.6},
		# Procedural single bed. Placing one AUTO-TAGS it as a capacity-1 sleep
		# space (PlacedPropService), and a sleeper aligns to its long axis —
		# see BedBuilder's orientation contract (long axis = local Z, head -Z).
		{"id": "bed", "label": "Bed",
			"procedural": true, "preserve_scale": true, "category": "structures",
			"target_height_m": 0.75},
		# Procedural FIREPIT: a black steel ring with a small fire that burns
		# at night when it is cold (FirepitFire). Placing one auto-tags it as
		# a fire circle, and while lit it is a warm spot for the crowd.
		{"id": "firepit", "label": "Firepit",
			"procedural": true, "preserve_scale": true, "category": "structures",
			"target_height_m": 0.36},
		# Driveable vehicles (category "vehicles" — the library's Vehicles
		# tab). `vehicle` names a PlacedVehicle.PROFILES entry; Interact gets
		# in. The first three are the scene vehicles' own art at its native
		# scale; the buses and the van go through VehicleModelBuilder
		# (`source_path` + `isolate` + real `length_m`), which isolates one bus
		# out of Busses.tscn's pair and normalises the units. `flip`: the
		# 3800's nose is at its +Z (vehicle_look_diag.gd).
		{"id": "vehicle_euc", "label": "EUC (electric unicycle)",
			"path": "res://Imported Models/euc/EUC.glb", "preserve_scale": true,
			"category": "vehicles", "vehicle": "euc"},
		{"id": "vehicle_appa", "label": "Appa (golf cart)",
			"path": "res://Imported Models/appa.tscn", "preserve_scale": true,
			"category": "vehicles", "vehicle": "golf_cart", "vehicle_name": "Appa"},
		{"id": "vehicle_skid_steer", "label": "Skid steer",
			"path": "res://Imported Models/Skid Steer.glb", "preserve_scale": true,
			"category": "vehicles", "vehicle": "skid_steer"},
		{"id": "vehicle_tool_bus", "label": "Tool Bus (International 3800 school bus)",
			"procedural": true, "preserve_scale": true, "category": "vehicles",
			"vehicle": "bus", "vehicle_name": "Tool Bus",
			"source_path": "res://Imported Models/Busses.tscn",
			"isolate": "Node/Assembly-953/International 3800 School Bus", "length_m": 11.6,
			"flip": true},
		{"id": "vehicle_camper_van", "label": "Camper van (GMC)",
			"procedural": true, "preserve_scale": true, "category": "vehicles",
			"vehicle": "van", "vehicle_name": "Camper Van",
			"source_path": "res://Imported Models/GMC camper van.glb", "length_m": 5.6},
		# Procedural stream / spring intake — minted where a player drops the
		# uphill end of a penstock (conduits have no free endpoints, so the
		# water source has to be a real prop + graph node).
		{"id": "stream_intake", "label": "Stream Intake",
			"procedural": true, "preserve_scale": true, "category": "structures",
			"target_height_m": 0.42},
		# Procedural scissor-linkage structure — designed in the Linkage Lab
		# modal, built via LinkageStructureBuilder from a v30 linkage_spec.
		{"id": "linkage_structure", "label": "Linkage Structure (Linkage Lab)",
			"procedural": true, "preserve_scale": true, "category": "structures",
			"target_height_m": 2.5},
		# Procedural grow bed — library "Grow Beds" → Place in world.
		{"id": "grow_bed", "label": "Grow Bed",
			"procedural": true, "preserve_scale": true, "category": "nature",
			"target_height_m": 0.5},
		{"id": "pine_1", "label": "Pine Tree", "path": "res://Imported Models/Trees/free_tree_1.glb",
			"target_height_m": 13.0, "mesh_scale": 1.0, "category": "nature"},
		# Vertical Axis Wind Turbine — authored in SketchUp, exported to GLB already
		# in metres (~11.5 m tall: 6.4 m mast + 5 m rotor). preserve_scale keeps that
		# real size. The rotor sub-node ("Component#2") spins about the vertical axis;
		# WindTurbineSpin (attached at placement) reads turbine_node to find it.
		{"id": "vawt", "label": "Vertical Axis Wind Turbine",
			"path": "res://Imported Models/Wind/VAWT.glb",
			"preserve_scale": true, "category": "structures",
			"turbine_node": "Component#2"},
		# Single-axis parabolic-trough CSP. Authored in inches (Node2 child
		# carries the 0.0254 inch→m scale baked into the GLB itself, like the
		# StarShade exports), so preserve_scale keeps true size. Component#452
		# is the fixed pedestal/base; Component#453 is the moving concentrator
		# (mirror + focal tube). The GLB's natural orientation already runs the
		# module-length / pivot axis (model local +X) along world EAST-WEST
		# (verified empirically — see csp_trough_tracker.gd class doc), which is
		# exactly what a single-axis E-W trough wants (long axis E-W, aperture
		# tilting to face the equator). So forced_yaw_deg = 0 (no yaw); the
		# concentrator only ever rotates about that E-W pivot to track the sun's
		# altitude. Kept explicit so the ghost + placed prop share one constant.
		{"id": "csp_trough", "label": "Parabolic Trough CSP",
			"path": "res://Imported Models/CSP/single_axis_csp.glb",
			"preserve_scale": true, "category": "structures",
			"csp_base_node": "Component#452", "csp_concentrator_node": "Component#453",
			"forced_yaw_deg": 0.0},
		# Small horizontal-axis wind turbine (HAWT) — modeled after a
		# Primus-style "Air 30" 500 W-class turbine (see component_presets.gd's
		# "Small HAWT 500W (3D)" preset for the manufacturer specs this drives).
		# Authored in SketchUp-style inches baked into the "WIND POWER
		# GENERATOR..." ancestor node's 0.0254 scale (same convention as
		# VAWT.glb / single_axis_csp.glb), so preserve_scale + that internal
		# scale keeps the ~9 m mast true size. "turbine vane assembly" is the
		# yaw sub-node (nacelle + nosecone + blades; rotates horizontally to
		# face the wind); its child "Nosecone and Blades" is the sub-node that
		# spins about the horizontal rotor axis. HawtTracker (attached at
		# placement) drives both from the live wind model —
		# see gameplay/hawt_tracker.gd.
		{"id": "small_hawt", "label": "Small HAWT (Air 30 class)",
			"path": "res://Imported Models/Wind/small_hawt.glb",
			"preserve_scale": true, "category": "structures",
			"hawt_yaw_node": "turbine vane assembly",
			"hawt_blade_node": "Nosecone and Blades"},
		# Siphon micro-hydro (6″ PVC intake + 8″ culvert out, hoverboard motor
		# ≤250 W DC). Place via library Siphon Hydroturbine preset.
		# Siphon Lab + SiphonTurbineSpin: spins smallest/prop-named mesh from
		# graph electrical W (see gameplay/siphon_turbine_spin.gd).
		# Spin axis = model local +Z (SiphonTurbineSpin). CT camera looks along
		# −cross; yaw = −section_heading faces the disk into the cut. Bias 0 —
		# Lab/Elev call _ensure_hydroturbine_section_yaw on open.
		# Measured with glb_dump_diag: the 8″ propeller is "Node15"
		# (Geom3D_10, a 0.207 m disc 0.085 m thick, normal = model +Z, in the
		# horizontal leg under the vertical riser + hoverboard motor). The
		# old "" let the size heuristic pick the SMALLEST mesh — a motor
		# bolt — so the world prop spun a bolt and the close-up found no
		# runner at all.
		{"id": "hydroturbine", "label": "Siphon Hydroturbine",
			"path": "res://Imported Models/Hydro/hydroturbine.glb",
			"preserve_scale": true, "category": "structures",
			"forced_yaw_deg": 0.0,
			"turbine_node": "Node15",
			"spin_axis": "z",
			"hydro_turbine": true},
		# PowerSpout PLT-class pico Pelton (turbine_kind "powerspout_pelton").
		# SimLab/SketchUp export: the inch→metre 0.0254 is baked on the
		# "Assembly-4" ancestor, so the GLB imports at TRUE metres (~0.35 W ×
		# 0.38 H × 0.59 D) — preserve_scale with NO reference height (the
		# mud_printer idiom). The runner is the node literally named
		# "Pelton Wheel, 24 Spoon"; its disc normal composes to model local
		# ±X, NOT the +Z that SiphonTurbineSpin assumes by default — hence the
		# explicit spin_axis (the spin runtime also measures it geometrically
		# when the key is absent). Measured runner radius ≈ 0.139 m → PCD
		# ≈ 0.28 m, which is what HydroSource.KINDS.runner_pcd_m carries.
		{"id": "powerspout_plt", "label": "PowerSpout PLT (Pelton)",
			"path": "res://Imported Models/Hydro/powerspout_plt.glb",
			"preserve_scale": true, "category": "structures",
			"forced_yaw_deg": 0.0,
			"turbine_node": "Pelton Wheel, 24 Spoon",
			"spin_axis": "x",
			"hydro_turbine": true},
		# AliExpress-class micro Pelton (turbine_kind "micro_pelton"): an 8"
		# bucket runner on a VERTICAL shaft under a 10" mounting plate, a
		# Nema 34 stepper hung below as the generator, and a 1/4" NPT hose-barb
		# fitting through the housing wall as the nozzle. SketchUp/SimLab export,
		# inch->metre 0.0254 baked on "Assembly-11", so it imports at true
		# metres (0.25 x 0.16 x 0.25). The runner is the generic "Node6"; its
		# disc normal composes to model-local +Y (the shaft is vertical), hence
		# spin_axis "y" (SiphonTurbineSpin would otherwise assume +Z). The
		# nozzle is the McMaster fitting node: its local +Z runs INTO the wheel
		# (model-local -X), measured by the close-up (ModelCatalog.nozzle_*).
		# Measured runner radius 0.101 m; the fitting's centreline sits 0.084 m
		# off the shaft -> PCD 0.168 m (HydroSource.KINDS.micro_pelton).
		# strip_nodes: the export carries two flat SketchUp SCALE FIGURES
		# ("Sree", and "Susan#1" under a node confusingly named "Pelton") plus
		# an empty "Active View" camera marker, all metres away from the
		# machine — they would pollute the foot / AABB and draw as cardboard
		# people. ModelCatalog.instantiate frees them on every instantiate.
		{"id": "ali_pelton", "label": "Micro Pelton 8\u2033 (vertical shaft)",
			"path": "res://Imported Models/Hydro/ali_pelton.glb",
			"preserve_scale": true, "category": "structures",
			"forced_yaw_deg": 0.0,
			"turbine_node": "Node6",
			"spin_axis": "y",
			"nozzle_node": "fitting, 0_25MNPT to 0_25 hose barb, McMaster-Carr 5346K14",
			"nozzle_axis": "z",
			"strip_nodes": ["Sree", "Pelton", "Active View"],
			"hydro_turbine": true},
		# Dual-axis point-focus solar concentrator ("dish" heliostat / solar
		# furnace). Authored in inches baked into the "Component#1" ancestor's
		# 0.025 scale (same convention as VAWT.glb / single_axis_csp.glb), so
		# preserve_scale keeps the ~8 m mast + ~5 m (≈19.4 m²) dish true size —
		# no reference height needed, and the natural size already matches the
		# 19.36 m² mirror-area spec (see the "Heliostat" preset in
		# component_presets.gd). Alt-azimuth mount: "horizontal rotating
		# assembly" yaws about the vertical bearing (azimuth) and its child
		# "Vertical Rotating Assembly" tilts about the horizontal bearing
		# (altitude); "Mirror array" is the concentrating facets and "solar
		# collector area" is the focal-point box. HeliostatTracker (attached at
		# placement) points the dish straight at the sun in both axes and lights
		# the focus — see gameplay/heliostat_tracker.gd. forced_yaw_deg = 0
		# keeps the model's local frame world-aligned (shared by the ghost +
		# placed prop so confirming never visibly rotates it).
		{"id": "heliostat", "label": "Dual-Axis Heliostat (dish)",
			"path": "res://Imported Models/CSP/heliostat.glb",
			"preserve_scale": true, "category": "structures", "forced_yaw_deg": 0.0,
			"helio_base_node": "fixed base",
			"helio_azimuth_node": "horizontal rotating assembly",
			"helio_altitude_node": "Vertical Rotating Assembly",
			"helio_mirror_node": "Mirror array",
			"helio_focal_node": "solar collector area"},
		# HomeBiogas 2.0 household biodigester (210×115×130 cm → 1.3 m tall).
		# Unit-agnostic height fit (same technique as CNC tool GLBs) so an
		# inch- or metre-authored export seats at the datasheet height.
		{"id": "home_biogas_2", "label": "HomeBiogas 2.0",
			"path": "res://Imported Models/Biogas/home_biogas_2.glb",
			"preserve_scale": true, "reference_height_m": 1.3,
			"category": "structures", "forced_yaw_deg": 0.0},
		# ---- Tools: Cartesian CNC machines (X/Y/Z kinematics) ----
		# CAD-export GLBs in arbitrary internal units → preserve_scale + a
		# reference height fits them to real-world size unit-agnostically (same
		# technique as the StarShade/CSP bundles). The moving axis sub-nodes are
		# tagged generically via CartesianMachineProfile (baked defaults in
		# core/machines/cartesian_machine_profile.gd), NOT hardcoded here, so any
		# imported machine can be axis-tagged by the player. CncMachineRuntime
		# (attached at placement for kind == "cartesian_machine") animates them.
		{"id": "cnc_router", "label": "CNC Router (4x5 Gantry)",
			"path": "res://Imported Models/Tools/cnc_router.glb",
			"preserve_scale": true, "reference_height_m": 1.3,
			"category": "tools", "forced_yaw_deg": 0.0},
		{"id": "trash_printer", "label": "Trash Printer (flake FDM)",
			"path": "res://Imported Models/Tools/trash_printer.glb",
			"preserve_scale": true, "reference_height_m": 2.0,
			"category": "tools", "forced_yaw_deg": 0.0},
		# Large-format gantry mud/clay/concrete printer. The GLB is authored at
		# true real-world size (composed AABB ≈ 3.74 m ≈ 12' wide, ~5.5 m tall),
		# so preserve_scale WITHOUT a reference height keeps its natural metres.
		# Axis nodes (Z assembly / X Y Assembly / X assembly / Fog Nozzle) are
		# tagged in cartesian_machine_profile.gd BUILTIN.
		{"id": "mud_printer", "label": "Mud Printer (gantry FDM)",
			"path": "res://Imported Models/Tools/mud_printer.glb",
			"preserve_scale": true,
			"category": "tools", "forced_yaw_deg": 0.0},
		# Precious Plastic workshop machines (SketchUp/CAD exports → height fit).
		{"id": "pp_shredder", "label": "PP Shredder",
			"path": "res://Imported Models/Tools/pp_shredder.glb",
			"preserve_scale": true, "reference_height_m": 1.6,
			"category": "tools", "forced_yaw_deg": 0.0},
		{"id": "pp_beam_extruder", "label": "PP Beam Extruder",
			"path": "res://Imported Models/Tools/pp_beam_extruder.glb",
			"preserve_scale": true, "reference_height_m": 1.8,
			"category": "tools", "forced_yaw_deg": 0.0,
			"beam_mesh_name": "Recycled Plastic Beam",
			"mold_mesh_name": "beam#1"},
		{"id": "pp_sheet_press", "label": "PP Sheet Press",
			"path": "res://Imported Models/Tools/pp_sheet_press.glb",
			"preserve_scale": true, "reference_height_m": 2.0,
			"category": "tools", "forced_yaw_deg": 0.0,
			"z_axis_node": "Z axis",
			"sheet_mesh_name": "Recycled Plastic Sheet"},
		# Procedural crafting output — placed when a RecipeCatalog dome is
		# assembled from fabricated parts (see core/machines/recipe_catalog.gd).
		{"id": "geodesic_dome", "label": "Geodesic Dome (2V recycled plastic)",
			"procedural": true, "preserve_scale": true, "category": "structures",
			"target_height_m": 2.4},
		{"id": "mud_building", "label": "Mud Building (designer)",
			"procedural": true, "preserve_scale": true, "category": "structures",
			"target_height_m": 2.4},
	]


static func _ensure_user_catalog() -> void:
	if _catalog_loaded:
		return
	_catalog_loaded = true
	_user_catalog = []
	if not FileAccess.file_exists(CATALOG_PATH):
		return
	var f := FileAccess.open(CATALOG_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Array):
		return
	for item in parsed as Array:
		if item is Dictionary:
			_user_catalog.append(item as Dictionary)


static func _save_user_catalog() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(USER_DIR))
	var f := FileAccess.open(CATALOG_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(_user_catalog))


## Converted user models, saved so a launch loads them instead of re-importing
## the raw glTF: an import is slow for a big SketchUp model (142 materials on
## one of the author's), and Godot's importer prints a "specular and
## glossiness workflow" warning for every SimLab material on EVERY launch —
## 259 lines a session — although ImportMaterialFixer rewrites those very
## materials. Keyed on the file's size + modified time + the fix mode, so an
## edited model or a changed Materials setting converts again.
const USER_SCENE_CACHE_DIR := "user://model_cache"
const USER_SCENE_CACHE_VERSION := 1


static func _user_scene_cache_path(path: String) -> String:
	var mode := str(_user_entry_for_path(path).get("material_fix", ImportMaterialFixer.MODE_AUTO))
	var f := FileAccess.open(path, FileAccess.READ)
	var size := f.get_length() if f != null else 0
	var key := hash([USER_SCENE_CACHE_VERSION, path, size, FileAccess.get_modified_time(path), mode])
	return "%s/%s_%08x.scn" % [USER_SCENE_CACHE_DIR, path.get_file().get_basename(), key & 0xFFFFFFFF]


static func _packed_scene_for_user(path: String) -> PackedScene:
	if _user_packed.has(path):
		return _user_packed[path] as PackedScene
	var abs_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(path):
		return null
	var cache_path := _user_scene_cache_path(path)
	if FileAccess.file_exists(cache_path):
		var cached := ResourceLoader.load(cache_path, "PackedScene") as PackedScene
		if cached != null:
			_user_packed[path] = cached
			return cached
	var gltf := GLTFDocument.new()
	var state := GLTFState.new()
	if gltf.append_from_file(abs_path, state) != OK:
		if ResourceLoader.exists(path):
			var res: Resource = ResourceLoader.load(path)
			if res is PackedScene:
				_user_packed[path] = res
				return res as PackedScene
		return null
	var root := gltf.generate_scene(state)
	if root == null:
		return null
	_replace_importer_meshes(root, root)
	# SketchUp exports carry invented gloss values (ImportMaterialFixer); the
	# catalog entry's `material_fix` (auto / off / force) decides.
	var mode := str(_user_entry_for_path(path).get("material_fix", ImportMaterialFixer.MODE_AUTO))
	if ImportMaterialFixer.should_fix(state.json, mode):
		var rep := ImportMaterialFixer.fix_scene(root)
		print("ModelCatalog: %s — SketchUp material fix on %d materials %s" % [
			path.get_file(), int(rep.get("fixed", 0)), JSON.stringify(rep.get("profiles", {}))])
	var ps := PackedScene.new()
	var err := ps.pack(root)
	root.queue_free()
	if err != OK:
		return null
	_user_packed[path] = ps
	_save_user_scene_cache(path, cache_path, ps)
	return ps


## Write the converted scene and drop this model's older conversions.
static func _save_user_scene_cache(path: String, cache_path: String, ps: PackedScene) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(USER_SCENE_CACHE_DIR))
	var stem := path.get_file().get_basename() + "_"
	var dir := DirAccess.open(USER_SCENE_CACHE_DIR)
	if dir != null:
		for fn in dir.get_files():
			if fn.begins_with(stem) and fn != cache_path.get_file():
				dir.remove(fn)
	if ResourceSaver.save(ps, cache_path, ResourceSaver.FLAG_COMPRESS) != OK:
		push_warning("ModelCatalog: could not cache %s" % path.get_file())


static func _user_entry_for_path(path: String) -> Dictionary:
	_ensure_user_catalog()
	for e: Dictionary in _user_catalog:
		if str(e.get("path", "")) == path:
			return e
	return {}


## Set a user model's material-fix mode (auto / off / force), persist it and
## drop the cached scene so the next instance rebuilds with it. Placed props
## already in the world keep their old materials until rebuilt.
static func set_material_fix(model_id: String, mode: String) -> void:
	_ensure_user_catalog()
	for i in _user_catalog.size():
		if str(_user_catalog[i].get("id", "")) == model_id:
			_user_catalog[i]["material_fix"] = mode
			_user_packed.erase(str(_user_catalog[i].get("path", "")))
			invalidate_metrics(model_id)
			_save_user_catalog()
			return


## The source app recorded for a user model at import ("sketchup" or "").
static func source_app_for(model_id: String) -> String:
	var e := find(model_id)
	if e.has("source_app"):
		return str(e["source_app"])
	var path := str(e.get("path", ""))
	if path.is_empty() or not path.begins_with("user://"):
		return ""
	return ImportMaterialFixer.source_app(ImportMaterialFixer.read_gltf_json(path))


static func _replace_importer_meshes(node: Node, root: Node) -> void:
	for i in range(node.get_child_count() - 1, -1, -1):
		var child = node.get_child(i)
		if child.get_class() == "ImporterMeshInstance3D":
			var mi := MeshInstance3D.new()
			mi.name = child.name
			mi.transform = child.transform
			if child.get("mesh") != null:
				mi.mesh = child.get("mesh").get_mesh()
			node.add_child(mi)
			mi.owner = root
			node.remove_child(child)
			child.queue_free()
			child = mi
		_replace_importer_meshes(child, root)
