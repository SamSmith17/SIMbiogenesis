class_name StageBeat
extends RefCounted

## The music ON SITE right now, for everything that moves to it: the crowd
## (the GPU figures through shader globals, the stick figures through at()),
## the DJ, and sound-reactive lights. StageMusic publishes one entry per
## stage that is playing — a real track's live analysis (BeatTracker) or a
## set's virtual beat (BeatGrid) — every frame; readers ask "what reaches
## this spot".
##
## An entry: {sid, pos: Vector2 (the speakers), radius (how far it carries —
## EARSHOT_M), bpm, beat (at `stamp_us`), running (false while the sim is
## paused: the music is paused too), energy, breakdown, build, drop_pulse,
## until_drop, since_drop, live (true = a real track)}. at() extrapolates the
## beat and the drop timers to NOW, so a reader between two publishes still
## lands on the beat.
##
## The crowd shader reads the SHADER_SLOTS nearest entries to the camera as
## the globals music_pos0..3 = (x, z, radius, energy) and music_beat0..3 =
## (beat mod PHRASE, until_drop, build, drop_pulse) — declared in
## project.godot [shader_globals] (never added at runtime).

const EARSHOT_M := 180.0
const SHADER_SLOTS := 4
## The beat handed to the shader wraps every 128 beats (a float32 beat count
## of hours of music would lose its fraction); every pose cycles in whole
## beats, so the wrap is invisible.
const SHADER_WRAP := 128.0
## The anticipation window the dancers and the DJ react in.
const ANTICIPATE_S := 4.0

static var _venues: Array = []
static var _pushed_count := -1
## What push_shader last sent, slot by slot (music_pos) — diagnostics and
## the harness (reading a global back is editor-only).
static var pushed_pos: Array = [Vector4.ZERO, Vector4.ZERO, Vector4.ZERO, Vector4.ZERO]


static func publish(venues: Array) -> void:
	_venues = venues
	_at_memo.clear()


static func clear() -> void:
	_venues = []


static func venues() -> Array:
	return _venues


## The music reaching `pos`: the nearest playing source within its radius,
## extrapolated to now. {} = silence. `for_npc` respects Settings → NPCs →
## "Dance to the beat" (lights ask with false).
static func at(pos: Vector3, for_npc: bool = true) -> Dictionary:
	if _venues.is_empty():
		return {}
	if for_npc and not NpcDisplayPrefs.beat_sync():
		return {}
	# Every dancing figure and every sound-reactive light asks each frame, and
	# extrapolate() copies the entry: one copy per venue per frame is shared
	# instead (callers only read it).
	var p := Vector2(pos.x, pos.z)
	var best_i := -1
	var best_d := INF
	for i in _venues.size():
		var e: Dictionary = _venues[i]
		var d := p.distance_to(e.get("pos", Vector2.INF))
		if d <= float(e.get("radius", EARSHOT_M)) and d < best_d:
			best_d = d
			best_i = i
	if best_i < 0:
		return {}
	var frame := Engine.get_process_frames()
	if frame != _at_memo_frame:
		_at_memo_frame = frame
		_at_memo.clear()
	var hit: Variant = _at_memo.get(best_i)
	if hit == null:
		hit = extrapolate(_venues[best_i], Time.get_ticks_usec())
		_at_memo[best_i] = hit
	return hit


static var _at_memo: Dictionary = {}
static var _at_memo_frame := -1


## Pure: the nearest entry within its radius, extrapolated to `now_us`.
static func nearest(venues_list: Array, p: Vector2, now_us: int) -> Dictionary:
	var best: Dictionary = {}
	var best_d := INF
	for v in venues_list:
		var e: Dictionary = v
		var d := p.distance_to(e.get("pos", Vector2.INF))
		if d <= float(e.get("radius", EARSHOT_M)) and d < best_d:
			best_d = d
			best = e
	if best.is_empty():
		return {}
	return extrapolate(best, now_us)


static func extrapolate(e: Dictionary, now_us: int) -> Dictionary:
	var out := e.duplicate()
	var dt := 0.0
	if bool(e.get("running", true)):
		dt = maxf(float(now_us - int(e.get("stamp_us", now_us))) / 1e6, 0.0)
	out["beat"] = float(e.get("beat", 0.0)) + dt * float(e.get("bpm", 120.0)) / 60.0
	var since := float(e.get("since_drop", INF)) + dt
	out["since_drop"] = since
	out["until_drop"] = float(e.get("until_drop", INF)) - dt
	out["drop_pulse"] = exp(-since / BeatGrid.DROP_DECAY_S) if since < INF else 0.0
	return out


## How far into the run-up to a drop, 0..1 (1 = the drop is now), from
## until_drop inside the ANTICIPATE_S window. 0 when no drop is coming.
static func anticipation(b: Dictionary) -> float:
	var u := float(b.get("until_drop", INF))
	if u == INF or u < 0.0 or u > ANTICIPATE_S:
		return 0.0
	return 1.0 - u / ANTICIPATE_S


## Push the SHADER_SLOTS nearest entries to `cam` into the crowd shader's
## globals (an empty slot has radius 0, which the shader skips). With "Dance
## to the beat" off, every slot is empty.
static func push_shader(cam: Vector3) -> void:
	var picked: Array = []
	if NpcDisplayPrefs.beat_sync() and not _venues.is_empty():
		var c2 := Vector2(cam.x, cam.z)
		picked = _venues.duplicate()
		picked.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return c2.distance_squared_to(a["pos"]) < c2.distance_squared_to(b["pos"]))
		picked = picked.slice(0, SHADER_SLOTS)
	if picked.is_empty() and _pushed_count == 0:
		return
	_pushed_count = picked.size()
	var now := Time.get_ticks_usec()
	for i in SHADER_SLOTS:
		var pos := Vector4.ZERO
		var bt := Vector4(0.0, 99.0, 0.0, 0.0)
		if i < picked.size():
			var e := extrapolate(picked[i], now)
			var p: Vector2 = e["pos"]
			pos = Vector4(p.x, p.y, float(e.get("radius", EARSHOT_M)), float(e.get("energy", 1.0)))
			bt = Vector4(fposmod(float(e["beat"]), SHADER_WRAP), minf(float(e["until_drop"]), 99.0),
				float(e.get("build", 0.0)), float(e["drop_pulse"]))
		RenderingServer.global_shader_parameter_set("music_pos%d" % i, pos)
		pushed_pos[i] = pos
		RenderingServer.global_shader_parameter_set("music_beat%d" % i, bt)


# --- sound-reactive lights ---------------------------------------------------

## A light's brightness multiplier on the music `b` (a StageBeat entry,
## extrapolated). `depth` 0..1 is how hard it pumps. A kick envelope on every
## beat (doubling to 8ths then 16ths through a build, the way a riser
## rolls), scaled by the music's energy (dim in a breakdown), plus a flash on
## the drop. 1.0 with no music.
static func light_level(b: Dictionary, depth: float) -> float:
	if b.is_empty():
		return 1.0
	var d := clampf(depth, 0.0, 1.0)
	var build := float(b.get("build", 0.0))
	var sub := 4.0 if build > 0.85 else (2.0 if build > 0.5 else 1.0)
	var ph := fposmod(float(b.get("beat", 0.0)) * sub, 1.0)
	var kick := exp(-ph * 5.0)
	var energy := clampf(float(b.get("energy", 1.0)), 0.0, 1.0)
	var pumped := (0.22 + 1.4 * kick) * (0.5 + 0.5 * energy)
	return lerpf(1.0, pumped, d) + float(b.get("drop_pulse", 0.0)) * 2.0 * d


## An effect clock that moves WITH the music: beats × 0.5 s (= real seconds
## at 120 BPM, so an effect's own speed setting still reads) — a chase speeds
## up and slows down with the tempo and freezes when the music pauses.
static func light_time(b: Dictionary) -> float:
	if b.is_empty():
		return 0.0
	return float(b.get("beat", 0.0)) * 0.5
