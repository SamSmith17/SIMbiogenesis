extends TourStop

const MODAL_SCRIPT := "res://scenes/ui/intermodal_unit_modal.gd"

var _node: Node = null


func _init() -> void:
	id = "intermodal_units"
	title = "Intermodal units"
	chapter = "Labs"
	summary = "Shipping containers, pallets and crates at real ISO and GMA sizes, ready to pack or place."
	how = PackedStringArray(["Library → Structures → Intermodal unit designer…",
		"Pick a container or pallet and adjust it",
		"Place it on the site, or open it in the Packing Lab"])
	action = ""
	button = "Library → Structures → Intermodal unit designer…"
	world = "burningman"
	budget_s = 30.0
	hour = 14.0
	blurb = ("Every unit carries its interior, door opening, tare and payload, so the " +
		"Packing Lab knows what really fits and what a forklift has to lift.")


func run(ctx: TourContext) -> void:
	var script := load(MODAL_SCRIPT) as Script
	if not ctx.require(script != null, "the intermodal unit designer script loads"):
		return
	_node = script.call("open", ctx.tree(), "iso_20")
	await ctx.wait(1.2)
	if not ctx.require(_node != null and is_instance_valid(_node), "the intermodal unit designer opened"):
		return
	ctx.caption("A 20 ft ISO container: interior, door opening, tare and payload", 3.0)
	await ctx.wait(2.0)
	await ctx.hero()
	await ctx.wait(1.0)


func teardown(_ctx: TourContext) -> void:
	if _node != null and is_instance_valid(_node) and _node.has_method("close"):
		_node.call("close")
	_node = null
