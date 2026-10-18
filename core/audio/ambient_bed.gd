class_name AmbientBed
extends Node

## The first-person sound bed — a child of Main (made in Main._ready beside
## StageMusic). Four non-positional layers under ONE rule (AmbientMix):
## wind with WeatherService's wind speed, rain with rain_rate_mmh, the
## nearest StreamNetwork feature's Manning velocity falling off with
## distance, birdsong gated by DaylightModel and the forest round the
## listener (TerrainLoader.forest_trees_within). Each layer plays the
## player's own file from user://ambient/<layer>.{mp3,ogg,wav} when there is
## one, else a procedural loop (AmbientSynth) made once at load — the repo
## ships no audio. Muted while SimFxRate says the sim is paused and away
## from first person (the graph hides the world; the settlement view, the
## globe and the window wall own the camera). Volume: NpcDisplayPrefs
## .ambient_volume (Settings → NPCs, beside the stage music).

const DIR := "user://ambient/"
const LAYERS := ["wind", "rain", "stream", "birds"]
const POLL_S := 0.25
const SLOW_POLL_S := 2.0      # the forest count + the stream search
const CHIRP_VARIANTS := 4
const CHIRP_PLAYERS := 3

var _players: Dictionary = {}       # layer -> AudioStreamPlayer
var _chirps: Array = []             # AudioStreamWAV variants
var _chirp_players: Array = []
var _gain: Dictionary = {}          # layer -> smoothed gain
var _target: Dictionary = {}        # the mix rule's last answer
var _inputs: Dictionary = {}        # what the rule was last fed (probes read it)
var _accum := 0.0
var _slow_accum := SLOW_POLL_S
var _chirp_in_s := 1.0
var _gust_t := 0.0
var _forest := 0.0
var _stream := {}
var _from_files: Dictionary = {}
var _ready_done := false
## Calls played so far (probes count them).
var chirps_played := 0
## Harness / probe: forced inputs win over the live ones (keys of inputs()).
var override_inputs: Dictionary = {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for layer in LAYERS:
		_gain[layer] = 0.0
	# The loops are a few hundred thousand GDScript samples; build them a
	# few frames after the world lands rather than inside its load frame.
	call_deferred("_build")


func _build() -> void:
	for layer in LAYERS:
		if layer == "birds":
			continue
		var p := AudioStreamPlayer.new()
		p.name = layer.capitalize()
		p.bus = "Master"
		p.volume_db = -80.0
		var stream := _load_user_file(layer)
		_from_files[layer] = stream != null
		if stream == null:
			match layer:
				"wind": stream = AmbientSynth.to_wav(AmbientSynth.wind_loop(), true)
				"rain": stream = AmbientSynth.to_wav(AmbientSynth.rain_loop(), true)
				"stream": stream = AmbientSynth.to_wav(AmbientSynth.stream_loop(), true)
		p.stream = stream
		add_child(p)
		_players[layer] = p
	# Birds: a file loops like the others; the procedural chorus is single
	# calls on a Poisson clock over a few one-shot players.
	var bird_file := _load_user_file("birds")
	_from_files["birds"] = bird_file != null
	if bird_file != null:
		var bp := AudioStreamPlayer.new()
		bp.name = "Birds"
		bp.bus = "Master"
		bp.volume_db = -80.0
		bp.stream = bird_file
		add_child(bp)
		_players["birds"] = bp
	else:
		for i in CHIRP_VARIANTS:
			_chirps.append(AmbientSynth.to_wav(AmbientSynth.chirp(101 + i * 17), false))
		for i in CHIRP_PLAYERS:
			var cp := AudioStreamPlayer.new()
			cp.name = "Chirp%d" % i
			cp.bus = "Master"
			cp.volume_db = -80.0
			add_child(cp)
			_chirp_players.append(cp)
	_ready_done = true


static func _load_user_file(layer: String) -> AudioStream:
	for ext in ["mp3", "ogg", "wav"]:
		var path := "%s%s.%s" % [DIR, layer, ext]
		if not FileAccess.file_exists(path):
			continue
		match ext:
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


func _process(delta: float) -> void:
	if not _ready_done:
		return
	var main := get_parent()
	_accum += delta
	_slow_accum += delta
	if _slow_accum >= SLOW_POLL_S:
		_slow_accum = 0.0
		_poll_slow(main)
	if _accum >= POLL_S:
		_accum = 0.0
		_inputs = _live_inputs(main)
		for k in override_inputs:
			_inputs[k] = override_inputs[k]
		_target = AmbientMix.levels(_inputs)
	if _target.is_empty():
		return
	# Gusts ride on the wind's gain: two slow sines, never below 55 %.
	_gust_t += delta
	var gust := 0.8 + 0.15 * sin(_gust_t * 0.31) + 0.1 * sin(_gust_t * 0.73 + 1.3)
	for layer in LAYERS:
		var want := float(_target.get(layer, 0.0))
		if layer == "wind":
			want *= gust
		_gain[layer] = AmbientMix.smooth(float(_gain[layer]), want, delta)
		var p: AudioStreamPlayer = _players.get(layer, null)
		if p == null:
			continue
		var g := float(_gain[layer])
		p.volume_db = AmbientMix.gain_to_db(g)
		if g > 0.001 and not p.playing:
			p.play()
		elif g <= 0.001 and p.playing:
			p.stop()
	_tick_chirps(delta)


## A Poisson scheduler over the one-shot chirp players at the rule's rate.
func _tick_chirps(delta: float) -> void:
	if _chirp_players.is_empty():
		return
	var rate := float(_target.get("chirps_per_s", 0.0))
	var g := float(_gain["birds"])
	if rate <= 0.0 or g <= 0.001:
		return
	_chirp_in_s -= delta
	if _chirp_in_s > 0.0:
		return
	# Next call: exponential gap at the current rate (deterministic hash of
	# the gust clock, never randf — the bed must replay the same).
	var u := fposmod(sin(_gust_t * 12.9898) * 43758.5453, 1.0)
	_chirp_in_s = -log(maxf(1.0 - u, 1e-4)) / rate
	for cp in _chirp_players:
		var p := cp as AudioStreamPlayer
		if p.playing:
			continue
		var v := fposmod(sin(_gust_t * 78.233) * 12345.678, 1.0)
		p.stream = _chirps[int(v * float(_chirps.size())) % _chirps.size()]
		p.pitch_scale = 0.9 + 0.3 * fposmod(v * 7.0, 1.0)
		p.volume_db = AmbientMix.gain_to_db(g * (0.6 + 0.4 * fposmod(v * 13.0, 1.0)))
		p.play()
		chirps_played += 1
		break


## The expensive lookups (forest count, stream search), every SLOW_POLL_S.
func _poll_slow(main: Node) -> void:
	var cam := _listener_camera(main)
	var pos := cam.global_position if cam != null else Vector3.ZERO
	var loader: Node = main.get_node_or_null("TerrainLoader") if main != null else null
	_forest = 0.0
	_stream = {}
	if loader == null:
		return
	if loader.has_method("forest_trees_within"):
		_forest = AmbientMix.forest_density(int(loader.call("forest_trees_within", pos.x, pos.z, AmbientMix.FOREST_RADIUS_M)))
	if loader.has_method("water_network"):
		var wn: Node = loader.call("water_network")
		if wn != null and wn.has_method("nearest_flow"):
			_stream = wn.call("nearest_flow", Vector2(pos.x, pos.z), AmbientMix.STREAM_FAR_M)


func _listener_camera(main: Node) -> Camera3D:
	var vp := get_viewport()
	return vp.get_camera_3d() if vp != null else null


## Everything the rule needs, read off the live world.
func _live_inputs(main: Node) -> Dictionary:
	var out := {"wind_ms": 2.0, "rain_mmh": 0.0, "sun_sin_alt": -1.0, "forest": _forest,
		"stream_v_ms": float(_stream.get("velocity_ms", 0.0)), "stream_dist_m": float(_stream.get("dist_m", -1.0)),
		"volume": NpcDisplayPrefs.ambient_volume(), "paused": SimFxRate.is_paused(main),
		"first_person": _in_first_person(main)}
	if main == null:
		return out
	var ws := get_node_or_null("/root/WeatherService")
	var lat := float(main.get("latitude")) if main.get("latitude") != null else 0.0
	var lon := float(main.get("longitude")) if main.get("longitude") != null else 0.0
	if ws != null and ws.has_method("covers") and bool(ws.call("covers", lat, lon)):
		var month := int(main.get("month"))
		var day := int(main.get("day"))
		var hour := float(main.get("day_time"))
		out["wind_ms"] = float(ws.call("wind_speed_ms", month, day, hour))
		out["rain_mmh"] = float(ws.call("rain_rate_mmh", month, day, hour))
	var clock: Variant = main.get("clock")
	if clock != null and clock.has_method("get_sun_direction"):
		out["sun_sin_alt"] = float((clock.call("get_sun_direction") as Vector3).y)
	return out


## First person = the world is on screen through the player's own camera
## (the drone borrows it, so a flight still hears the wind). The graph
## hides the 3D world; a camera claim (settlement view, globe, window wall)
## swaps the camera.
func _in_first_person(main: Node) -> bool:
	if main == null:
		return false
	var gv := main.get_node_or_null("UILayer/SystemGraphView")
	if gv != null and gv.visible:
		return false
	var cam := _listener_camera(main)
	if cam == null:
		return false
	var pcam: Variant = main.call("_player_camera") if main.has_method("_player_camera") else null
	return pcam == null or cam == pcam


## Probes: the rule's last inputs / answer / the smoothed gains.
func inputs() -> Dictionary:
	return _inputs.duplicate()


func levels() -> Dictionary:
	return _target.duplicate()


func gains() -> Dictionary:
	return _gain.duplicate()


func from_files() -> Dictionary:
	return _from_files.duplicate()


func debug_line() -> String:
	return "wind %.1f m/s -> %.2f · rain %.1f mm/h -> %.2f · stream %.2f m/s at %.0f m -> %.2f · birds (sun %.2f, forest %.2f) -> %.2f · master %.2f%s" % [
		float(_inputs.get("wind_ms", 0.0)), float(_target.get("wind", 0.0)),
		float(_inputs.get("rain_mmh", 0.0)), float(_target.get("rain", 0.0)),
		float(_inputs.get("stream_v_ms", 0.0)), float(_inputs.get("stream_dist_m", -1.0)), float(_target.get("stream", 0.0)),
		float(_inputs.get("sun_sin_alt", 0.0)), float(_inputs.get("forest", 0.0)), float(_target.get("birds", 0.0)),
		float(_target.get("master", 0.0)),
		"" if bool(_inputs.get("first_person", true)) else " (not first person)"]
