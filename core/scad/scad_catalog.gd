class_name ScadCatalog
extends RefCounted

## Pure logic for the parametric-store library: scan a folder of .scad files,
## parse each one's Customizer schema (ScadParamParser), detect external library
## dependencies, infer a rough category, and reconcile against the credits ledger
## so nothing ships uncredited. The rendering/validation + file writes live in the
## scad_ingest.gd runner (needs the OpenSCAD binary); everything here is offline
## and deterministic so it can be self-tested. See PARAMETRIC_STORE_PLAN.md Phase 2.

const ParserScript := preload("res://core/scad/scad_param_parser.gd")

## filename keyword -> store category (first hit wins; order matters).
const CATEGORY_KEYWORDS := [
	["fan", "fans"],
	["duct", "ducts"],
	["vent", "ducts"],
	["hose", "adapters"],
	["reducer", "adapters"],
	["adapter", "adapters"],
	["coupler", "adapters"],
	["turbine", "energy"],
	["impeller", "energy"],
	["vase", "vessels"],
	["cup", "vessels"],
	["bowl", "vessels"],
	["pot", "vessels"],
	["planter", "vessels"],
	["box", "containers"],
	["bin", "containers"],
	["case", "containers"],
	["bracket", "hardware"],
	["mount", "hardware"],
	["gear", "hardware"],
	["knob", "hardware"],
]


## Stable part id from a filename (basename without extension).
static func part_id(filename: String) -> String:
	return filename.get_file().get_basename()


## Rough store category from filename keywords; "uncategorized" if none match.
static func infer_category(filename: String) -> String:
	var low := filename.get_file().to_lower()
	for pair in CATEGORY_KEYWORDS:
		if low.contains(pair[0]):
			return pair[1]
	return "uncategorized"


## External libraries a file pulls in: use <lib> / include <lib>. A non-empty
## result means the file can't stand alone unless that library is also bundled.
static func detect_dependencies(text: String) -> Array:
	var deps: Array = []
	var re := RegEx.new()
	re.compile("^\\s*(use|include)\\s*<([^>]+)>")
	for raw in text.split("\n"):
		var m := re.search(String(raw))
		if m:
			var target := m.get_string(2).strip_edges()
			if not deps.has(target):
				deps.append(target)
	return deps


## Builds a catalog entry for one .scad file (parse + deps + category + license
## reconciliation). No rendering. credits_entries is credits.json's "entries"
## array, used to resolve license_status by matching local_path filename.
static func build_entry(res_path: String, credits_entries: Array) -> Dictionary:
	var filename := res_path.get_file()
	var pid := part_id(filename)
	var schema: Dictionary = ParserScript.parse_file(res_path)
	var text := ""
	var abs := ProjectSettings.globalize_path(res_path)
	if FileAccess.file_exists(abs):
		var f := FileAccess.open(abs, FileAccess.READ)
		if f != null:
			text = f.get_as_text()
			f.close()
	var deps := detect_dependencies(text)
	var lic := license_status_for(filename, credits_entries)

	var parse_ok: bool = schema.get("ok", false)
	# Shippable readiness is decided later (also needs a successful render); here we
	# capture the structural blockers we already know.
	var blockers: Array = []
	if not parse_ok:
		blockers.append("parse_failed")
	if not deps.is_empty():
		blockers.append("needs_dependency")
	if lic != "verified":
		blockers.append("license_%s" % lic)

	return {
		"id": pid,
		"source_file": filename,
		"res_path": res_path,
		"title": schema.get("title", pid),
		"category": infer_category(filename),
		"parse_ok": parse_ok,
		"param_count": (schema.get("params", []) as Array).size(),
		"params": schema.get("params", []),
		"groups": schema.get("groups", []),
		"warnings": schema.get("warnings", []),
		"dependencies": deps,
		"credits_id": "scad-%s" % pid,
		"license_status": lic,
		"blockers": blockers,
		# render{} filled in by the runner; status finalized there too.
		"render": {"ok": null, "reason": "not rendered"},
		"status": "pending",
	}


## Resolve a part's license from the credits ledger by matching the source file
## name inside any entry's local_path. Returns "verified" | "pending-verification"
## | "missing" (no ledger entry at all -> must be quarantined).
static func license_status_for(filename: String, credits_entries: Array) -> String:
	for e in credits_entries:
		if typeof(e) != TYPE_DICTIONARY:
			continue
		var lp := String(e.get("local_path", ""))
		if lp.is_empty():
			continue
		if lp.get_file() == filename:
			return String(e.get("status", "pending-verification"))
	return "missing"


## Produce a pending-verification credits stub for a part with no ledger entry.
## Idempotent at the call site (only call when license_status == "missing").
static func make_credits_stub(entry: Dictionary) -> Dictionary:
	return {
		"id": entry.get("credits_id", "scad-%s" % entry.get("id", "unknown")),
		"name": entry.get("title", entry.get("id", "SCAD part")),
		"category": "scad-part",
		"role": "Parametric OpenSCAD part in the in-game hardware store",
		"author": null,
		"source": null,
		"license": "pending",
		"attribution_required": null,
		"share_alike": null,
		"commercial_ok": null,
		"local_path": entry.get("res_path", ""),
		"status": "pending-verification",
		"notes": ("Auto-added by scad_ingest. Confirm the original Thingiverse/"
			+ "Printables thing URL + license before shipping; reject if CC-BY-NC "
			+ "or CC-BY-ND. Quarantined until a license is recorded."),
	}


## Decide a part's final ship status given its render outcome. The RENDER is the
## real arbiter of whether dependencies are satisfied (siblings copied alongside,
## or MCAD bundled with OpenSCAD) — so dependencies are recorded for info but do
## not by themselves quarantine; a genuinely missing lib manifests as a render
## failure instead.
## "ready"      = renders + permissive license (CC-BY / -SA / CC0 / MIT …)
## "review"     = renders, but license is NC or ND (usable in dev; a licensing
##                decision is required before shipping — parametrizing an ND work
##                is a derivative; NC blocks commercial forks)
## "usable-dev" = renders, but license still pending-verification
## "quarantined"= render failed/absent, or no ledger entry at all (license missing)
static func finalize_status(entry: Dictionary) -> String:
	var render: Dictionary = entry.get("render", {})
	# ok==false => tried and failed (broken). ok==null => not validated (unknown,
	# don't punish — the UI renders on demand anyway). ok==true => renders.
	var render_failed: bool = render.get("ok", null) == false
	var lic := String(entry.get("license_status", "missing"))
	if render_failed or lic == "missing":
		return "quarantined"
	match lic:
		"verified":
			return "ready"
		"restricted":
			return "review"
		_:
			return "usable-dev"


# -- License-document parsing (Thingiverse LICENSE.txt) ------------------------

## Classifies a Thingiverse-style LICENSE.txt into a structured license record.
## Handles both the rich form ("Title (URL) by AUTHOR is licensed under the
## Creative Commons - Attribution - Share Alike license.\n<cc-url>") and the terse
## form ("This thing was created by Thingiverse user AUTHOR, and is licensed under
## cc-nc."), plus empty templates. Never guesses beyond the text: unrecognized ->
## spdx "unknown".
static func classify_license(text: String) -> Dictionary:
	var out := {
		"spdx": "unknown", "author": "", "title": "", "source_url": "",
		"attribution_required": true, "share_alike": false,
		"non_commercial": false, "no_derivatives": false, "restricted": false,
		"raw": text.strip_edges().left(300),
	}
	var low := text.to_lower()

	# Flags from either a CC URL slug or the prose terms.
	var slug := ""
	var re_cc := RegEx.new()
	re_cc.compile("creativecommons\\.org/licenses/([a-z0-9-]+)/")
	var m := re_cc.search(low)
	if m:
		slug = m.get_string(1)
	if slug.is_empty():
		# Terse code: "...licensed under cc-nc." / "cc-sa" / "cc" / "cc0"
		var re_code := RegEx.new()
		re_code.compile("licensed under\\s+(cc[a-z0-9-]*|public domain|pd|gpl|lgpl|bsd|mit)")
		var mc := re_code.search(low)
		if mc:
			var code := mc.get_string(1)
			slug = _slug_from_terse(code)

	var nc := slug.contains("nc") or low.contains("non-commercial") or low.contains("noncommercial")
	var nd := slug.contains("nd") or low.contains("no derivative") or low.contains("noderiv")
	var sa := slug.contains("sa") or low.contains("share alike") or low.contains("sharealike")
	var pd := slug == "cc0" or slug == "zero" or slug == "pd" or low.contains("public domain")

	out["non_commercial"] = nc
	out["no_derivatives"] = nd
	out["share_alike"] = sa
	out["restricted"] = nc or nd
	out["spdx"] = _spdx_from_flags(slug, nc, nd, sa, pd, m)
	if pd:
		out["attribution_required"] = false

	# Author / title / source URL (rich form first, then terse).
	var re_rich := RegEx.new()
	re_rich.compile("(?i)^\\s*(.+?)\\s*\\((https?://[^)]+)\\)\\s*by\\s+(.+?)\\s+is licensed")
	var mr := re_rich.search(text)
	if mr:
		out["title"] = mr.get_string(1).strip_edges()
		out["source_url"] = mr.get_string(2).strip_edges()
		out["author"] = mr.get_string(3).strip_edges()
	else:
		var re_by := RegEx.new()
		re_by.compile("(?i)\\bby\\s+(.+?)\\s+is licensed")
		var mby := re_by.search(text)
		if mby:
			out["author"] = mby.get_string(1).strip_edges()
		var re_user := RegEx.new()
		re_user.compile("(?i)Thingiverse user\\s+([^,]+?)\\s*,")
		var mu := re_user.search(text)
		if mu:
			out["author"] = mu.get_string(1).strip_edges()
	if out["source_url"] == "":
		var re_url := RegEx.new()
		re_url.compile("(https?://(?:www\\.)?thingiverse\\.com/thing:\\d+)")
		var murl := re_url.search(text)
		if murl:
			out["source_url"] = murl.get_string(1)
	return out


static func _slug_from_terse(code: String) -> String:
	match code:
		"cc": return "by"
		"cc-sa": return "by-sa"
		"cc-nc": return "by-nc"
		"cc-nd": return "by-nd"
		"cc-nc-sa": return "by-nc-sa"
		"cc-nc-nd": return "by-nc-nd"
		"cc0", "pd", "public domain": return "cc0"
		_: return code  # gpl/mit/bsd pass through


static func _spdx_from_flags(slug: String, nc: bool, nd: bool, sa: bool, pd: bool, cc_url_match: Variant) -> String:
	if pd:
		return "CC0-1.0"
	if slug in ["gpl", "lgpl", "bsd", "mit"]:
		return slug.to_upper()
	# Determine CC version if a URL supplied one; default 3.0 (Thingiverse era).
	var version := "3.0"
	if cc_url_match != null:
		var re_ver := RegEx.new()
		re_ver.compile("/([0-9]\\.[0-9])/")
		var mv := re_ver.search(String(cc_url_match.get_string(0)))
		if mv:
			version = mv.get_string(1)
	# Build "CC-BY[-NC][-SA][-ND]-<ver>" only when we actually recognized CC terms.
	if slug.begins_with("by") or slug.contains("nc") or slug.contains("sa") or slug.contains("nd"):
		var parts := PackedStringArray(["CC", "BY"])
		if nc:
			parts.append("NC")
		if nd:
			parts.append("ND")
		elif sa:
			parts.append("SA")
		return "%s-%s" % ["-".join(parts), version]
	return "unknown"


## Maps a classified license to a catalog license_status:
##   "verified"   permissive enough to ship (CC-BY, CC-BY-SA, CC0, MIT/BSD…)
##   "restricted" known but NC or ND (needs a licensing decision before ship)
##   "pending-verification" text present but unrecognized
static func license_status_from_classification(lic: Dictionary) -> String:
	if String(lic.get("spdx", "unknown")) == "unknown":
		return "pending-verification"
	if lic.get("restricted", false):
		return "restricted"
	return "verified"


# -- README extraction (for the store UI) --------------------------------------

## Pulls a human description out of a Thingiverse README.txt: strips the ASCII-art
## banner, prefers the "# Summary" section, falls back to the first prose
## paragraph. Returns "" if nothing usable. Capped to keep the catalog lean.
static func extract_readme_description(text: String, max_chars: int = 700) -> String:
	var lines := text.split("\n")
	# Prefer the Summary section.
	var summary: Array = []
	var in_summary := false
	for raw in lines:
		var line := String(raw)
		var t := line.strip_edges()
		if t.to_lower().begins_with("# summary"):
			in_summary = true
			continue
		if in_summary:
			if t.begins_with("#"):  # next heading ends the section
				break
			summary.append(t)
	var body := "\n".join(summary).strip_edges()
	if body.is_empty():
		# Fallback: first run of "prose" lines (mostly alphanumeric, has a space).
		var prose: Array = []
		for raw in lines:
			var t := String(raw).strip_edges()
			if t.is_empty():
				if not prose.is_empty():
					break
				continue
			if _is_banner_line(t) or t.begins_with("http") or t.begins_with("#"):
				continue
			prose.append(t)
		body = " ".join(prose).strip_edges()
	# Collapse whitespace and cap.
	body = body.replace("\r", " ")
	while body.contains("  "):
		body = body.replace("  ", " ")
	if body.length() > max_chars:
		body = body.substr(0, max_chars).strip_edges() + "…"
	return body


static func _is_banner_line(line: String) -> bool:
	if line.is_empty():
		return true
	var alnum := 0
	for i in line.length():
		if line[i].to_lower() != line[i].to_upper() or line[i].is_valid_int():
			alnum += 1
	# Banner rows are mostly punctuation (:,.` etc).
	return float(alnum) / float(line.length()) < 0.35
