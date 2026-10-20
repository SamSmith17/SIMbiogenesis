extends Node

## AiImageryService — AI-enhanced "hero patch" ground imagery for generated maps.
## Takes a real aerial crop (from the hyper drape) around the map origin and asks
## the Gemini "nano-banana" image model to sharpen it + add photorealistic fine
## surface detail, beating the ESRI ~0.24 m/px ceiling where the player spawns.
## Generative (not deterministic super-res): the prompt strongly constrains it to
## preserve framing/positions so the result stays geo-registered; it only recolours
## the ground (buildings/roads/veg are separate meshes), so drift is cosmetic.
##
## Model: gemini-2.5-flash-image (Gemini API generateContent, image in + image out;
## ~$0.04 per image, invisible SynthID watermark). One call per site, cached to
## disk, so it is a one-time cost. Opt-in — nothing runs without a key + toggle.
##
## Key: user://terrain_config.cfg [gemini] api_key=  (or the GEMINI_API_KEY env var,
## the same the offline tools/generate_facades.py uses). User-local, gitignored
## (docs/LOCAL_CONFIG.md policy — never log it).
##
## HTTP + cache + deferred-signal pattern mirrors imagery_service.gd /
## mapillary_service.gd. Cache PNGs under user://terrain_cache/ai_imagery/.

signal ai_imagery_ready(key: String, texture: ImageTexture, bbox: Dictionary)
signal ai_imagery_failed(reason: String)

const MODEL := "gemini-2.5-flash-image"
const ENDPOINT := "https://generativelanguage.googleapis.com/v1beta/models/%s:generateContent"
const CACHE_DIR := "user://terrain_cache/ai_imagery"
const CONFIG_PATH := "user://terrain_config.cfg"
const CACHE_VERSION := "v1"
const REQUEST_TIMEOUT := 120.0
## Instruction that keeps the model an enhancer, not a scene generator: sharpen +
## add micro-detail while preserving exact framing/positions so it stays registered.
const PROMPT := "Enhance this top-down orthographic aerial photograph of the ground. Increase sharpness and add photorealistic fine surface detail such as soil grain, gravel, sand ripples, and small ground vegetation, consistent with what is already visible. Preserve the exact framing, scale, colours, and positions of every feature. Do not add, remove, or move any objects, buildings, vehicles, roads, paths, or shadows. Keep it a flat orthographic top-down view with even lighting."

var _http: HTTPRequest = null
var _busy := false
var _job: Dictionary = {}
var _pending: Array[Dictionary] = []


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))


## True when a Gemini API key is available (config or env).
func has_key() -> bool:
	return not _api_key().is_empty()


## Delete the cached PNG for a key so the next enhance() regenerates it.
func clear_cache(cache_key: String) -> void:
	var cache_path := "%s/ai_%s_%s.png" % [CACHE_DIR, CACHE_VERSION, cache_key]
	if FileAccess.file_exists(cache_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(cache_path))


func _api_key() -> String:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		var k := str(cfg.get_value("gemini", "api_key", "")).strip_edges()
		if not k.is_empty():
			return k
	return OS.get_environment("GEMINI_API_KEY").strip_edges()


## Enhance `source_img` (a real aerial crop) into a higher-detail drape for the
## square described by `bbox` (GeoMath.bbox_for dict). `cache_key` identifies the
## site+radius so the result caches once. `image_size` is "1K" or "2K". Emits
## ai_imagery_ready(cache_key, texture, bbox) on success.
func enhance(source_img: Image, bbox: Dictionary, cache_key: String,
		image_size: String = "2K", force_refetch: bool = false) -> void:
	if source_img == null or source_img.is_empty():
		ai_imagery_failed.emit.call_deferred("no source image to enhance")
		return
	var cache_path := "%s/ai_%s_%s.png" % [CACHE_DIR, CACHE_VERSION, cache_key]
	if not force_refetch and TerrainCacheSettings.cache_enabled():
		var cached := Image.new()
		if FileAccess.file_exists(cache_path) and cached.load(cache_path) == OK:
			print("AiImageryService: hero patch served from cache (%s) — no API call" % cache_key)
			ai_imagery_ready.emit.call_deferred(
				cache_key, ImageTexture.create_from_image(cached), bbox)
			return
	if not has_key():
		ai_imagery_failed.emit.call_deferred(
			"No Gemini key — add [gemini] api_key= to %s (or set GEMINI_API_KEY)" % CONFIG_PATH)
		return

	# Encode the source crop as PNG for the request.
	var png := source_img.save_png_to_buffer()
	if png.is_empty():
		ai_imagery_failed.emit.call_deferred("failed to encode source image")
		return
	var body := {
		"contents": [{
			"parts": [
				{"text": PROMPT},
				{"inlineData": {"mimeType": "image/png",
					"data": Marshalls.raw_to_base64(png)}},
			],
		}],
		"generationConfig": {
			"responseModalities": ["IMAGE"],
			"imageConfig": {"aspectRatio": "1:1",
				"imageSize": ("1K" if image_size == "1K" else "2K")},
		},
	}
	_pending.append({
		"key": cache_key,
		"bbox": bbox,
		"cache_path": cache_path,
		"body": JSON.stringify(body),
	})
	print("AiImageryService: requesting hero patch enhancement (%s, %s) …" % [cache_key, image_size])
	_start_next()


func _start_next() -> void:
	if _busy or _pending.is_empty():
		return
	_ensure_http()
	_job = _pending.pop_front()
	_busy = true
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"x-goog-api-key: %s" % _api_key(),
	])
	var url := ENDPOINT % MODEL
	var err := _http.request(url, headers, HTTPClient.METHOD_POST, str(_job["body"]))
	if err != OK:
		_fail("HTTPRequest error %d" % err)


func _ensure_http() -> void:
	if _http != null and is_instance_valid(_http):
		return
	_http = HTTPRequest.new()
	_http.timeout = REQUEST_TIMEOUT
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


func _on_request_completed(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if _job.is_empty():
		return
	if result != HTTPRequest.RESULT_SUCCESS:
		_fail("request failed (result %d, HTTP %d)" % [result, code])
		return
	if code < 200 or code >= 300:
		_fail("API error HTTP %d: %s" % [code, body.get_string_from_utf8().substr(0, 300)])
		return
	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if not (parsed is Dictionary):
		_fail("unexpected response (not JSON object)")
		return
	var b64 := _extract_image_b64(parsed as Dictionary)
	if b64.is_empty():
		_fail("no image in response: %s" % JSON.stringify(parsed).substr(0, 300))
		return
	var img := Image.new()
	var raw := Marshalls.base64_to_raw(b64)
	if img.load_png_from_buffer(raw) != OK and img.load_jpg_from_buffer(raw) != OK \
			and img.load_webp_from_buffer(raw) != OK:
		_fail("returned image failed to decode")
		return
	if img.get_format() != Image.FORMAT_RGB8 and img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGB8)
	var key := str(_job["key"])
	var bbox: Dictionary = _job["bbox"]
	if TerrainCacheSettings.cache_enabled():
		img.save_png(str(_job["cache_path"]))
	print("AiImageryService: hero patch ready (%s, %dx%d)" % [key, img.get_width(), img.get_height()])
	_busy = false
	_job = {}
	ai_imagery_ready.emit(key, ImageTexture.create_from_image(img), bbox)
	_start_next()


## Pull the first inline image out of a generateContent response.
func _extract_image_b64(resp: Dictionary) -> String:
	var candidates: Variant = resp.get("candidates")
	if not (candidates is Array):
		return ""
	for cand in (candidates as Array):
		if not (cand is Dictionary):
			continue
		var content: Variant = (cand as Dictionary).get("content")
		if not (content is Dictionary):
			continue
		var parts: Variant = (content as Dictionary).get("parts")
		if not (parts is Array):
			continue
		for part in (parts as Array):
			if not (part is Dictionary):
				continue
			var inline: Variant = (part as Dictionary).get("inlineData")
			if inline == null:
				inline = (part as Dictionary).get("inline_data")
			if inline is Dictionary:
				var data: Variant = (inline as Dictionary).get("data")
				if data is String and not (data as String).is_empty():
					return data as String
	return ""


func _fail(reason: String) -> void:
	_busy = false
	_job = {}
	push_warning("AiImageryService: %s" % reason)
	ai_imagery_failed.emit(reason)
	_start_next()
