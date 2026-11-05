class_name GraphSystemAlerts
extends RefCounted
## The graph's alerts rail (plans/GRAPH_SYSTEMS_UX_PLAN.md, Phase 3): each
## system that NEWLY needs attention adds one entry, latched like the
## settlement log so nothing strobes:
##   - a system must stay worse than it was for HOLD_S before it is shown;
##   - an entry stays until the system has been fine for CLEAR_S;
##   - a system that is already in trouble when the rail first sees it is
##     shown only when it is critical (a festival that loads with forty
##     "open loop" warnings must not fill the rail; the board lists those);
##   - a dismissed entry comes back only if the system gets WORSE.
## Times are real seconds handed in by the caller. Pure.

const HOLD_S := 2.0
const CLEAR_S := 5.0

## id -> {level, since, shown, reason, name, kind, base, dismissed, ok_since}
var _state: Dictionary = {}
var _order: Array = []      # shown ids, newest first
var revision := 0


func clear() -> void:
	_state.clear()
	_order.clear()
	revision += 1


## Feed the board's rows. Returns true when the entries changed.
func update(rows: Array, now_s: float) -> bool:
	var changed := false
	var seen: Dictionary = {}
	for r: Dictionary in rows:
		var id := str(r.get("id", ""))
		if id.is_empty():
			continue
		seen[id] = true
		var lvl := str(r.get("level", "ok"))
		var rank := int(GraphSystemBoard.LEVEL_RANK.get(lvl, 0))
		var reasons: Array = r.get("reasons", []) as Array
		var reason := str(reasons[0]) if not reasons.is_empty() else ""
		var st: Dictionary = _state.get(id, {})
		if st.is_empty():
			# First sight: the level it already has is its baseline, except
			# a critical system, which is news however long it has been so.
			st = {"rank": rank, "since": now_s, "shown": false, "reason": reason,
				"name": str(r.get("name", "")), "kind": str(r.get("kind", "")),
				"base": rank if rank < 3 else 1, "dismissed": -1, "ok_since": -1.0}
			_state[id] = st
		st["name"] = str(r.get("name", ""))
		st["reason"] = reason
		if rank != int(st["rank"]):
			st["rank"] = rank
			st["since"] = now_s
		var bad := rank >= 2 and rank > int(st["base"]) and rank > int(st["dismissed"])
		if bad:
			st["ok_since"] = -1.0
			if not bool(st["shown"]) and now_s - float(st["since"]) >= HOLD_S:
				st["shown"] = true
				st["at"] = now_s
				_order.erase(id)
				_order.push_front(id)
				changed = true
		else:
			if rank < 2:
				st["base"] = mini(int(st["base"]), 1)
				st["dismissed"] = -1
				if float(st["ok_since"]) < 0.0:
					st["ok_since"] = now_s
				if bool(st["shown"]) and now_s - float(st["ok_since"]) >= CLEAR_S:
					st["shown"] = false
					_order.erase(id)
					changed = true
	for id: String in _state.keys():
		if not seen.has(id):
			_state.erase(id)
			if _order.has(id):
				_order.erase(id)
				changed = true
	if changed:
		revision += 1
	return changed


## The player closed an entry: it comes back only if the system gets worse.
func dismiss(id: String) -> void:
	var st: Dictionary = _state.get(id, {})
	if st.is_empty():
		return
	st["dismissed"] = int(st["rank"])
	st["shown"] = false
	_order.erase(id)
	revision += 1


## [{id, name, kind, level, reason}], newest first.
func entries() -> Array:
	var out: Array = []
	for id: String in _order:
		var st: Dictionary = _state[id]
		var lvl := "warn"
		for k: String in GraphSystemBoard.LEVEL_RANK.keys():
			if int(GraphSystemBoard.LEVEL_RANK[k]) == int(st["rank"]):
				lvl = k
		out.append({"id": id, "name": st["name"], "kind": st["kind"], "level": lvl,
			"reason": st["reason"]})
	return out
