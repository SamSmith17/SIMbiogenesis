class_name StageMusic
extends Node3D

## STAGE MUSIC — a venue's own track, playing from its speakers while its set
## is on. A venue record's `music` names a file in DIR (user data, not the
## repo: tracks are the player's, and their licences are theirs); the venue
## row's "Music" picker sets it (NpcSpaceTagRow).
##
## One AudioStreamPlayer3D per venue with a track, at the speakers: the
## stage's FRONT EDGE (the bridge's venue_front), raised to the deck plus
## SPEAKER_H_M, facing the way the speakers point. Distance does the rest:
## inverse-distance falloff (full volume inside UNIT_SIZE_M, gone by
## MAX_DISTANCE_M), high frequencies rolled off with distance (bass carries,
## as it does across a real site), and an emission CONE — behind the stage it
## is muffled and quieter. The listener is the active camera, so the
## settlement view hears the site from where it looks.
##
## When it plays (`should_play`, pure): a stage while a SET is on (its
## programme, NpcVenueState — the same moment the crowd starts raving and the
## DJ takes the decks); a fire circle while it burns; any other venue while
## it is open. It fades in and out over FADE_S, restarts from the top when a
## set begins, loops, and PAUSES while the sim is paused (the crowd freezes,
## so does the music). Volume: NpcDisplayPrefs.stage_music_volume (Settings ->
## NPCs; 0 = off). Works on any map with a space registry, population or not.

const DIR := "user://stage_audio/"
const EXTENSIONS: Array = ["mp3", "ogg", "wav"]
const POLL_S := 0.25
const FADE_S := 2.0
const UNIT_SIZE_M := 14.0
const MAX_DISTANCE_M := 520.0
const MAX_DB := 4.0
const SPEAKER_H_M := 2.0
const CONE_DEG := 70.0
const BEHIND_DB := -14.0
## Below this the player is stopped (not just silent) — no decoding cost.
const SILENT_DB := -60.0

## sid -> {player (null for a stage with no track), file, on, gain (0..1
## fade), vt (the virtual beat's clock), ana (the analysis slot), pos, seed}
var _players: Dictionary = {}
var _accum := 0.0
var _streams: Dictionary = {}   # file -> AudioStream (loaded once)


# --- pure rules (selftested) -------------------------------------------------

## Should a venue with a track be playing now? `st` is NpcVenueState.resolve's
## dict (or the bridge's, which adds a firepit's `lit`).
static func should_play(space_type: String, st: Dictionary) -> bool:
	if st.is_empty():
		return false
	match space_type:
		"stage":
			return bool(st.get("active", false)) and bool(st.get("programmed", false))
		"fire_circle":
			return bool(st.get("lit", true))
	return bool(st.get("active", true))


## The audio files in DIR the picker offers, sorted.
static func list_tracks() -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(DIR)
	if d == null:
		return out
	for f in d.get_files():
		if str(f.get_extension()).to_lower() in EXTENSIONS:
			out.append(f)
	out.sort()
	return out


## Copy a file from anywhere into DIR (the picker's "Add file…"); returns the
## file name to store on the record, "" on failure.
static func import_track(src_path: String) -> String:
	if not FileAccess.file_exists(src_path):
		return ""
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	var name := src_path.get_file()
	var err := DirAccess.copy_absolute(src_path, ProjectSettings.globalize_path(DIR + name))
	return name if err == OK else ""


## A track as an AudioStream, loaded straight from the file (no import step:
## these live in user data). Null when the file is missing or unreadable.
static func load_track(file: String) -> AudioStream:
	var path := DIR + file
	if file.is_empty() or not FileAccess.file_exists(path):
		return null
	match str(file.get_extension()).to_lower():
		"mp3":
			var mp3 := AudioStreamMP3.load_from_file(path)
			if mp3 != null:
				mp3.loop = true
			return mp3
		"ogg":
			var ogg := AudioStreamOggVorbis.load_from_file(path)
			if ogg != null:
				ogg.loop = true
			return ogg
		"wav":
			var wav := AudioStreamWAV.load_from_file(path)
			if wav != null:
				wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
				wav.loop_end = int(wav.get_length() * float(wav.mix_rate))
			return wav
	return null


# --- runtime -------------------------------------------------------------------
#
# THE BEAT (StageBeat). Every stage with a set on — and every other venue
# playing its own track — publishes its beat each frame:
#   - a venue with a TRACK gets one of ANALYSIS_SLOTS analysis buses: a
#     second, silent, non-positional player of the same stream runs
#     LOOKAHEAD_S AHEAD of the one you hear, a spectrum analyzer on its bus
#     (at -80 dB — the analyzer sees the signal before the bus volume, so
#     nothing is heard) reads the bass band every frame, and a BeatTracker
#     turns that into kicks, tempo, breakdowns and DROPS. Queried at the HEARD
#     time, a drop is therefore known up to LOOKAHEAD_S before it is heard —
#     the DJ's arm goes up in time. The audible player is kept on the
#     analysis clock (started at, and re-synced to, analysis − LOOKAHEAD_S).
#   - a stage with a set and NO track (or no free slot) gets BeatGrid's
#     virtual set on its own clock (real seconds while the sim runs, from the
#     moment the set began).
# Both stop with the sim (the music pauses, the crowd freezes, the beat holds).

const LOOKAHEAD_S := 5.0
const ANALYSIS_SLOTS := 4
const ANALYSIS_BUS := "BeatAnalysis%d"
## The kick drum's band.
const BASS_LO_HZ := 35.0
const BASS_HI_HZ := 150.0
## Re-seek the audible player when it drifts this far off the analysis clock.
const RESYNC_S := 0.12


func _process(delta: float) -> void:
	_accum += delta
	if _accum >= POLL_S:
		_accum = 0.0
		_refresh()
	var paused := SimFxRate.is_paused(get_parent())
	_tick_analysis(delta, paused)
	_fade(delta)
	_publish(paused)


func _exit_tree() -> void:
	StageBeat.clear()
	StageBeat.push_shader(Vector3.ZERO)


func _refresh() -> void:
	var main := get_parent()
	var reg := _registry(main)
	var bridge := _bridge()
	var seen: Dictionary = {}
	if reg != null:
		var hour := float(main.get("day_time")) if main != null and "day_time" in main else 12.0
		var abs_h := float(main.call("get_absolute_hours")) if main != null and main.has_method("get_absolute_hours") else 0.0
		for rec_v in reg.spaces:
			var rec: Dictionary = rec_v
			var file := str(rec.get("music", ""))
			var stype := str(rec.get("space_type", ""))
			if not SpaceTypes.is_venue(stype):
				continue
			# A track plays from any venue; a stage with no track still has a
			# (virtual) beat while its set is on.
			if file.is_empty() and stype != "stage":
				continue
			var sid := str(rec.get("id", ""))
			seen[sid] = true
			# NPCs switched off = the bridge's venue states are frozen; resolve
			# the programme here so a set still ends on time.
			var st: Dictionary = bridge.call("venue_state", sid) \
				if bridge != null and NpcDisplayPrefs.npcs_enabled() else {}
			if st.is_empty():
				st = NpcVenueState.resolve(rec, hour, abs_h)
			var e := _entry(sid, file)
			if e.is_empty():
				continue
			var want := should_play(stype, st)
			if want and not bool(e["on"]):
				# A set beginning: the music (and its beat) start from the top.
				e["vt"] = 0.0
				_stop_analysis(e)
			e["on"] = want
			e["stype"] = stype
			_place(e, main, reg, rec, sid, bridge)
	# Venues that lost their track (or were untagged): go.
	for sid in _players.keys():
		if not seen.has(sid):
			var gone: Dictionary = _players[sid]
			_stop_analysis(gone)
			if gone["player"] != null:
				(gone["player"] as Node).queue_free()
			_players.erase(sid)
	# Free analysis slots go to playing tracks that have none.
	for sid in _players:
		var e2: Dictionary = _players[sid]
		if bool(e2["on"]) and e2["player"] != null and (e2["ana"] as Dictionary).is_empty():
			_start_analysis(e2)


func _entry(sid: String, file: String) -> Dictionary:
	var e: Dictionary = _players.get(sid, {})
	if not e.is_empty() and str(e["file"]) == file:
		return e
	if not e.is_empty():
		_stop_analysis(e)
		if e["player"] != null:
			(e["player"] as Node).queue_free()
		_players.erase(sid)
	var p: AudioStreamPlayer3D = null
	if not file.is_empty():
		var stream: AudioStream = _streams.get(file)
		if stream == null:
			stream = load_track(file)
			if stream == null:
				return {}
			_streams[file] = stream
		p = AudioStreamPlayer3D.new()
		p.name = "StageMusic_%s" % sid.validate_node_name()
		p.stream = stream
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.unit_size = UNIT_SIZE_M
		p.max_distance = MAX_DISTANCE_M
		p.max_db = MAX_DB
		# Distance rolls off the highs first: the bass is what reaches the camps.
		p.attenuation_filter_cutoff_hz = 3500.0
		p.attenuation_filter_db = -20.0
		p.emission_angle_enabled = true
		p.emission_angle_degrees = CONE_DEG
		p.emission_angle_filter_attenuation_db = BEHIND_DB
		p.doppler_tracking = AudioStreamPlayer3D.DOPPLER_TRACKING_DISABLED
		p.volume_db = SILENT_DB
		add_child(p)
	e = {"player": p, "file": file, "on": false, "gain": 0.0, "vt": 0.0, "ana": {},
		"pos": Vector2.INF, "stype": "", "seed": NpcHash.unit01(sid, "bpm"), "sid": sid}
	_players[sid] = e
	return e


## At the speakers: the front edge (the crowd's side), deck height + a
## speaker stack, facing the way the speakers point (-Z = forward for the
## emission cone). The same spot is where the beat comes FROM.
func _place(e: Dictionary, main: Node, reg: SpaceRegistry, rec: Dictionary, sid: String,
		bridge: Object) -> void:
	var c: Variant = reg.cached_position(sid)
	if not (c is Vector2):
		c = reg.resolve_position(rec, main)
	if not (c is Vector2):
		return
	var centre: Vector2 = c
	var fr: Dictionary = bridge.call("venue_front", sid) if bridge != null else {}
	var fwd: Vector2 = fr.get("fwd", Vector2.ZERO)
	if fwd.length() < 0.01:
		var deg := float(rec.get("facing_deg", -1.0))
		fwd = VenueCrowd.fwd_from_deg(deg) if deg >= 0.0 else Vector2(0.0, 1.0)
	var at: Vector2 = fr.get("front", centre)
	e["pos"] = at
	var p: AudioStreamPlayer3D = e["player"]
	if p == null:
		return
	var deck := float(rec.get("perform_h_m", -1.0))
	if deck < 0.0:
		var tgt: Dictionary = rec.get("target", {})
		deck = float(bridge.call("stage_deck_m", main, str(tgt.get("prop_id", "")))) \
			if bridge != null and str(tgt.get("kind", "")) == "prop" else 0.0
	var y := TerrainSurfaceQuery.ground_height_at(main, at.x, at.y) + maxf(deck, 0.0) + SPEAKER_H_M
	p.global_transform = Transform3D(Basis(Vector3.UP, atan2(-fwd.x, -fwd.y)), Vector3(at.x, y, at.y))


# --- analysis ------------------------------------------------------------------

func _start_analysis(e: Dictionary) -> void:
	var p: AudioStreamPlayer3D = e["player"]
	if p == null or p.stream == null:
		return
	var length := p.stream.get_length()
	if length < LOOKAHEAD_S + 2.0:
		return
	var used: Dictionary = {}
	for sid in _players:
		var a: Dictionary = (_players[sid] as Dictionary)["ana"]
		if not a.is_empty():
			used[int(a["slot"])] = true
	var slot := -1
	for i in ANALYSIS_SLOTS:
		if not used.has(i):
			slot = i
			break
	if slot < 0:
		return
	var bus := _analysis_bus(slot)
	var ap := AudioStreamPlayer.new()
	ap.name = "BeatAnalysis_%s" % str(e["sid"]).validate_node_name()
	ap.stream = p.stream
	ap.bus = AudioServer.get_bus_name(bus)
	add_child(ap)
	var tr := BeatTracker.new()
	tr.lookahead = LOOKAHEAD_S
	# The audible track starts at 0; its analysis copy LOOKAHEAD_S ahead.
	var start := LOOKAHEAD_S
	if p.playing:
		start = fposmod(p.get_playback_position() + LOOKAHEAD_S, length)
	ap.play(start)
	e["ana"] = {"player": ap, "slot": slot, "bus": bus, "tracker": tr, "len": length,
		"wrap": start - fposmod(start, length), "last": start, "mono": start}


func _stop_analysis(e: Dictionary) -> void:
	var a: Dictionary = e.get("ana", {})
	if a.is_empty():
		return
	var ap: AudioStreamPlayer = a["player"]
	if is_instance_valid(ap):
		ap.stop()
		ap.queue_free()
	e["ana"] = {}


## One bus per slot, created once: silent (the analyzer reads the signal
## before the bus volume), sent to Master like every bus must be.
func _analysis_bus(slot: int) -> int:
	var name := ANALYSIS_BUS % slot
	var idx := AudioServer.get_bus_index(name)
	if idx >= 0:
		return idx
	idx = AudioServer.bus_count
	AudioServer.add_bus(idx)
	AudioServer.set_bus_name(idx, name)
	AudioServer.set_bus_send(idx, "Master")
	AudioServer.set_bus_volume_db(idx, -80.0)
	var sa := AudioEffectSpectrumAnalyzer.new()
	sa.buffer_length = 0.5
	sa.fft_size = AudioEffectSpectrumAnalyzer.FFT_SIZE_1024
	AudioServer.add_bus_effect(idx, sa, 0)
	return idx


func _tick_analysis(delta: float, paused: bool) -> void:
	for sid in _players:
		var e: Dictionary = _players[sid]
		if bool(e["on"]) and not paused:
			e["vt"] = float(e["vt"]) + delta
		var a: Dictionary = e["ana"]
		if a.is_empty():
			continue
		if not bool(e["on"]):
			_stop_analysis(e)
			continue
		var ap: AudioStreamPlayer = a["player"]
		ap.stream_paused = paused
		if paused or not ap.playing:
			continue
		var pos := ap.get_playback_position()
		if pos < float(a["last"]) - 0.5:
			a["wrap"] = float(a["wrap"]) + float(a["len"])
		a["last"] = pos
		# The track position alone (no time-since-mix extrapolation: measured
		# closer to the true tempo — 128.09 vs 128.23 BPM on a 128 track).
		var mono := float(a["wrap"]) + pos
		a["mono"] = mono
		var inst := AudioServer.get_bus_effect_instance(int(a["bus"]), 0) as AudioEffectSpectrumAnalyzerInstance
		if inst == null:
			continue
		var m := inst.get_magnitude_for_frequency_range(BASS_LO_HZ, BASS_HI_HZ,
			AudioEffectSpectrumAnalyzerInstance.MAGNITUDE_MAX)
		(a["tracker"] as BeatTracker).feed(mono, m.x + m.y)


## The HEARD position on the analysis clock: LOOKAHEAD_S behind it, less the
## output latency (what the speakers are playing now).
static func _heard(a: Dictionary) -> float:
	return float(a["mono"]) - LOOKAHEAD_S - AudioServer.get_output_latency()


func _fade(delta: float) -> void:
	var main := get_parent()
	var paused := SimFxRate.is_paused(main)
	var vol := NpcDisplayPrefs.stage_music_volume()
	for sid in _players:
		var e: Dictionary = _players[sid]
		var p: AudioStreamPlayer3D = e["player"]
		if p == null:
			continue
		var target := 1.0 if bool(e["on"]) and vol > 0.0 else 0.0
		e["gain"] = move_toward(float(e["gain"]), target, delta / FADE_S)
		var g := float(e["gain"]) * vol
		if g <= 0.001:
			if p.playing:
				p.stop()
			continue
		p.stream_paused = paused
		var a: Dictionary = e["ana"]
		var want_pos := 0.0
		if not a.is_empty():
			want_pos = fposmod(float(a["mono"]) - LOOKAHEAD_S, float(a["len"]))
		if not p.playing and not paused:
			p.play(want_pos)
		elif p.playing and not paused and not a.is_empty():
			# Keep what you hear on the analysis clock (the beat the crowd
			# dances to IS this track's).
			var drift := absf(wrapf(p.get_playback_position() - want_pos, -float(a["len"]) * 0.5,
				float(a["len"]) * 0.5))
			if drift > RESYNC_S:
				p.seek(want_pos)
		p.volume_db = linear_to_db(g)


func _publish(paused: bool) -> void:
	var out: Array = []
	var now := Time.get_ticks_usec()
	for sid in _players:
		var e: Dictionary = _players[sid]
		if not bool(e["on"]) or not (e["pos"] is Vector2) or e["pos"] == Vector2.INF:
			continue
		var q: Dictionary = {}
		var live := false
		var a: Dictionary = e["ana"]
		if not a.is_empty():
			var tr: BeatTracker = a["tracker"]
			if not tr.synced():
				continue   # a few seconds in: no tempo yet, nobody fakes one
			q = tr.query(_heard(a))
			live = true
		elif str(e["stype"]) == "stage":
			q = BeatGrid.state(float(e["vt"]), float(e["seed"]))
		else:
			continue
		q["sid"] = sid
		q["pos"] = e["pos"]
		q["radius"] = StageBeat.EARSHOT_M
		q["stamp_us"] = now
		q["running"] = not paused
		q["live"] = live
		out.append(q)
	StageBeat.publish(out)
	var cam := get_viewport().get_camera_3d() if get_viewport() != null else null
	StageBeat.push_shader(cam.global_position if cam != null else Vector3.ZERO)


func _registry(main: Node) -> SpaceRegistry:
	var b := _bridge()
	if b != null and b.has_method("registry_for"):
		var r: Variant = b.call("registry_for", main)
		if r is SpaceRegistry:
			return r
	var loader := TerrainSurfaceQuery.find_terrain_loader(main)
	if loader != null:
		var reg: Variant = loader.get("npc_spaces")
		if reg is SpaceRegistry:
			return reg
	return null


func _bridge() -> Object:
	var scene := get_tree().current_scene if get_tree() != null else null
	var sgv := scene.get_node_or_null("UILayer/SystemGraphView") if scene != null else null
	if sgv == null or not sgv.has_method("npc_population_bridge"):
		return null
	return sgv.call("npc_population_bridge")


## Diagnostics / harness: {sid: {file, on, gain, playing, pos, analysed,
## synced, bpm}}.
func status() -> Dictionary:
	var out := {}
	for sid in _players:
		var e: Dictionary = _players[sid]
		var p: AudioStreamPlayer3D = e["player"]
		var a: Dictionary = e["ana"]
		var tr: BeatTracker = a.get("tracker") if not a.is_empty() else null
		out[sid] = {"file": e["file"], "on": e["on"], "gain": e["gain"],
			"playing": p.playing if p != null else false,
			"pos": p.global_position if p != null else Vector3.ZERO,
			"analysed": tr != null, "synced": tr != null and tr.synced(),
			"bpm": tr.bpm() if tr != null else 0.0}
	return out
