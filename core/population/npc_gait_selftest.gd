extends SceneTree

## Bodies at speed (NPC life pass, Phase 1): NpcGait's display cadence and the
## stick figure's walk at 1x .. the 12x playback cap. The slant the player saw
## at 1440x: the knee bends only on the recovery, so the average foot trailed
## the hips by ~0.12 m at EVERY speed — hidden by the stride at 1x, but at 12x
## the eased joints could not follow the swing (0.09 rad left of 0.62), and
## what remained was a static body leaning forward over its feet. Measured
## here as the mean foot position along the body's facing over many strides,
## and the swing the thigh actually reaches. Carries EXPECTED_CHECKS (a runtime error aborts a
## test function while PASS still prints).
##   Godot --headless --path . --script core/population/npc_gait_selftest.gd

const EXPECTED_CHECKS := 11

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_test_display()
	await _test_walk_offsets()
	if _checks != EXPECTED_CHECKS:
		_failures += 1
		print("  FAIL: ran %d checks, expected %d (a test function aborted?)" % [_checks, EXPECTED_CHECKS])
	if _failures == 0:
		print("NPC GAIT SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("NPC GAIT SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
	quit(1 if _failures > 0 else 0)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _test_display() -> void:
	_check("a normal walk is shown as it is", is_equal_approx(NpcGait.display_hz(0.95), 0.95))
	_check("paused shows no stride", NpcGait.display_hz(0.0) == 0.0)
	var prev := 0.0
	var mono := true
	for k in 200:
		var f := float(k) * 0.5
		var d := NpcGait.display_hz(f)
		if d < prev - 1e-6:
			mono = false
		prev = d
	_check("faster is never shown slower", mono)
	_check("the shown cadence never passes MAX_HZ", NpcGait.display_hz(5000.0) <= NpcGait.MAX_HZ + 1e-6)
	_check("12x is shown near the cap, still faster than 4x",
		NpcGait.display_hz(0.95 * 12.0) > NpcGait.display_hz(0.95 * 4.0))
	_check("continuous at the knee", absf(NpcGait.display_hz(NpcGait.KNEE_HZ + 1e-4) - NpcGait.KNEE_HZ) < 1e-3)


## Mean foot position along the facing (+ = ahead of the hips) and the thigh
## swing reached, for one walk at `rate` and frame time `dt`.
func _walk_stats(rate: float, dt: float) -> Dictionary:
	var fig := NpcSimpleFigure.new()
	root.add_child(fig)
	fig.setup("gait_npc_0", Color.WHITE)
	var frames := int(12.0 / dt)
	var warm := int(2.0 / dt)
	var sum := 0.0
	var n := 0
	var swing_max := 0.0
	for f in frames:
		fig.pose(NpcRig.CLIP_WALK, rate, dt)
		if f < warm:
			continue
		var fwd := -fig.global_transform.basis.z    # the avatar's forward after its half-turn
		var mid_foot := Vector3.ZERO
		var mid_hip := Vector3.ZERO
		for i in 2:
			var knee: Node3D = fig._knee[i]
			var hip: Node3D = fig._hip[i]
			mid_foot += knee.global_transform * Vector3(0.0, -NpcSimpleFigure.SHIN, 0.0)
			mid_hip += hip.global_position
			swing_max = maxf(swing_max, absf(hip.rotation.x))
		sum += ((mid_foot - mid_hip) * 0.5).dot(fwd)
		n += 1
	fig.queue_free()
	return {"offset": sum / maxf(n, 1), "swing": swing_max}


func _test_walk_offsets() -> void:
	await process_frame
	# The figure faces +Z in its own frame and the avatar turns it PI; here it
	# stands untransformed, so "forward" is its local +Z. Either sign is fine:
	# what matters is that the mean foot sits UNDER the hips.
	for rate: float in [1.0, 4.0, 12.0]:
		var s := _walk_stats(rate, 1.0 / 60.0)
		print("  gait rate %.0fx @60 fps: mean foot offset %+.3f m, thigh swing %.2f rad"
			% [rate, s["offset"], s["swing"]])
		_check("feet under the hips at %.0fx (60 fps)" % rate, absf(float(s["offset"])) < 0.02,
			"offset %.3f m" % s["offset"])
		if rate >= 12.0:
			_check("the stride still reads at 12x (thigh swing >= 0.4 rad)", float(s["swing"]) >= 0.4,
				"swing %.2f" % s["swing"])
	var slow := _walk_stats(12.0, 1.0 / 20.0)
	print("  gait rate 12x @20 fps: mean foot offset %+.3f m" % slow["offset"])
	_check("feet under the hips at 12x on a 20 fps frame", absf(float(slow["offset"])) < 0.02,
		"offset %.3f m" % slow["offset"])
