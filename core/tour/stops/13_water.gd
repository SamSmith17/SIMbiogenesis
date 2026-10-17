extends TourStop

var _saved_mode := ""


func _init() -> void:
	id = "water"
	title = "Streams and drainage"
	chapter = "Build"
	summary = "Mapped streams carved into the land, with real flow, drainage and culverts."
	how = PackedStringArray(["Open the edit toolbar (T) and pick the WATER section",
		"Trace / Draw / Edit / Culvert / View tools",
		"View → flow shows the water moving at its Manning velocity"])
	action = "terrain_edit"
	button = "WATER section"
	world = "mtvernon"
	budget_s = 40.0
	hour = 14.0
	blurb = ("OSM waterways and the player's own streams are one network: carved into " +
		"the terrain, drawn level in their channels, sized by real hydraulics, and fed " +
		"by rain on their catchments at the clock's time. A stream can feed a " +
		"turbine's penstock or a pond on the systems graph.")


func run(ctx: TourContext) -> void:
	var wn: Node = ctx.loader.get_node_or_null("WaterNetwork") if ctx.loader != null else null
	if not ctx.require(wn != null, "the water network exists"):
		return
	var feats: Array = wn.call("features")
	var best: Dictionary = {}
	var bd := INF
	for ft in feats:
		var m2: Variant = _midpoint((ft as Dictionary).get("points", []))
		if m2 == null:
			continue
		var d := (m2 as Vector2).distance_to(ctx.player_xz())
		if d < bd:
			bd = d
			best = ft
	if not ctx.require(not best.is_empty(), "there is a stream on this map"):
		return
	var m: Vector2 = _midpoint(best["points"])
	var c := Vector3(m.x, ctx.ground_y(m.x, m.y), m.y)
	var tb: Variant = ctx.loader.get("_edit_toolbar_ui")
	if tb != null and is_instance_valid(tb):
		tb.call("open_with_section", "water")
	var layer: Variant = wn.get("layer")
	if layer != null and (layer as Object).has_method("setting"):
		_saved_mode = str(layer.call("setting", "display_mode"))
	ctx.caption("%s — carved into the land" % str(best.get("name", "Stream")), 3.0)
	await ctx.orbit(c, 45.0, 32.0, 20.0, 70.0, 4.0)
	wn.call("set_display_mode", "flow")
	ctx.caption("Flow view: beads move at the stream's real velocity", 3.0)
	await ctx.orbit(c, 45.0, 32.0, 70.0, 100.0, 3.5)
	await ctx.hero()


## The middle vertex of a feature's polyline as xz (points may be Vector2 xz
## or Vector3), or null.
func _midpoint(pts: Variant) -> Variant:
	var n := 0
	if pts is PackedVector2Array or pts is PackedVector3Array or pts is Array:
		n = pts.size()
	if n < 2:
		return null
	var mid: Variant = pts[n / 2]
	if mid is Vector2:
		return mid
	if mid is Vector3:
		return Vector2(mid.x, mid.z)
	return null


func teardown(ctx: TourContext) -> void:
	var wn: Node = ctx.loader.get_node_or_null("WaterNetwork") if ctx.loader != null else null
	if wn != null and not _saved_mode.is_empty():
		wn.call("set_display_mode", _saved_mode)
	var tb: Variant = ctx.loader.get("_edit_toolbar_ui") if ctx.loader != null else null
	if tb != null and is_instance_valid(tb) and bool((tb as Control).visible):
		tb.call("_exit_mode")
