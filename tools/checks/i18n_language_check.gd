extends RefCounted

## Localization Phase 1 (plans/LOCALIZATION_PLAN.md) on a real world (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/i18n_language_check.gd -Label i18n_langs
## For each proof-of-concept language (I18N_LANGS, default es,zh_Hans,ar,hi):
## switch to it live, open Settings on Interface and on Lighting and the
## graph's top bar, count the visible labels and buttons that read in that
## language (a label whose drawn text differs from its English source), run
## the UI audit (text cut off, overlapping), and take shots. English comes
## back at the end. Uses I18n.apply, never writes ui_prefs.cfg.

var _fails: Array = []
var _dir := "user://screenshots/i18n_langs"
## A real word (3+ letters): chips like "E●" and clock times are not counted.
var _word := RegEx.create_from_string("\\p{L}{3,}")


func _ok(cond: bool, what: String, detail: String = "") -> void:
	print("i18n-langs %s: %s%s" % ["PASS" if cond else "FAIL", what, ("  (" + detail + ")") if detail else ""])
	if not cond:
		_fails.append(what)


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [ProjectSettings.globalize_path(_dir), name])


## [translated, total] over visible Labels / Buttons with letters.
func _count(n: Node, acc: Array) -> void:
	if n is CanvasItem and not (n as CanvasItem).is_visible_in_tree():
		return
	if (n is Label or n is Button) and String(n.text).strip_edges().length() >= 3:
		var src := String(n.text)
		if _word.search(src) != null:
			acc[1] += 1
			var shown := String(n.atr(src)) if n.can_auto_translate() else src
			if shown != src or _not_latin(src):
				acc[0] += 1
			elif acc[2].size() < 10:
				acc[2].append(src.replace("\n", " ").left(48))
	for c in n.get_children():
		_count(c, acc)


## A label set already translated (I18n.t / f) holds the translation itself.
func _not_latin(s: String) -> bool:
	for ch in s:
		var u := ch.unicode_at(0)
		if u >= 0x0370 and not (u >= 0x2000 and u <= 0x2BFF) and u < 0x1F000:
			return true
	return false


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	if harness != null and "shots_dir" in harness and str(harness.get("shots_dir")).begins_with("user://"):
		_dir = str(harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	var langs := OS.get_environment("I18N_LANGS")
	var codes: PackedStringArray = (langs if not langs.is_empty() else "es,zh_Hans,ar,hi").split(",")
	var tl: Node = main.find_child("TimelineUI", true, false)
	_ok(tl != null, "TimelineUI found")
	if tl == null:
		return {"ok": false, "fails": _fails}
	for code in codes:
		_ok(I18n.has_file(code), "%s has a translation file" % code)
		I18n.apply(code)
		await tree.create_timer(0.3).timeout
		_ok(I18n.locale() == code, "switched live to %s" % code)
		for page in ["Interface", "Lighting"]:
			tl.call("open_settings_page", page)
			await tree.create_timer(0.6).timeout
			var acc := [0, 0, []]
			# Only the Settings panel itself (the timeline row is counted apart).
			var sp: Variant = tl.get("_settings_panel")
			_count(sp if sp is Node else tree.root, acc)
			var share := float(acc[0]) / maxf(1.0, float(acc[1]))
			_ok(share >= 0.5, "%s Settings → %s mostly in the language" % [code, page],
				"%d of %d labels (%d %%); still English: %s" % [acc[0], acc[1], int(round(share * 100.0)),
				" | ".join(PackedStringArray(acc[2]))])
			var audit: Dictionary = UiAudit.run(main.get_viewport())
			print("i18n-langs audit %s %s: %d errors, %d warnings %s" % [code, page,
				int(audit.get("errors", 0)), int(audit.get("warnings", 0)), str(audit.get("counts", {}))])
			await _shot(main, "%s_settings_%s" % [code, page.to_lower()])
		var panel: Variant = tl.get("_settings_panel")
		if panel is Node and (panel as Node).has_method("close"):
			(panel as Node).call("close")
		await tree.create_timer(0.3).timeout
		await _shot(main, "%s_hud" % code)
	I18n.apply("en")
	await tree.create_timer(0.3).timeout
	_ok(I18n.locale() == "en", "English comes back")
	return {"ok": _fails.is_empty(), "fails": _fails}
