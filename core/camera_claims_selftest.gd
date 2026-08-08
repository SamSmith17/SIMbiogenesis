extends SceneTree

## Offline deterministic selftest for CameraClaims (core/camera_claims.gd).
##
## Mirrors core/clock_claims_selftest.gd deliberately: the two services share a
## contract, so they should share a test shape. The reproduction at the bottom
## is the camera equivalent of that file's snowglobe-over-CSV-playback bug.
##
## Run: Godot.exe.exe --headless --path . --script core/camera_claims_selftest.gd

var _fails := 0
var _checks := 0

# Stand-in camera ids. Real ones come from Object.get_instance_id(); the
# service never dereferences them, which is exactly what keeps it pure.
const PLAYER_CAM := 1001
const CAPTURE_CAM := 1002
const GLOBE_CAM := 1003
const SETTLEMENT_CAM := 1004


func _check(name: String, cond: bool, detail: String = "") -> void:
	_checks += 1
	if not cond:
		_fails += 1
		push_error("FAIL: %s  %s" % [name, detail])


func _initialize() -> void:
	_test_basic_stack()
	_test_reclaim_does_not_stack()
	_test_release_is_order_independent()
	_test_the_snowglobe_over_capture_bug()
	_test_exclusive()
	_test_value_falls_through()
	_test_signal()
	if _fails == 0:
		print("CAMERA CLAIMS SELFTEST PASS  (%d checks)" % _checks)
	else:
		print("CAMERA CLAIMS SELFTEST FAIL  (%d of %d checks failed)" % [_fails, _checks])
	quit(1 if _fails > 0 else 0)


func _test_basic_stack() -> void:
	var c := CameraClaims.new()
	_check("empty at start", c.is_empty())
	_check("base camera shows through", c.effective_camera_id() == 0)
	c.claim("settlement", {"camera_id": SETTLEMENT_CAM, "hide_player_mesh": true})
	_check("a claim takes the camera", c.effective_camera_id() == SETTLEMENT_CAM)
	_check("side-effecting values ride along",
			bool(c.value_or("hide_player_mesh", false)))
	_check("the owner is listed", c.has_claim("settlement"))
	c.release("settlement")
	_check("release restores the base", c.effective_camera_id() == 0 and c.is_empty())
	_check("the side effect is gone too",
			not bool(c.value_or("hide_player_mesh", false)))


func _test_reclaim_does_not_stack() -> void:
	var c := CameraClaims.new()
	c.claim("settlement", {"camera_id": SETTLEMENT_CAM})
	c.claim("settlement", {"camera_id": GLOBE_CAM})
	_check("re-claiming replaces in place", c.owners().size() == 1)
	_check("the newer value wins", c.effective_camera_id() == GLOBE_CAM)
	c.release("settlement")
	# The point: ONE release is enough however many times the owner claimed,
	# so a repeated call cannot leak a claim that strands the viewport.
	_check("one release is enough", c.is_empty())


func _test_release_is_order_independent() -> void:
	var c := CameraClaims.new()
	c.claim("a", {"camera_id": CAPTURE_CAM})
	c.claim("b", {"camera_id": GLOBE_CAM})
	c.release("a")   # release the BOTTOM claim first
	_check("releasing underneath leaves the top live",
			c.effective_camera_id() == GLOBE_CAM)
	c.release("b")
	_check("the stack empties to base", c.effective_camera_id() == 0)
	c.release("b")
	c.release("never_claimed")
	_check("releasing what was never claimed is safe", c.is_empty())


## The bug this service exists to prevent, in the shape it actually takes.
##
## With private saved-camera fields: the capture saves the player camera, the
## snowglobe then saves the CAPTURE camera and restores that on close, and when
## the capture frees its camera the viewport is left pointing at a freed
## object. There is no ordering of save/restore that fixes it — the bug IS the
## private "previous" field.
func _test_the_snowglobe_over_capture_bug() -> void:
	var c := CameraClaims.new()
	_check("the player camera is the base", c.effective_camera_id() == 0)
	c.claim("harness_capture", {"camera_id": CAPTURE_CAM})
	_check("the capture takes the viewport", c.effective_camera_id() == CAPTURE_CAM)
	c.claim("soi_snowglobe", {"camera_id": GLOBE_CAM, "hide_player_mesh": true})
	_check("the snowglobe takes it next", c.effective_camera_id() == GLOBE_CAM)
	# Out of order: the capture finishes FIRST, while the globe is still up.
	c.release("harness_capture")
	_check("the globe keeps the viewport when the capture ends underneath it",
			c.effective_camera_id() == GLOBE_CAM)
	c.release("soi_snowglobe")
	_check("and the PLAYER camera comes back, not a freed one",
			c.effective_camera_id() == 0 and c.is_empty())
	_check("the player mesh is shown again",
			not bool(c.value_or("hide_player_mesh", false)))


func _test_exclusive() -> void:
	var c := CameraClaims.new()
	_check("an exclusive claim is taken",
			c.claim("video_export", {"camera_id": CAPTURE_CAM}, true))
	_check("the holder is named", c.exclusive_owner() == "video_export")
	_check("a competing claim is refused",
			not c.claim("settlement", {"camera_id": SETTLEMENT_CAM}))
	_check("and does not change the camera", c.effective_camera_id() == CAPTURE_CAM)
	_check("the holder may still update its own claim",
			c.claim("video_export", {"camera_id": GLOBE_CAM}, true))
	c.release("video_export")
	_check("release frees the lock", c.exclusive_owner().is_empty())
	_check("and the refused system can now claim",
			c.claim("settlement", {"camera_id": SETTLEMENT_CAM}))


## A claim that carries only a side-effecting key must not blank out the
## camera chosen underneath it.
func _test_value_falls_through() -> void:
	var c := CameraClaims.new()
	c.claim("settlement", {"camera_id": SETTLEMENT_CAM})
	c.claim("zoom_tuning", {"prop_cull_scale_m": 900.0})
	_check("the underlying camera survives a partial claim",
			c.effective_camera_id() == SETTLEMENT_CAM)
	_check("the partial claim's own value is live",
			absf(float(c.value_or("prop_cull_scale_m", 0.0)) - 900.0) < 0.001)
	c.release("zoom_tuning")
	_check("and reverts on release",
			absf(float(c.value_or("prop_cull_scale_m", 0.0))) < 0.001)


func _test_signal() -> void:
	var c := CameraClaims.new()
	var seen: Array = []
	c.effective_changed.connect(func(v: Dictionary) -> void: seen.append(v))
	c.claim("settlement", {"camera_id": SETTLEMENT_CAM})
	_check("claiming emits", seen.size() == 1)
	c.claim("settlement", {"camera_id": SETTLEMENT_CAM})
	_check("an identical re-claim does not emit", seen.size() == 1)
	c.claim("settlement", {"camera_id": GLOBE_CAM})
	_check("a changed re-claim emits", seen.size() == 2)
	c.release("settlement")
	_check("release emits the return to base", seen.size() == 3)
	_check("and reports an empty effective", (seen[2] as Dictionary).is_empty())
