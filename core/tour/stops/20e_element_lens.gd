extends TourStop

## Colour by element and "Where it goes": the graph's wires coloured and
## sized by the nitrogen (then the water) they carry, with dotted stubs for
## what each node gives to or takes from the air; then the nitrogen
## followed through the site as a Sankey over the hours the clock ran.
## The player's lens is put back.

var _lens_was := ""


func _init() -> void:
	id = "element_lens"
	title = "Where the nitrogen goes"
	chapter = "Systems"
	summary = "Colour every wire by the element it carries and follow it through the site."
	how = PackedStringArray(["Press G, then Show ▾ → Colour by element → Nitrogen (or water, carbon …)",
		"Show ▾ → Where it goes… follows it from source to sink",
		"Timeline → Tracks ▾ → Add water & nutrients track"])
	action = "system_graph_toggle"
	world = "walton"
	budget_s = 50.0
	hour = 13.0
	blurb = ("Every kind of resource is made of something: urine of water, urea and salts; " +
		"food of protein, fat and starch; down to carbon, nitrogen, phosphorus and potassium. " +
		"Colour the graph by one of them and each wire shows how much of it it carries, with " +
		"dotted stubs where people breathe it out or plants take it from the air. Where it goes " +
		"follows it through the site as a Sankey, over the hours the clock has run, and the " +
		"timeline can track what the stores hold and how much used water comes back clean.")


func run(ctx: TourContext) -> void:
	if not ctx.require(await ctx.open_graph("freeform"), "the graph opened"):
		return
	var g := ctx.graph
	_lens_was = str(g.call("element_lens"))
	# A camp's own wires carry the flows: open the busiest camp.
	var camp := _busiest_camp(g)
	if not camp.is_empty():
		g.call("focus_graph_item", camp, true)
		await ctx.wait(1.6)
		var cv: Variant = g.get("_graph_canvas")
		var model: Variant = g.get("model")
		if cv != null and model != null:
			var ids: Array = []
			for it in model.call("get_items_in_scope", str(g.get("_active_scope_id"))):
				ids.append(str((it as Dictionary).get("id", "")))
			cv.call("fit_items_to_view", ids, 0.08)
			await ctx.wait(0.8)
	ctx.run_clock(600.0)
	await ctx.wait(1.5)
	ctx.caption("Show ▾ → Colour by element → Nitrogen", 3.0)
	g.call("set_element_lens", "N", false)
	await ctx.wait(2.2)
	var canvas: Variant = g.get("_graph_canvas")
	ctx.require(canvas != null and str(canvas.get("element_lens")) == "N", "the nitrogen lens is on")
	ctx.caption("Each wire is as wide as the nitrogen it carries", 3.5)
	await ctx.wait(2.5)
	await ctx.hero()
	ctx.caption("Water: dotted stubs are what people breathe out", 3.5)
	g.call("set_element_lens", "water", false)
	await ctx.wait(3.0)
	await ctx.shot("water")
	ctx.caption("Show ▾ → Where it goes… follows it from source to sink", 3.5)
	g.call("open_element_sankey", "N")
	await ctx.wait(3.0)
	await ctx.shot("sankey_nitrogen")
	await ctx.wait(1.5)


## The camp compound with the most people present ("" when there is none).
func _busiest_camp(g: Node) -> String:
	var model: Variant = g.get("model")
	if model == null:
		return ""
	var best := ""
	var best_n := -1
	for it in model.call("get_items_in_scope", "root"):
		var d: Dictionary = it
		var sp: Dictionary = d.get("specs", {})
		if str(sp.get("camp_lot_id", "")).is_empty():
			continue
		var n := int(sp.get("camp_present", sp.get("camp_headcount", 0)))
		if n > best_n:
			best_n = n
			best = str(d.get("id", ""))
	return best


func teardown(ctx: TourContext) -> void:
	for n in ctx.tree().root.get_children():
		var s: Script = n.get_script()
		if s != null and s.resource_path.ends_with("element_sankey_modal.gd"):
			var f: Variant = n.get("_frame")
			if f != null:
				f.call("close")
	var g := ctx.graph
	if g != null:
		g.call("set_element_lens", _lens_was, false)
	ctx.run_clock(0.0)
	if g != null:
		g.call("_jump_to_scope_index", 0)
	ctx.close_graph()
