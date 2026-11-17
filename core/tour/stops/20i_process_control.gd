extends TourStop

## The Process lens: a plant drawn the way an operator sees it. A template
## (a tank held at a level by a PID loop) is dropped in with its control
## block, alarms, a gauge and a trend; the clock runs and the loop settles.
## Everything the stop adds is taken out again.

var _view_was := ""
var _ids: Array = []
var _logic_was: Array = []
var _alarms_was: Array = []
var _screens_was: Dictionary = {}
var _added := false


func _init() -> void:
	id = "process_control"
	title = "Process control: valves, loops, alarms"
	chapter = "Systems"
	summary = "The graph as a plant picture, with control loops, alarms, gauges and trends."
	how = PackedStringArray(["Press G, then the Process lens",
		"Templates drops in a whole process; Lessons teaches it in five steps",
		"Logic, Alarms, Widgets, Trends and Hardware are in the bar under the picture"])
	action = "system_graph_toggle"
	world = "mtvernon"
	budget_s = 50.0
	hour = 13.0
	blurb = ("The Process lens draws the piped part of the graph as tanks, pipes, valves and pumps. " +
		"Click anything for its faceplate. Control blocks (on / off bands, PID loops, interlocks, " +
		"sequences) run on the site's clock; alarms flash until acknowledged; gauges, buttons and " +
		"trends can be set down on the picture and on extra screens. Templates drop in a whole " +
		"process and can be shared as a code. With Home Assistant connected, in Live mode and armed, " +
		"the same tags can drive real devices.")


func run(ctx: TourContext) -> void:
	if not ctx.require(await ctx.open_graph("freeform"), "the graph opened"):
		return
	var g := ctx.graph
	var pack_cls: Script = ctx.klass("ProcessPack")
	var hub: Node = g.call("scada_hub") if g.has_method("scada_hub") else null
	if not ctx.require(pack_cls != null and hub != null and g.has_method("process_insert"), "process templates are available"):
		return
	_view_was = str(g.get("_graph_view_mode"))
	var canvas: Variant = g.get("_graph_canvas")
	_logic_was = (hub.call("logic_blocks") as Array).duplicate(true)
	_alarms_was = (hub.call("alarm_rules") as Array).duplicate(true)
	_screens_was = (canvas.call("process_screens_data") as Dictionary).duplicate(true)
	g.call("_on_mode_chip_pressed", "process")
	await ctx.wait(0.6)
	var res: Dictionary = g.call("process_insert", pack_cls.call("template", "level_pid"), Vector2(0.0, -6000.0), true)
	if not ctx.require(bool(res.get("ok", false)), "the template went in"):
		return
	_added = true
	_ids = (res["ids"] as Dictionary).values()
	var lens: Variant = canvas.call("process_lens")
	if lens != null:
		lens.call("refresh", true)
		lens.call("fit")
	ctx.caption("A whole process from a template: tanks, a control valve, a PID loop, alarms", 3.5)
	await ctx.wait(2.0)
	ctx.run_clock(90.0)
	ctx.caption("The loop moves the valve until the level sits on its setpoint", 3.5)
	await ctx.wait(4.0)
	await ctx.hero()
	if g.has_method("open_trend_window"):
		ctx.run_clock(0.0)
		var day := ""
		for k in (res["ids"] as Dictionary):
			if str(k) == "day":
				day = str(res["ids"][k])
		var tw: Node = g.call("open_trend_window", "tank.%s.level" % day)
		ctx.caption("Trends: any readings over time on one chart", 3.0)
		await ctx.wait(2.5)
		if tw != null and is_instance_valid(tw):
			tw.call("close")
	await ctx.wait(0.5)


func teardown(ctx: TourContext) -> void:
	var g := ctx.graph
	if g == null:
		return
	ctx.run_clock(0.0)
	var hub: Node = g.call("scada_hub") if g.has_method("scada_hub") else null
	if _added:
		var model: Variant = g.get("model")
		var canvas: Variant = g.get("_graph_canvas")
		if model != null:
			for iid in _ids:
				model.call("remove_item", str(iid))
		if hub != null:
			hub.call("set_logic_blocks", _logic_was)
			hub.call("set_alarm_rules", _alarms_was)
			var pens: Array = hub.call("trend_pens")
			var keep: Array = []
			for p in pens:
				var mine := false
				for iid in _ids:
					mine = mine or str(p).contains(str(iid))
				if not mine:
					keep.append(p)
			hub.call("set_trend_pens", keep)
		if canvas != null:
			canvas.call("set_process_screens_data", _screens_was)
		_added = false
	g.call("_on_mode_chip_pressed", _view_was if _view_was != "" else "freeform")
	ctx.close_graph()
