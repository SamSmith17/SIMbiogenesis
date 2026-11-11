extends TourStop

## The Earthship designer and earth-sheltered structures: a tyre-wall
## Earthship placed on open ground opens the terrain over its rooms, berms
## its back to the roof and digs its front down to the floor; walk down the
## ramp, through the door, into the greenhouse.

var _pid := ""


func _init() -> void:
	id = "earthship"
	title = "Earthships and rooms in the ground"
	chapter = "Build"
	summary = "Design an Earthship, place it, and walk down into it: the ground opens over its rooms, earth is piled against its back to the roof, and the front is dug down to the floor."
	how = PackedStringArray(["Library → Designers → Earthship designer…",
		"Pick a layout, the number of U rooms, their size, how far the floor sits below the ground and the greenhouse's glass angle (Best for this site)",
		"Place in world: the terrain opens over the rooms, berms rise on the back and ends, a cut and a ramp lead down to the door",
		"Any placed model can do the same: prop editor → Earthworks (sink, opening, berms per side, a daylight side and a ramp)",
		"A house from the Building Builder can have a basement with a walkout or an areaway",
		"Rain runs off the roof (Roof water to the graph fills a cistern); inside stays near the soil's temperature"])
	button = "Earthship designer…"
	world = "burningman"
	budget_s = 50.0
	hour = 10.5
	blurb = ("Earthships are built into the ground: walls of rammed tyres, the back and ends " +
		"buried to the roof, a sloped wall of glass facing the sun. The designer draws one from a few " +
		"numbers and works out the earth it needs. Placed, it asks the terrain for an opening over its " +
		"rooms, berms against its walls and a cut with a ramp down to the door, and the ground follows " +
		"it when it moves. You walk down the ramp and in; rain runs off the roof into its cisterns, and " +
		"the rooms sit near the temperature of the soil at that depth. The same earthworks sink any " +
		"placed model, and give houses their basements.")


func run(ctx: TourContext) -> void:
	var pps := ctx.klass("PlacedPropService")
	var eb := ctx.klass("EarthshipBuilder")
	var es := ctx.klass("EarthshipSpec")
	var ep := ctx.klass("EarthshipPresets")
	var ed := ctx.klass("EarthshipDesign")
	if not ctx.require(pps != null and eb != null and es != null and ep != null and ed != null
			and ctx.player != null, "the Earthship designer and a player exist"):
		return
	var modal_script: Script = load("res://scenes/ui/earthshiplab_modal.gd")
	var spec: Dictionary = ep.call("builtin", "global_model")
	var modal: Node = modal_script.call("open", ctx.main.get_tree(), {"spec": spec})
	await ctx.wait(1.5)
	ctx.caption("Three U rooms of rammed tyres behind a sloped greenhouse, sunk into the ground", 3.0)
	await ctx.wait(3.0)
	await ctx.shot("designer", true)
	if modal != null and is_instance_valid(modal):
		modal.call("close")
	await ctx.wait(0.5)
	var start := ctx.player_xz()
	var at3: Vector3 = ctx.find_flat(start + Vector2(0.0, -30.0), 20.0, 160.0, 40.0)
	_pid = str(pps.call("place_prepped_at", ctx.main, eb.get("MODEL_ID"),
		{"record_extra": {es.get("KEY"): es.call("to_json_safe", spec), "collision_enabled": true}},
		at3.x, at3.z, 0.0))
	await ctx.wait(2.0)
	if not ctx.require(not _pid.is_empty(), "an Earthship is placed"):
		return
	var d: Dictionary = ed.call("solve", spec)
	var fr: Dictionary = d["frame"]
	var grade := ctx.ground_y(at3.x, at3.z + float(fr["z_front"]) + 12.0)
	var ex := at3.x + float(d["entry_x"])
	var ramp_top := float(fr["z_front"]) + float((d["spec"] as Dictionary)["front_cut"]) \
		+ float((d["earthworks_simple"] as Dictionary)["ramp_len"]) + 1.5
	ctx.caption("Placed: the ground opens over the rooms, earth climbs the back to the roof", 3.0)
	await ctx.fly([[Vector3(at3.x + 16.0, grade + 11.0, at3.z + 24.0), Vector3(at3.x, grade, at3.z - 1.0)]], 3.0)
	await ctx.wait(1.5)
	await ctx.shot("earthship_outside", true)
	ctx.release_camera()
	ctx.player.global_position = Vector3(ex, grade + 0.4, at3.z + ramp_top)
	ctx.player.velocity = Vector3.ZERO
	ctx.aim_player_at(Vector3(ex, grade - 0.5, at3.z))
	await ctx.wait(1.0)
	ctx.caption("Down the ramp and through the door", 3.0)
	await ctx.hold(["move_forward"], 3.0)
	var floor_y := grade + float(fr["yf"])
	ctx.require(ctx.player.global_position.y < grade - 0.3, "the walk went down below the ground")
	# Stand in the greenhouse, looking along the glass toward the rooms.
	ctx.player.global_position = Vector3(ex + 3.0, floor_y + 0.1, at3.z + float(fr["door_z"]) - 1.2)
	ctx.player.velocity = Vector3.ZERO
	ctx.aim_player_at(Vector3(ex - 6.0, floor_y + 1.3, at3.z + 0.5))
	await ctx.wait(0.8)
	ctx.caption("The greenhouse: glass to the sun, the rooms behind, below the ground outside", 3.5)
	await ctx.turn_player(-12.0, 2.0)
	await ctx.hero(true)
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	if not _pid.is_empty():
		ctx.remove_prop(_pid)
	_pid = ""
