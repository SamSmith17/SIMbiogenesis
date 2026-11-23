extends Node
## OffService — in-game Open Food Facts lookups (plans/FOOD_WASTE_REALISM_PLAN.md
## Phase 3): add-a-product-by-barcode and free-text product search for the
## shopping UI. The shipped catalog (FoodProducts) covers offline play; this
## service only ADDS products the player asks for.
##
## API: https://world.openfoodfacts.org — no key. Data is ODbL; see
## CREDITS.md (data-openfoodfacts). OFF's rate limits are 15 product
## reads / 10 searches a minute, so requests go through one queue with a
## per-kind minimum spacing and never retry-storm. The User-Agent is a
## GENERIC client name on purpose (never the player's identity).
##
## Product replies are cached under user://food_cache/ for CACHE_MAX_AGE_S
## (products change rarely); a cached reply answers WITHOUT network.
## Offline / simkit (`SimkitMode.blocks("food_products")`) / failed →
## the *_failed signal, nothing errors, nothing blocks.
##
## Parsing is FoodProducts.parse_off_product — one parser for the game,
## the catalog tool and this service. The selftest feeds the public parse
## wrappers fixtures; no test touches the network.

signal product_ready(barcode: String, record: Dictionary)
signal product_failed(barcode: String, reason: String)
signal search_ready(query: String, records: Array)
signal search_failed(query: String, reason: String)

const PRODUCT_URL := "https://world.openfoodfacts.org/api/v2/product/%s.json?fields=%s"
## v2 has no free-text search; the v1 endpoint is the documented route for it.
const SEARCH_URL := "https://world.openfoodfacts.org/cgi/search.pl?search_terms=%s&search_simple=1&action=process&json=1&page_size=%d&page=%d&fields=%s"
const FIELDS := "code,product_name,brands,categories_tags,quantity,product_quantity,serving_size,serving_quantity,nutriments,packagings,rev"
const UA := "SIMbiogenesis/1.0 (open-source simulation game)"

const CACHE_DIR := "user://food_cache"
## Bump when FIELDS or the envelope changes so old blobs retire.
const CACHE_VERSION := "v1"
const CACHE_MAX_AGE_S := 30 * 24 * 3600
const SEARCH_PAGE_SIZE := 24

## OFF rate limits: product <= 15/min, search <= 10/min.
const PRODUCT_SPACING_S := 4.2
const SEARCH_SPACING_S := 6.2
const MAX_QUEUE := 12

## Tests set this true: every request fails at once, nothing opens a socket
## (the ImageryService pattern).
static var offline_for_test := false

var _http: HTTPRequest = null
var _fetching := false
var _current: Dictionary = {}
var _queue: Array = []
var _last_sent_unix := {"product": 0.0, "search": 0.0}


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))


func _ensure_http() -> void:
	if _http != null and is_instance_valid(_http):
		return
	_http = HTTPRequest.new()
	_http.timeout = 30.0
	add_child(_http)
	_http.request_completed.connect(_on_completed)


## --- public API ---------------------------------------------------------------

## The cached product record for a barcode, {} when not cached (or stale).
func cached_product(barcode: String) -> Dictionary:
	var env := _load_cache(barcode)
	if env.is_empty():
		return {}
	var j := JSON.new()
	if j.parse(str(env.get("response_text", ""))) != OK or not (j.data is Dictionary):
		return {}
	return parse_product_json(j.data)


## Fetch one product by barcode. Emits product_ready / product_failed
## (deferred when answered from cache, so a consumer connecting right after
## this call still hears it — the project-wide signal rule).
func request_product(barcode: String) -> void:
	var code := barcode.strip_edges()
	if code.is_empty() or not code.is_valid_int():
		product_failed.emit.call_deferred(code, "not a barcode")
		return
	var cached := cached_product(code)
	if not cached.is_empty() and _cache_fresh(code):
		product_ready.emit.call_deferred(code, cached)
		return
	_enqueue({"kind": "product", "key": code,
		"url": PRODUCT_URL % [code, FIELDS]})


## Free-text search. Emits search_ready(query, [records]) / search_failed.
func request_search(query: String, page: int = 1) -> void:
	var q := query.strip_edges()
	if q.is_empty():
		search_failed.emit.call_deferred(q, "empty search")
		return
	_enqueue({"kind": "search", "key": q,
		"url": SEARCH_URL % [q.uri_encode(), SEARCH_PAGE_SIZE, maxi(page, 1), FIELDS]})


## --- pure parse wrappers (fixture-testable) ------------------------------------

static func parse_product_json(body: Dictionary) -> Dictionary:
	return FoodProducts.parse_off_product(body)


## A v1 search reply ({products: [...]}) -> product records, unparsable
## entries dropped.
static func parse_search_json(body: Dictionary) -> Array:
	var out: Array = []
	for p in body.get("products", []):
		if not (p is Dictionary):
			continue
		var rec := FoodProducts.parse_off_product(p)
		if not rec.is_empty():
			out.append(rec)
	return out


## --- queue + fetch plumbing -----------------------------------------------------

func _enqueue(job: Dictionary) -> void:
	if offline_for_test or SimkitMode.blocks("food_products"):
		_emit_failed(job, "offline")
		return
	for q in _queue:
		if str(q.get("url", "")) == str(job.get("url", "")):
			return  # already queued
	if _queue.size() >= MAX_QUEUE:
		_emit_failed(job, "too many requests queued")
		return
	_queue.append(job)
	_pump()


func _pump() -> void:
	if _fetching or _queue.is_empty():
		return
	var job: Dictionary = _queue[0]
	var kind := str(job.get("kind", "product"))
	var spacing := PRODUCT_SPACING_S if kind == "product" else SEARCH_SPACING_S
	var wait := float(_last_sent_unix.get(kind, 0.0)) + spacing - Time.get_unix_time_from_system()
	if wait > 0.0:
		get_tree().create_timer(wait).timeout.connect(_pump, CONNECT_ONE_SHOT)
		return
	_queue.pop_front()
	_ensure_http()
	_current = job
	_fetching = true
	_last_sent_unix[kind] = Time.get_unix_time_from_system()
	var err := ERR_UNAVAILABLE if (offline_for_test or SimkitMode.blocks("food_products")) \
			else _http.request(str(job["url"]), ["User-Agent: %s" % UA])
	if err != OK:
		_fetching = false
		_emit_failed(job, "HTTPRequest error %d" % err)
		_schedule_pump()


func _on_completed(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray) -> void:
	if not _fetching:
		return
	_fetching = false
	var job := _current
	_current = {}
	if result != HTTPRequest.RESULT_SUCCESS:
		_emit_failed(job, "network error %d" % result)
		_schedule_pump()
		return
	if code == 404 and str(job.get("kind", "")) == "product":
		_emit_failed(job, "no such product")
		_schedule_pump()
		return
	if code != 200:
		# 429 / 5xx: one polite retry later via the queue's own spacing.
		if (code == 429 or code >= 500) and not bool(job.get("retried", false)):
			var retry := job.duplicate()
			retry["retried"] = true
			_queue.append(retry)
			_emit_nothing()
		else:
			_emit_failed(job, "HTTP %d" % code)
		_schedule_pump()
		return
	var text := body.get_string_from_utf8()
	var j := JSON.new()
	if j.parse(text) != OK or not (j.data is Dictionary):
		_emit_failed(job, "bad reply")
		_schedule_pump()
		return
	if str(job.get("kind", "")) == "search":
		search_ready.emit(str(job.get("key", "")), parse_search_json(j.data))
	else:
		var rec := parse_product_json(j.data)
		if rec.is_empty():
			_emit_failed(job, "no such product")
		else:
			_store_cache(str(job.get("key", "")), text)
			product_ready.emit(str(job.get("key", "")), rec)
	_schedule_pump()


func _schedule_pump() -> void:
	if _queue.is_empty():
		return
	get_tree().create_timer(0.1).timeout.connect(_pump, CONNECT_ONE_SHOT)


func _emit_failed(job: Dictionary, reason: String) -> void:
	if str(job.get("kind", "")) == "search":
		search_failed.emit.call_deferred(str(job.get("key", "")), reason)
	else:
		product_failed.emit.call_deferred(str(job.get("key", "")), reason)


func _emit_nothing() -> void:
	pass


## --- cache ----------------------------------------------------------------------

func _cache_path(barcode: String) -> String:
	return CACHE_DIR.path_join("off_%s.json" % barcode)


func _load_cache(barcode: String) -> Dictionary:
	var path := _cache_path(barcode)
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var j := JSON.new()
	if j.parse(f.get_as_text()) != OK or not (j.data is Dictionary):
		return {}
	var env: Dictionary = j.data
	if str(env.get("cache_version", "")) != CACHE_VERSION:
		return {}
	return env


func _cache_fresh(barcode: String) -> bool:
	var env := _load_cache(barcode)
	if env.is_empty():
		return false
	return Time.get_unix_time_from_system() - float(env.get("fetched_unix", 0.0)) < CACHE_MAX_AGE_S


func _store_cache(barcode: String, response_text: String) -> void:
	var f := FileAccess.open(_cache_path(barcode), FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"cache_version": CACHE_VERSION,
		"fetched_unix": Time.get_unix_time_from_system(),
		"response_text": response_text}))
	f.close()
