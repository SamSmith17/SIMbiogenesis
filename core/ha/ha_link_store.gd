class_name HaLinkStore
extends RefCounted
## A world's Home Assistant links (pure; the file path is a parameter).
##
## Saved per world (WorldPaths kind "ha_links", next to the graph), holding
## entity ids and target ids only — never an address or a token, so a world
## can be copied or shared in a pack. A link is
##   {id, entity_id, target_id, scale, offset, invert, enabled}
## and a target takes at most ONE link (a second link to the same target
## replaces the first); an entity may feed several targets.
##
## The old places links lived are migrated once, into a world that has no link
## file yet: every graph node's specs.ha_links (role → entity id; the roles are
## HaTargets' field ids) and SolarUI's solar_ui_ha_entities.cfg.

const VERSION := 1
const KIND := "ha_links"
const LEGACY_SOLAR_CFG := "user://solar_ui_ha_entities.cfg"

var links: Array = []
var migrated: bool = false
var _next: int = 1


static func load_from(path: String) -> HaLinkStore:
	var s := HaLinkStore.new()
	if path.is_empty() or not FileAccess.file_exists(path):
		return s
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (data is Dictionary):
		return s
	s.migrated = bool(data.get("migrated", false))
	for l in data.get("links", []):
		if l is Dictionary and not str(l.get("entity_id", "")).is_empty() \
				and not str(l.get("target_id", "")).is_empty():
			s.links.append(_normalized(l))
	s._next = int(data.get("next", s.links.size() + 1))
	return s


func save_to(path: String) -> bool:
	if path.is_empty():
		return false
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": VERSION, "migrated": migrated,
		"next": _next, "links": links}, "\t"))
	return true


## Link `entity_id` to `target_id` (replacing that target's old link); returns
## the link.
func link(entity_id: String, target_id: String, opts: Dictionary = {}) -> Dictionary:
	unlink_target(target_id)
	var l := _normalized({"id": "l%d" % _next, "entity_id": entity_id.strip_edges(),
		"target_id": target_id, "scale": opts.get("scale", 1.0), "offset": opts.get("offset", 0.0),
		"invert": opts.get("invert", false), "enabled": opts.get("enabled", true)})
	_next += 1
	links.append(l)
	return l


func unlink_target(target_id: String) -> bool:
	var n := links.size()
	links = links.filter(func(l): return str(l["target_id"]) != target_id)
	return links.size() != n


func remove(link_id: String) -> bool:
	var n := links.size()
	links = links.filter(func(l): return str(l["id"]) != link_id)
	return links.size() != n


func set_fields(link_id: String, patch: Dictionary) -> bool:
	for l in links:
		if str(l["id"]) == link_id:
			for k in ["scale", "offset", "invert", "enabled"]:
				if patch.has(k):
					l[k] = patch[k]
			l.merge(_normalized(l), true)
			return true
	return false


func for_target(target_id: String) -> Dictionary:
	for l in links:
		if str(l["target_id"]) == target_id:
			return l
	return {}


func for_entity(entity_id: String) -> Array:
	return links.filter(func(l): return str(l["entity_id"]) == entity_id)


func entity_ids() -> Array:
	var out: Array = []
	for l in links:
		if bool(l.get("enabled", true)) and not out.has(str(l["entity_id"])):
			out.append(str(l["entity_id"]))
	return out


## Drop links whose graph node is gone; returns how many.
func prune_items(live_item_ids: Dictionary) -> int:
	var n := links.size()
	links = links.filter(func(l):
		var p := HaTargets.parse(str(l["target_id"]))
		return p.is_empty() or str(p["scope"]) != "item" or live_item_ids.has(str(p["item_id"])))
	return n - links.size()


## One-time import of the old link places. `items` = the graph's items (their
## specs.ha_links are returned in `cleared` so the caller can strip them);
## `solar_cfg` = path of the old SolarUI file ("" to skip). Returns how many
## links were added.
func migrate_legacy(items: Array, solar_cfg: String = LEGACY_SOLAR_CFG) -> Dictionary:
	var added := 0
	var cleared: Array = []
	if migrated:
		return {"added": 0, "cleared": cleared}
	for it in items:
		if not (it is Dictionary):
			continue
		var specs: Dictionary = it.get("specs", {}) if it.get("specs", {}) is Dictionary else {}
		var hl: Variant = specs.get("ha_links", null)
		if not (hl is Dictionary) or (hl as Dictionary).is_empty():
			continue
		var iid := str(it.get("id", ""))
		for role in (hl as Dictionary).keys():
			var eid := str(hl[role]).strip_edges()
			if eid.is_empty():
				continue
			var tid := HaTargets.item_target_id(iid, str(role))
			if for_target(tid).is_empty():
				link(eid, tid)
				added += 1
		cleared.append(iid)
	if not solar_cfg.is_empty():
		var cfg := ConfigFile.new()
		if cfg.load(solar_cfg) == OK:
			for sec in ["entities", "weather_entities"]:
				if not cfg.has_section(sec):
					continue
				for k in cfg.get_section_keys(sec):
					var tid := str(HaTargets.SOLAR_UI_KEYS.get(k, ""))
					var eid := str(cfg.get_value(sec, k, "")).strip_edges()
					if tid.is_empty() or eid.is_empty() or not for_target(tid).is_empty():
						continue
					# The sensor's own unit_of_measurement does the converting now
					# (the old "values in watts" flags are not carried over).
					link(eid, tid)
					added += 1
	migrated = true
	return {"added": added, "cleared": cleared}


static func _normalized(l: Dictionary) -> Dictionary:
	return {
		"id": str(l.get("id", "")),
		"entity_id": str(l.get("entity_id", "")).strip_edges(),
		"target_id": str(l.get("target_id", "")),
		"scale": float(l.get("scale", 1.0)),
		"offset": float(l.get("offset", 0.0)),
		"invert": bool(l.get("invert", false)),
		"enabled": bool(l.get("enabled", true)),
	}
