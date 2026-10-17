class_name SitePrivacy
extends RefCounted
## Keeps a real site's street address and precise coordinates off the screen
## while the harness is recording (the feature tour's stills and video end up
## in docs/ and the README, which are public once committed).
##
## A world's place label is the reverse-geocoded address of the spot the
## player picked ("23253, State Route 534, …"), and the loading screen, the
## Site Report header and the world panel all print it. Every one of those
## goes through `place()` / `coords()`, which hand back a neutral stand-in
## while `redact` is on. Only DISPLAY text changes: the saved label, the
## geocode results and every coordinate the simulation uses are untouched.
##
## PlaytestHarness turns it on for every harness run (`--show-location`
## turns it back off). Pure static and autoload-free so selftests can load it.

const PLACE_STAND_IN := "this site"
const COORDS_STAND_IN := "location hidden"

static var redact := false


## The place label to show. `fallback` is what a redacted label reads as.
static func place(label: String, fallback: String = PLACE_STAND_IN) -> String:
	return fallback if redact else label


## Latitude / longitude to show, at `decimals` places ("48.3252, -122.2469").
static func coords(lat: float, lon: float, decimals: int = 4) -> String:
	if redact:
		return COORDS_STAND_IN
	var f := "%." + str(decimals) + "f"
	return (f + ", " + f) % [lat, lon]


## The pieces of a place label that identify it: any comma part with a digit
## in it (house number, road number, postcode) plus the label's first two
## parts together, and the coordinates at 3 decimals (~100 m).
static func sensitive_tokens(label: String, lat: float = NAN, lon: float = NAN) -> PackedStringArray:
	var out := PackedStringArray()
	var parts := label.split(",", false)
	for i in parts.size():
		var p := parts[i].strip_edges()
		if p.length() >= 3 and _has_digit(p):
			out.append(p)
	if parts.size() >= 2:
		out.append("%s, %s" % [parts[0].strip_edges(), parts[1].strip_edges()])
	if not is_nan(lat) and not is_nan(lon):
		out.append("%.3f" % lat)
		out.append("%.3f" % lon)
	return out


static func _has_digit(s: String) -> bool:
	for ch in s:
		if ch >= "0" and ch <= "9":
			return true
	return false


## Every visible text Control under `root` that shows one of `tokens`:
## ["<node path>: <token>", …]. What the tour checks before a hero shot.
static func leaks(root: Node, tokens: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	if tokens.is_empty() or root == null:
		return out
	_walk(root, tokens, out)
	return out


static func _walk(n: Node, tokens: PackedStringArray, out: PackedStringArray) -> void:
	if n is CanvasItem and not (n as CanvasItem).is_visible_in_tree():
		return
	if n is CanvasLayer and not (n as CanvasLayer).visible:
		return
	var text := ""
	if n is Label or n is Button or n is LineEdit or n is TextEdit:
		text = str(n.get("text"))
	elif n is RichTextLabel:
		text = (n as RichTextLabel).get_parsed_text()
	if not text.is_empty():
		for t in tokens:
			if text.contains(t):
				out.append("%s: %s" % [n.get_path(), t])
				break
	for c in n.get_children():
		_walk(c, tokens, out)
