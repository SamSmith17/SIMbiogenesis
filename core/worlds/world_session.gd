class_name WorldSession
extends RefCounted

## The running world: save it, flush it, launch one, leave one.
##
## Static and autoload-free (autoloads are looked up by path at call time) so
## every class that names it still compiles under `--script` selftests.
##
## The save model is ALWAYS-LIVE: almost everything a world holds (props,
## lights, camps, sculpting, water, vegetation, the graph incl. NPC state, the
## peak score) is written to the world's own files as it changes. A "save"
## flushes whatever is still waiting on a debounce and writes the SNAPSHOT —
## the things that only exist in memory: player position and view, the
## clock, SolarUI's battery, gameplay rules, the vehicle being ridden,
## festival mode and the panel config. It runs every 3 minutes (autosave),
## on Save now, on Exit to menu and on window close.

const PERSIST_GROUP := "world_persist"
const SOLAR_CONFIG_PATH := "user://solar_panel_config.cfg"
const THUMB_W := 320
const THUMB_H := 180
const MAP_CHOOSER_SCENE := "res://scenes/ui/map_select/map_select.tscn"


static func _tree() -> SceneTree:
	return Engine.get_main_loop() as SceneTree


static func _autoload(name: String) -> Node:
	var t := _tree()
	return t.root.get_node_or_null(name) if t != null else null


static func active_id() -> String:
	return WorldPaths.active_world_id()


static func active_record() -> Dictionary:
	return WorldStore.get_world(active_id())


# -- Flush + snapshot ------------------------------------------------------------

## Everything waiting on a debounce goes to disk now (graph + NPC state + peak
## score, props, lights).
static func flush(main: Node) -> void:
	var t := _tree()
	if t != null:
		t.call_group(PERSIST_GROUP, "flush_world_state")
	if main != null:
		PlacedLightService.save(main)


## main.build_save_snapshot() plus what a world needs to resume EXACTLY.
static func build_snapshot(main: Node) -> Dictionary:
	if main == null or not main.has_method("build_save_snapshot"):
		return {}
	var snap: Dictionary = main.call("build_save_snapshot")
	var rec := active_record()
	snap["world_id"] = active_id()
	var map: Dictionary = rec.get("map", {}) if rec.get("map", {}) is Dictionary else {}
	snap["map_display_name"] = str(map.get("label", ""))
	var extras := {}
	if main.has_method("festival_mode_active"):
		extras["festival_mode"] = bool(main.call("festival_mode_active"))
	var riding := _riding_state(main)
	if not riding.is_empty():
		extras["riding"] = riding
	if FileAccess.file_exists(SOLAR_CONFIG_PATH):
		extras["solar_config"] = FileAccess.get_file_as_string(SOLAR_CONFIG_PATH)
	var loader := main.get_node_or_null("TerrainLoader")
	if loader != null and loader.has_method("world_imagery_record"):
		extras["terrain_imagery"] = loader.call("world_imagery_record")
	snap["world_extras"] = extras
	return snap


## Counts for the world list and the in-game "what this world holds" panel.
static func summary(main: Node) -> Dictionary:
	var out := {}
	if main == null:
		return out
	var loader := main.get_node_or_null("TerrainLoader")
	var props := PlacedPropService._layer_for_main(main)
	if props != null:
		out["props"] = props.props.size()
	var lights := PlacedLightService.get_layer(main)
	if lights != null:
		out["lights"] = lights.lights.size()
	if loader != null:
		var camps: Variant = loader.get("camp_areas")
		if camps is CampAreaLayer:
			out["camps"] = (camps as CampAreaLayer).areas.size()
		var tiles: Variant = loader.get("_edit_tiles")
		if tiles is TerrainEditTiles:
			out["edited_tiles"] = ((tiles as TerrainEditTiles)._tiles as Dictionary).size()
	var g := ServiceLocator.graph()
	if g != null:
		var model: Variant = g.get("model")
		if model != null and "items" in model:
			out["graph_nodes"] = (model.get("items") as Array).size()
		var bridge: Variant = g.get("_npc_population")
		if bridge != null:
			if bridge.has_method("peak_score"):
				out["peak_total"] = int((bridge.call("peak_score") as Dictionary).get("total", 0))
			if bridge.has_method("agent_dots"):
				out["people"] = (bridge.call("agent_dots") as Array).size()
	return out


## What "jump back in with everything intact" means, as data: one value per
## thing a world must restore. `--capture=worlds` takes this before a save and
## after a reload through the real picker path and diffs it key by key, so a
## subsystem that loses anything fails BY NAME.
static func fingerprint(main: Node) -> Dictionary:
	var fp := {}
	if main == null:
		return fp
	fp["clock.date"] = "%04d-%02d-%02d" % [int(main.get("year")), int(main.get("month")), int(main.get("day"))]
	fp["clock.hour"] = snappedf(float(main.get("day_time")), 0.05)
	var player: Variant = main.get("player")
	if player != null and is_instance_valid(player):
		var p3 := player as Node3D
		# Half-metre grid: physics settles a resumed body by a few centimetres.
		var sp := p3.global_position.snapped(Vector3(0.5, 0.5, 0.5))
		fp["player.pos"] = "%.1f,%.1f,%.1f" % [sp.x, sp.y, sp.z]
		fp["player.yaw"] = snappedf(p3.rotation.y, 0.01)
		var cam := p3.get_node_or_null("CameraArm/Camera3D") as Node3D
		if cam != null:
			fp["player.pitch"] = snappedf(cam.rotation.x, 0.01)
		fp["player.riding"] = bool(player.get("is_riding"))
	var sm := summary(main)
	for k in ["props", "lights", "camps", "edited_tiles", "graph_nodes", "peak_total"]:
		fp["count." + k] = int(sm.get(k, 0))
	var props := PlacedPropService._layer_for_main(main)
	if props != null:
		var ids: Array[String] = []
		for r in props.props:
			if r is Dictionary:
				ids.append(str((r as Dictionary).get("id", "")))
		ids.sort()
		fp["props.ids"] = ",".join(ids).sha256_text().left(12)
	var lights := PlacedLightService.get_layer(main)
	if lights != null:
		var lids: Array[String] = []
		for l in lights.lights:
			if l is Dictionary:
				lids.append(str((l as Dictionary).get("id", "")))
		lids.sort()
		fp["lights.ids"] = ",".join(lids).sha256_text().left(12)
	var g := ServiceLocator.graph()
	if g != null:
		var model: Variant = g.get("model")
		if model != null:
			var gids: Array[String] = []
			for it in model.get("items"):
				gids.append(str((it as Dictionary).get("id", "")))
			gids.sort()
			fp["graph.ids"] = ",".join(gids).sha256_text().left(12)
			fp["graph.connections"] = (model.get("connections") as Array).size()
			for it2 in model.get("items"):
				var specs: Dictionary = (it2 as Dictionary).get("specs", {})
				if bool(specs.get("pop_driven", false)):
					fp["npc.present." + str((it2 as Dictionary).get("id", ""))] = int(specs.get("pop_present", -1))
					fp["npc.morale." + str((it2 as Dictionary).get("id", ""))] = snappedf(float(specs.get("pop_morale", -1.0)), 0.05)
	var solar := main.get_node_or_null("UILayer/SolarUI")
	if solar != null and solar.get("battery_kwh_stored") != null:
		fp["solar.battery_kwh"] = snappedf(float(solar.get("battery_kwh_stored")), 0.01)
	if main.has_method("festival_mode_active"):
		fp["festival_mode"] = bool(main.call("festival_mode_active"))
	return fp


## Keys whose values differ between two fingerprints: [[key, before, after]].
static func fingerprint_diff(a: Dictionary, b: Dictionary) -> Array:
	var out: Array = []
	var keys := a.keys()
	for k in b.keys():
		if not keys.has(k):
			keys.append(k)
	keys.sort()
	for k in keys:
		if str(a.get(k, "<missing>")) != str(b.get(k, "<missing>")):
			out.append([k, a.get(k, "<missing>"), b.get(k, "<missing>")])
	return out


## Save the running world. `full` also vendors referenced library assets
## (parses the graph — explicit saves, exit and copies, not the autosave).
static func save_now(main: Node, full: bool = true, thumb: bool = true) -> bool:
	var id := active_id()
	if id.is_empty() or main == null:
		return false
	flush(main)
	var snap := build_snapshot(main)
	if snap.is_empty():
		return false
	var ok := WorldStore.record_save(id, snap, summary(main))
	if thumb:
		capture_thumb(main, id)
	if full:
		WorldAssets.collect(active_record())
	return ok


static func capture_thumb(main: Node, id: String) -> void:
	var vp := main.get_viewport() if main != null else null
	if vp == null or DisplayServer.get_name() == "headless":
		return
	# The 2D graph covers the 3D view (and turns the root viewport's 3D off) —
	# keep the last thumbnail rather than save a picture of the graph.
	var g := ServiceLocator.graph()
	if g is CanvasItem and (g as CanvasItem).visible:
		return
	var tex := vp.get_texture()
	if tex == null:
		return
	var img := tex.get_image()
	if img == null or img.is_empty():
		return
	img.resize(THUMB_W, THUMB_H, Image.INTERPOLATE_BILINEAR)
	img.save_png(WorldStore.thumb_path(id))


# -- Launch / leave ---------------------------------------------------------------

## Play a world: activate it, restore its assets, hand its map + snapshot to
## the next scene, change scene. `opts.force_refetch` re-downloads the MAP's
## data (DEM, imagery, OSM) — the world's own files are untouched.
static func launch(rec: Dictionary, opts: Dictionary = {}) -> Error:
	var t := _tree()
	if t == null or rec.is_empty():
		return ERR_INVALID_PARAMETER
	var map: Dictionary = rec.get("map", {}) if rec.get("map", {}) is Dictionary else {}
	var scene := MapDefinition.normalize_scene_path(str(map.get("scene_path", "")))
	if not MapDefinition.is_trusted_scene_path(scene):
		return ERR_FILE_UNRECOGNIZED
	var stats := WorldAssets.restore(rec)
	if int(stats.get("restored", 0)) + int(stats.get("remapped", 0)) + int(stats.get("registered", 0)) > 0:
		print("WorldSession: assets restored %s" % str(stats))
	WorldStore.touch_played(str(rec.get("id", "")))
	var snap := WorldStore.read_snapshot(str(rec.get("id", "")))
	var extras: Dictionary = snap.get("world_extras", {}) if snap.get("world_extras", {}) is Dictionary else {}
	var cfg := str(extras.get("solar_config", ""))
	var has_snap := not snap.is_empty()
	var sg := _autoload("SaveSystem")
	if sg != null:
		if has_snap and sg.has_method("validate_payload") and bool(sg.call("validate_payload", snap)):
			var payload := snap.duplicate(true)
			payload["scene_path"] = scene
			sg.call("set_pending_resume_payload", payload)
		elif sg.has_method("clear_pending_resume_payload"):
			sg.call("clear_pending_resume_payload")
			has_snap = false
	if scene == MapDefinition.GENERATED_SCENE:
		var ctx := _autoload("MapContext")
		if ctx != null:
			var he := float(map.get("half_extent_m", 0.0))
			var dhe := float(map.get("detail_half_extent_m", 0.0))
			var ohe := float(map.get("osm_half_extent_m", 0.0))
			# The snapshot is the newest record of the extents the world was
			# last built at (Terrain options can change them mid-world).
			if has_snap:
				if float(snap.get("half_extent_m", 0.0)) > 0.0:
					he = float(snap["half_extent_m"])
				if float(snap.get("detail_half_extent_m", 0.0)) > 0.0:
					dhe = float(snap["detail_half_extent_m"])
				if float(snap.get("osm_half_extent_m", 0.0)) > 0.0:
					ohe = float(snap["osm_half_extent_m"])
			if he <= 0.0 or dhe <= 0.0 or ohe <= 0.0:
				var meta := TerrainCacheSettings.get_meta_extents(float(map.get("lat", 0.0)), float(map.get("lon", 0.0)))
				he = he if he > 0.0 else float(meta.get("half_extent_m", 0.0))
				dhe = dhe if dhe > 0.0 else float(meta.get("detail_half_extent_m", 0.0))
				ohe = ohe if ohe > 0.0 else float(meta.get("osm_half_extent_m", 0.0))
			ctx.call("set_pending", float(map.get("lat", 0.0)), float(map.get("lon", 0.0)),
				str(map.get("label", "")), he, has_snap, dhe, ohe, bool(opts.get("force_refetch", false)))
			ctx.set("terrain_imagery", imagery_record(rec, snap))
	return switch_scene(MapDefinition.resolve_playable_scene_path(scene), rec, cfg)


## The world's imagery record ({"tier", "saved_tier", "mode"}): world.json's
## (the Share window and the world panel write the mode there), else the
## snapshot's, else {} (this computer's quality, no fallback).
static func imagery_record(rec: Dictionary, snap: Dictionary = {}) -> Dictionary:
	var ti: Variant = rec.get("terrain_imagery", null)
	if ti is Dictionary and not (ti as Dictionary).is_empty():
		return (ti as Dictionary).duplicate()
	var extras: Variant = snap.get("world_extras", {})
	if extras is Dictionary and (extras as Dictionary).get("terrain_imagery", null) is Dictionary:
		return ((extras as Dictionary)["terrain_imagery"] as Dictionary).duplicate()
	return {}


## Save, then back to the map chooser (which runs with no world active).
static func exit_to_menu(main: Node) -> void:
	save_now(main, true, true)
	var sg := _autoload("SaveSystem")
	if sg != null and sg.has_method("clear_pending_resume_payload"):
		sg.call("clear_pending_resume_payload")
	switch_scene(MAP_CHOOSER_SCENE, {}, "")


## Change scene WITHOUT the old scene's teardown writing into the wrong world.
## The old scene's exit-time flushes (graph autosave in _exit_tree, prop
## saves, …) happen during or after change_scene; with the next world already
## active they would land in ITS files, and with no world active on the
## player's legacy per-site files. So WorldPaths is sealed (those writes go to
## a discard folder — save_now already wrote the same data), and the next
## world is activated the moment the NEW scene's root enters the tree, before
## any of its nodes run _ready. `solar_cfg` (the world's panel config) is
## written at that same moment, after the old SolarUI is gone.
static func switch_scene(scene_file: String, rec: Dictionary, solar_cfg: String = "") -> Error:
	var t := _tree()
	if t == null:
		return ERR_UNCONFIGURED
	WorldPaths.seal()
	var want_file := scene_file.get_file()
	var hook := [null, false]  # [callable, arrived] — lambdas capture an Array by reference
	hook[0] = func(n: Node) -> void:
		if n.get_parent() != t.root or str(n.scene_file_path).get_file() != want_file:
			return
		if t.node_added.is_connected(hook[0]):
			t.node_added.disconnect(hook[0])
		hook[1] = true
		_arrive(rec, solar_cfg)
	t.node_added.connect(hook[0])
	var err := t.change_scene_to_file(scene_file)
	if err != OK:
		if t.node_added.is_connected(hook[0]):
			t.node_added.disconnect(hook[0])
		WorldPaths.unseal()
		return err
	# Never stay sealed: a sealed session silently discards every world write.
	t.create_timer(3.0).timeout.connect(func() -> void:
		if not bool(hook[1]):
			if t.node_added.is_connected(hook[0]):
				t.node_added.disconnect(hook[0])
			push_warning("WorldSession: new scene root never matched %s — activating late" % want_file)
			_arrive(rec, solar_cfg))
	return err


static func _arrive(rec: Dictionary, solar_cfg: String) -> void:
	if rec.is_empty():
		WorldPaths.clear_active()
	else:
		WorldStore.activate(rec)
	WorldStore.remove_tree(WorldPaths.DISCARD_DIR)
	if not solar_cfg.is_empty():
		var f := FileAccess.open(SOLAR_CONFIG_PATH, FileAccess.WRITE)
		if f != null:
			f.store_string(solar_cfg)
			f.close()


## A session opened WITHOUT a world (a harness, a direct scene boot) wrote its
## data in the legacy per-site layout. Make it a world: reuse the legacy world
## already filed on this site, else create one — nothing is copied or moved.
static func adopt_session(main: Node) -> Dictionary:
	if main == null or WorldPaths.has_active_world():
		return active_record()
	var map := current_map_ref(main)
	if map.is_empty():
		return {}
	var key := WorldStore.site_key_of({"map": map})
	var rec := {}
	for w in WorldStore.list():
		if str(w.get("storage", "")) == WorldPaths.STORAGE_LEGACY and WorldStore.site_key_of(w) == key:
			rec = w
			break
	if rec.is_empty():
		rec = WorldStore.create(map, "", WorldPaths.STORAGE_LEGACY)
	WorldStore.activate(rec)
	save_now(main, true, true)
	return WorldStore.get_world(str(rec.get("id", "")))


## The map the running scene stands on, as a world record's "map" block.
static func current_map_ref(main: Node) -> Dictionary:
	if main == null:
		return {}
	var scene := MapDefinition.normalize_scene_path(str(main.scene_file_path))
	var loader := main.get_node_or_null("TerrainLoader")
	if scene == MapDefinition.GENERATED_SCENE and loader != null:
		var ext: Dictionary = loader.call("get_terrain_extents") if loader.has_method("get_terrain_extents") else {}
		return {"scene_path": scene, "lat": float(loader.get("_lat")), "lon": float(loader.get("_lon")),
			"label": str(loader.get("_map_label")),
			"half_extent_m": float(ext.get("half_extent_m", 0.0)),
			"detail_half_extent_m": float(ext.get("detail_half_extent_m", 0.0)),
			"osm_half_extent_m": float(ext.get("osm_half_extent_m", 0.0))}
	if MapDefinition.is_trusted_scene_path(scene):
		return {"scene_path": scene, "lat": float(main.get("latitude")), "lon": float(main.get("longitude")),
			"label": ""}
	return {}


## Copy the running world as a checkpoint; the original keeps playing.
static func save_copy(main: Node, name: String) -> Dictionary:
	var id := active_id()
	if id.is_empty():
		return {}
	save_now(main, true, true)
	return WorldStore.duplicate_world(id, name)


# -- After the scene is up ---------------------------------------------------------

## The parts of a resume that need a BUILT world (props exist, terrain loaded):
## re-mount the vehicle the player was riding, reopen festival mode.
static func restore_extras(main: Node, snap: Dictionary) -> void:
	var extras: Dictionary = snap.get("world_extras", {}) if snap.get("world_extras", {}) is Dictionary else {}
	if extras.is_empty() or main == null:
		return
	var loader := main.get_node_or_null("TerrainLoader")
	if loader != null and loader.has_signal("map_load_complete") and not bool(loader.get("load_completed")):
		await loader.map_load_complete
	# Props are (re)built a beat after the load signal.
	for i in 30:
		await main.get_tree().process_frame
	if not is_instance_valid(main):
		return
	var riding: Dictionary = extras.get("riding", {}) if extras.get("riding", {}) is Dictionary else {}
	if not riding.is_empty():
		_remount(main, riding)
	if bool(extras.get("festival_mode", false)) and main.has_method("festival_mode_active") \
			and not bool(main.call("festival_mode_active")) and main.has_method("open_festival_mode"):
		main.call("open_festival_mode")


static func _riding_state(main: Node) -> Dictionary:
	var player: Variant = main.get("player")
	if player == null or not is_instance_valid(player) or not bool(player.get("is_riding")):
		return {}
	if bool(player.get("is_fpv_drone_mode")):
		return {}  # the drone has its own restore path in the snapshot
	var v: Variant = player.get("current_vehicle")
	if v == null or not is_instance_valid(v):
		return {}
	if v is PlacedVehicle:
		return {"kind": "prop", "prop_id": (v as PlacedVehicle).prop_id}
	return {"kind": "node", "path": str(main.get_path_to(v as Node))}


static func _remount(main: Node, riding: Dictionary) -> void:
	var player: Variant = main.get("player")
	if player == null or not is_instance_valid(player) or not player.has_method("request_mount"):
		return
	var vehicle: Node3D = null
	if str(riding.get("kind", "")) == "prop":
		var prop := PlacedPropRuntime.find_by_prop_id(main, str(riding.get("prop_id", "")))
		if prop != null:
			vehicle = prop.get_node_or_null("PlacedVehicle") as Node3D
	else:
		vehicle = main.get_node_or_null(NodePath(str(riding.get("path", "")))) as Node3D
	if vehicle != null:
		player.call("request_mount", vehicle)
