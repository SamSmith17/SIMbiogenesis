class_name MpGuestWorld
extends RefCounted

## A guest plays inside a THROWAWAY world, never their own.
##
## Joining used to load the host's map with whatever world (or no world) the
## guest had active, and then wrote the host's props and graph into those
## files — a guest who joined a session on Walton came home to the host's
## Walton in place of their own. Now joining:
##   1. saves the guest's own world as it stands,
##   2. copies the guest's own files for the host's site (their terrain edits,
##      vegetation, water … — what the shared sync does not carry, so the
##      site still looks like itself) into user://worlds/_mp_guest/,
##   3. points WorldPaths at that copy for the rest of the session.
## The host's props and graph then arrive over the network and are written
## there. The folder starts with "_", so it is never listed as a world, and
## it is wiped on the next join.

const ID := "_mp_guest"
const ROOT := "user://worlds/_mp_guest"


## The record WorldStore.activate / WorldSession.switch_scene take.
static func record_for(map_info: Dictionary) -> Dictionary:
	var generated := str(map_info.get("kind", "generated")) == "generated" \
		or str(map_info.get("scene_path", "")).contains("generated_location")
	return {
		"id": ID,
		"name": "Multiplayer session",
		"storage": WorldPaths.STORAGE_DIR,
		"scratch": true,
		"map": {
			"scene_path": MapDefinition.GENERATED_SCENE if generated
				else MapDefinition.normalize_scene_path(str(map_info.get("scene_path", ""))),
			"lat": float(map_info.get("latitude", 0.0)),
			"lon": float(map_info.get("longitude", 0.0)),
			"label": str(map_info.get("label", "")),
		},
	}


static func site_key_for(map_info: Dictionary) -> String:
	return WorldStore.site_key_of(record_for(map_info))


static func is_active() -> bool:
	return WorldPaths.active_world_id() == ID


## Wipe the folder and copy the guest's own files for this site into it.
## Source: the guest's active world when it is on the same site, else the
## legacy per-site layout (where a migrated or world-less site keeps its files).
static func prepare(map_info: Dictionary) -> int:
	var key := site_key_for(map_info)
	WorldStore.remove_tree(ROOT)
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(ROOT))
	var src_storage := WorldPaths.STORAGE_LEGACY
	var src_root := ""
	var src_key := key
	if WorldPaths.has_active_world() and not is_active() and WorldPaths.active_site_key() == key:
		src_storage = WorldPaths.storage()
		src_root = WorldPaths.active_root()
	var copied := 0
	for kind_ext in WorldPaths.KINDS:
		var kind := str(kind_ext[0])
		var ext := str(kind_ext[1])
		var src := WorldPaths.path_in(kind, key, ext, src_storage, src_root, src_key)
		var dst := WorldPaths.path_in(kind, key, ext, WorldPaths.STORAGE_DIR, ROOT, key)
		if _copy(src, dst):
			copied += 1
	var gkey := WorldPaths.graph_key_for_site(key)
	if _copy(WorldPaths.graph_path_in(gkey, src_storage, src_root, src_key),
			WorldPaths.graph_path_in(gkey, WorldPaths.STORAGE_DIR, ROOT, key)):
		copied += 1
	# A record, so the world autosave and Save now work in here like anywhere
	# else (WorldStore.record_save refuses a folder with no world.json).
	var rec := record_for(map_info)
	rec["created_unix"] = Time.get_unix_time_from_system()
	WorldStore.save_record(rec, ROOT.get_base_dir())
	return copied


## Point WorldPaths at the copy NOW (joining without a scene change).
static func activate(map_info: Dictionary) -> void:
	WorldStore.activate(record_for(map_info))


static func _copy(src: String, dst: String) -> bool:
	if src.is_empty() or not FileAccess.file_exists(src):
		return false
	return DirAccess.copy_absolute(ProjectSettings.globalize_path(src),
		ProjectSettings.globalize_path(dst)) == OK
