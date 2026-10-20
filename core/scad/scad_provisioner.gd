class_name ScadProvisioner
extends Node

## On-demand + updatable OpenSCAD install manager. We deliberately do NOT commit
## the ~120 MB GPL binary to git (same rationale as the gitignored asset pack in
## docs/ASSETS.md): the game runs fine without it, and the parametric store prompts to
## install when first used. Installs land in versioned folders under
## user://tools/openscad/<version>/ keyed by a small JSON manifest, so "update"
## is just fetching a newer version alongside and repointing — no reinstall, no
## git churn.
##
## Layout:
##   user://tools/openscad/manifest.json         { active: "<ver>", installs: {...} }
##   user://tools/openscad/<version>/openscad(.exe)
##
## Pure logic (manifest/version/plan) is static and offline-testable. The actual
## network fetch (request_install) is an instance method that owns an HTTPRequest;
## it is the permission-gated step and is never triggered automatically.

const MANAGED_ROOT := "user://tools/openscad"
const MANIFEST := "user://tools/openscad/manifest.json"

## Default release the store offers to fetch. The download URL is intentionally
## read from config/descriptor rather than hardcoded, so a wrong/stale URL can't
## ship baked in — confirm the exact release artifact URL before enabling
## one-click install (see PARAMETRIC_STORE_PLAN.md Phase 0).
const DEFAULT_VERSION := "2021.01"

signal install_progress(fraction: float, note: String)
signal install_finished(ok: bool, version: String, reason: String)

var _http: HTTPRequest = null
var _pending: Dictionary = {}


# ---------------------------------------------------------------------------
# Pure status / manifest logic (static, offline-testable)
# ---------------------------------------------------------------------------

## True when no usable OpenSCAD binary is resolvable anywhere (config, managed,
## system, PATH) — i.e. the store should offer to install one.
static func needs_install() -> bool:
	return not ScadRuntime.is_available()


## Versions we've installed under the managed root (dirs that actually hold a
## binary), newest-sorted.
static func installed_versions() -> PackedStringArray:
	var out := PackedStringArray()
	var root := ProjectSettings.globalize_path(MANAGED_ROOT)
	if not DirAccess.dir_exists_absolute(root):
		return out
	var names := Array(DirAccess.get_directories_at(root))
	names.sort()
	names.reverse()
	for name in names:
		if not _dir_has_binary(root.path_join(String(name))):
			continue
		out.append(String(name))
	return out


static func read_manifest() -> Dictionary:
	if not FileAccess.file_exists(MANIFEST):
		return {"active": "", "installs": {}}
	var f := FileAccess.open(MANIFEST, FileAccess.READ)
	if f == null:
		return {"active": "", "installs": {}}
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"active": "", "installs": {}}
	if not parsed.has("installs"):
		parsed["installs"] = {}
	if not parsed.has("active"):
		parsed["active"] = ""
	return parsed


static func write_manifest(manifest: Dictionary) -> bool:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(MANAGED_ROOT))
	var f := FileAccess.open(MANIFEST, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(manifest, "  "))
	f.close()
	return true


## Record a freshly extracted install and make it active. source is free-form
## provenance (URL) for the credits/audit trail.
static func record_install(version: String, source: String = "") -> bool:
	var m := read_manifest()
	var installs: Dictionary = m.get("installs", {})
	installs[version] = {
		"version": version,
		"source": source,
		"installed_at": Time.get_datetime_string_from_system(true),
		"dir": "%s/%s" % [MANAGED_ROOT, version],
	}
	m["installs"] = installs
	m["active"] = version
	return write_manifest(m)


## Descriptor for fetching a version: where it downloads from, and where it lands.
## url resolution: explicit arg -> [openscad] download_url_<version> in
## user://terrain_config.cfg -> "" (caller must supply / confirm before install).
static func plan_install(version: String = DEFAULT_VERSION, url: String = "") -> Dictionary:
	var resolved_url := url
	if resolved_url.is_empty():
		resolved_url = _config_download_url(version)
	var dest_dir := "%s/%s" % [MANAGED_ROOT, version]
	var archive := "%s/_dl/openscad-%s.zip" % [MANAGED_ROOT, version]
	return {
		"version": version,
		"url": resolved_url,
		"dest_dir": dest_dir,
		"archive_path": archive,
		"ready": not resolved_url.is_empty(),
	}


# ---------------------------------------------------------------------------
# Network install (permission-gated instance method — never auto-invoked)
# ---------------------------------------------------------------------------

## Downloads + extracts the planned version, then records it active. Emits
## install_progress / install_finished. This performs a large (~100+ MB) network
## download and MUST only be called after explicit user opt-in in the UI.
func request_install(descriptor: Dictionary) -> void:
	if not descriptor.get("ready", false) or String(descriptor.get("url", "")).is_empty():
		install_finished.emit(false, String(descriptor.get("version", "")),
			"No download URL configured — set [openscad] download_url_<ver>= in "
			+ "user://terrain_config.cfg or pass one explicitly (confirm the "
			+ "official OpenSCAD release artifact first).")
		return
	_pending = descriptor
	var archive_abs := ProjectSettings.globalize_path(String(descriptor["archive_path"]))
	DirAccess.make_dir_recursive_absolute(archive_abs.get_base_dir())
	if _http == null:
		_http = HTTPRequest.new()
		add_child(_http)
		_http.request_completed.connect(_on_download_done)
	_http.download_file = archive_abs
	install_progress.emit(0.0, "Downloading OpenSCAD %s…" % descriptor["version"])
	var err := _http.request(String(descriptor["url"]))
	if err != OK:
		install_finished.emit(false, String(descriptor["version"]),
			"Download request failed to start (err %d)" % err)


func _on_download_done(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	var version := String(_pending.get("version", ""))
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		install_finished.emit(false, version, "Download failed (result %d, HTTP %d)" % [result, code])
		return
	install_progress.emit(0.6, "Extracting…")
	var ok := _extract_zip(String(_pending["archive_path"]), String(_pending["dest_dir"]))
	if not ok:
		install_finished.emit(false, version, "Extraction failed")
		return
	# Confirm a binary actually landed before recording.
	if not _dir_has_binary(ProjectSettings.globalize_path(String(_pending["dest_dir"]))):
		install_finished.emit(false, version, "Archive extracted but no openscad binary found inside")
		return
	record_install(version, String(_pending.get("url", "")))
	install_progress.emit(1.0, "Installed")
	install_finished.emit(true, version, "")


## Native zip extraction via ZIPReader (no external tool). Flattens the archive
## into dest_dir; ScadRuntime._binary_in_dir handles a one-level-deep exe.
## Downloaded-and-extracted content is untrusted: every entry is validated to stay
## within dest_dir (zip-slip guard) and the total/per-file size is capped so a
## malicious or corrupt archive can't write outside the managed root or fill the
## disk. Any rejected entry fails the whole extraction.
const MAX_ENTRY_BYTES := 512 * 1024 * 1024   # 512 MB per file
const MAX_TOTAL_BYTES := 1024 * 1024 * 1024  # 1 GB per archive

func _extract_zip(archive_path: String, dest_dir: String) -> bool:
	var reader := ZIPReader.new()
	if reader.open(archive_path) != OK:
		return false
	var dest_abs := ProjectSettings.globalize_path(dest_dir).simplify_path()
	DirAccess.make_dir_recursive_absolute(dest_abs)
	# Trailing separator so "/rootevil" can't pass a naive prefix check on "/root".
	var dest_prefix := dest_abs.trim_suffix("/") + "/"
	var total_bytes := 0
	for entry in reader.get_files():
		if not _entry_path_is_safe(entry):
			push_warning("ScadProvisioner: rejected unsafe zip entry '%s'" % entry)
			reader.close()
			return false
		var target := dest_abs.path_join(entry).simplify_path()
		# Zip-slip guard: the resolved target must live under dest_abs.
		if target != dest_abs and not target.begins_with(dest_prefix):
			push_warning("ScadProvisioner: zip entry '%s' escapes install dir" % entry)
			reader.close()
			return false
		if entry.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(target)
			continue
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var data := reader.read_file(entry)
		if data.size() > MAX_ENTRY_BYTES:
			push_warning("ScadProvisioner: zip entry '%s' exceeds per-file cap" % entry)
			reader.close()
			return false
		total_bytes += data.size()
		if total_bytes > MAX_TOTAL_BYTES:
			push_warning("ScadProvisioner: archive exceeds total-size cap")
			reader.close()
			return false
		var out := FileAccess.open(target, FileAccess.WRITE)
		if out == null:
			reader.close()
			return false
		out.store_buffer(data)
		out.close()
	reader.close()
	# Best-effort exec bit on unix (Godot can't chmod; note for the installer UI).
	return true


## An archive entry path is safe when it is relative and contains no parent-dir
## (`..`) segment and no absolute/drive root — the two ways a crafted zip walks
## out of the extraction directory. Static so scad_selftest can exercise it
## offline; the rule itself is SafeZip's, shared with asset packs.
static func _entry_path_is_safe(entry: String) -> bool:
	return SafeZip.entry_is_safe(entry)


# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

static func _dir_has_binary(dir_abs: String) -> bool:
	var names := PackedStringArray(["openscad.exe", "openscad.com", "openscad", "OpenSCAD"])
	for n in names:
		if FileAccess.file_exists(dir_abs.path_join(n)):
			return true
	if DirAccess.dir_exists_absolute(dir_abs):
		for sub in DirAccess.get_directories_at(dir_abs):
			for n in names:
				if FileAccess.file_exists(dir_abs.path_join(String(sub)).path_join(n)):
					return true
	return false


static func _config_download_url(version: String) -> String:
	var cfg := ConfigFile.new()
	if cfg.load("user://terrain_config.cfg") != OK:
		return ""
	return str(cfg.get_value("openscad", "download_url_%s" % version, "")).strip_edges()
