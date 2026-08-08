extends Node

## Phase 3–4 design collaboration under MultiplayerSession:
## - chunked .esim push → ghost preview (graph + 3D props) → merge
## - host-canonical live graph/props snapshot sync + soft locks

signal offer_changed()
signal sync_changed()
signal locks_changed()

const EsimPackageScript := preload("res://core/esim/esim_package.gd")
const EsimImporterScript := preload("res://core/esim/esim_importer.gd")
const MpTransferScript := preload("res://core/multiplayer/mp_transfer.gd")
const MpPropGhostScript := preload("res://core/multiplayer/mp_prop_ghost_layer.gd")

const SYNC_DEBOUNCE_S := 0.35
const SNAPSHOT_RESYNC_S := 12.0
const MAX_OFFERS := 4

## Incoming design offers: transfer_id -> {from_peer, from_name, summary, package?, chunks{}, total, ready}
var offers: Dictionary = {}
## Currently previewed offer id (empty if none).
var active_offer_id: String = ""
var pending_package: Dictionary = {}
var ghost_prop_count: int = 0

var live_sync_enabled: bool = true
var design_rev: int = 0
## target_key ("graph:<id>" | "prop:<id>") -> {peer_id, name, until_ms}
var locks: Dictionary = {}

var _applying: bool = false
var _graph_timer: Timer = null
var _props_timer: Timer = null
var _resync_timer: Timer = null
var _tx_counter: int = 0
var _inbound: Dictionary = {}  # transfer_id -> assemble state
var resync_count: int = 0


func _ready() -> void:
	name = "Design"
	_graph_timer = Timer.new()
	_graph_timer.one_shot = true
	_graph_timer.wait_time = SYNC_DEBOUNCE_S
	_graph_timer.timeout.connect(_flush_graph_snapshot)
	add_child(_graph_timer)
	_props_timer = Timer.new()
	_props_timer.one_shot = true
	_props_timer.wait_time = SYNC_DEBOUNCE_S
	_props_timer.timeout.connect(_flush_props_snapshot)
	add_child(_props_timer)
	_resync_timer = Timer.new()
	_resync_timer.one_shot = false
	_resync_timer.wait_time = SNAPSHOT_RESYNC_S
	_resync_timer.timeout.connect(_host_periodic_resync)
	add_child(_resync_timer)


func session() -> Node:
	return get_parent()


func is_session_active() -> bool:
	var s := session()
	return s != null and s.has_method("is_active") and bool(s.call("is_active"))


func clear_session_state() -> void:
	offers.clear()
	active_offer_id = ""
	pending_package = {}
	ghost_prop_count = 0
	locks.clear()
	design_rev = 0
	_inbound.clear()
	_applying = false
	resync_count = 0
	if _graph_timer != null:
		_graph_timer.stop()
	if _props_timer != null:
		_props_timer.stop()
	if _resync_timer != null:
		_resync_timer.stop()
	var main := _find_main()
	MpPropGhostScript.clear(main)
	var sgv := _find_sgv(main)
	if sgv != null and sgv.has_method("clear_esim_ghost"):
		sgv.call("clear_esim_ghost")
	offer_changed.emit()
	sync_changed.emit()
	locks_changed.emit()


func on_session_started() -> void:
	if _resync_timer != null:
		_resync_timer.start()
	# Host pushes an initial snapshot shortly after session start / join welcome.
	if _is_host():
		call_deferred("_flush_graph_snapshot")
		call_deferred("_flush_props_snapshot")


func on_joined_as_client() -> void:
	# Ask host for canonical design.
	rpc_request_full_sync.rpc_id(1)


# ── Phase 3: share / preview / merge ─────────────────────────────────────────

func share_my_design() -> Dictionary:
	if not is_session_active():
		return {"ok": false, "error": "Not in a session"}
	var main := _find_main()
	var collected: Dictionary = EsimPackageScript.collect_from_main(main)
	if not bool(collected.get("ok", false)):
		return collected
	var pkg: Dictionary = collected.get("package", {}) as Dictionary
	var enc: Dictionary = MpTransferScript.encode_dict(pkg)
	if not bool(enc.get("ok", false)):
		return enc
	var bytes: PackedByteArray = enc.get("bytes", PackedByteArray()) as PackedByteArray
	var chunks: Array = MpTransferScript.chunk_bytes(bytes)
	_tx_counter += 1
	var transfer_id := "%d_%d" % [multiplayer.get_unique_id(), _tx_counter]
	var summary: Dictionary = EsimPackageScript.summary_of(pkg)
	var from_name := str(session().get("display_name"))
	# Always stage via host so every peer receives (client→host→broadcast).
	var from_peer := multiplayer.get_unique_id()
	if _is_host():
		_broadcast_design_chunks(
			transfer_id, from_peer, from_name, summary, chunks, bytes.size())
	else:
		rpc_design_begin.rpc_id(
			1, transfer_id, from_peer, from_name, summary, chunks.size(), bytes.size())
		for i in chunks.size():
			rpc_design_chunk.rpc_id(1, transfer_id, i, chunks[i])
		rpc_design_end.rpc_id(1, transfer_id)
	_status("Shared design with session (%d nodes, %d props)" % [
		int(summary.get("item_count", 0)), int(summary.get("prop_count", 0))], "ok")
	return {"ok": true, "transfer_id": transfer_id, "summary": summary, "chunks": chunks.size()}


func _broadcast_design_chunks(transfer_id: String, from_peer: int, from_name: String,
		summary: Dictionary, chunks: Array, compressed_size: int) -> void:
	rpc_design_begin.rpc(
		transfer_id, from_peer, from_name, summary, chunks.size(), compressed_size)
	for i in chunks.size():
		rpc_design_chunk.rpc(transfer_id, i, chunks[i])
	rpc_design_end.rpc(transfer_id)


func preview_offer(transfer_id: String) -> Dictionary:
	var offer: Dictionary = offers.get(transfer_id, {}) as Dictionary
	if offer.is_empty() or not bool(offer.get("ready", false)):
		return {"ok": false, "error": "Offer not ready"}
	var pkg: Dictionary = offer.get("package", {}) as Dictionary
	return preview_package(pkg, transfer_id)


func preview_package(package: Dictionary, offer_id: String = "") -> Dictionary:
	var v: Dictionary = EsimPackageScript.validate(package)
	if not bool(v.get("ok", false)):
		return v
	var main := _find_main()
	var tree := get_tree()
	# Graph ghost via existing Phase 1 path.
	var ghost_graph: Dictionary = EsimImporterScript.apply_to_scene(
		tree, package, {"mode": "ghost"})
	if not bool(ghost_graph.get("ok", false)):
		return ghost_graph
	var tint := Color(0.35, 0.8, 1.0, 0.42)
	var from_peer := int((offers.get(offer_id, {}) as Dictionary).get("from_peer", 0))
	if from_peer > 0:
		tint = RemotePlayerAvatar.color_for_peer(from_peer)
		tint.a = 0.42
	var prop_result: Dictionary = MpPropGhostScript.spawn_from_package(main, package, tint)
	ghost_prop_count = int(prop_result.get("count", 0))
	pending_package = package.duplicate(true)
	active_offer_id = offer_id
	offer_changed.emit()
	_status("Ghost preview · %d graph nodes · %d props" % [
		int(ghost_graph.get("item_count", 0)), ghost_prop_count], "info")
	return {
		"ok": true,
		"item_count": int(ghost_graph.get("item_count", 0)),
		"prop_count": ghost_prop_count,
	}


func discard_preview() -> void:
	var main := _find_main()
	MpPropGhostScript.clear(main)
	var sgv := _find_sgv(main)
	if sgv != null and sgv.has_method("clear_esim_ghost"):
		sgv.call("clear_esim_ghost")
	pending_package = {}
	active_offer_id = ""
	ghost_prop_count = 0
	offer_changed.emit()
	_status("Ghost preview cleared", "info")


func apply_pending(mode: String = "replace") -> Dictionary:
	## mode: replace | graph_only | props_only
	if pending_package.is_empty():
		return {"ok": false, "error": "No pending design preview"}
	var pkg := pending_package.duplicate(true)
	discard_preview()
	_applying = true
	var result: Dictionary
	match mode:
		"graph_only":
			result = EsimImporterScript.apply_to_scene(get_tree(), pkg, {
				"mode": "replace", "graph_only": true})
		"props_only":
			result = _apply_props_only(pkg)
		_:
			result = EsimImporterScript.apply_to_scene(get_tree(), pkg, {"mode": "replace"})
	_applying = false
	if bool(result.get("ok", false)):
		_status("Merged shared design (%s)" % mode, "ok")
		# After merge, host/client should push live snapshot.
		notify_graph_edited("merge")
		notify_props_edited()
	else:
		_status(str(result.get("error", "Merge failed")), "error")
	offer_changed.emit()
	return result


func dismiss_offer(transfer_id: String) -> void:
	if active_offer_id == transfer_id:
		discard_preview()
	offers.erase(transfer_id)
	offer_changed.emit()


func list_offers() -> Array:
	var out: Array = []
	for tid in offers.keys():
		var o: Dictionary = offers[tid] as Dictionary
		out.append({
			"id": tid,
			"from_peer": int(o.get("from_peer", 0)),
			"from_name": str(o.get("from_name", "")),
			"summary": o.get("summary", {}),
			"ready": bool(o.get("ready", false)),
		})
	return out


@rpc("any_peer", "reliable", "call_remote")
func rpc_design_begin(transfer_id: String, from_peer: int, from_name: String,
		summary: Dictionary, total_chunks: int, compressed_size: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if transfer_id.is_empty() or total_chunks <= 0:
		return
	if compressed_size > MpTransferScript.MAX_PAYLOAD_BYTES:
		_note_traffic(sender, MpHardening.COST_DESIGN_START)
		_status("Rejected oversized design package", "warn")
		return
	if not _note_traffic(sender, MpHardening.COST_DESIGN_START):
		return
	# Prefer explicit author id (survives host rebroadcast); fall back to sender.
	var author := from_peer if from_peer > 0 else sender
	_inbound[transfer_id] = {
		"from_peer": author,
		"from_name": from_name,
		"summary": summary.duplicate(true),
		"total": total_chunks,
		"chunks": {},
		"compressed_size": compressed_size,
		"sender": sender,
	}


@rpc("any_peer", "reliable", "call_remote")
func rpc_design_chunk(transfer_id: String, index: int, data: PackedByteArray) -> void:
	if not _inbound.has(transfer_id):
		return
	var state: Dictionary = _inbound[transfer_id] as Dictionary
	var sender := int(state.get("sender", multiplayer.get_remote_sender_id()))
	if not _note_traffic(sender, MpHardening.COST_DESIGN_CHUNK):
		_inbound.erase(transfer_id)
		return
	var chunks: Dictionary = state.get("chunks", {}) as Dictionary
	chunks[index] = data
	state["chunks"] = chunks


@rpc("any_peer", "reliable", "call_remote")
func rpc_design_end(transfer_id: String) -> void:
	if not _inbound.has(transfer_id):
		return
	var state: Dictionary = _inbound[transfer_id] as Dictionary
	var total := int(state.get("total", 0))
	var assembled: PackedByteArray = MpTransferScript.assemble_chunks(
		state.get("chunks", {}) as Dictionary, total)
	var from_peer := int(state.get("from_peer", 0))
	var from_name := str(state.get("from_name", "Peer"))
	_inbound.erase(transfer_id)
	if assembled.is_empty():
		_status("Design transfer incomplete", "warn")
		return
	var decoded: Dictionary = MpTransferScript.decode_bytes(assembled)
	if not bool(decoded.get("ok", false)):
		_status(str(decoded.get("error", "Bad design payload")), "warn")
		return
	var pkg: Dictionary = decoded.get("data", {}) as Dictionary
	var v: Dictionary = EsimPackageScript.validate(pkg)
	if not bool(v.get("ok", false)):
		_status(str(v.get("error", "Invalid .esim")), "warn")
		return
	# Host receiving a client share: keep a local offer + rebroadcast to peers.
	var sender := int(state.get("sender", from_peer))
	if _is_host() and sender != 0 and sender != multiplayer.get_unique_id():
		_store_offer(transfer_id, from_peer, from_name, pkg)
		var chunks: Array = MpTransferScript.chunk_bytes(assembled)
		_broadcast_design_chunks(
			transfer_id, from_peer, from_name, EsimPackageScript.summary_of(pkg),
			chunks, assembled.size())
		return
	# Skip offering a design back to its author.
	if from_peer == multiplayer.get_unique_id():
		return
	_store_offer(transfer_id, from_peer, from_name, pkg)


func _store_offer(transfer_id: String, from_peer: int, from_name: String, pkg: Dictionary) -> void:
	while offers.size() >= MAX_OFFERS:
		var keys := offers.keys()
		offers.erase(keys[0])
	offers[transfer_id] = {
		"from_peer": from_peer,
		"from_name": from_name,
		"summary": EsimPackageScript.summary_of(pkg),
		"package": pkg,
		"ready": true,
	}
	_status("Design offer from %s — open Multiplayer to preview" % from_name, "ok")
	offer_changed.emit()


# ── Phase 4: live snapshot sync ──────────────────────────────────────────────

func set_live_sync_enabled(on: bool) -> void:
	live_sync_enabled = on
	sync_changed.emit()
	_status("Live design sync %s" % ("ON" if on else "OFF"), "info")


func notify_graph_edited(_reason: String = "") -> void:
	if not live_sync_enabled or not is_session_active() or _applying:
		return
	if _graph_timer != null:
		_graph_timer.start(SYNC_DEBOUNCE_S)


func notify_props_edited() -> void:
	if not live_sync_enabled or not is_session_active() or _applying:
		return
	if _props_timer != null:
		_props_timer.start(SYNC_DEBOUNCE_S)


func request_lock(target: String) -> Dictionary:
	if not is_session_active() or target.is_empty():
		return {"ok": false, "error": "No session"}
	var existing: Dictionary = locks.get(target, {}) as Dictionary
	var holder := int(existing.get("peer_id", 0))
	var my_id := multiplayer.get_unique_id()
	if holder != 0 and holder != my_id:
		var until := int(existing.get("until_ms", 0))
		if until > Time.get_ticks_msec():
			return {"ok": false, "error": "Locked by %s" % str(existing.get("name", "peer"))}
	rpc_lock_claim.rpc(target, str(session().get("display_name")))
	return {"ok": true}


func release_lock(target: String) -> void:
	if not is_session_active() or target.is_empty():
		return
	rpc_lock_release.rpc(target)


func lock_holder_name(target: String) -> String:
	var existing: Dictionary = locks.get(target, {}) as Dictionary
	if existing.is_empty():
		return ""
	if int(existing.get("until_ms", 0)) < Time.get_ticks_msec():
		return ""
	return str(existing.get("name", ""))


@rpc("any_peer", "reliable", "call_local")
func rpc_lock_claim(target: String, p_name: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	# Had no gate and no rate limit at all: a peer could claim every lock on the
	# site before it had even said hello. This is a `call_local` RPC that
	# bypasses _note_traffic, so the check has to be explicit.
	if not _peer_admitted(sender):
		return
	var existing: Dictionary = locks.get(target, {}) as Dictionary
	var holder := int(existing.get("peer_id", 0))
	if holder != 0 and holder != sender and int(existing.get("until_ms", 0)) > Time.get_ticks_msec():
		return
	locks[target] = {
		"peer_id": sender,
		"name": p_name,
		"until_ms": Time.get_ticks_msec() + 30_000,
	}
	locks_changed.emit()


@rpc("any_peer", "reliable", "call_local")
func rpc_lock_release(target: String) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender == 0:
		sender = multiplayer.get_unique_id()
	if not _peer_admitted(sender):
		return
	var existing: Dictionary = locks.get(target, {}) as Dictionary
	if int(existing.get("peer_id", 0)) in [0, sender]:
		locks.erase(target)
		locks_changed.emit()


func _flush_graph_snapshot() -> void:
	if not live_sync_enabled or not is_session_active() or _applying:
		return
	var main := _find_main()
	var sgv := _find_sgv(main)
	if sgv == null or not sgv.has_method("collect_save_state"):
		return
	var state: Dictionary = sgv.call("collect_save_state")
	state = EsimPackageScript.strip_esim_ghosts_from_graph_state(state)
	if _is_host():
		design_rev += 1
	var enc: Dictionary = MpTransferScript.encode_dict({
		"kind": "graph",
		"rev": design_rev if _is_host() else design_rev + 1,
		"state": state,
	})
	if not bool(enc.get("ok", false)):
		return
	_send_sync_payload(enc.get("bytes", PackedByteArray()) as PackedByteArray, "graph")


func _flush_props_snapshot() -> void:
	if not live_sync_enabled or not is_session_active() or _applying:
		return
	var main := _find_main()
	var loader := _find_loader(main)
	if loader == null or not loader.has_method("collect_esim_site_layers"):
		return
	var layers: Dictionary = loader.call("collect_esim_site_layers")
	if _is_host():
		design_rev += 1
	var enc: Dictionary = MpTransferScript.encode_dict({
		"kind": "props",
		"rev": design_rev if _is_host() else design_rev + 1,
		"placed_props": layers.get("placed_props", {}),
		"soi": layers.get("soi", {}),
	})
	if not bool(enc.get("ok", false)):
		return
	_send_sync_payload(enc.get("bytes", PackedByteArray()) as PackedByteArray, "props")


func _host_periodic_resync() -> void:
	if not _is_host() or not live_sync_enabled or not is_session_active():
		return
	resync_count += 1
	var s := session()
	if s != null and s.has_method("log_telemetry"):
		s.call("log_telemetry", "design_resync", {"count": resync_count, "rev": design_rev})
	_flush_graph_snapshot()
	_flush_props_snapshot()


func _note_traffic(peer_id: int, cost: int) -> bool:
	var s := session()
	if s != null and s.has_method("note_peer_traffic"):
		return bool(s.call("note_peer_traffic", peer_id, cost))
	return true


## Admission check for the two RPCs that do not route through _note_traffic.
## Permissive when there is no session (headless selftests instantiate this
## controller standalone).
func _peer_admitted(peer_id: int) -> bool:
	var s := session()
	if s == null or not s.has_method("peer_admitted"):
		return true
	if not bool(s.call("is_host")):
		return true  # only the host arbitrates
	return bool(s.call("peer_admitted", peer_id))


func _send_sync_payload(bytes: PackedByteArray, kind: String) -> void:
	var chunks: Array = MpTransferScript.chunk_bytes(bytes)
	_tx_counter += 1
	var transfer_id := "sync_%s_%d_%d" % [kind, multiplayer.get_unique_id(), _tx_counter]
	if _is_host():
		rpc_sync_begin.rpc(transfer_id, kind, chunks.size())
		for i in chunks.size():
			rpc_sync_chunk.rpc(transfer_id, i, chunks[i])
		rpc_sync_end.rpc(transfer_id)
	else:
		rpc_sync_begin.rpc_id(1, transfer_id, kind, chunks.size())
		for i in chunks.size():
			rpc_sync_chunk.rpc_id(1, transfer_id, i, chunks[i])
		rpc_sync_end.rpc_id(1, transfer_id)


@rpc("any_peer", "reliable", "call_remote")
func rpc_request_full_sync() -> void:
	if not _is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	if not _note_traffic(sender, MpHardening.COST_DESIGN_START):
		return
	_flush_graph_snapshot()
	_flush_props_snapshot()


@rpc("any_peer", "reliable", "call_remote")
func rpc_sync_begin(transfer_id: String, kind: String, total_chunks: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	# Host→client sync has sender 0/1 depending on peer; only rate-limit clients.
	if sender > 1 and not _note_traffic(sender, MpHardening.COST_DESIGN_START):
		return
	_inbound[transfer_id] = {
		"kind": kind,
		"from_peer": sender,
		"total": total_chunks,
		"chunks": {},
		"is_sync": true,
	}


@rpc("any_peer", "reliable", "call_remote")
func rpc_sync_chunk(transfer_id: String, index: int, data: PackedByteArray) -> void:
	if not _inbound.has(transfer_id):
		return
	var state: Dictionary = _inbound[transfer_id] as Dictionary
	var sender := int(state.get("from_peer", multiplayer.get_remote_sender_id()))
	if sender > 1 and not _note_traffic(sender, MpHardening.COST_DESIGN_CHUNK):
		_inbound.erase(transfer_id)
		return
	var chunks: Dictionary = state.get("chunks", {}) as Dictionary
	chunks[index] = data
	state["chunks"] = chunks


@rpc("any_peer", "reliable", "call_remote")
func rpc_sync_end(transfer_id: String) -> void:
	if not _inbound.has(transfer_id):
		return
	var state: Dictionary = _inbound[transfer_id] as Dictionary
	var total := int(state.get("total", 0))
	var assembled: PackedByteArray = MpTransferScript.assemble_chunks(
		state.get("chunks", {}) as Dictionary, total)
	_inbound.erase(transfer_id)
	if assembled.is_empty():
		return
	var decoded: Dictionary = MpTransferScript.decode_bytes(assembled)
	if not bool(decoded.get("ok", false)):
		return
	var payload: Dictionary = decoded.get("data", {}) as Dictionary
	var sender := int(state.get("from_peer", 0))

	# Clients send to host; host accepts (bumps rev) + rebroadcasts as authority.
	if _is_host() and sender != 0 and sender != multiplayer.get_unique_id():
		design_rev += 1
		payload["rev"] = design_rev
		_apply_sync_payload(payload)
		var re_enc: Dictionary = MpTransferScript.encode_dict(payload)
		if bool(re_enc.get("ok", false)):
			var bytes: PackedByteArray = re_enc.get("bytes", PackedByteArray()) as PackedByteArray
			var chunks: Array = MpTransferScript.chunk_bytes(bytes)
			_tx_counter += 1
			var out_id := "sync_rebroadcast_%d" % _tx_counter
			rpc_sync_begin.rpc(out_id, str(payload.get("kind", "")), chunks.size())
			for i in chunks.size():
				rpc_sync_chunk.rpc(out_id, i, chunks[i])
			rpc_sync_end.rpc(out_id)
		return

	# Host-originated apply on clients.
	if not _is_host():
		_apply_sync_payload(payload)


func _apply_sync_payload(payload: Dictionary) -> void:
	var kind := str(payload.get("kind", ""))
	var rev := int(payload.get("rev", 0))
	if rev > 0 and rev < design_rev:
		return
	if rev > design_rev:
		design_rev = rev
	_applying = true
	match kind:
		"graph":
			var sgv := _find_sgv(_find_main())
			var state: Dictionary = payload.get("state", {}) as Dictionary
			if sgv != null and not state.is_empty() and sgv.has_method("apply_save_state"):
				sgv.call("apply_save_state", state)
		"props":
			var loader := _find_loader(_find_main())
			if loader != null and loader.has_method("apply_esim_site_layers"):
				loader.call("apply_esim_site_layers", {
					"placed_props": payload.get("placed_props", {}),
					"soi": payload.get("soi", {}),
				}, {"rebuild": true})
	_applying = false
	sync_changed.emit()


func _apply_props_only(package: Dictionary) -> Dictionary:
	var loader := _find_loader(_find_main())
	if loader == null or not loader.has_method("apply_esim_site_layers"):
		return {"ok": false, "error": "TerrainLoader missing"}
	var result: Dictionary = loader.call("apply_esim_site_layers", {
		"placed_props": package.get("placed_props", {}),
		"soi": package.get("soi", {}),
		"building_styles": package.get("building_styles", {}),
		"user_water": package.get("user_water", {}),
	}, {"rebuild": true})
	return result if not result.is_empty() else {"ok": true}


# ── Helpers ──────────────────────────────────────────────────────────────────

func _is_host() -> bool:
	var s := session()
	return s != null and s.has_method("is_host") and bool(s.call("is_host"))


func _find_main() -> Node:
	var s := session()
	if s != null and s.has_method("_find_main"):
		return s.call("_find_main")
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return null
	var scene := tree.current_scene
	if str(scene.name) == "Main":
		return scene
	return scene.find_child("Main", true, false)


func _find_sgv(main: Node) -> Node:
	if main == null:
		return null
	var n := ServiceLocator.graph()
	if n != null:
		return n
	return main.find_child("SystemGraphView", true, false)


func _find_loader(main: Node) -> Node:
	if main == null:
		return null
	var n := main.get_node_or_null("TerrainLoader")
	if n != null:
		return n
	return main.find_child("TerrainLoader", true, false)


func _status(text: String, level: String) -> void:
	var s := session()
	if s != null and s.has_method("_emit_status"):
		s.call("_emit_status", text, level)
