extends TourStop


func _init() -> void:
	id = "multiplayer"
	title = "Play together"
	chapter = "Labs"
	summary = "Host or join a shared world; Discord sign-in, chat and live design sync."
	how = PackedStringArray(["Click the Multiplayer chip on the timeline",
		"Host to get a join code, or paste one to join; Enter opens chat"])
	button = "Multiplayer"
	world = "burningman"
	budget_s = 30.0
	hour = 14.0
	blurb = ("A listen server with no servers of ours: the host's world, clock and " +
		"simulation are authoritative, guests see the people and the graph streamed " +
		"live, can possess an NPC, and a Discord community file handles identity, " +
		"discovery and an optional chat mirror.")


func run(ctx: TourContext) -> void:
	if not ctx.require(ctx.timeline != null, "the timeline exists"):
		return
	ctx.timeline.call("_on_mp_pressed")
	await ctx.wait(1.5)
	var lobby: Variant = ctx.timeline.get("_mp_lobby")
	ctx.require(lobby != null and is_instance_valid(lobby) and bool((lobby as CanvasItem).visible),
		"the lobby opened")
	ctx.caption("Host, join by code, or play with your Discord community", 3.0)
	await ctx.wait(3.0)
	await ctx.hero()
	await ctx.wait(1.0)


func teardown(ctx: TourContext) -> void:
	var lobby: Variant = ctx.timeline.get("_mp_lobby") if ctx.timeline != null else null
	if lobby != null and is_instance_valid(lobby) and bool((lobby as CanvasItem).visible):
		lobby.call("close")
