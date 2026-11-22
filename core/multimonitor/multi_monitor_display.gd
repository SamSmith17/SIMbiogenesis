class_name MultiMonitorDisplay
extends RefCounted

## Pure OS-screen geometry, fingerprint matching, DWM-safe borderless rects,
## portrait base-canvas sizing, and off-screen window rescue.
##
## Kept stateless and allocation-light so `multi_monitor_selftest.gd` can
## exercise 5-monitor setups (4 landscape + 1 portrait, negative virtual-desktop
## coordinates, shuffled OS screen indices, unplugged displays) offline.

const LANDSCAPE_BASE := Vector2i(1920, 1080)
const PORTRAIT_BASE  := Vector2i(1080, 1920)
const DEFAULT_WIN_LANDSCAPE := Vector2i(1280, 800)
const DEFAULT_WIN_PORTRAIT  := Vector2i(840, 1240)
const MIN_WIN_SIZE := Vector2i(640, 480)
const TITLEBAR_VISIBLE_MIN_W := 140
const TITLEBAR_VISIBLE_H := 44


## Query live OS screens from DisplayServer. Safe when headless (returns []).
static func os_screens() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if DisplayServer.get_name() == "headless":
		return out
	var n := DisplayServer.get_screen_count()
	var primary := DisplayServer.get_primary_screen()
	for i in n:
		var pos := DisplayServer.screen_get_position(i)
		var sz := DisplayServer.screen_get_size(i)
		var usable := DisplayServer.screen_get_usable_rect(i)
		out.append(make_screen_dict(i, pos.x, pos.y, sz.x, sz.y, i == primary, usable))
	return out


## Canonical screen dictionary used by both live DisplayServer queries and tests.
static func make_screen_dict(index: int, x: int, y: int, w: int, h: int,
		is_primary: bool = false, usable: Rect2i = Rect2i()) -> Dictionary:
	var portrait := h > w
	var u := usable if (usable.size.x > 0 and usable.size.y > 0) else Rect2i(x, y, w, h)
	var fp := "%d,%d,%dx%d" % [x, y, w, h]
	return {
		"index": index,
		"x": x,
		"y": y,
		"w": w,
		"h": h,
		"is_portrait": portrait,
		"is_primary": is_primary,
		"usable": u,
		"fingerprint": fp,
	}


static func fingerprint_of(screen: Dictionary) -> String:
	if screen.has("fingerprint") and not str(screen["fingerprint"]).is_empty():
		return str(screen["fingerprint"])
	return "%d,%d,%dx%d" % [
		int(screen.get("x", 0)), int(screen.get("y", 0)),
		int(screen.get("w", 0)), int(screen.get("h", 0)),
	]


static func parse_fingerprint(fp: String) -> Dictionary:
	if fp.is_empty():
		return {}
	var parts := fp.split(",")
	if parts.size() != 3:
		return {}
	var wh := parts[2].split("x")
	if wh.size() != 2:
		return {}
	if not parts[0].is_valid_int() or not parts[1].is_valid_int() \
			or not wh[0].is_valid_int() or not wh[1].is_valid_int():
		return {}
	var w := parts[2].get_slice("x", 0).to_int()
	var h := parts[2].get_slice("x", 1).to_int()
	if w <= 0 or h <= 0:
		return {}
	return {
		"x": parts[0].to_int(),
		"y": parts[1].to_int(),
		"w": w,
		"h": h,
	}


## Match a saved monitor against the current OS screen list.
##
## Order of precedence:
##   1. Exact geometry fingerprint "(x,y,wxh)" — immune to Windows shuffling
##      DisplayServer screen indices 0..N after sleep/wake.
##   2. Same resolution (w, h) whose centre is within 120 px of the saved rect
##      (minor Windows display-arrangement nudge).
##   3. Unique resolution/orientation match (e.g., the single 1080x1920 portrait
##      monitor in a 5-monitor rig whose virtual-desktop origin moved).
##   4. `saved_index` if `saved_fingerprint` was empty and `saved_index` exists.
##   Returns -1 when the saved monitor is disconnected / unknown.
static func resolve_screen(saved_fingerprint: String, saved_index: int, screens: Array) -> int:
	if screens.is_empty():
		return -1
	if not saved_fingerprint.is_empty():
		for s in screens:
			var sd := s as Dictionary
			if fingerprint_of(sd) == saved_fingerprint:
				return int(sd.get("index", -1))
		var parsed := parse_fingerprint(saved_fingerprint)
		if not parsed.is_empty():
			var want_w := int(parsed["w"])
			var want_h := int(parsed["h"])
			var want_c := Vector2(float(parsed["x"]) + want_w * 0.5, float(parsed["y"]) + want_h * 0.5)
			var best_idx := -1
			var best_dist := INF
			var same_size_matches: Array[int] = []
			for s in screens:
				var sd := s as Dictionary
				if int(sd.get("w", 0)) == want_w and int(sd.get("h", 0)) == want_h:
					var idx := int(sd.get("index", -1))
					same_size_matches.append(idx)
					var sc := Vector2(float(sd.get("x", 0)) + want_w * 0.5, float(sd.get("y", 0)) + want_h * 0.5)
					var d := want_c.distance_to(sc)
					if d < best_dist:
						best_dist = d
						best_idx = idx
			if best_idx >= 0 and best_dist <= 120.0:
				return best_idx
			if same_size_matches.size() == 1:
				return same_size_matches[0]
		return -1
	if saved_index >= 0:
		for s in screens:
			if int((s as Dictionary).get("index", -1)) == saved_index:
				return saved_index
	return -1


static func screen_by_index(screens: Array, idx: int) -> Dictionary:
	for s in screens:
		var sd := s as Dictionary
		if int(sd.get("index", -1)) == idx:
			return sd
	return {}


static func primary_screen_index(screens: Array) -> int:
	for s in screens:
		var sd := s as Dictionary
		if bool(sd.get("is_primary", false)):
			return int(sd.get("index", 0))
	if not screens.is_empty():
		return int((screens[0] as Dictionary).get("index", 0))
	return 0


## Which OS screen owns the largest overlap with `win_rect` (or nearest centre).
static func screen_containing_rect(win_rect: Rect2i, screens: Array) -> int:
	if screens.is_empty():
		return 0
	var best_idx := -1
	var best_area := 0
	for s in screens:
		var sd := s as Dictionary
		var sr := Rect2i(int(sd.get("x", 0)), int(sd.get("y", 0)), int(sd.get("w", 0)), int(sd.get("h", 0)))
		var inter := sr.intersection(win_rect)
		var area := inter.size.x * inter.size.y
		if area > best_area:
			best_area = area
			best_idx = int(sd.get("index", 0))
	if best_idx >= 0:
		return best_idx
	var c := Vector2(win_rect.position) + Vector2(win_rect.size) * 0.5
	var nearest_idx := int((screens[0] as Dictionary).get("index", 0))
	var nearest_d := INF
	for s in screens:
		var sd := s as Dictionary
		var sc := Vector2(float(sd.get("x", 0)) + float(sd.get("w", 0)) * 0.5,
			float(sd.get("y", 0)) + float(sd.get("h", 0)) * 0.5)
		var d := c.distance_to(sc)
		if d < nearest_d:
			nearest_d = d
			nearest_idx = int(sd.get("index", 0))
	return nearest_idx


## DWM-safe borderless fullscreen rectangle for `screen`.
##
## On Windows 10/11 with Vulkan (Forward+), a borderless WS_POPUP window whose
## position and size EXACTLY equal a monitor's bounds is promoted by Windows DWM
## into DirectFlip / Exclusive-Fullscreen presentation. On 5-monitor rigs where
## monitors span two GPUs (e.g. 4 on dGPU + 1 on iGPU) or mixed refresh/portrait,
## secondary DirectFlip swapchains fail to present (showing flat grey/black).
## Reducing height by 1 pixel (`h - 1`) keeps the window visually fullscreen
## while keeping it on the standard DWM composed presentation path.
static func dwm_safe_fullscreen_rect(screen: Dictionary, anti_directflip: bool = true) -> Rect2i:
	var x := int(screen.get("x", 0))
	var y := int(screen.get("y", 0))
	var w := maxi(int(screen.get("w", 1920)), 64)
	var h := maxi(int(screen.get("h", 1080)), 64)
	if anti_directflip and h > 64:
		h -= 1
	return Rect2i(x, y, w, h)


## Clean initial draggable windowed rectangle on `screen`, cascaded per slot so
## multiple newly launched windows never stack identically on top of each other.
static func default_windowed_rect(screen: Dictionary, want_portrait: bool, cascade_idx: int = 0) -> Rect2i:
	var usable: Rect2i = screen.get("usable", Rect2i(
		int(screen.get("x", 0)), int(screen.get("y", 0)),
		maxi(int(screen.get("w", 1920)), 800), maxi(int(screen.get("h", 1080)), 600)))
	var margin := 48
	var max_w := maxi(usable.size.x - margin * 2, MIN_WIN_SIZE.x)
	var max_h := maxi(usable.size.y - margin * 2, MIN_WIN_SIZE.y)
	var base := DEFAULT_WIN_PORTRAIT if want_portrait else DEFAULT_WIN_LANDSCAPE
	var w := mini(base.x, max_w)
	var h := mini(base.y, max_h)
	var step := (cascade_idx % 6) * 34
	var x := usable.position.x + maxi((usable.size.x - w) / 2 + step, 24)
	var y := usable.position.y + maxi((usable.size.y - h) / 2 + step, 36)
	if x + w > usable.end.x - 12:
		x = maxi(usable.position.x + 24, usable.end.x - w - 12)
	if y + h > usable.end.y - 12:
		y = maxi(usable.position.y + 36, usable.end.y - h - 12)
	return Rect2i(x, y, w, h)


## Verify a saved windowed rect still has a reachable OS titlebar on at least one
## connected monitor; otherwise rescue it onto the primary screen.
static func rescue_window_rect(win_rect: Rect2i, screens: Array, cascade_idx: int = 0) -> Rect2i:
	var sz := Vector2i(maxi(win_rect.size.x, MIN_WIN_SIZE.x), maxi(win_rect.size.y, MIN_WIN_SIZE.y))
	if screens.is_empty():
		return Rect2i(win_rect.position, sz)
	var title_strip := Rect2i(win_rect.position.x, win_rect.position.y, sz.x, TITLEBAR_VISIBLE_H)
	for s in screens:
		var sd := s as Dictionary
		var sr := Rect2i(int(sd.get("x", 0)), int(sd.get("y", 0)), int(sd.get("w", 0)), int(sd.get("h", 0)))
		var inter := sr.intersection(title_strip)
		if inter.size.x >= TITLEBAR_VISIBLE_MIN_W and inter.size.y >= 16:
			var clamped_sz := Vector2i(mini(sz.x, maxi(sr.size.x - 32, MIN_WIN_SIZE.x)),
				mini(sz.y, maxi(sr.size.y - 48, MIN_WIN_SIZE.y)))
			return Rect2i(win_rect.position, clamped_sz)
	var prim_idx := primary_screen_index(screens)
	var prim := screen_by_index(screens, prim_idx)
	return default_windowed_rect(prim, sz.y > sz.x, cascade_idx)


## Logical base canvas size for `CONTENT_SCALE_MODE_CANVAS_ITEMS`.
## Swaps to 1080x1920 for portrait windows so UI text and panels stay crisp
## instead of shrinking by 1080/1920 (~56%).
static func logical_canvas_size(pixel_size: Vector2i, portrait_override: int = 0) -> Vector2i:
	if portrait_override == 1:
		return PORTRAIT_BASE
	if portrait_override == 2:
		return LANDSCAPE_BASE
	if pixel_size.y > pixel_size.x:
		return PORTRAIT_BASE
	return LANDSCAPE_BASE


static func is_portrait_size(pixel_size: Vector2i, portrait_override: int = 0) -> bool:
	if portrait_override == 1:
		return true
	if portrait_override == 2:
		return false
	return pixel_size.y > pixel_size.x


## Fit all OS monitors proportionally inside `box_size` (for the live monitor
## arrangement diagram in Settings -> Multi-Monitor).
## Returns [{index, rect: Rect2, is_portrait, is_primary, w, h, x, y}, ...].
static func layout_diagram_rects(screens: Array, box_size: Vector2, pad: float = 12.0) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if screens.is_empty() or box_size.x <= pad * 2.0 or box_size.y <= pad * 2.0:
		return out
	var min_x := INF
	var min_y := INF
	var max_x := -INF
	var max_y := -INF
	for s in screens:
		var sd := s as Dictionary
		var x := float(sd.get("x", 0))
		var y := float(sd.get("y", 0))
		var w := maxf(float(sd.get("w", 1920)), 1.0)
		var h := maxf(float(sd.get("h", 1080)), 1.0)
		min_x = minf(min_x, x)
		min_y = minf(min_y, y)
		max_x = maxf(max_x, x + w)
		max_y = maxf(max_y, y + h)
	var span_x := maxf(max_x - min_x, 1.0)
	var span_y := maxf(max_y - min_y, 1.0)
	var avail := Vector2(box_size.x - pad * 2.0, box_size.y - pad * 2.0)
	var scale := minf(avail.x / span_x, avail.y / span_y)
	var draw_sz := Vector2(span_x, span_y) * scale
	var origin := Vector2((box_size.x - draw_sz.x) * 0.5, (box_size.y - draw_sz.y) * 0.5)
	for s in screens:
		var sd := s as Dictionary
		var rx := origin.x + (float(sd.get("x", 0)) - min_x) * scale
		var ry := origin.y + (float(sd.get("y", 0)) - min_y) * scale
		var rw := maxf(float(sd.get("w", 1920)) * scale - 3.0, 24.0)
		var rh := maxf(float(sd.get("h", 1080)) * scale - 3.0, 24.0)
		out.append({
			"index": int(sd.get("index", 0)),
			"rect": Rect2(rx + 1.5, ry + 1.5, rw, rh),
			"is_portrait": bool(sd.get("is_portrait", false)),
			"is_primary": bool(sd.get("is_primary", false)),
			"w": int(sd.get("w", 1920)),
			"h": int(sd.get("h", 1080)),
			"x": int(sd.get("x", 0)),
			"y": int(sd.get("y", 0)),
		})
	return out
