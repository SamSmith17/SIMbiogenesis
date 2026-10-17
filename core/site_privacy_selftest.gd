extends SceneTree
## SitePrivacy (offline): redaction on/off, the identifying tokens a place
## label yields, and the visible-text leak walk the tour runs before every
## hero shot (hidden nodes are not leaks).
##   Godot --headless --path . --script core/site_privacy_selftest.gd

const EXPECTED_CHECKS := 16

var _checks := 0
var _fails := 0


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_fails += 1
		print("  FAIL: ", what)


func _initialize() -> void:
	# The visibility walk needs nodes INSIDE the tree; the root is not in-tree
	# during _initialize, so run on the first process frame.
	_run.call_deferred()


func _run() -> void:
	var label := "123, Example Road, Smalltown, Some County, Washington, 98000, United States"
	SitePrivacy.redact = false
	_check(SitePrivacy.place(label) == label, "redaction off shows the label")
	_check(SitePrivacy.coords(48.32521, -122.24693) == "48.3252, -122.2469", "redaction off shows coords")
	_check(SitePrivacy.coords(48.32521, -122.24693, 6) == "48.325210, -122.246930", "decimals honoured")
	SitePrivacy.redact = true
	_check(SitePrivacy.place(label) == SitePrivacy.PLACE_STAND_IN, "redacted label")
	_check(SitePrivacy.place(label, "map") == "map", "redacted label takes a fallback")
	_check(SitePrivacy.coords(48.3, -122.2) == SitePrivacy.COORDS_STAND_IN, "redacted coords")

	var tokens := SitePrivacy.sensitive_tokens(label, 48.32521, -122.24693)
	_check("123" in tokens, "house number is a token")
	_check("98000" in tokens, "postcode is a token")
	_check("123, Example Road" in tokens, "first two parts together are a token")
	_check("48.325" in tokens and "-122.247" in tokens, "coords at 3 dp are tokens")
	_check(not ("United States" in tokens) and not ("Washington" in tokens), "region names alone are not tokens")
	_check(SitePrivacy.sensitive_tokens("Black Rock City, Nevada").size() == 1, "a numberless label yields only its head")

	var root := Control.new()
	var shown := Label.new()
	shown.text = "Site Report — 123, Example Road, Smalltown"
	root.add_child(shown)
	var hidden := Label.new()
	hidden.text = "Loading 123, Example Road"
	hidden.visible = false
	root.add_child(hidden)
	var safe := Button.new()
	safe.text = "Site Report — this site"
	root.add_child(safe)
	get_root().add_child(root)
	var found := SitePrivacy.leaks(root, tokens)
	_check(found.size() == 1, "one visible leak found (got %d)" % found.size())
	_check(found.size() > 0 and str(found[0]).contains(str(shown.name)), "the leak names the visible label")
	shown.text = "Site Report — %s" % SitePrivacy.place(label)
	_check(SitePrivacy.leaks(root, tokens).is_empty(), "redacted text is clean")
	_check(SitePrivacy.leaks(root, PackedStringArray()).is_empty(), "no tokens, no leaks")
	root.free()
	SitePrivacy.redact = false

	if _checks != EXPECTED_CHECKS:
		_fails += 1
		print("  FAIL: ran %d checks, expected %d" % [_checks, EXPECTED_CHECKS])
	print("site_privacy_selftest: %s (%d checks, %d failed)" % ["PASS" if _fails == 0 else "FAIL", _checks, _fails])
	quit(0 if _fails == 0 else 1)
