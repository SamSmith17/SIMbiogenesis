extends TourStop


func _init() -> void:
	id = "prop_editor"
	title = "Placed things and the prop editor"
	chapter = "Build"
	summary = "Place real equipment from the library and move it with a gumball."
	how = PackedStringArray(["Press U for the library and place a model",
		"Click a placed thing to open its editor: move / rotate gizmo, fire, model tools",
		"M toggles placed-props mode"])
	action = "toggle_library"
	world = "mtvernon"
	budget_s = 35.0
	hour = 14.0
	blurb = ("Turbines, shade structures, tanks, vehicles and imported models are placed " +
		"in the world and bound to their nodes on the systems graph. One editor " +
		"handles every placed thing: a world/local gumball, duplicate and delete, " +
		"and the model's own tools.")


func run(ctx: TourContext) -> void:
	var recs := ctx.prop_records(func(r: Dictionary) -> bool:
		return not bool(r.get("packed", false)) and not str(r.get("model_id", "")).begins_with("cargo"))
	var rec := ctx.nearest(recs)
	if not ctx.require(not rec.is_empty(), "there is a placed prop on this map"):
		return
	var at := ctx.prop_position(rec)
	var f := (at - ctx.player.global_position)
	f.y = 0.0
	f = f.normalized() if f.length() > 0.1 else ctx.player_forward()
	var eye := at - f * 9.0 + Vector3.UP * 4.5
	ctx.place_camera(eye, at + Vector3.UP * 1.0)
	await ctx.wait(0.8)
	var ui: Node = ctx.main.get_node_or_null("UILayer/PlacedPropEditUI")
	if not ctx.require(ui != null, "the prop editor exists"):
		return
	ui.call("open_for_prop", str(rec.get("id", "")))
	ctx.caption("%s — move, rotate, duplicate, delete" % str(rec.get("name", rec.get("model_id", "Prop"))), 3.5)
	await ctx.fly([[eye, at + Vector3.UP], [at - f.rotated(Vector3.UP, 0.5) * 8.0 + Vector3.UP * 3.5, at + Vector3.UP]], 4.0)
	await ctx.hero()
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	var ui: Node = ctx.main.get_node_or_null("UILayer/PlacedPropEditUI")
	if ui != null:
		ui.call("close")
