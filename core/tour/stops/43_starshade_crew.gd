extends TourStop

## A StarShade built by a crew of twelve on the shared crew build site
## (PalletRackBuildSite): the kit laid out in a yard, the frame put up folded
## in the Lab's own step order (bottom ring, V modules, top ring, supports),
## then opened about its own middle — played on the clock as a rehearsal on a
## freshly placed structure, which is removed again afterwards.

const DESIGN := "res://core/linkage/presets/ll_starshade_v1_soak_2026.json"
const CREW := 12
## The moments the camera stops on: [a job label pattern (String.match), caption].
const PHASES := [
	["carry*", "The kit laid out in the yard, carried to the frame piece by piece"],
	["fit*bottom-ring*", "The bottom ring first, folded, as the Lab's steps put it"],
	["fit*V-module*", "Then the V modules, their brackets and bolts"],
	["fit*top-ring*", "The top ring goes on"],
	["fit*support*", "…and the supports"],
]

var _pid := ""
var _clock := {}


func _init() -> void:
	id = "starshade_crew"
	title = "StarShade: built by the crew"
	chapter = "People"
	summary = "Twelve people put a StarShade up from its real parts, folded, then open it."
	how = PackedStringArray(["Place a StarShade (Linkage Lab → Place in world)",
		"Click it → Crew → Rehearse build, or queue the build for the camp's crew",
		"Scrub the timeline: the build runs forwards and backwards with the clock"])
	button = "Rehearse build (prop editor)"
	world = "walton"
	budget_s = 60.0
	hour = 11.0
	blurb = ("Every structure a crew builds runs on the same site: the kit is laid out " +
		"in a yard, and each piece of the real structure is carried out and fitted in " +
		"the Lab's own order — bottom ring, V modules, top ring, supports — with the " +
		"frame folded, then the StarShade opens about its own middle. The build is a " +
		"pure function of the clock — scrub it back and it comes apart again. Queued " +
		"for a camp, the real crew builds it as fast as their credited work allows.")


func run(ctx: TourContext) -> void:
	var m := ctx.main
	var pps := ctx.klass("PlacedPropService")
	var lbs := ctx.klass("PalletRackBuildSite")
	var f := FileAccess.open(DESIGN, FileAccess.READ)
	var cfg: Variant = JSON.parse_string(f.get_as_text()) if f != null else null
	if not ctx.require(pps != null and lbs != null and cfg is Dictionary, "the StarShade design and the build site load"):
		return
	_clock = ctx.save_clock()
	m.set("time_scale", 0.0)
	ctx.set_hour(11.0)
	await ctx.frames(1)
	var h0 := float(m.call("get_absolute_hours"))
	var fwd := ctx.player_forward()
	var at := ctx.find_flat(ctx.player_xz() + Vector2(fwd.x, fwd.z) * 30.0, 12.0, 200.0, 10.0)
	var placed: Dictionary = pps.call("place_model_at_xz", m, "linkage_structure", at.x, at.z, {"linkage_spec": cfg})
	_pid = str(placed.get("prop_id", ""))
	if not ctx.require(not _pid.is_empty(), "the StarShade was placed"):
		return
	await ctx.frames(6)
	if not ctx.require(bool(lbs.call("start_rehearsal", m, _pid, CREW, h0)), "the crew rehearsal started"):
		return
	await ctx.frames(2)
	var site: Variant = lbs.call("site_for", m, _pid)
	if not ctx.require(site != null, "the build site is up"):
		return
	var tl: Dictionary = site.call("timeline")
	var mk := float(tl.get("makespan", 0.0))
	if not ctx.require(mk > 0.0, "the crew has a build plan"):
		return
	var lbt := ctx.klass("PalletRackBuildPlan")
	ctx.note(str(lbt.call("summary", tl)) if lbt != null else "plan %.0f s" % mk)
	var dir := Vector3(at.x, 0.0, at.z) - Vector3(ctx.player.global_position.x, 0.0, ctx.player.global_position.z)
	dir = dir.normalized() if dir.length() > 0.5 else fwd
	var side := dir.cross(Vector3.UP)
	var look := at + Vector3.UP * 1.5
	var eye := at - dir * 16.0 + side * 6.0 + Vector3.UP * 7.0
	eye.y = maxf(eye.y, ctx.ground_y(eye.x, eye.z) + 3.0)
	ctx.place_camera(eye, look)
	ctx.caption("The plan, from the StarShade's own parts — a crew of %d" % CREW, 3.0)
	await ctx.wait(2.5)
	var t := 0.0
	var shot := false
	for ph in PHASES:
		if ctx.cancelled:
			break
		var mid := _phase_mid(tl, str(ph[0]), t)
		if is_nan(mid):
			continue
		ctx.caption(str(ph[1]), 3.0)
		await _sweep(ctx, m, h0, t, mid, 2.6)
		t = mid
		var orbit_a := float(PHASES.find(ph)) * 14.0 - 30.0
		await ctx.orbit(look, 16.0, 6.0, orbit_a, orbit_a + 10.0, 1.2)
		await ctx.shot("phase_%d" % PHASES.find(ph), true)
	# The unfold: the real structure opens about its own middle.
	var dep := float(lbs.get("LINKAGE_DEPLOY_S")) if lbs != null else 120.0
	ctx.caption("…and the StarShade opens", 3.0)
	await _sweep(ctx, m, h0, t, mk + dep * 0.5, 2.0)
	await ctx.shot("phase_deploy", true)
	await _sweep(ctx, m, h0, mk + dep * 0.5, mk + dep + 10.0, 1.6)
	await ctx.hero(true)
	ctx.caption(str(site.call("progress_line")), 2.5)
	await ctx.orbit(look, 22.0, 9.0, 60.0, 100.0, 3.0)


## Middle of the earliest job whose label matches `pattern` (long enough to
## see) that is still to come after build time `after` (s), or NAN.
func _phase_mid(tl: Dictionary, pattern: String, after: float) -> float:
	var best := NAN
	for j in tl.get("jobs", []):
		var jd: Dictionary = j
		if not str(jd.get("label", "")).match(pattern) or float(jd["t1"]) - float(jd["t0"]) <= 1.0:
			continue
		var mid := (float(jd["t0"]) + float(jd["t1"])) * 0.5
		if mid > after + 1.0 and (is_nan(best) or mid < best):
			best = mid
	return best


## Move build time from t0 to t1 (seconds into the build) over `seconds`.
func _sweep(ctx: TourContext, m: Node, h0: float, t0: float, t1: float, seconds: float) -> void:
	var dur := maxf(seconds * ctx.pace, 0.05)
	var e := 0.0
	while e < dur and not ctx.cancelled:
		var u := smoothstep(0.0, 1.0, e / dur)
		m.call("set_absolute_hours", h0 + lerpf(t0, t1, u) / 3600.0)
		await ctx.tree().process_frame
		e += ctx.host.get_process_delta_time()
	m.call("set_absolute_hours", h0 + t1 / 3600.0)


func teardown(ctx: TourContext) -> void:
	var lbs := ctx.klass("PalletRackBuildSite")
	if not _pid.is_empty():
		if lbs != null:
			lbs.call("clear_rehearsal", ctx.main, _pid)
		ctx.remove_prop(_pid)
	_pid = ""
	ctx.restore_clock(_clock)
	_clock = {}
