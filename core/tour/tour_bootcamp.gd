class_name TourBootcamp
extends RefCounted

## Shared by the Solar Bootcamp tour stops (27_bootcamp, 27a, 27b): start a
## level, press "Let's go" on its brief, wire ports with real drags on the
## freeform canvas (the tour's pointer shows them), wait for the level's
## outcome. The same moves `--capture=bootcamp` (BootcampAudit) makes, at a
## pace a viewer can follow.
##
## TutorialDirector.State (gameplay/tutorial_director.gd).
const STATE_BUILD := 2
const STATE_DEBRIEF := 3
const STATE_CELEBRATE := 4


static func director(ctx: TourContext) -> Variant:
	if ctx.graph == null:
		return null
	return ctx.graph.call("_ensure_tutorial_director")


## Start level `index` (1-based) in the tutorial sandbox (it opens the graph
## and shows the brief). Returns the director or null.
static func start_level(ctx: TourContext, index: int) -> Variant:
	var td: Variant = director(ctx)
	if td == null:
		return null
	var cat := ctx.klass("TutorialCatalog")
	var ids: Array = cat.call("ordered_ids") if cat != null else []
	if index < 1 or index > ids.size():
		return null
	if bool(td.call("is_active")):
		td.call("exit_tutorial")
		await ctx.frames(4)
	td.call("start", str(ids[index - 1]))
	await ctx.frames(6)
	return td if bool(td.call("is_active")) else null


## "Let's go" on the brief, clicked the way a player clicks it.
static func dismiss_brief(ctx: TourContext, td: Variant) -> void:
	if not await ctx.click_button("Let's go"):
		var m: Variant = ctx.graph.get("_fault_card_modal")
		if m != null:
			m.call("close")
		td.call("_on_brief_done")
	await ctx.frames(4)


## Ease the canvas onto the level's circuit: the seeded nodes fill the canvas
## between the level card (top) and the caption (bottom), at most `max_zoom`.
## The bootcamp itself never zooms past 1×, which left a three-node circuit a
## small island in the middle of a 1080p frame.
static func frame_circuit(ctx: TourContext, seconds: float = 0.9, max_zoom: float = 2.2) -> void:
	var canvas := ctx.graph.get("_graph_canvas") as Control
	var gl := ctx.klass("GraphLayout")
	if canvas == null or gl == null or ctx.cancelled:
		return
	var model: Object = ctx.graph.get("model")
	var its: Array = gl.call("filter_layout_items", model.call("get_items_in_scope", "root"))
	if its.is_empty():
		return
	var b: Rect2 = gl.call("content_bounds", its)
	b = b.grow(70.0)
	var k := float(canvas.get_viewport().get_visible_rect().size.y) / 1080.0
	var area := Rect2(Vector2(40.0, 150.0 * k), canvas.size - Vector2(80.0, 150.0 * k + 120.0 * k))
	var view: Dictionary = canvas.call("_view_for_bbox_in_rect", b, area)
	if not bool(view.get("ok", false)):
		return
	var z1 := minf(float(view["zoom"]), max_zoom)
	# Re-solve the pan for the capped zoom (the rect's centre stays the target).
	var gc := b.get_center()
	var rc := area.get_center()
	var p1: Vector2 = rc - canvas.size * 0.5 - gc * z1
	var z0 := float(canvas.get("_zoom"))
	var p0 := canvas.get("_pan") as Vector2
	var dur := maxf(seconds * ctx.pace, 0.05)
	var t := 0.0
	while t < dur and not ctx.cancelled:
		var u := smoothstep(0.0, 1.0, t / dur)
		canvas.set("_zoom", lerpf(z0, z1, u))
		canvas.set("_pan", p0.lerp(p1, u))
		canvas.queue_redraw()
		await ctx.frames(1)
		t += ctx.host.get_process_delta_time()
	canvas.set("_zoom", z1)
	canvas.set("_pan", p1)
	canvas.queue_redraw()
	await ctx.frames(2)


## Root-scope items of a type, left to right.
static func items(ctx: TourContext, type: String) -> Array:
	var model: Object = ctx.graph.get("model")
	var out: Array = []
	for it in model.call("get_items_in_scope", "root"):
		if str((it as Dictionary).get("type", "")) == type:
			out.append(it)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a.get("x", 0.0)) < float(b.get("x", 0.0)))
	return out


## A port's position in the viewport, or Vector2.INF.
static func port_screen(ctx: TourContext, item: Dictionary, handle_id: String) -> Vector2:
	var canvas: Variant = ctx.graph.get("_graph_canvas")
	if canvas == null:
		return Vector2.INF
	var model: Object = ctx.graph.get("model")
	var live: Dictionary = model.call("get_item", str(item.get("id", "")))
	var infos: Array = canvas.call("_get_all_handle_infos", live, (canvas as Control).size * 0.5)
	for h: Dictionary in infos:
		if str(h.get("handle_id", "")) == handle_id:
			return (canvas as Control).get_global_transform_with_canvas() * (h["pos"] as Vector2)
	return Vector2.INF


## Drag a wire from one port to another over `seconds`. Falls back to adding
## the connection through the model (and says so in the manifest) if the drag
## made none, so the level can still play out.
static func wire(ctx: TourContext, a: Dictionary, ah: String, b: Dictionary, bh: String,
		seconds: float = 1.1) -> bool:
	if ctx.cancelled:
		return false
	var model: Object = ctx.graph.get("model")
	var before := (model.get("connections") as Array).size()
	var pa := port_screen(ctx, a, ah)
	var pb := port_screen(ctx, b, bh)
	if pa != Vector2.INF and pb != Vector2.INF:
		await ctx.drag_to(pa, pb, seconds)
		await ctx.frames(3)
	if (model.get("connections") as Array).size() > before:
		return true
	ctx.note("the %s.%s → %s.%s drag made no wire; added it directly" % [
		str(a.get("type")), ah, str(b.get("type")), bh])
	var pol := "negative" if ah.to_lower().contains("neg") else "positive"
	model.call("add_connection", {"scope_id": str(a.get("scope_id", "root")), "polarity": pol,
		"source_item_id": str(a.get("id")), "source_handle_id": ah,
		"target_item_id": str(b.get("id")), "target_handle_id": bh})
	ctx.graph.call("_check_electrical_faults")
	return false


## Wait until the director reaches `state` (or `timeout_s` passes).
static func wait_state(ctx: TourContext, td: Variant, state: int, timeout_s: float) -> bool:
	var t := 0.0
	while not ctx.cancelled and t < timeout_s:
		if int(td.get("_state")) == state:
			return true
		await ctx.wait(0.1)
		t += 0.1
	return int(td.get("_state")) == state


## Leave the tutorial (the player's own graph comes back) and close the graph.
static func finish(ctx: TourContext) -> void:
	ctx.hide_pointer()
	var td: Variant = ctx.graph.get("_tutorial_director") if ctx.graph != null else null
	if td != null and is_instance_valid(td) and bool(td.call("is_active")):
		td.call("exit_tutorial")
		await ctx.frames(10)
	ctx.close_graph()
