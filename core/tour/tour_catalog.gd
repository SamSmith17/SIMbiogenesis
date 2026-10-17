class_name TourCatalog
extends RefCounted

## Finds the tour's stops (one script per file in STOPS_DIR, ordered by file
## name) and filters them for a run. Pure enough to run under `--script`: the
## selftest uses the same discovery the tour does.

const STOPS_DIR := "res://core/tour/stops"
const TEMPLATE_FILE := "_template.gd"


## Every stop script path, sorted by file name ("03_drone.gd" < "10_graph.gd").
## Files starting with "_" are not stops (the template).
static func stop_paths() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var da := DirAccess.open(STOPS_DIR)
	if da == null:
		return out
	for f in da.get_files():
		var name := f.trim_suffix(".remap")
		if not name.ends_with(".gd") or name.begins_with("_"):
			continue
		out.append("%s/%s" % [STOPS_DIR, name])
	out.sort()
	return out


## Instantiate one stop. Returns null (and says why) when the file is not a
## TourStop.
static func load_stop(path: String) -> TourStop:
	var script := load(path) as Script
	if script == null or not script.can_instantiate():
		push_error("TourCatalog: %s did not load" % path)
		return null
	var obj: Variant = script.new()
	if not (obj is TourStop):
		push_error("TourCatalog: %s does not extend TourStop" % path)
		return null
	var stop := obj as TourStop
	if stop.id.is_empty():
		stop.id = path.get_file().get_basename().trim_prefix(
			path.get_file().get_basename().get_slice("_", 0) + "_")
	return stop


static func all_stops() -> Array:
	var out: Array = []
	for p in stop_paths():
		var s := load_stop(p)
		if s != null:
			out.append(s)
	return out


## Filter: `ids` (empty = all), `chapters` (empty = all), `world` (empty =
## any), optional stops only with `include_optional` or when named in `ids`.
## Order is the file order, chapters grouped as the files already are.
static func select(stops: Array, ids: PackedStringArray, chapters: PackedStringArray,
		world: String, include_optional: bool) -> Array:
	var out: Array = []
	var want_ids := {}
	for i in ids:
		want_ids[i.strip_edges().to_lower()] = true
	var want_ch := {}
	for c in chapters:
		want_ch[c.strip_edges().to_lower()] = true
	for s0 in stops:
		var s := s0 as TourStop
		var named := want_ids.has(s.id.to_lower())
		if not want_ids.is_empty() and not named:
			continue
		if not want_ch.is_empty() and not want_ch.has(s.chapter.to_lower()):
			continue
		if not world.is_empty() and s.world != world:
			continue
		if s.optional and not include_optional and not named:
			continue
		out.append(s)
	return out


## The worlds a selection needs, in first-use order.
static func worlds_of(stops: Array) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for s0 in stops:
		var w := (s0 as TourStop).world
		if not (w in out):
			out.append(w)
	return out
