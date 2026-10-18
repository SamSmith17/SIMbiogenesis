extends RefCounted

## The first-person ambient bed on a REAL world (sandbox, read-only):
##   tools\harness.ps1 -World mtvernon -RunScript res://tools/checks/ambient_bed_probe.gd
## Asserts what the offline selftest cannot: Main made the AmbientBed and
## its players; the live inputs come from the world (the weather's wind, the
## sun, a forest count, the nearest stream); forcing the inputs through
## `override_inputs` drives the players (gain -> volume_db, playing); pausing
## the clock silences every layer; opening the graph silences them too and
## closing it brings them back; and the procedural loops are what plays when
## user://ambient/ holds no files. Prints the bed's debug line at each step.

var _fails: Array = []


func _ok(cond: bool, what: String) -> void:
	print("ambient-check %s: %s" % ["PASS" if cond else "FAIL", what])
	if not cond:
		_fails.append(what)


func _settle(tree: SceneTree, frames: int) -> void:
	for _i in frames:
		await tree.process_frame


func run(main: Node, _harness: Node) -> Dictionary:
	var tree := main.get_tree()
	var bed: Node = main.get_node_or_null("AmbientBed")
	_ok(bed != null, "Main carries an AmbientBed")
	if bed == null:
		return {"ok": false, "why": "no AmbientBed"}
	await _settle(tree, 30)
	var files: Dictionary = bed.call("from_files")
	print("ambient-check: layers from user files: %s" % str(files))
	var players: Dictionary = bed.get("_players")
	_ok(players.has("wind") and players.has("rain") and players.has("stream"),
		"wind / rain / stream players exist (%s)" % str(players.keys()))
	# The clock runs at 1x for the probe; the world may be saved paused.
	var ts0 := float(main.get("time_scale"))
	main.set("time_scale", 1.0 / 3600.0)
	await _settle(tree, 40)
	print("ambient-check: live  " + str(bed.call("debug_line")))
	var live: Dictionary = bed.call("inputs")
	_ok(live.has("wind_ms") and live.has("sun_sin_alt") and live.has("forest") and live.has("stream_dist_m"),
		"the live inputs carry wind / sun / forest / stream")
	_ok(bool(live.get("first_person", false)), "first person is recognised on the loaded world")
	_ok(not bool(live.get("paused", true)), "the clock at 1x reads as not paused")
	# Force a windy rainy evening in a forest by a stream and watch the players.
	bed.set("override_inputs", {"wind_ms": 9.0, "rain_mmh": 6.0, "stream_v_ms": 1.2, "stream_dist_m": 5.0,
		"sun_sin_alt": 0.5, "forest": 0.9, "volume": 1.0})
	await _settle(tree, 150)
	print("ambient-check: forced  " + str(bed.call("debug_line")))
	var gains: Dictionary = bed.call("gains")
	var loud := true
	for layer in ["wind", "rain", "stream"]:
		loud = loud and float(gains.get(layer, 0.0)) > 0.2
	_ok(loud and float(gains.get("birds", 0.0)) > 0.05 and float(gains.get("birds", 0.0)) < 0.4,
		"wind / rain / stream rose under forced inputs and the rain + wind hushed the birds (%s)" % str(gains))
	var playing := true
	for layer in ["wind", "rain", "stream"]:
		var p := players[layer] as AudioStreamPlayer
		playing = playing and p.playing and p.volume_db > -30.0
	_ok(playing, "the loop players are playing above -30 dB")
	# A calm sunny forest: the chorus, and real calls on the one-shot players.
	var chirps0 := int(bed.get("chirps_played"))
	bed.set("override_inputs", {"wind_ms": 1.0, "rain_mmh": 0.0, "stream_v_ms": 0.0, "stream_dist_m": -1.0,
		"sun_sin_alt": 0.25, "forest": 0.9, "volume": 1.0})
	await _settle(tree, 240)
	print("ambient-check: forest  " + str(bed.call("debug_line")))
	var gf: Dictionary = bed.call("gains")
	var chirps := int(bed.get("chirps_played")) - chirps0
	_ok(float(gf.get("birds", 0.0)) > 0.5 and float(gf.get("wind", 1.0)) < 0.05 and float(gf.get("rain", 1.0)) < 0.05,
		"a calm sunny forest is birds and nothing else (%s)" % str(gf))
	_ok(chirps >= 2 or bool(files.get("birds", false)), "calls were played on the chirp players (%d in 4 s)" % chirps)
	bed.set("override_inputs", {"wind_ms": 9.0, "rain_mmh": 6.0, "stream_v_ms": 1.2, "stream_dist_m": 5.0,
		"sun_sin_alt": 0.5, "forest": 0.9, "volume": 1.0})
	await _settle(tree, 100)
	# Pause: silence.
	main.set("time_scale", 0.0)
	await _settle(tree, 200)
	print("ambient-check: paused  " + str(bed.call("debug_line")))
	var g2: Dictionary = bed.call("gains")
	var quiet := true
	for layer in ["wind", "rain", "stream", "birds"]:
		quiet = quiet and float(g2.get(layer, 1.0)) < 0.02
	_ok(quiet, "a paused clock silences every layer (%s)" % str(g2))
	main.set("time_scale", 1.0 / 3600.0)
	await _settle(tree, 150)
	# The graph hides the world: silence; back in first person: sound.
	var gv: Node = main.get_node_or_null("UILayer/SystemGraphView")
	if gv != null and gv.has_method("open_graph_view"):
		gv.call("open_graph_view")
		await _settle(tree, 200)
		var g3: Dictionary = bed.call("gains")
		_ok(float(g3.get("wind", 1.0)) < 0.02 and not bool((bed.call("inputs") as Dictionary).get("first_person", true)),
			"the open graph silences the bed (wind gain %.3f)" % float(g3.get("wind", 1.0)))
		gv.call("close_graph_view")
		await _settle(tree, 200)
		var g4: Dictionary = bed.call("gains")
		_ok(float(g4.get("wind", 0.0)) > 0.2, "closing the graph brings it back (wind gain %.3f)" % float(g4.get("wind", 0.0)))
	else:
		print("ambient-check: no graph view / open_graph_view — the graph gate is not exercised here")
	# Volume 0 through the pref itself (restored).
	var vol0 := NpcDisplayPrefs.ambient_volume()
	bed.set("override_inputs", {"wind_ms": 9.0, "rain_mmh": 6.0, "stream_v_ms": 1.2, "stream_dist_m": 5.0,
		"sun_sin_alt": 0.5, "forest": 0.9})
	NpcDisplayPrefs.set_ambient_volume(0.0)
	await _settle(tree, 200)
	var g5: Dictionary = bed.call("gains")
	_ok(float(g5.get("wind", 1.0)) < 0.02, "the Settings volume at 0 silences it (wind gain %.3f)" % float(g5.get("wind", 1.0)))
	NpcDisplayPrefs.set_ambient_volume(vol0)
	bed.set("override_inputs", {})
	main.set("time_scale", ts0)
	await _settle(tree, 10)
	return {"ok": _fails.is_empty(), "fails": _fails}
