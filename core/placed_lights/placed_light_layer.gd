class_name PlacedLightLayer
extends RefCounted

## Per-map placed lights (J Light Studio) — data only, no scene access.
##
## v3 file: {version, lights[], styles{}, groups{}}
##   light  {id, kind: omni|spot|string, name, style_id, overrides{}, group_ids[],
##           enabled, x,y,z (WORLD), pitch,yaw,roll (DEGREES, YXZ),
##           waypoints[{x,y,z}] (string only), graph_item_id}
##   style  {name, kind, fields{}}     resolved by PlacedLightStyles.resolve
##   group  {name, hidden}
##
## What v3 fixed, so nobody restores it: v2 stored rotation in RADIANS while
## every other placed thing (props) uses degrees; positions were world hit
## points applied as LOCAL positions under Terrain/PlacedLights; and the file
## was keyed by scene basename, so every generated user map (one shared shell
## scene) read and wrote the SAME lights file.

const VERSION := 3
const MAX_LIGHTS := 500
const MAX_WAYPOINTS_PER_STRING := 64
const MAX_WAYPOINTS_TOTAL := 4000

var lights: Array = []
var styles: Dictionary = {}
var groups: Dictionary = {}
## Set when deserialize() converted an older file (the caller saves once).
var migrated_from := 0


static func create_empty() -> PlacedLightLayer:
	return PlacedLightLayer.new()


## `key` is either "scene_<basename>" (built-in maps) or "<lat>_<lon>" tokens.
static func path_for_key(key: String) -> String:
	return "user://maps/placed_lights_%s.json" % key


static func legacy_path_for_scene(scene_path: String) -> String:
	var tag := scene_path.get_file().get_basename() if scene_path.contains("/") else scene_path
	if tag.is_empty():
		tag = "unknown_scene"
	return "user://maps/placed_lights_scene_%s.json" % tag


func save_to(path: String) -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(serialize(), "\t"))
	return true


func load_from(path: String) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return false
	deserialize(parsed as Dictionary)
	return true


func serialize() -> Dictionary:
	return {"version": VERSION, "lights": lights.duplicate(true),
		"styles": styles.duplicate(true), "groups": groups.duplicate(true)}


func deserialize(data: Dictionary) -> void:
	lights = []
	styles = {}
	groups = {}
	migrated_from = 0
	var ver := int(data.get("version", 1))
	if data.get("styles") is Dictionary:
		styles = (data["styles"] as Dictionary).duplicate(true)
	if data.get("groups") is Dictionary:
		groups = (data["groups"] as Dictionary).duplicate(true)
	var src: Variant = data.get("lights", [])
	if not (src is Array):
		return
	if ver < 3:
		migrated_from = ver
		_migrate_legacy(src as Array)
		return
	for r in src:
		if r is Dictionary:
			lights.append(_heal(r as Dictionary))


## v1/v2 → v3: radians → degrees, `type` → `kind`, and identical looks share
## ONE auto style (a field of 40 same-colour lights becomes one editable style,
## not 40).
func _migrate_legacy(src: Array) -> void:
	var by_sig := {}
	for r in src:
		if not (r is Dictionary):
			continue
		var old: Dictionary = r
		var kind := "spot" if str(old.get("type", "omni")) == "spot" else "omni"
		var fields := {
			"color": str(old.get("color", "ffffff")),
			"energy": float(old.get("energy", 1.0)),
			"range": float(old.get("range", 10.0)),
			"shadow_enabled": bool(old.get("shadow_enabled", true)),
			"fade_m": float(old.get("lod_m", 0.0)),
		}
		if kind == "spot":
			fields["spot_angle"] = float(old.get("spot_angle", 45.0))
		var sig := PlacedLightStyles.signature(kind, fields)
		var sid: String = by_sig.get(sig, "")
		if sid.is_empty():
			sid = add_style("%s %d" % [kind.capitalize(), styles.size() + 1], kind, fields)
			by_sig[sig] = sid
		lights.append(_heal({
			"id": str(old.get("id", new_id("light"))),
			"kind": kind,
			"style_id": sid,
			"x": float(old.get("x", 0.0)), "y": float(old.get("y", 0.0)),
			"z": float(old.get("z", 0.0)),
			"pitch": rad_to_deg(float(old.get("pitch", 0.0))),
			"yaw": rad_to_deg(float(old.get("yaw", 0.0))),
			"roll": rad_to_deg(float(old.get("roll", 0.0))),
		}))


static func _heal(r: Dictionary) -> Dictionary:
	var kind := str(r.get("kind", r.get("type", "omni")))
	if not kind in PlacedLightStyles.KINDS:
		kind = "omni"
	r["kind"] = kind
	r.erase("type")
	for k in ["x", "y", "z", "pitch", "yaw", "roll"]:
		r[k] = float(r.get(k, 0.0))
	if not (r.get("overrides") is Dictionary):
		r["overrides"] = {}
	if not (r.get("group_ids") is Array):
		r["group_ids"] = []
	r["enabled"] = bool(r.get("enabled", true))
	r["style_id"] = str(r.get("style_id", ""))
	r["name"] = str(r.get("name", ""))
	r["graph_item_id"] = str(r.get("graph_item_id", ""))
	if kind == "string":
		var wps: Array = []
		if r.get("waypoints") is Array:
			for w in r["waypoints"]:
				if w is Dictionary:
					wps.append({"x": float(w.get("x", 0.0)), "y": float(w.get("y", 0.0)),
						"z": float(w.get("z", 0.0))})
		r["waypoints"] = wps
	return r


static func new_id(prefix: String) -> String:
	return "%s_%d_%05d" % [prefix, int(Time.get_unix_time_from_system()), randi() % 100000]


# -- Lights ------------------------------------------------------------------

func add_light(kind: String, pos: Vector3, rot_deg: Vector3, style_id: String,
		overrides: Dictionary = {}) -> String:
	if lights.size() >= MAX_LIGHTS:
		return ""
	var id := new_id("light")
	lights.append(_heal({"id": id, "kind": kind, "style_id": style_id,
		"overrides": overrides.duplicate(true),
		"x": snappedf(pos.x, 0.001), "y": snappedf(pos.y, 0.001), "z": snappedf(pos.z, 0.001),
		"pitch": snappedf(rot_deg.x, 0.01), "yaw": snappedf(rot_deg.y, 0.01),
		"roll": snappedf(rot_deg.z, 0.01)}))
	return id


func add_string(points: Array, style_id: String, overrides: Dictionary = {}) -> String:
	if lights.size() >= MAX_LIGHTS or points.size() < 2:
		return ""
	if total_waypoints() + points.size() > MAX_WAYPOINTS_TOTAL:
		return ""
	var wps: Array = []
	for p in points.slice(0, MAX_WAYPOINTS_PER_STRING):
		var v: Vector3 = p
		wps.append(_wp(v))
	var first: Vector3 = points[0]
	var id := new_id("string")
	lights.append(_heal({"id": id, "kind": "string", "style_id": style_id,
		"overrides": overrides.duplicate(true), "waypoints": wps,
		"x": first.x, "y": first.y, "z": first.z}))
	return id


static func _wp(v: Vector3) -> Dictionary:
	return {"x": snappedf(v.x, 0.001), "y": snappedf(v.y, 0.001), "z": snappedf(v.z, 0.001)}


static func waypoint_vec(w: Dictionary) -> Vector3:
	return Vector3(float(w.get("x", 0.0)), float(w.get("y", 0.0)), float(w.get("z", 0.0)))


static func waypoints_of(rec: Dictionary) -> Array:
	var out: Array = []
	for w in rec.get("waypoints", []):
		if w is Dictionary:
			out.append(waypoint_vec(w))
	return out


func set_waypoints(id: String, points: Array) -> bool:
	var rec := find_light(id)
	if rec.is_empty() or points.size() < 2:
		return false
	var wps: Array = []
	for p in points.slice(0, MAX_WAYPOINTS_PER_STRING):
		wps.append(_wp(p as Vector3))
	rec["waypoints"] = wps
	var first: Vector3 = points[0]
	rec["x"] = first.x
	rec["y"] = first.y
	rec["z"] = first.z
	return true


func total_waypoints() -> int:
	var n := 0
	for r in lights:
		n += (r.get("waypoints", []) as Array).size()
	return n


func position_of(rec: Dictionary) -> Vector3:
	return Vector3(float(rec.get("x", 0.0)), float(rec.get("y", 0.0)), float(rec.get("z", 0.0)))


func rotation_of(rec: Dictionary) -> Vector3:
	return Vector3(float(rec.get("pitch", 0.0)), float(rec.get("yaw", 0.0)), float(rec.get("roll", 0.0)))


func update_light(id: String, props: Dictionary) -> bool:
	var rec := find_light(id)
	if rec.is_empty():
		return false
	for k in props:
		rec[k] = props[k]
	return true


func remove_light(id: String) -> bool:
	for i in lights.size():
		if str(lights[i].get("id", "")) == id:
			lights.remove_at(i)
			return true
	return false


func find_light(id: String) -> Dictionary:
	for l in lights:
		if str(l.get("id", "")) == id:
			return l
	return {}


## The record's fields as it renders: style ⊕ overrides.
func resolved(rec: Dictionary) -> Dictionary:
	var kind := str(rec.get("kind", "omni"))
	var st: Dictionary = styles.get(str(rec.get("style_id", "")), {})
	return PlacedLightStyles.resolve(kind, st.get("fields", {}), rec.get("overrides", {}))


## Write one style field for a light, either INTO its style (every light using
## the style follows) or as this light's own override.
func set_field(id: String, key: String, value: Variant, into_style: bool) -> void:
	var rec := find_light(id)
	if rec.is_empty():
		return
	var kind := str(rec["kind"])
	if not PlacedLightStyles.is_style_key(kind, key):
		return
	var sid := str(rec.get("style_id", ""))
	if into_style and styles.has(sid):
		(styles[sid]["fields"] as Dictionary)[key] = value
		# The style now says it — an override equal to it would be noise.
		var ov: Dictionary = rec["overrides"]
		if ov.has(key) and PlacedLightStyles._same(ov[key], value):
			ov.erase(key)
		return
	var ov2: Dictionary = rec["overrides"]
	ov2[key] = value
	rec["overrides"] = PlacedLightStyles.prune_overrides(kind,
		(styles.get(sid, {}) as Dictionary).get("fields", {}), ov2)


func revert_override(id: String, key: String) -> void:
	var rec := find_light(id)
	if not rec.is_empty():
		(rec["overrides"] as Dictionary).erase(key)


# -- Styles ------------------------------------------------------------------

func add_style(style_name: String, kind: String, fields: Dictionary) -> String:
	var sid := new_id("style")
	while styles.has(sid):
		sid = new_id("style")
	var clean := {}
	for k in fields.keys():
		if PlacedLightStyles.is_style_key(kind, k):
			clean[k] = fields[k]
	styles[sid] = {"name": style_name, "kind": kind, "fields": clean}
	return sid


## The style new lights of `kind` get when nothing is active yet.
func ensure_default_style(kind: String) -> String:
	for sid in styles.keys():
		if str(styles[sid].get("kind", "")) == kind and bool(styles[sid].get("default", false)):
			return sid
	var sid := add_style("Default %s" % kind, kind, {})
	styles[sid]["default"] = true
	return sid


func styles_of_kind(kind: String) -> Array:
	var out: Array = []
	for sid in styles.keys():
		if str(styles[sid].get("kind", "")) == kind:
			out.append(sid)
	return out


func style_usage(sid: String) -> int:
	var n := 0
	for r in lights:
		if str(r.get("style_id", "")) == sid:
			n += 1
	return n


func lights_with_style(sid: String) -> Array:
	var out: Array = []
	for r in lights:
		if str(r.get("style_id", "")) == sid:
			out.append(str(r["id"]))
	return out


## Detach a light: its resolved look becomes a NEW style of its own.
func make_unique(id: String, style_name: String = "") -> String:
	var rec := find_light(id)
	if rec.is_empty():
		return ""
	var kind := str(rec["kind"])
	var res := resolved(rec)
	var sid := add_style(style_name if not style_name.is_empty() else "%s (copy)" % style_display_name(str(rec["style_id"])),
		kind, res)
	rec["style_id"] = sid
	rec["overrides"] = {}
	return sid


## Push a light's overrides into its style (every user of the style follows).
func push_overrides_to_style(id: String) -> void:
	var rec := find_light(id)
	var sid := str(rec.get("style_id", ""))
	if rec.is_empty() or not styles.has(sid):
		return
	var fields: Dictionary = styles[sid]["fields"]
	var ov: Dictionary = rec["overrides"]
	for k in ov.keys():
		fields[k] = ov[k]
	rec["overrides"] = {}
	# Other users' overrides that now equal the style are noise.
	for r in lights:
		if str(r.get("style_id", "")) == sid:
			r["overrides"] = PlacedLightStyles.prune_overrides(str(r["kind"]), fields, r["overrides"])


## Removing a style re-homes its lights onto the kind's default, keeping each
## light's resolved look as overrides so nothing visibly changes.
func remove_style(sid: String) -> void:
	if not styles.has(sid):
		return
	var kind := str(styles[sid].get("kind", "omni"))
	var users := lights_with_style(sid)
	var keep := {}
	for id in users:
		keep[id] = resolved(find_light(id))
	styles.erase(sid)
	var fallback := ensure_default_style(kind)
	for id in users:
		var rec := find_light(id)
		rec["style_id"] = fallback
		rec["overrides"] = PlacedLightStyles.prune_overrides(kind,
			styles[fallback]["fields"], keep[id])


func style_display_name(sid: String) -> String:
	return str((styles.get(sid, {}) as Dictionary).get("name", "Style"))


# -- Groups ------------------------------------------------------------------

func add_group(group_name: String, ids: Array) -> String:
	var gid := new_id("group")
	groups[gid] = {"name": group_name, "hidden": false}
	for id in ids:
		var rec := find_light(str(id))
		if not rec.is_empty() and not gid in rec["group_ids"]:
			(rec["group_ids"] as Array).append(gid)
	return gid


func group_members(gid: String) -> Array:
	var out: Array = []
	for r in lights:
		if gid in (r.get("group_ids", []) as Array):
			out.append(str(r["id"]))
	return out


func remove_group(gid: String) -> void:
	groups.erase(gid)
	for r in lights:
		(r.get("group_ids", []) as Array).erase(gid)


func set_group_membership(gid: String, ids: Array, member: bool) -> void:
	for id in ids:
		var rec := find_light(str(id))
		if rec.is_empty():
			continue
		var g: Array = rec["group_ids"]
		if member and not gid in g:
			g.append(gid)
		elif not member:
			g.erase(gid)


func is_hidden_by_group(rec: Dictionary) -> bool:
	for gid in rec.get("group_ids", []):
		if bool((groups.get(gid, {}) as Dictionary).get("hidden", false)):
			return true
	return false


## Copy of a light offset by `delta`: same style, overrides and groups; no
## graph binding (a copy is a new, untracked fixture).
func duplicate_light(id: String, delta: Vector3) -> String:
	var rec := find_light(id)
	if rec.is_empty() or lights.size() >= MAX_LIGHTS:
		return ""
	var copy: Dictionary = rec.duplicate(true)
	var prefix := "string" if str(rec["kind"]) == "string" else "light"
	copy["id"] = new_id(prefix)
	while not find_light(str(copy["id"])).is_empty():
		copy["id"] = new_id(prefix)
	copy["graph_item_id"] = ""
	copy["x"] = float(copy["x"]) + delta.x
	copy["y"] = float(copy["y"]) + delta.y
	copy["z"] = float(copy["z"]) + delta.z
	if str(rec["kind"]) == "string":
		if total_waypoints() + (copy["waypoints"] as Array).size() > MAX_WAYPOINTS_TOTAL:
			return ""
		for w in copy["waypoints"]:
			w["x"] = float(w["x"]) + delta.x
			w["y"] = float(w["y"]) + delta.y
			w["z"] = float(w["z"]) + delta.z
	lights.append(copy)
	return str(copy["id"])


## Move a light (and a string's every waypoint) by `delta`.
func translate_light(id: String, delta: Vector3) -> void:
	var rec := find_light(id)
	if rec.is_empty():
		return
	rec["x"] = float(rec["x"]) + delta.x
	rec["y"] = float(rec["y"]) + delta.y
	rec["z"] = float(rec["z"]) + delta.z
	for w in rec.get("waypoints", []):
		w["x"] = float(w["x"]) + delta.x
		w["y"] = float(w["y"]) + delta.y
		w["z"] = float(w["z"]) + delta.z
