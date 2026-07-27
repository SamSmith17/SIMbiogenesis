class_name EsimPackage
extends RefCounted

## Portable site-design package (.esim) — graph + SoI + placed props + style
## sidecars. Async share foundation for private-beta collaboration (Phases 0–1).
## Terrain DEM/imagery caches and binary sculpt tiles are intentionally excluded.

const EXPORT_TYPE := "simbiogenesis.esim"
const SCHEMA_VERSION := "1.0"
const PASTE_PREFIX := "ESIM1:"
const LIBRARY_DIR := "user://saves/esim"
## Clipboard share codes stay graph+SoI+location (Discord-friendly).
const MAX_PASTE_RAW_BYTES := 96_000
const ESIM_GHOST_PREFIX := "esim_ghost_"
const ESIM_GHOST_SCOPE_PREFIX := "esim_ghost_scope_"


static func validate(raw: Dictionary) -> Dictionary:
	if raw.is_empty():
		return {"ok": false, "error": "Empty package"}
	var export_type := str(raw.get("exportType", ""))
	if export_type != EXPORT_TYPE:
		return {"ok": false, "error": "Not an .esim package (exportType=%s)" % export_type}
	var schema := str(raw.get("schema_version", ""))
	if schema.is_empty():
		return {"ok": false, "error": "Missing schema_version"}
	# Forward-compatible: accept unknown newer minor schemas with a warning.
	if schema != SCHEMA_VERSION:
		push_warning("EsimPackage: schema_version %s differs from supported %s" % [
			schema, SCHEMA_VERSION])
	var loc: Variant = raw.get("location", {})
	if not (loc is Dictionary):
		return {"ok": false, "error": "Missing location object"}
	var graph_state: Variant = raw.get("system_graph", {})
	if not (graph_state is Dictionary):
		return {"ok": false, "error": "Missing system_graph object"}
	var graph: Variant = (graph_state as Dictionary).get("graph", {})
	if not (graph is Dictionary):
		return {"ok": false, "error": "system_graph.graph missing"}
	if not ((graph as Dictionary).get("items") is Array):
		return {"ok": false, "error": "system_graph.graph.items missing"}
	return {
		"ok": true,
		"package": raw,
		"name": str(raw.get("name", "Site design")),
		"location": (loc as Dictionary).duplicate(true),
		"system_graph": (graph_state as Dictionary).duplicate(true),
		"summary": summary_of(raw),
	}


static func load_from_path(path: String) -> Dictionary:
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"ok": false, "error": "File not found: %s" % path}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {"ok": false, "error": "Could not open: %s" % path}
	return load_from_text(f.get_as_text())


static func load_from_text(text: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		return {"ok": false, "error": "Invalid JSON"}
	return validate(parsed as Dictionary)


static func save_to_path(package: Dictionary, path: String) -> Dictionary:
	var v := validate(package)
	if not bool(v.get("ok", false)):
		return v
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "error": "Could not write: %s" % path}
	f.store_string(JSON.stringify(package, "\t"))
	f.close()
	return {"ok": true, "path": path}


## Build a package dict from already-collected layer blobs (offline / selftest).
static func build(
		location: Dictionary,
		system_graph: Dictionary,
		layers: Dictionary = {},
		meta: Dictionary = {}) -> Dictionary:
	var graph_state := strip_esim_ghosts_from_graph_state(system_graph.duplicate(true))
	var pkg := {
		"exportType": EXPORT_TYPE,
		"schema_version": SCHEMA_VERSION,
		"name": str(meta.get("name", _default_name(location))),
		"exported_at": str(meta.get("exported_at", Time.get_datetime_string_from_system())),
		"location": location.duplicate(true),
		"system_graph": graph_state,
		"soi": (layers.get("soi", {}) as Dictionary).duplicate(true),
		"placed_props": (layers.get("placed_props", {"version": 1, "props": []}) as Dictionary).duplicate(true),
		"building_styles": (layers.get("building_styles", {"version": 1, "styles": {}}) as Dictionary).duplicate(true),
		"vegetation": (layers.get("vegetation", {}) as Dictionary).duplicate(true),
		"vegetation_style": (layers.get("vegetation_style", {}) as Dictionary).duplicate(true),
		"auto_veg_edits": (layers.get("auto_veg_edits", {}) as Dictionary).duplicate(true),
		"user_water": (layers.get("user_water", {"version": 1, "ponds": []}) as Dictionary).duplicate(true),
	}
	pkg["summary"] = summary_of(pkg)
	return pkg


## Collect a full .esim from the live Main scene tree.
static func collect_from_main(main: Node) -> Dictionary:
	if main == null:
		return {"ok": false, "error": "Main node missing"}
	var sgv := _find_system_graph_view(main)
	if sgv == null or not sgv.has_method("collect_save_state"):
		return {"ok": false, "error": "SystemGraphView missing"}
	var loader := _find_terrain_loader(main)
	var location := {
		"latitude": float(main.get("latitude")),
		"longitude": float(main.get("longitude")),
		"label": _read_location_label(main),
		"half_extent_m": 0.0,
		"detail_half_extent_m": 0.0,
		"osm_half_extent_m": 0.0,
	}
	if loader != null and loader.has_method("get_terrain_extents"):
		var ext: Dictionary = loader.call("get_terrain_extents")
		location["half_extent_m"] = float(ext.get("half_extent_m", 0.0))
		location["detail_half_extent_m"] = float(ext.get("detail_half_extent_m", 0.0))
		location["osm_half_extent_m"] = float(ext.get("osm_half_extent_m", 0.0))
	var layers: Dictionary = {}
	if loader != null and loader.has_method("collect_esim_site_layers"):
		layers = loader.call("collect_esim_site_layers")
	else:
		var soi := _soi_service()
		if soi != null and soi.has_method("collect_save_state"):
			layers["soi"] = soi.call("collect_save_state")
	var graph_state: Dictionary = sgv.call("collect_save_state")
	var pkg := build(location, graph_state, layers, {
		"name": _default_name(location),
	})
	return {"ok": true, "package": pkg, "summary": pkg.get("summary", {})}


static func summary_of(package: Dictionary) -> Dictionary:
	var graph_state: Dictionary = package.get("system_graph", {}) as Dictionary
	var graph: Dictionary = graph_state.get("graph", {}) as Dictionary
	var items: Array = graph.get("items", []) as Array
	var conns: Array = graph.get("connections", []) as Array
	var props_blob: Dictionary = package.get("placed_props", {}) as Dictionary
	var props: Array = props_blob.get("props", []) as Array
	var styles_blob: Dictionary = package.get("building_styles", {}) as Dictionary
	var styles: Dictionary = styles_blob.get("styles", {}) as Dictionary
	var water: Dictionary = package.get("user_water", {}) as Dictionary
	var ponds: Array = water.get("ponds", []) as Array
	var real_items := 0
	for it in items:
		if it is Dictionary and not bool((it as Dictionary).get("esim_ghost", false)) \
				and not bool((it as Dictionary).get("is_ghost", false)):
			real_items += 1
	var loc: Dictionary = package.get("location", {}) as Dictionary
	return {
		"name": str(package.get("name", "")),
		"item_count": real_items,
		"connection_count": conns.size(),
		"prop_count": props.size(),
		"building_style_count": styles.size(),
		"pond_count": ponds.size(),
		"latitude": float(loc.get("latitude", 0.0)),
		"longitude": float(loc.get("longitude", 0.0)),
		"label": str(loc.get("label", "")),
	}


## Lite clipboard payload: location + SoI + system_graph only.
static func encode_share_code(package: Dictionary) -> Dictionary:
	var v := validate(package)
	if not bool(v.get("ok", false)):
		return v
	var lite := {
		"exportType": EXPORT_TYPE,
		"schema_version": SCHEMA_VERSION,
		"name": str(package.get("name", "Site design")),
		"exported_at": str(package.get("exported_at", "")),
		"location": package.get("location", {}),
		"system_graph": strip_esim_ghosts_from_graph_state(
			(package.get("system_graph", {}) as Dictionary).duplicate(true)),
		"soi": package.get("soi", {}),
	}
	lite["summary"] = summary_of(lite)
	var raw := JSON.stringify(lite).to_utf8_buffer()
	if raw.size() > MAX_PASTE_RAW_BYTES:
		return {
			"ok": false,
			"error": "Share code too large (%d bytes). Export a .esim file instead." % raw.size(),
		}
	var compressed := raw.compress(FileAccess.COMPRESSION_GZIP)
	var code := PASTE_PREFIX + Marshalls.raw_to_base64(compressed)
	return {"ok": true, "code": code, "raw_bytes": raw.size(), "code_chars": code.length()}


static func decode_share_code(code: String) -> Dictionary:
	var trimmed := code.strip_edges()
	if trimmed.is_empty():
		return {"ok": false, "error": "Empty share code"}
	if not trimmed.begins_with(PASTE_PREFIX):
		return {"ok": false, "error": "Share code must start with %s" % PASTE_PREFIX}
	var b64 := trimmed.substr(PASTE_PREFIX.length())
	var compressed := Marshalls.base64_to_raw(b64)
	if compressed.is_empty():
		return {"ok": false, "error": "Invalid share-code encoding"}
	var raw := compressed.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	if raw.is_empty():
		return {"ok": false, "error": "Could not decompress share code"}
	return load_from_text(raw.get_string_from_utf8())


static func strip_esim_ghosts_from_graph_state(state: Dictionary) -> Dictionary:
	if state.is_empty():
		return state
	var graph: Variant = state.get("graph", {})
	if not (graph is Dictionary):
		return state
	var g: Dictionary = (graph as Dictionary).duplicate(true)
	var items_in: Array = g.get("items", []) as Array
	var conns_in: Array = g.get("connections", []) as Array
	var scopes_in: Dictionary = g.get("scopes", {}) as Dictionary
	var keep_ids: Dictionary = {}
	var items_out: Array = []
	for it in items_in:
		if not (it is Dictionary):
			continue
		var d: Dictionary = it as Dictionary
		if bool(d.get("esim_ghost", false)):
			continue
		var iid := str(d.get("id", ""))
		if iid.begins_with(ESIM_GHOST_PREFIX):
			continue
		items_out.append(d)
		if not iid.is_empty():
			keep_ids[iid] = true
	var conns_out: Array = []
	for c in conns_in:
		if not (c is Dictionary):
			continue
		var cd: Dictionary = c as Dictionary
		if bool(cd.get("esim_ghost", false)):
			continue
		var sid := str(cd.get("source_item_id", ""))
		var tid := str(cd.get("target_item_id", ""))
		if sid.begins_with(ESIM_GHOST_PREFIX) or tid.begins_with(ESIM_GHOST_PREFIX):
			continue
		if keep_ids.has(sid) and keep_ids.has(tid):
			conns_out.append(cd)
	var scopes_out: Dictionary = {}
	for sk in scopes_in.keys():
		var key := str(sk)
		if key.begins_with(ESIM_GHOST_SCOPE_PREFIX):
			continue
		scopes_out[key] = scopes_in[sk]
	g["items"] = items_out
	g["connections"] = conns_out
	g["scopes"] = scopes_out
	var out := state.duplicate(true)
	out["graph"] = g
	return out


## Remap a foreign system_graph into ghost overlay items/connections/scopes
## suitable for injecting into the live GraphModel (Phase 1 2D compare).
static func make_ghost_overlay(system_graph: Dictionary) -> Dictionary:
	var cleaned := strip_esim_ghosts_from_graph_state(system_graph.duplicate(true))
	var graph: Dictionary = cleaned.get("graph", {}) as Dictionary
	var items_in: Array = graph.get("items", []) as Array
	var conns_in: Array = graph.get("connections", []) as Array
	var scopes_in: Dictionary = graph.get("scopes", {}) as Dictionary
	var defs_in: Dictionary = graph.get("definitions", {}) as Dictionary

	var item_map: Dictionary = {}
	var scope_map: Dictionary = {"root": "root"}
	for sk in scopes_in.keys():
		var key := str(sk)
		if key == "root" or key.is_empty():
			continue
		scope_map[key] = ESIM_GHOST_SCOPE_PREFIX + key

	var items_out: Array = []
	for it in items_in:
		if not (it is Dictionary):
			continue
		var src: Dictionary = (it as Dictionary).duplicate(true)
		if bool(src.get("is_virtual", false)):
			continue
		if bool(src.get("is_ghost", false)) or bool(src.get("esim_ghost", false)):
			continue
		var old_id := str(src.get("id", ""))
		if old_id.is_empty():
			continue
		var new_id := ESIM_GHOST_PREFIX + old_id
		item_map[old_id] = new_id
		src["id"] = new_id
		src["is_ghost"] = true
		src["esim_ghost"] = true
		var old_scope := str(src.get("scope_id", "root"))
		src["scope_id"] = str(scope_map.get(old_scope, "root"))
		var child_scope := str(src.get("child_scope_id", ""))
		if not child_scope.is_empty():
			src["child_scope_id"] = str(scope_map.get(child_scope, child_scope))
		var specs: Dictionary = src.get("specs", {}) as Dictionary
		specs = specs.duplicate(true)
		specs["is_ghost"] = true
		specs["esim_ghost"] = true
		# Drop live HA / 3D bindings so ghosts never drive the sim.
		for k in ["ha_entity", "device_path", "bound_prop_id", "array_tag",
				"osm_water_tag", "starshade_tag"]:
			specs.erase(k)
		var label := str(specs.get("name", src.get("type", "node")))
		if not label.begins_with("👻 "):
			specs["name"] = "👻 " + label
		src["specs"] = specs
		# Drop stale handle links — add_connection re-links with remapped ids.
		var handles: Array = src.get("handles", []) as Array
		if not handles.is_empty():
			var cleaned_handles: Array = []
			for h in handles:
				if h is Dictionary:
					var hd: Dictionary = (h as Dictionary).duplicate(true)
					hd["connected_to"] = []
					cleaned_handles.append(hd)
			src["handles"] = cleaned_handles
		items_out.append(src)

	var scopes_out: Dictionary = {}
	for sk in scopes_in.keys():
		var key := str(sk)
		if key == "root" or key.is_empty():
			continue
		var sd: Dictionary = (scopes_in[sk] as Dictionary).duplicate(true) \
				if scopes_in[sk] is Dictionary else {}
		var new_sid := str(scope_map.get(key, ESIM_GHOST_SCOPE_PREFIX + key))
		sd["id"] = new_sid
		var parent := str(sd.get("parent_scope_id", "root"))
		sd["parent_scope_id"] = str(scope_map.get(parent, "root"))
		var owner := str(sd.get("owner_compound_id", ""))
		if not owner.is_empty() and item_map.has(owner):
			sd["owner_compound_id"] = item_map[owner]
		scopes_out[new_sid] = sd

	var conns_out: Array = []
	for c in conns_in:
		if not (c is Dictionary):
			continue
		var cd: Dictionary = (c as Dictionary).duplicate(true)
		var sid := str(cd.get("source_item_id", ""))
		var tid := str(cd.get("target_item_id", ""))
		if not item_map.has(sid) or not item_map.has(tid):
			continue
		cd["id"] = ESIM_GHOST_PREFIX + str(cd.get("id", "%s_%s" % [sid, tid]))
		cd["source_item_id"] = item_map[sid]
		cd["target_item_id"] = item_map[tid]
		cd["esim_ghost"] = true
		var c_scope := str(cd.get("scope_id", "root"))
		cd["scope_id"] = str(scope_map.get(c_scope, "root"))
		conns_out.append(cd)

	return {
		"items": items_out,
		"connections": conns_out,
		"scopes": scopes_out,
		"definitions": defs_in.duplicate(true),
		"item_count": items_out.size(),
		"connection_count": conns_out.size(),
	}


static func location_mismatch_m(package_loc: Dictionary, lat: float, lon: float) -> float:
	## Rough metres between package site and current coords (equirectangular).
	var plat := float(package_loc.get("latitude", lat))
	var plon := float(package_loc.get("longitude", lon))
	var dlat := (plat - lat) * 111_320.0
	var dlon := (plon - lon) * 111_320.0 * cos(deg_to_rad((plat + lat) * 0.5))
	return sqrt(dlat * dlat + dlon * dlon)


static func _default_name(location: Dictionary) -> String:
	var label := str(location.get("label", "")).strip_edges()
	if not label.is_empty():
		return label
	return "Site %.4f, %.4f" % [
		float(location.get("latitude", 0.0)),
		float(location.get("longitude", 0.0)),
	]


static func _read_location_label(main: Node) -> String:
	if main == null:
		return ""
	var cfg := ConfigFile.new()
	if cfg.load("user://location_prefs.cfg") != OK:
		return ""
	# Prefer scene-specific section when present; fall back to global.
	for section in cfg.get_sections():
		if cfg.has_section_key(section, "label"):
			var lbl := str(cfg.get_value(section, "label", "")).strip_edges()
			if not lbl.is_empty():
				return lbl
	return ""


static func _find_system_graph_view(main: Node) -> Node:
	var n := main.get_node_or_null("UILayer/SystemGraphView")
	if n != null:
		return n
	return main.find_child("SystemGraphView", true, false)


static func _find_terrain_loader(main: Node) -> Node:
	var n := main.get_node_or_null("TerrainLoader")
	if n != null:
		return n
	return main.find_child("TerrainLoader", true, false)


static func _soi_service() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return null
	return tree.root.get_node_or_null("SoiService")
