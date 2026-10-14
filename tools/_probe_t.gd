extends SceneTree
func _initialize() -> void:
	var f := FileAccess.open("res://core/linkage/presets/ll_starshade_v1_soak_2026.json", FileAccess.READ)
	var p := LinkageParams.new()
	p.from_config(JSON.parse_string(f.get_as_text()))
	var t0 := Time.get_ticks_msec()
	var tl := LinkageBuildTimeline.plan(p, [], 12)
	print("plan ms ", Time.get_ticks_msec() - t0, " ", LinkageBuildTimeline.summary(tl))
	quit()
