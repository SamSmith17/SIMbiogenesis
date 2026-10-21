extends Node

## Shared design under MultiplayerSession.
##
## Phase 3 (unchanged): share a whole .esim design → ghost preview → merge.
##
## Live sync — the HOST's world is the shared world, and only CHANGES travel:
## - The host edits: within ~0.1 s the props and graph nodes that changed go to
##   everyone as ops (MpChangeSet) and are applied to just those objects.
## - A guest edits: the change shows on the guest's screen at once, marked as
##   waiting, and goes to the host as a PROPOSAL. The host accepts it (it then
##   goes to everyone) or rejects it (the guest's copy is put back). The host
##   can also accept everything automatically, or take no changes at all.
## - Every few seconds the host sends what its simulation computed (tank
##   levels, live output) — guests do not run the flow engine — plus the
##   design revision, so a guest that missed a change asks for the whole world.
##
## What replaced what: the old sync sent the WHOLE props layer and the WHOLE
## graph on every edit and every 12 s, and the receiver rebuilt every prop and
## re-applied the host's whole save state (lens and camera included). One
## moved tent took seconds to arrive, and anything the guest changed was simply
## written over the host's world with nobody asked.

signal offer_changed()
signal sync_changed()
signal locks_changed()
## Host: the review queue changed. Guest: a proposal was answered.
signal review_changed()
## What the HUD's sync line should say changed.
signal activity_changed()

const EsimPackageScript := preload("res://core/esim/esim_package.gd")
const EsimImporterScript := preload("res://core/esim/esim_importer.gd")
const MpTransferScript := preload("res://core/multiplayer/mp_transfer.gd")
const MpPropGhostScript := preload("res://core/multiplayer/mp_prop_ghost_layer.gd")

const MAX_OFFERS := 4
## Quiet period before a change is sent. The host sends fast (and at least
## every HOST_MAX_HOLD_S during a long burst); a guest waits for a pause so a
## drag becomes ONE proposal, not twenty.
const HOST_DEBOUNCE_S := 0.12
const HOST_MAX_HOLD_S := 0.5
const GUEST_DEBOUNCE_S := 0.45
## Host → guests: simulated values + design revision.
const SIM_FRAME_S := 2.0
## Payloads up to this go as one message; larger ones are chunked.
const INLINE_MAX_BYTES := 48_000
const MAX_REVIEW := 40
const FULL_REQUEST_COOLDOWN_MS := 3000
const ACTIVITY_HOLD_MS := 4000
const REVIEW_GHOST_ROOT := "MpReviewGhosts"

## What the host does with a guest's change.
const POLICY_ASK := "ask"
const POLICY_AUTO := "auto"
const POLICY_VIEW := "view"
const POLICY_LABELS := {
	POLICY_ASK: "Ask me to approve each change",
	POLICY_AUTO: "Accept every change",
	POLICY_VIEW: "Guests can only look",
}

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

## Host: the policy for guests' changes, and peers accepted without asking.
var guest_policy: String = POLICY_ASK
var auto_peers: Dictionary = {}
## Host: proposals waiting for a decision, oldest first:
## {pid, peer, name, props, graph, lines, ms}.
var review: Array = []
## Guest: what the host said its policy is.
var host_policy: String = POLICY_ASK
## Guest: my proposals the host has not answered: pid -> {props, graph, lines, ms}.
var my_pending: Dictionary = {}
## The sync line: {tone: ok|info|warn|busy, text, detail, progress, until_ms}.
var activity: Dictionary = {}
var accepted_count: int = 0
var rejected_count: int = 0

var _applying: bool = false
var _tx_counter: int = 0
var _inbound: Dictionary = {}  # transfer_id -> assemble state
## The shared world as last published by the host (both sides keep it).
var _canon_props: Dictionary = {}
var _canon_graph: Dictionary = {}
## Guest: the shared world plus my unanswered proposals — what a new local
## edit is measured against, so each proposal carries only what is new.
var _shadow_props: Dictionary = {}
var _shadow_graph: Dictionary = {}
var _have_canon: bool = false
var _pid_counter: int = 0
var _first_dirty_ms: int = 0
var _full_requested_ms: int = -100000
var _sim_last: Dictionary = {}
var _send_timer: Timer = null
var _sim_timer: Timer = null


func _ready() -> void:
	name = "Design"
	_send_timer = Timer.new()
	_send_timer.one_shot = true
	_send_timer.timeout.connect(_flush_local_edits)
	add_child(_send_timer)
	_sim_timer = Timer.new()
	_sim_timer.one_shot = false
	_sim_timer.wait_time = SIM_FRAME_S
	_sim_timer.timeout.connect(_host_send_sim_frame)
	add_child(_sim_timer)


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
	_canon_props = {}
	_canon_graph = {}
	_shadow_props = {}
	_shadow_graph = {}
	_have_canon = false
	_first_dirty_ms = 0
	_sim_last = {}
	my_pending.clear()
	host_policy = POLICY_ASK
	accepted_count = 0
	rejected_count = 0
	if _send_timer != null:
		_send_timer.stop()
	if _sim_timer != null:
		_sim_timer.stop()
	var main := _find_main()
	MpPropGhostScript.clear(main)
	for e in review:
		_clear_review_ghosts(str((e as Dictionary).get("pid", "")))
	review.clear()
	activity = {}
	var sgv := _find_sgv(main)
	if sgv != null and sgv.has_method("clear_esim_ghost"):
		sgv.call("clear_esim_ghost")
	_set_id_prefix("")
	offer_changed.emit()
	sync_changed.emit()
	locks_changed.emit()
	review_changed.emit()
	activity_changed.emit()


func on_session_started() -> void:
	# The host's world as it stands IS the shared world.
	_take_canon_from_world()
	if _sim_timer != null:
		_sim_timer.start()


func on_joined_as_client() -> void:
	# Ids this guest mints can never collide with the host's.
	_set_id_prefix("p%d_" % multiplayer.get_unique_id())
	_set_activity("busy", "Getting the host's world…", "", 15000)
	# The host pushes the whole world on admission; ask anyway in case the
	# admission happened before this controller was listening.
	_request_full()


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
	_status("Shared design with session (%s, %s)" % [
		UiText.count(int(summary.get("item_count", 0)), "node"), UiText.count(int(summary.get("prop_count", 0)), "prop")], "ok")
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
	_status("Ghost preview · %s · %s" % [
		UiText.count(int(ghost_graph.get("item_count", 0)), "graph node"), UiText.count(ghost_prop_count, "prop")], "info")
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


# ── Live sync: changes, proposals, review ───────────────────────────────────

func set_live_sync_enabled(on: bool) -> void:
	live_sync_enabled = on
	sync_changed.emit()
	_status("Live design sync %s" % ("ON" if on else "OFF"), "info")


func notify_graph_edited(_reason: String = "") -> void:
	_mark_dirty()


func notify_props_edited() -> void:
	_mark_dirty()


func _mark_dirty() -> void:
	if not live_sync_enabled or not is_session_active() or _applying:
		return
	var now := Time.get_ticks_msec()
	if _first_dirty_ms == 0:
		_first_dirty_ms = now
	if _is_host():
		if now - _first_dirty_ms >= int(HOST_MAX_HOLD_S * 1000.0):
			_send_timer.stop()
			_flush_local_edits()
			return
		_send_timer.start(HOST_DEBOUNCE_S)
	else:
		_send_timer.start(GUEST_DEBOUNCE_S)


func _flush_local_edits() -> void:
	_first_dirty_ms = 0
	if not live_sync_enabled or not is_session_active() or _applying:
		return
	if _is_host():
		_host_publish()
	else:
		_guest_propose()


## Host: send what changed since the last publish (and any `meta` — who made
## an accepted change, in words) to everyone.
func _host_publish(meta: Dictionary = {}) -> void:
	if not _is_host():
		return
	if not _have_canon:
		_take_canon_from_world()
	var pops := MpChangeSet.diff_props(_canon_props, _current_props())
	var gops := {}
	var cur_graph := _current_graph()
	var touched: Variant = _take_touched()
	if not cur_graph.is_empty():
		gops = MpChangeSet.diff_graph(_canon_graph, cur_graph, touched)
		if MpChangeSet.graph_empty(gops):
			gops = {}
	if MpChangeSet.props_empty(pops) and gops.is_empty() and meta.is_empty():
		return
	MpChangeSet.apply_to_index(_canon_props, pops.get("up", []), pops.get("rm", []))
	if not gops.is_empty():
		_canon_graph = MpChangeSet.apply_graph(_canon_graph, gops)
	design_rev += 1
	_send("delta", {"rev": design_rev, "props": pops, "graph": gops, "meta": meta,
		"policy": guest_policy})
	sync_changed.emit()


## Host: the whole shared world to one guest (on join, or when it fell behind).
var _full_sent_ms: Dictionary = {}
func send_full_to(peer_id: int) -> void:
	if not _is_host() or peer_id <= 1:
		return
	var now := Time.get_ticks_msec()
	if now - int(_full_sent_ms.get(peer_id, -100000)) < FULL_REQUEST_COOLDOWN_MS:
		return
	_full_sent_ms[peer_id] = now
	# Whatever the host changed in the last debounce goes out first, so the
	# snapshot and the revision agree.
	_send_timer.stop()
	_first_dirty_ms = 0
	_host_publish()
	var soi := get_node_or_null("/root/SoiService")
	var soi_state: Dictionary = soi.call("collect_save_state") \
		if soi != null and soi.has_method("collect_save_state") else {}
	_send("full", {"rev": design_rev, "props": _canon_props.values(), "graph": _canon_graph,
		"soi": soi_state, "policy": guest_policy}, peer_id)


func _host_send_sim_frame() -> void:
	if not _is_host() or not is_session_active() or multiplayer.get_peers().is_empty():
		return
	var sgv := _find_sgv(_find_main())
	var frame := {}
	if sgv != null and sgv.get("model") != null:
		frame = MpChangeSet.volatile_frame(sgv.model.items, _sim_last)
	# The revision rides along every time: a guest behind it missed a change.
	_send("sim", {"rev": design_rev, "frame": frame, "policy": guest_policy})


func set_guest_policy(policy: String) -> void:
	if not POLICY_LABELS.has(policy):
		return
	guest_policy = policy
	if is_session_active() and _is_host():
		_send("policy", {"policy": policy})
		# Switching to "accept everything" settles the waiting ones too.
		if policy == POLICY_AUTO:
			accept_all()
		elif policy == POLICY_VIEW:
			for e in review.duplicate():
				reject_proposal(str((e as Dictionary).get("pid", "")), "The host is not taking changes now")
	sync_changed.emit()


## [[id, label], …] for the lobby's picker, in display order.
func policy_options() -> Array:
	return [[POLICY_ASK, POLICY_LABELS[POLICY_ASK]], [POLICY_AUTO, POLICY_LABELS[POLICY_AUTO]],
		[POLICY_VIEW, POLICY_LABELS[POLICY_VIEW]]]


func set_auto_accept_peer(peer_id: int, on: bool) -> void:
	if on:
		auto_peers[peer_id] = true
		for e in review.duplicate():
			if int((e as Dictionary).get("peer", 0)) == peer_id:
				accept_proposal(str((e as Dictionary).get("pid", "")))
	else:
		auto_peers.erase(peer_id)
	review_changed.emit()


# -- soft locks ---------------------------------------------------------------

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


# -- guest side ---------------------------------------------------------------

func _guest_propose() -> void:
	if _is_host() or not _have_canon:
		return
	var pops := MpChangeSet.diff_props(_shadow_props, _current_props())
	var gops := {}
	var cur_graph := _current_graph()
	var touched: Variant = _take_touched()
	if not cur_graph.is_empty() and not _shadow_graph.is_empty():
		gops = MpChangeSet.diff_graph(_shadow_graph, cur_graph, touched)
		if MpChangeSet.graph_empty(gops):
			gops = {}
	if MpChangeSet.props_empty(pops) and gops.is_empty():
		return
	var lines := MpChangeSet.summarize(pops, gops, _shadow_props, _shadow_graph)
	if host_policy == POLICY_VIEW:
		_revert_local(pops, gops)
		_set_activity("warn", "View only — the host isn't taking changes", "Put back: %s" % _first_line(lines))
		return
	MpChangeSet.apply_to_index(_shadow_props, pops.get("up", []), pops.get("rm", []))
	if not gops.is_empty():
		_shadow_graph = MpChangeSet.apply_graph(_shadow_graph, gops)
	_pid_counter += 1
	var pid := "%d_%d" % [multiplayer.get_unique_id(), _pid_counter]
	my_pending[pid] = {"props": pops, "graph": gops, "lines": lines, "ms": Time.get_ticks_msec()}
	_send("propose", {"pid": pid, "props": pops, "graph": gops, "base_rev": design_rev})
	_set_activity("busy", _waiting_text(), _first_line(lines), 0)
	review_changed.emit()


func _waiting_text() -> String:
	var n := my_pending.size()
	if host_policy == POLICY_AUTO:
		return "Sending your %s…" % ("change" if n == 1 else "%d changes" % n)
	return "Waiting for %s to approve %s" % [_host_name(),
		"your change" if n == 1 else "%d changes" % n]


func _client_apply_full(p: Dictionary) -> void:
	design_rev = int(p.get("rev", 0))
	host_policy = str(p.get("policy", host_policy))
	var props: Array = p.get("props", []) as Array
	var graph: Dictionary = p.get("graph", {}) as Dictionary
	var main := _find_main()
	_applying = true
	if main != null:
		PlacedPropService.mp_replace_all(main, props)
	var sgv := _find_sgv(main)
	# The host's sphere of influence (centre + radius) — the site everyone plans.
	var soi_state: Dictionary = p.get("soi", {}) as Dictionary
	var soi := get_node_or_null("/root/SoiService")
	if not soi_state.is_empty() and soi != null and soi.has_method("apply_save_state"):
		soi.call("apply_save_state", soi_state)
	if sgv != null and not graph.is_empty() and sgv.has_method("apply_shared_graph"):
		sgv.call("apply_shared_graph", graph)
	_applying = false
	_canon_props = MpChangeSet.index_records(props.duplicate(true))
	_shadow_props = _canon_props.duplicate(true)
	_canon_graph = graph.duplicate(true)
	_shadow_graph = graph.duplicate(true)
	_have_canon = true
	var lost := my_pending.size()
	my_pending.clear()
	call_deferred("_settle_after_apply")
	_set_activity("ok", "In sync with %s's world" % _host_name(),
		("%d unanswered change(s) were dropped" % lost) if lost > 0 else
		"%s · %s" % [UiText.count(props.size(), "object"),
			UiText.count((graph.get("items", []) as Array).size(), "graph node")])
	review_changed.emit()
	sync_changed.emit()


func _client_apply_delta(p: Dictionary) -> void:
	var rev := int(p.get("rev", 0))
	host_policy = str(p.get("policy", host_policy))
	if rev <= design_rev:
		return
	if not _have_canon or rev != design_rev + 1:
		_request_full()
		return
	design_rev = rev
	var pops: Dictionary = p.get("props", {}) as Dictionary
	var gops: Dictionary = p.get("graph", {}) as Dictionary
	_applying = true
	_apply_props_world(pops)
	if not gops.is_empty():
		_apply_graph_world(gops)
	_applying = false
	MpChangeSet.apply_to_index(_canon_props, pops.get("up", []), pops.get("rm", []))
	MpChangeSet.apply_to_index(_shadow_props, pops.get("up", []), pops.get("rm", []))
	if not gops.is_empty():
		_canon_graph = MpChangeSet.apply_graph(_canon_graph, gops)
		_shadow_graph = MpChangeSet.apply_graph(_shadow_graph, gops)
	call_deferred("_settle_after_apply")
	var meta: Dictionary = p.get("meta", {}) as Dictionary
	var lines: Array = meta.get("lines", []) as Array
	var by := str(meta.get("by", ""))
	var accepted: Array = meta.get("accepted", []) as Array
	var mine := false
	for pid in accepted:
		if my_pending.has(str(pid)):
			mine = true
	if not mine:
		if not lines.is_empty():
			_set_activity("info", "%s's change was accepted" % by if not by.is_empty() else "World updated",
				_first_line(lines))
		else:
			var n := (pops.get("up", []) as Array).size() + (pops.get("rm", []) as Array).size() \
				+ (gops.get("items_up", []) as Array).size() + (gops.get("items_rm", []) as Array).size() \
				+ (gops.get("conns_up", []) as Array).size() + (gops.get("conns_rm", []) as Array).size()
			if n > 0:
				_set_activity("info", "Updated from %s" % _host_name(), UiText.count(n, "change"), 2000)
	sync_changed.emit()


func _client_apply_sim(p: Dictionary) -> void:
	host_policy = str(p.get("policy", host_policy))
	var rev := int(p.get("rev", 0))
	if _have_canon and rev > design_rev:
		# Reliable + ordered: every delta up to `rev` came before this. Missing
		# one means the world here is not the host's — get the whole thing.
		_request_full()
		return
	var frame: Dictionary = p.get("frame", {}) as Dictionary
	if frame.is_empty():
		return
	var sgv := _find_sgv(_find_main())
	if sgv != null and sgv.has_method("apply_shared_sim_state"):
		_applying = true
		sgv.call("apply_shared_sim_state", frame)
		_applying = false


func _client_proposal_result(p: Dictionary) -> void:
	var pid := str(p.get("pid", ""))
	var ok := bool(p.get("ok", false))
	var entry: Dictionary = my_pending.get(pid, {}) as Dictionary
	my_pending.erase(pid)
	var line := _first_line(entry.get("lines", []) as Array)
	if ok:
		accepted_count += 1
		if host_policy == POLICY_AUTO:
			_set_activity("ok", "Saved to the shared world", line, 2000)
		else:
			_set_activity("ok", "%s accepted your change" % _host_name(), line)
	else:
		rejected_count += 1
		if not entry.is_empty():
			_revert_local(entry.get("props", {}) as Dictionary, entry.get("graph", {}) as Dictionary)
		var why := str(p.get("reason", ""))
		_set_activity("warn", "%s declined your change — put back" % _host_name(),
			line if why.is_empty() else "%s · %s" % [line, why], 6000)
	if not my_pending.is_empty():
		_set_activity("busy", _waiting_text(), str(activity.get("text", "")), 0)
	review_changed.emit()


## Put what `pops` / `gops` touched back the way the shared world has it.
func _revert_local(pops: Dictionary, gops: Dictionary) -> void:
	var rp := MpChangeSet.revert_props(pops, _canon_props)
	var rg := {}
	if not gops.is_empty():
		rg = MpChangeSet.revert_graph(gops, _canon_graph)
	_applying = true
	_apply_props_world(rp)
	if not rg.is_empty():
		_apply_graph_world(rg)
	_applying = false
	MpChangeSet.apply_to_index(_shadow_props, rp.get("up", []), rp.get("rm", []))
	if not rg.is_empty():
		_shadow_graph = MpChangeSet.apply_graph(_shadow_graph, rg)
	call_deferred("_settle_after_apply")


func _request_full() -> void:
	var now := Time.get_ticks_msec()
	if now - _full_requested_ms < FULL_REQUEST_COOLDOWN_MS:
		return
	_full_requested_ms = now
	_send("request_full", {})


# -- host side: the review queue ---------------------------------------------

func _host_receive_proposal(peer_id: int, p: Dictionary) -> void:
	var pid := str(p.get("pid", ""))
	if pid.is_empty() or not pid.begins_with("%d_" % peer_id):
		return
	var pops: Dictionary = _clean_props_ops(p.get("props", {}))
	var gops: Dictionary = p.get("graph", {}) if p.get("graph") is Dictionary else {}
	if MpChangeSet.props_empty(pops) and (gops.is_empty() or MpChangeSet.graph_empty(gops)):
		return
	var entry := {
		"pid": pid, "peer": peer_id, "name": _peer_name(peer_id),
		"props": pops, "graph": gops, "ms": Time.get_ticks_msec(),
		# Worded HERE, from the host's own copy — text from a guest is never shown.
		"lines": MpChangeSet.summarize(pops, gops, _canon_props, _canon_graph),
	}
	if guest_policy == POLICY_VIEW:
		_send("result", {"pid": pid, "ok": false, "reason": "The host is not taking changes now"}, peer_id)
		return
	if guest_policy == POLICY_AUTO or auto_peers.has(peer_id):
		_host_accept_entry(entry)
		return
	while review.size() >= MAX_REVIEW:
		var old: Dictionary = review[0]
		reject_proposal(str(old.get("pid", "")), "Too many changes were waiting")
	review.append(entry)
	_show_review_ghosts(entry)
	_set_activity("busy", "%s wants to change the world" % str(entry["name"]), _first_line(entry["lines"]), 0)
	review_changed.emit()


func accept_proposal(pid: String) -> void:
	var idx := _review_index(pid)
	if idx < 0:
		return
	var entry: Dictionary = review[idx]
	review.remove_at(idx)
	_host_accept_entry(entry)
	_after_review_change()


func reject_proposal(pid: String, reason: String = "") -> void:
	var idx := _review_index(pid)
	if idx < 0:
		return
	var entry: Dictionary = review[idx]
	review.remove_at(idx)
	_clear_review_ghosts(pid)
	rejected_count += 1
	_send("result", {"pid": pid, "ok": false, "reason": reason}, int(entry.get("peer", 0)))
	_set_activity("info", "Declined %s's change" % str(entry.get("name", "")),
		_first_line(entry.get("lines", []) as Array), 2500)
	_after_review_change()


func accept_all() -> void:
	for e in review.duplicate():
		accept_proposal(str((e as Dictionary).get("pid", "")))


func reject_all() -> void:
	for e in review.duplicate():
		reject_proposal(str((e as Dictionary).get("pid", "")))


func _host_accept_entry(entry: Dictionary) -> void:
	var pid := str(entry.get("pid", ""))
	_clear_review_ghosts(pid)
	# Flush the host's own pending edits first, so the delta that carries this
	# change is attributed to it alone.
	_send_timer.stop()
	_first_dirty_ms = 0
	_host_publish()
	_applying = true
	_apply_props_world(entry.get("props", {}) as Dictionary)
	var gops: Dictionary = entry.get("graph", {}) as Dictionary
	if not gops.is_empty():
		_apply_graph_world(gops)
	_applying = false
	accepted_count += 1
	_host_publish({"accepted": [pid], "by": str(entry.get("name", "")),
		"lines": entry.get("lines", [])})
	_send("result", {"pid": pid, "ok": true}, int(entry.get("peer", 0)))
	_set_activity("ok", "Accepted %s's change" % str(entry.get("name", "")),
		_first_line(entry.get("lines", []) as Array), 2500)


func _after_review_change() -> void:
	if review.is_empty() and str(activity.get("tone", "")) == "busy":
		activity["until_ms"] = Time.get_ticks_msec() + 1500
	review_changed.emit()
	activity_changed.emit()


func _review_index(pid: String) -> int:
	for i in review.size():
		if str((review[i] as Dictionary).get("pid", "")) == pid:
			return i
	return -1


## A guest's peer drops: its waiting changes go with it.
func drop_peer(peer_id: int) -> void:
	for e in review.duplicate():
		if int((e as Dictionary).get("peer", 0)) == peer_id:
			var pid := str((e as Dictionary).get("pid", ""))
			_clear_review_ghosts(pid)
			review.remove_at(_review_index(pid))
	auto_peers.erase(peer_id)
	_full_sent_ms.erase(peer_id)
	review_changed.emit()


## What a proposal will do, drawn in the world: new / moved objects as ghosts
## in the guest's colour, removed ones as red ghosts where they stand.
func _show_review_ghosts(entry: Dictionary) -> void:
	var main := _find_main()
	if main == null:
		return
	var root := main.get_node_or_null(REVIEW_GHOST_ROOT) as Node3D
	if root == null:
		root = Node3D.new()
		root.name = REVIEW_GHOST_ROOT
		main.add_child(root)
	var holder := Node3D.new()
	holder.name = "P_" + str(entry.get("pid", "")).replace(".", "_")
	root.add_child(holder)
	var tint := RemotePlayerAvatar.color_for_peer(int(entry.get("peer", 0)))
	tint.a = 0.45
	var pops: Dictionary = entry.get("props", {}) as Dictionary
	for rec in pops.get("up", []):
		var g := MpPropGhostScript._make_ghost_node(main, rec as Dictionary, tint)
		if g != null:
			holder.add_child(g)
	for id in pops.get("rm", []):
		var old: Dictionary = _canon_props.get(str(id), {}) as Dictionary
		if old.is_empty():
			continue
		var g2 := MpPropGhostScript._make_ghost_node(main, old, Color(1.0, 0.25, 0.2, 0.45))
		if g2 != null:
			holder.add_child(g2)


func _clear_review_ghosts(pid: String) -> void:
	var main := _find_main()
	if main == null or pid.is_empty():
		return
	var root := main.get_node_or_null(REVIEW_GHOST_ROOT)
	if root == null:
		return
	var holder := root.get_node_or_null("P_" + pid.replace(".", "_"))
	if holder != null:
		holder.queue_free()


## Where a proposal's first object stands (the review card's "Show").
func proposal_focus_point(pid: String) -> Vector3:
	var idx := _review_index(pid)
	if idx < 0:
		return Vector3.INF
	var pops: Dictionary = (review[idx] as Dictionary).get("props", {}) as Dictionary
	var recs: Array = pops.get("up", []) as Array
	var rec: Dictionary = recs[0] if not recs.is_empty() else {}
	if rec.is_empty():
		for id in pops.get("rm", []):
			rec = _canon_props.get(str(id), {}) as Dictionary
			if not rec.is_empty():
				break
	if rec.is_empty():
		return Vector3.INF
	var x := float(rec.get("x", 0.0))
	var z := float(rec.get("z", 0.0))
	var gy := TerrainSurfaceQuery.ground_height_at(_find_main(), x, z)
	return Vector3(x, gy if not is_nan(gy) else 0.0, z)


## Records arriving from a guest: dictionaries with an id, nothing else.
static func _clean_props_ops(raw: Variant) -> Dictionary:
	var out := {"up": [], "rm": []}
	if not (raw is Dictionary):
		return out
	for r in (raw as Dictionary).get("up", []):
		if r is Dictionary and not str((r as Dictionary).get("id", "")).is_empty():
			(out["up"] as Array).append(r)
	for id in (raw as Dictionary).get("rm", []):
		if id is String and not (id as String).is_empty():
			(out["rm"] as Array).append(id)
	return out


# -- applying + reading the world ---------------------------------------------

func _apply_props_world(ops: Dictionary) -> void:
	var main := _find_main()
	if main == null or MpChangeSet.props_empty(ops):
		return
	var full := false
	for rec in ops.get("up", []):
		if rec is Dictionary:
			full = PlacedPropService.mp_upsert_record(main, rec as Dictionary) or full
	for id in ops.get("rm", []):
		full = PlacedPropService.mp_remove_record(main, str(id)) or full
	PlacedPropService.mp_finish(main, full)


func _apply_graph_world(ops: Dictionary) -> void:
	var sgv := _find_sgv(_find_main())
	if sgv != null and sgv.has_method("apply_shared_graph_ops"):
		sgv.call("apply_shared_graph_ops", ops)


func _current_props() -> Array:
	var main := _find_main()
	return PlacedPropService.mp_records(main) if main != null else []


func _current_graph() -> Dictionary:
	var sgv := _find_sgv(_find_main())
	if sgv == null or sgv.get("model") == null:
		return {}
	var state := {"graph": sgv.model.serialize()}
	state = EsimPackageScript.strip_esim_ghosts_from_graph_state(state)
	return state.get("graph", {}) as Dictionary


func _take_touched() -> Variant:
	var sgv := _find_sgv(_find_main())
	if sgv == null or sgv.get("model") == null or not sgv.model.has_method("take_mp_touched"):
		return null
	return sgv.model.take_mp_touched()


func _take_canon_from_world() -> void:
	_canon_props = MpChangeSet.index_records(_current_props().duplicate(true))
	_canon_graph = _current_graph()
	_take_touched()
	_have_canon = true


## After a received change: whatever the receiving side's own follow-up code
## wrote to the model (normalisers, seeders) is not this player's edit.
func _settle_after_apply() -> void:
	var tree := get_tree()
	if tree != null:
		await tree.process_frame
	_take_touched()
	_first_dirty_ms = 0
	if _send_timer != null and not _is_host():
		_send_timer.stop()


func _set_id_prefix(prefix: String) -> void:
	var sgv := _find_sgv(_find_main())
	if sgv != null and sgv.get("model") != null:
		sgv.model.id_prefix = prefix


# -- the sync line ------------------------------------------------------------

func _set_activity(tone: String, text: String, detail: String = "", hold_ms: int = ACTIVITY_HOLD_MS,
		progress: float = -1.0) -> void:
	activity = {"tone": tone, "text": text, "detail": detail, "progress": progress,
		"until_ms": (Time.get_ticks_msec() + hold_ms) if hold_ms > 0 else 0}
	activity_changed.emit()


## What the sync line shows now ({} = nothing). A waiting proposal (guest) or
## review (host) keeps it up; anything else fades after its hold.
func activity_now() -> Dictionary:
	if not is_session_active():
		return {}
	if activity.is_empty():
		return {}
	var until := int(activity.get("until_ms", 0))
	if until > 0 and Time.get_ticks_msec() > until:
		if not _is_host() and not my_pending.is_empty():
			return {"tone": "busy", "text": _waiting_text(), "detail": "", "progress": -1.0}
		return {}
	if until == 0 and str(activity.get("tone", "")) == "busy":
		var waiting := my_pending.size() if not _is_host() else review.size()
		if waiting == 0 and str(activity.get("text", "")).begins_with("Waiting"):
			return {}
	return activity


static func _first_line(lines: Array) -> String:
	return str(lines[0]) if not lines.is_empty() else ""


func _host_name() -> String:
	return _peer_name(1) if _peer_name(1) != "Peer 1" else "the host"


func _peer_name(peer_id: int) -> String:
	var s := session()
	if s != null:
		var peers: Variant = s.get("peers")
		if peers is Dictionary and (peers as Dictionary).has(peer_id):
			var n := str(((peers as Dictionary)[peer_id] as Dictionary).get("name", ""))
			if not n.is_empty():
				return n
	return "Peer %d" % peer_id


# -- transport ----------------------------------------------------------------

## `peer` 0 = the natural target (host → everyone, guest → host); > 0 = one peer.
func _send(kind: String, payload: Dictionary, peer: int = 0) -> void:
	if not is_session_active():
		return
	payload["kind"] = kind
	var enc: Dictionary = MpTransferScript.encode_dict(payload)
	if not bool(enc.get("ok", false)):
		_status(str(enc.get("error", "Could not send the change")), "warn")
		return
	var bytes: PackedByteArray = enc.get("bytes", PackedByteArray()) as PackedByteArray
	var target := peer
	if target <= 0:
		target = 0 if _is_host() else 1
	elif target != 1 and not multiplayer.get_peers().has(target):
		return   # left (or never connected): nothing to send to
	if bytes.size() <= INLINE_MAX_BYTES:
		if target == 0:
			rpc_design_msg.rpc(bytes)
		else:
			rpc_design_msg.rpc_id(target, bytes)
		return
	var chunks: Array = MpTransferScript.chunk_bytes(bytes)
	_tx_counter += 1
	var tid := "x_%d_%d" % [multiplayer.get_unique_id(), _tx_counter]
	if target == 0:
		rpc_sync_begin.rpc(tid, kind, chunks.size())
		for i in chunks.size():
			rpc_sync_chunk.rpc(tid, i, chunks[i])
		rpc_sync_end.rpc(tid)
	else:
		rpc_sync_begin.rpc_id(target, tid, kind, chunks.size())
		for i in chunks.size():
			rpc_sync_chunk.rpc_id(target, tid, i, chunks[i])
		rpc_sync_end.rpc_id(target, tid)
	if kind == "full" or kind == "propose":
		_set_activity("busy", "Sending…", UiText.num(float(bytes.size()), "B", 2), 3000)


@rpc("any_peer", "reliable", "call_remote")
func rpc_design_msg(bytes: PackedByteArray) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender > 1 and not _note_traffic(sender, MpHardening.COST_DESIGN_START):
		return
	if bytes.size() > MpTransferScript.MAX_PAYLOAD_BYTES:
		return
	_on_payload(bytes, sender)


func _on_payload(bytes: PackedByteArray, sender: int) -> void:
	var decoded: Dictionary = MpTransferScript.decode_bytes(bytes)
	if not bool(decoded.get("ok", false)):
		return
	var p: Dictionary = decoded.get("data", {}) as Dictionary
	var from_host := sender == 1 and not _is_host()
	match str(p.get("kind", "")):
		"delta":
			if from_host:
				_client_apply_delta(p)
		"full":
			if from_host:
				_client_apply_full(p)
		"sim":
			if from_host:
				_client_apply_sim(p)
		"result":
			if from_host:
				_client_proposal_result(p)
		"policy":
			if from_host:
				host_policy = str(p.get("policy", host_policy))
				sync_changed.emit()
		"propose":
			if _is_host() and sender > 1:
				_host_receive_proposal(sender, p)
		"request_full":
			if _is_host() and sender > 1:
				send_full_to(sender)


@rpc("any_peer", "reliable", "call_remote")
func rpc_sync_begin(transfer_id: String, kind: String, total_chunks: int) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender > 1 and not _note_traffic(sender, MpHardening.COST_DESIGN_START):
		return
	if total_chunks <= 0 or total_chunks * MpTransferScript.CHUNK_BYTES > MpTransferScript.MAX_PAYLOAD_BYTES * 2:
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
	var total := int(state.get("total", 1))
	if total >= 3 and str(state.get("kind", "")) == "full":
		var frac := float(chunks.size()) / float(total)
		_set_activity("busy", "Getting the host's world…", UiText.pct(frac), 8000, frac)


@rpc("any_peer", "reliable", "call_remote")
func rpc_sync_end(transfer_id: String) -> void:
	if not _inbound.has(transfer_id):
		return
	var state: Dictionary = _inbound[transfer_id] as Dictionary
	_inbound.erase(transfer_id)
	var assembled: PackedByteArray = MpTransferScript.assemble_chunks(
		state.get("chunks", {}) as Dictionary, int(state.get("total", 0)))
	if assembled.is_empty():
		if str(state.get("kind", "")) == "full":
			_set_activity("warn", "The host's world did not arrive whole", "Asking again…")
			_full_requested_ms = -100000
			_request_full()
		return
	_on_payload(assembled, int(state.get("from_peer", 0)))


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
