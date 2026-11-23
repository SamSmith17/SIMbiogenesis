extends RefCounted

## Localization, Phase 0 (plans/LOCALIZATION_PLAN.md), on a real world (sandbox):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/i18n_pseudo_check.gd -Label i18n_pseudo
## The harness runs in English; the picker lists the pseudo-locales (debug
## build); switching to en_XA LIVE re-translates open Controls; Settings →
## Interface is shot in en_XA and ar_XB (right to left) for review; the share
## of visible text that went through translation is counted (the rest is the
## Phase 2 to-do list); English comes back. Never writes ui_prefs.cfg (uses
## I18n.apply, not set_pref).

var _fails: Array = []
var _dir := ""


func _ok(cond: bool, what: String, detail: String = "") -> void:
	print("i18n-check %s: %s%s" % ["PASS" if cond else "FAIL", what, ("  (" + detail + ")") if detail else ""])
	if not cond:
		_fails.append(what)


func _shot(main: Node, name: String) -> void:
	await RenderingServer.frame_post_draw
	main.get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])


func _visible_texts(n: Node, out: Array) -> void:
	if n is CanvasItem and not (n as CanvasItem).is_visible_in_tree():
		return
	if (n is Label or n is Button) and String(n.text).strip_edges().length() >= 3:
		# `text` is the source; what is drawn is its translation (atr follows
		# the node's auto_translate_mode).
		var s := String(n.atr(n.text)) if n.can_auto_translate() else String(n.text)
		if s.to_lower() != s.to_upper():  # has letters
			out.append(s)
	for c in n.get_children():
		_visible_texts(c, out)


func run(main: Node, harness: Node) -> Dictionary:
	var tree := main.get_tree()
	_dir = "user://screenshots/i18n_pseudo"
	if harness != null and "shots_dir" in harness and str(harness.get("shots_dir")).begins_with("user://"):
		_dir = str(harness.get("shots_dir"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_dir))
	_ok(I18n.locale() == "en", "a harness run is in English", I18n.locale())
	var avail := I18n.available()
	_ok("en_XA" in avail and "ar_XB" in avail, "pseudo-locales listed in a debug build", str(avail))
	var tl: Node = main.find_child("TimelineUI", true, false)
	_ok(tl != null and tl.has_method("open_settings_page"), "TimelineUI found")
	if tl == null:
		return {"ok": false, "fails": _fails}
	tl.call("open_settings_page", "Interface")
	await tree.create_timer(0.6).timeout
	var picker: Node = tree.root.find_child("language_picker", true, false)
	_ok(picker is OptionButton, "Settings → Interface has the language picker")
	if picker is OptionButton:
		var labels := []
		for i in (picker as OptionButton).item_count:
			labels.append((picker as OptionButton).get_item_text(i))
		_ok(labels.size() >= 3 and String(labels[0]).begins_with("Auto"), "picker lists Auto + languages", ", ".join(labels))
	await _shot(main, "00_settings_en")

	for code in ["en_XA", "ar_XB"]:
		I18n.apply(code)
		await tree.create_timer(0.5).timeout
		_ok(I18n.locale() == code, "switched live to %s" % code)
		var texts := []
		_visible_texts(tree.root, texts)
		var wrapped := 0
		for s in texts:
			if String(s).contains("[!") or String(s).contains("\u202e"):
				wrapped += 1
		var share := float(wrapped) / maxf(1.0, float(texts.size()))
		_ok(wrapped > 0, "%s: visible text goes through translation" % code,
			"%d of %d labels/buttons (%d %%)" % [wrapped, texts.size(), int(round(share * 100.0))])
		if code == "en_XA":
			var sample := []
			for s in texts:
				if not String(s).contains("[!") and sample.size() < 12:
					sample.append(String(s).replace("\n", " ").left(60))
			print("i18n-check not translated yet (sample): ", " | ".join(sample))
		await _shot(main, "01_settings_%s" % code)
	I18n.apply("en")
	await tree.create_timer(0.4).timeout
	var after := []
	_visible_texts(tree.root, after)
	var left := 0
	for s in after:
		if String(s).contains("[!"):
			left += 1
	_ok(I18n.locale() == "en" and left == 0, "English comes back live", "%d pseudo labels left" % left)
	return {"ok": _fails.is_empty(), "fails": _fails}
