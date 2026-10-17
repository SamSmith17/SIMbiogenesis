class_name AssetPackWriter
extends RefCounted

## Writes resolved catalog entries into one or more ".simpack.zip" parts.
## Synchronous: the UI runs it on a WorkerThreadPool task with an
## AssetPackProgress, the selftest calls it directly.
##
## Parts: Godot's ZIPPacker writes a corrupt archive past 4 GB (no zip64 —
## measured on 4.7.1: a 5 GB write closed "OK" and read back as nothing), so
## entries are binned IN ORDER into parts of at most PART_MAX_BYTES before
## anything is written. Part 1 starts with the manifest (everything the
## importer needs to preview, incl. how many parts to expect); every part
## ends with simpack.hashes.json, the SHA-256 of each file in that part,
## computed while streaming (no second read of 3 GB of art).

const HASHES := AssetPackFormat.HASHES


## The manifest's descriptive half for a resolved selection: who made it,
## the worlds (for the import preview), the items with sizes.
static func build_meta(resolved: Dictionary, creator: String, project_root: String = "res://") -> Dictionary:
	var worlds: Array = []
	var items: Array = []
	var art := false
	for it in resolved.get("items", []):
		var d: Dictionary = it
		items.append({"id": str(d["id"]), "section": str(d["section"]), "label": str(d["label"]),
			"sub": str(d.get("sub", "")), "size": int(d.get("size", 0))})
		if str(d["section"]) == AssetPackFormat.SEC_ART:
			art = true
		if str(d["section"]) == AssetPackFormat.SEC_WORLDS:
			var rec: Dictionary = d.get("rec", {})
			var map: Dictionary = rec.get("map", {}) if rec.get("map", {}) is Dictionary else {}
			var wid := str(d.get("world_id", ""))
			var thumb := "%s/%s/%s" % [AssetPackFormat.SEC_WORLDS, wid, WorldStore.THUMB_FILE]
			worlds.append({"id": wid, "name": str(d["label"]), "site": str(map.get("label", "")),
				"lat": float(map.get("lat", 0.0)), "lon": float(map.get("lon", 0.0)),
				"scene": str(map.get("scene_path", "")), "playtime_s": float(rec.get("playtime_s", 0.0)),
				"thumb": thumb if not str(d.get("thumb", "")).is_empty() else ""})
	return {
		"creator": creator.strip_edges(),
		"created_unix": Time.get_unix_time_from_system(),
		"game_commit": AssetPackFormat.game_commit(project_root),
		"godot": Engine.get_version_info().get("string", ""),
		"worlds": worlds,
		"items": items,
		"needs_reimport": art,
	}


## entries: from AssetPackCatalog.resolve(). meta: creator, worlds, items, …
## Returns {ok, error, parts: Array[String], bytes, files}.
static func write(base_path: String, entries: Array, meta: Dictionary,
		progress: AssetPackProgress = null, part_max: int = AssetPackFormat.PART_MAX_BYTES) -> Dictionary:
	if progress == null:
		progress = AssetPackProgress.new()
	var out := {"ok": false, "error": "", "parts": [], "bytes": 0, "files": 0}
	# 1. Bin entries into parts.
	var parts: Array = [[]]
	var part_bytes := 0
	var total := 0
	var file_index := {}
	for e in entries:
		var z := str(e["zip"])
		if not AssetPackFormat.entry_allowed(z):
			out["error"] = "Refusing to pack %s" % z
			return out
		var sz := AssetPackCatalog.entry_size(e)
		if sz > part_max:
			out["error"] = "%s is %s — larger than one pack part can hold" % [z.get_file(), AssetPackFormat.human_size(sz)]
			return out
		if part_bytes > 0 and part_bytes + sz > part_max:
			parts.append([])
			part_bytes = 0
		(parts[parts.size() - 1] as Array).append(e)
		part_bytes += sz
		total += sz
		file_index[z] = {"size": sz, "part": parts.size()}
	var part_names: Array = []
	for i in parts.size():
		part_names.append(AssetPackFormat.part_path(base_path, i + 1).get_file())
	var manifest := meta.duplicate(true)
	manifest["format"] = AssetPackFormat.FORMAT
	manifest["parts"] = parts.size()
	manifest["part_names"] = part_names
	manifest["bytes"] = total
	manifest["files"] = file_index
	if not manifest.has("created_unix"):
		manifest["created_unix"] = Time.get_unix_time_from_system()
	progress.set_total(total)
	# 2. Write.
	var written: Array[String] = []
	for pi in parts.size():
		var path := AssetPackFormat.part_path(base_path, pi + 1)
		written.append(path)
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
		var zp := ZIPPacker.new()
		if zp.open(path) != OK:
			out["error"] = "Could not create %s" % path
			_discard(written)
			return out
		if pi == 0:
			var err0 := _put_bytes(zp, AssetPackFormat.MANIFEST, JSON.stringify(manifest, "\t").to_utf8_buffer())
			if err0 != OK:
				zp.close()
				out["error"] = "Could not write the manifest"
				_discard(written)
				return out
		var hashes := {}
		for e in parts[pi]:
			if progress.cancelled():
				zp.close()
				out["error"] = "Cancelled"
				_discard(written)
				return out
			var r := _put_entry(zp, e, progress)
			if not bool(r["ok"]):
				zp.close()
				out["error"] = str(r["error"])
				_discard(written)
				return out
			hashes[str(e["zip"])] = str(r["sha256"])
			out["files"] = int(out["files"]) + 1
		_put_bytes(zp, HASHES, JSON.stringify({"part": pi + 1, "files": hashes}, "\t").to_utf8_buffer())
		if zp.close() != OK:
			out["error"] = "Could not finish %s" % path.get_file()
			_discard(written)
			return out
	out["ok"] = true
	out["parts"] = written
	out["bytes"] = total
	return out


static func _put_bytes(zp: ZIPPacker, name: String, data: PackedByteArray) -> Error:
	zp.compression_level = -1
	var err := zp.start_file(name)
	if err != OK:
		return err
	err = zp.write_file(data)
	zp.close_file()
	return err


## Stream one entry in CHUNK_BYTES pieces, hashing as it goes.
static func _put_entry(zp: ZIPPacker, e: Dictionary, progress: AssetPackProgress) -> Dictionary:
	var z := str(e["zip"])
	var store := AssetPackFormat.STORE_EXTENSIONS.has(AssetPackFormat.ext_of(z))
	zp.compression_level = 0 if store else -1
	if zp.start_file(z) != OK:
		return {"ok": false, "error": "Could not add %s" % z}
	var hc := HashingContext.new()
	hc.start(HashingContext.HASH_SHA256)
	var label := z.get_file()
	if e.has("data"):
		var data: PackedByteArray = e["data"]
		hc.update(data)
		if zp.write_file(data) != OK:
			zp.close_file()
			return {"ok": false, "error": "Could not write %s" % z}
		progress.advance(data.size(), label)
	else:
		var f := FileAccess.open(str(e["src"]), FileAccess.READ)
		if f == null:
			zp.close_file()
			return {"ok": false, "error": "Could not read %s" % str(e["src"])}
		var left := f.get_length()
		while left > 0:
			if progress.cancelled():
				f.close()
				zp.close_file()
				return {"ok": false, "error": "Cancelled"}
			var chunk := f.get_buffer(mini(left, AssetPackFormat.CHUNK_BYTES))
			if chunk.is_empty():
				break
			hc.update(chunk)
			if zp.write_file(chunk) != OK:
				f.close()
				zp.close_file()
				return {"ok": false, "error": "Could not write %s" % z}
			left -= chunk.size()
			progress.advance(chunk.size(), label)
		f.close()
	zp.close_file()
	return {"ok": true, "sha256": hc.finish().hex_encode()}


static func _discard(paths: Array[String]) -> void:
	for p in paths:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
