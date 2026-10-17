extends TourStop


func _init() -> void:
	id = "npc_anim_editor"
	title = "NPC animation editor"
	chapter = "People"
	summary = "Key-frame how people saw, drill, lift and carry — with the tool in their hands."
	how = PackedStringArray(["Settings ⚙ → NPC → Animation editor…",
		"Click a joint, drag the gizmo ring, K adds a key, Ctrl+S saves"])
	button = "⚙ → NPC → Animation editor…"
	world = "walton"
	budget_s = 30.0
	hour = 14.0
	blurb = ("Fabrication clips are authored on the same stick figure the crews use, in " +
		"the context of the real job — a saw on its bench, a drill at the hole — with " +
		"the hands held to the tool's grips by IK. Saved clips are picked up by the " +
		"build crews at once.")


func run(ctx: TourContext) -> void:
	var ed: Variant = ctx.main.call("open_npc_anim_editor", "drill_hole")
	await ctx.wait(2.0)
	if not ctx.require(ed != null and is_instance_valid(ed) and bool((ed as CanvasItem).visible),
			"the animation editor opened"):
		return
	ctx.caption("A drilling clip, played in its job context", 3.0)
	if (ed as Object).has_method("_toggle_play"):
		ed.call("_toggle_play")
	elif "_playing" in ed:
		ed.set("_playing", true)
	await ctx.wait(3.5)
	await ctx.hero()
	await ctx.wait(1.5)


func teardown(ctx: TourContext) -> void:
	var ed: Variant = ctx.main.get("npc_anim_editor_ui")
	if ed != null and is_instance_valid(ed):
		ed.call("close")
