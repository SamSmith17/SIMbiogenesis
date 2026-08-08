extends Node

## The one HTTP client every Discord surface shares.
##
## Follows this project's established service shape (see
## `core/terrain/elevation_service.gd` and `ai_imagery_service.gd`): a lazily
## created child `HTTPRequest`, a `_pending` queue behind a `_busy` flag, results
## delivered through a Callable, and linear backoff on 429/5xx.
##
## Two rules that are not conventions but security properties:
##
##   1. A request carrying an `Authorization` header may only target
##      discord.com. A community file is untrusted pasted input and contains
##      URLs we will POST to; without this, one bad file turns the game into an
##      SSRF proxy that leaks a bearer token.
##   2. Nothing here ever logs a request body or an Authorization header.
##
## Not an autoload — `DiscordIdentity` owns one instance and lends it to the
## directory, gate and relay, so per-route rate limiting stays in one place.

signal offline_changed(offline: bool)

const REQUEST_TIMEOUT := 20.0
const MAX_RETRIES := 3
const RETRY_BACKOFF := 1.5
const MAX_QUEUE := 32

var offline := false

var _http: HTTPRequest = null
var _busy := false
var _pending: Array = []
var _job: Dictionary = {}


func _ready() -> void:
	name = "DiscordHttp"


## `on_done` receives {ok, code, body: Dictionary, raw: String, error: String}.
## `body` is {} when the response was not JSON (a 204, or an HTML error page).
func request(method: int, url: String, on_done: Callable, opts: Dictionary = {}) -> void:
	var bearer := str(opts.get("bearer", "")).strip_edges()
	if not bearer.is_empty() and not DiscordConfig.is_allowed_api_url(url):
		# Refuse rather than "helpfully" stripping the header: a caller that
		# reaches here has been handed a URL it should never have trusted.
		_deliver(on_done, {
			"ok": false, "code": 0, "body": {}, "raw": "",
			"error": "Refusing to send credentials to a non-Discord host",
		})
		return
	if _pending.size() >= MAX_QUEUE:
		_deliver(on_done, {"ok": false, "code": 0, "body": {}, "raw": "",
			"error": "Discord request queue is full"})
		return
	_pending.append({
		"method": method,
		"url": url,
		"bearer": bearer,
		"body": str(opts.get("body", "")),
		"content_type": str(opts.get("content_type", "application/json")),
		"on_done": on_done,
		"retries": 0,
		# The directory's CLAIM patch sets this. Its election is only correct
		# while neither racer writes during the confirm window, so a silent
		# retry there could land after the rival's re-read and produce two
		# hosts. A 429 on a claim must surface as a loss, not a retry.
		"no_retry": bool(opts.get("no_retry", false)),
	})
	_start_next()


func get_json(url: String, on_done: Callable, bearer: String = "") -> void:
	request(HTTPClient.METHOD_GET, url, on_done, {"bearer": bearer})


func post_json(url: String, payload: Dictionary, on_done: Callable, bearer: String = "") -> void:
	request(HTTPClient.METHOD_POST, url, on_done,
		{"bearer": bearer, "body": JSON.stringify(payload)})


func patch_json(url: String, payload: Dictionary, on_done: Callable,
		bearer: String = "", no_retry: bool = false) -> void:
	request(HTTPClient.METHOD_PATCH, url, on_done,
		{"bearer": bearer, "body": JSON.stringify(payload), "no_retry": no_retry})


func post_form(url: String, form_body: String, on_done: Callable) -> void:
	request(HTTPClient.METHOD_POST, url, on_done,
		{"body": form_body, "content_type": "application/x-www-form-urlencoded"})


func cancel_all() -> void:
	_pending.clear()
	_job = {}
	_busy = false
	if _http != null and is_instance_valid(_http):
		_http.cancel_request()


## Seconds Discord asked us to wait, from either the JSON body or the header.
static func retry_after_from(body: Dictionary, headers: PackedStringArray) -> float:
	if body.has("retry_after"):
		return maxf(0.0, float(body["retry_after"]))
	for h in headers:
		var line := str(h)
		if line.to_lower().begins_with("retry-after:"):
			return maxf(0.0, line.split(":", true, 1)[1].strip_edges().to_float())
	return 1.0


# ── internals ────────────────────────────────────────────────────────────────

func _ensure_http() -> void:
	if _http != null and is_instance_valid(_http):
		return
	_http = HTTPRequest.new()
	_http.timeout = REQUEST_TIMEOUT
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


func _start_next() -> void:
	if _busy or _pending.is_empty():
		return
	_ensure_http()
	_job = _pending.pop_front()
	_busy = true
	var headers := PackedStringArray(["Content-Type: %s" % str(_job["content_type"])])
	var bearer := str(_job["bearer"])
	if not bearer.is_empty():
		headers.append("Authorization: Bearer %s" % bearer)
	var err := _http.request(str(_job["url"]), headers, int(_job["method"]), str(_job["body"]))
	if err != OK:
		var job := _job
		_busy = false
		_job = {}
		_deliver(job["on_done"], {"ok": false, "code": 0, "body": {}, "raw": "",
			"error": "Could not start request (err %d)" % err})
		_start_next()


func _on_request_completed(result: int, code: int, headers: PackedStringArray,
		body: PackedByteArray) -> void:
	var job := _job
	_busy = false
	_job = {}
	if job.is_empty():
		return

	if result != HTTPRequest.RESULT_SUCCESS:
		# Transport failure — the whole subsystem degrades to "Discord
		# unreachable" and every surface says so instead of hanging.
		_set_offline(true)
		if _retry(job):
			return
		_deliver(job["on_done"], {"ok": false, "code": 0, "body": {}, "raw": "",
			"error": "Could not reach Discord (network result %d)" % result})
		_start_next()
		return
	_set_offline(false)

	var raw := body.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(raw)
	var dict: Dictionary = parsed as Dictionary if parsed is Dictionary else {}

	if code == 429 or code >= 500:
		var wait := retry_after_from(dict, headers) if code == 429 else RETRY_BACKOFF
		if _retry(job, wait):
			return

	var ok := code >= 200 and code < 300
	_deliver(job["on_done"], {
		"ok": ok,
		"code": code,
		"body": dict,
		"raw": raw if not ok else "",
		"error": "" if ok else _error_text(code, dict),
		"retry_after": retry_after_from(dict, headers) if code == 429 else 0.0,
	})
	_start_next()


func _retry(job: Dictionary, delay: float = RETRY_BACKOFF) -> bool:
	if bool(job.get("no_retry", false)):
		return false
	var n := int(job.get("retries", 0)) + 1
	if n > MAX_RETRIES:
		return false
	job["retries"] = n
	var wait := delay * float(n)
	get_tree().create_timer(wait).timeout.connect(func() -> void:
		_pending.push_front(job)
		_start_next(), CONNECT_ONE_SHOT)
	return true


func _set_offline(v: bool) -> void:
	if offline == v:
		return
	offline = v
	offline_changed.emit(offline)


static func _error_text(code: int, body: Dictionary) -> String:
	var msg := str(body.get("message", "")).strip_edges()
	if msg.is_empty():
		msg = str(body.get("error_description", "")).strip_edges()
	if msg.is_empty():
		msg = str(body.get("error", "")).strip_edges()
	if msg.is_empty():
		return "Discord returned HTTP %d" % code
	return "%s (HTTP %d)" % [msg, code]


func _deliver(on_done: Callable, payload: Dictionary) -> void:
	if on_done.is_valid():
		on_done.call_deferred(payload)
