extends RefCounted

## The gameplay spine, on a real world (sandbox):
##   tools\harness.ps1 -World walton -RunScript res://tools/checks/first_run_probe.gd -Label first_run -Timeout 900
## The needs strip (four chips on the timeline, one per closure channel,
## reading the graph's closure metrics), the mission chip (idle text, the
## running challenge's progress, idle again after an abort), the first-mission
## offer (the picker opens once nothing covers it), the starter seed (a fresh
## model takes it, a world with a habitat refuses it), the guided-start
## hand-off through MapContext, and the live feature tour (starts on this
## world's stops, Esc / cancel ends it).

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("first-run %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _frames(tree: SceneTree, n: int) -> void:
	for _i in n:
		await tree.process_frame


func _wait(tree: SceneTree, s: float) -> void:
	await tree.create_timer(s).timeout


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var tl: Control = main.get_node_or_null("UILayer/TimelineUI")
	_ok(tl != null, "TimelineUI found")
	if tl == null:
		return {"ok": false, "fails": _fails}
	if is_instance_valid(CursorController):
		CursorController.set_paused(true)
	tl.call("set_bar_mode", 0, false)
	await _frames(tree, 4)

	# -- The needs strip ---------------------------------------------------
	var chips: Dictionary = tl.get("_needs_chips")
	_ok(chips.size() == 4, "four needs chips built (got %d)" % chips.size())
	for kind in ["energy", "water", "food", "waste"]:
		var b: Button = chips.get(kind) as Button
		_ok(b != null and b.is_inside_tree(), "needs chip '%s' is a Button in the tree" % kind)
	tl.call("_update_needs_strip")
	await _frames(tree, 2)
	var filled := 0
	var live := 0
	for kind in chips.keys():
		var b: Button = chips[kind] as Button
		if b == null:
			continue
		if not b.text.is_empty():
			filled += 1
		if b.text.find("○") < 0:
			live += 1
		print("first-run: chip %s = '%s' — %s" % [kind, b.text, b.tooltip_text])
	_ok(filled == 4, "every chip carries icon + letter + glyph")
	_ok(live >= 1, "at least one channel reads a status on this world (%d live)" % live)

	# -- The mission chip --------------------------------------------------
	var chip: Button = tl.get("_challenge_chip") as Button
	_ok(chip != null and chip.is_inside_tree(), "mission chip built")
	if chip != null:
		_ok(chip.text == "🎯 Mission", "mission chip idle text (got '%s')" % chip.text)
	var runner: Node = main.get_node_or_null("ChallengeRunner")
	_ok(runner != null, "ChallengeRunner exists")
	if runner != null and chip != null:
		var started := bool(runner.call("start_challenge_id", "keep_lights_on"))
		_ok(started, "Keep the Lights On starts")
		await _wait(tree, 1.5)
		tl.call("_update_challenge_chip")
		await _frames(tree, 2)
		print("first-run: mission chip while running = '%s'" % chip.text)
		_ok(chip.text.begins_with("🎯") and chip.text.find("/72h") >= 0,
			"mission chip shows the running challenge's progress")
		runner.call("abort_challenge")
		await _wait(tree, 1.5)
		tl.call("_update_challenge_chip")
		await _frames(tree, 2)
		_ok(chip.text == "🎯 Mission", "mission chip idle again after the abort (got '%s')" % chip.text)

	# -- The first-mission offer -------------------------------------------
	if main.has_method("offer_first_mission"):
		main.call("offer_first_mission", false)
		var picker: Control = null
		for _i in 40:
			await _wait(tree, 0.1)
			picker = tl.get("_challenge_picker_panel") as Control
			if picker != null and picker.visible:
				break
		_ok(picker != null and picker.visible, "offer_first_mission opens the mission picker")
		if picker != null and picker.has_method("close"):
			picker.call("close")
			await _frames(tree, 2)
	else:
		_ok(false, "Main.offer_first_mission exists")

	# -- The starter seed --------------------------------------------------
	var fresh := GraphModel.new()
	_ok(PuzzleStarterGraphSeeder.seed_graph(fresh, 1), "a fresh model takes the starter seed")
	_ok(PuzzleStarterGraphSeeder.has_starter_content(fresh), "the seed is marked as the starter")
	_ok(not PuzzleStarterGraphSeeder.seed_graph(fresh, 1), "seeding twice is refused")
	var gv := ServiceLocator.graph()
	if gv != null:
		var model: GraphModel = gv.get("model")
		if model != null and PuzzleStarterGraphSeeder.has_habitat(model):
			_ok(not bool(gv.call("try_seed_puzzle_starter", 1)),
				"a world that already has a habitat refuses the starter seed")

	# -- The guided-start hand-off ------------------------------------------
	var ctx := tree.root.get_node_or_null("MapContext")
	_ok(ctx != null, "MapContext autoload")
	if ctx != null:
		ctx.call("set_pending", 1.0, 2.0, "probe", 0.0, false, 0.0, 0.0, false)
		_ok(not bool(ctx.get("starter_kit")) and not bool(ctx.get("tour_on_load")),
			"set_pending clears the guided flags")
		ctx.set("starter_kit", true)
		ctx.set("tour_on_load", true)
		var d: Dictionary = ctx.call("consume")
		_ok(bool(d.get("starter_kit", false)) and bool(d.get("tour_on_load", false)),
			"consume() hands the guided flags over")
		_ok(not bool(ctx.get("starter_kit")) and not bool(ctx.get("tour_on_load")),
			"consume() resets them")

	# -- The live tour -------------------------------------------------------
	_ok(main.has_method("start_feature_tour"), "Main.start_feature_tour exists")
	if main.has_method("start_feature_tour"):
		main.call("start_feature_tour")
		await _wait(tree, 2.5)
		var director: Node = main.get_node_or_null("FeatureTour")
		_ok(director != null and bool(main.call("is_feature_tour_running")), "the tour is running")
		if director != null:
			_ok(bool(director.get("live")), "the tour runs in live mode")
			var alias := str(director.get("world_alias"))
			print("first-run: tour world alias = %s" % alias)
			_ok(alias == "walton", "the tour picked this world's own stops (got '%s')" % alias)
			director.call("cancel")
			var t0 := Time.get_ticks_msec()
			while bool(main.call("is_feature_tour_running")) and Time.get_ticks_msec() - t0 < 120000:
				await _wait(tree, 0.5)
			_ok(not bool(main.call("is_feature_tour_running")),
				"cancel() ends the tour after the current stop (%.1f s)" % ((Time.get_ticks_msec() - t0) / 1000.0))
			await _frames(tree, 3)   # queue_free lands on the next idle frame
			_ok(main.get_node_or_null("FeatureTour") == null, "the director is freed")

	if is_instance_valid(CursorController):
		CursorController.set_paused(false)
	return {"ok": _fails.is_empty(), "fails": _fails}
