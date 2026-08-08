class_name SiteProjectStore
extends RefCounted

## Per-habitat collection of SiteProject records, persisted into the habitat
## item's `specs["site_projects"]` beside pop_state (same change-gated write
## path in NpcPopulationBridge._maybe_persist). Records stay LEAN — the plan
## meta is a summary, never a timeline dump — and the collection is capped
## with oldest-done pruning so the specs blob can't grow without bound.

const MAX_PROJECTS := 8

var projects: Array = []   # of SiteProject record Dictionaries


func add(project: Dictionary) -> void:
	projects.append(project)
	_prune()


func find(project_id: String) -> Dictionary:
	for p in projects:
		if str((p as Dictionary).get("id", "")) == project_id:
			return p
	return {}


func remove(project_id: String) -> bool:
	for i in projects.size():
		if str((projects[i] as Dictionary).get("id", "")) == project_id:
			projects.remove_at(i)
			return true
	return false


func active() -> Array:
	var out: Array = []
	for p in projects:
		if str((p as Dictionary).get("state", "")) == "active":
			out.append(p)
	return out


## Derive every active project's task statuses from the board. Returns true
## when anything changed.
func sync(board) -> bool:
	var changed := false
	for p in projects:
		if SiteProject.sync_with_board(p as Dictionary, board):
			changed = true
	return changed


func _prune() -> void:
	while projects.size() > MAX_PROJECTS:
		var victim := -1
		for i in projects.size():
			if str((projects[i] as Dictionary).get("state", "")) != "active":
				victim = i
				break
		# All active and over cap: drop the oldest anyway — the cap is the
		# contract that bounds the persisted blob.
		projects.remove_at(victim if victim >= 0 else 0)


func serialize() -> Array:
	var out: Array = []
	for p in projects:
		out.append((p as Dictionary).duplicate(true))
	return out


func deserialize(data: Array) -> void:
	projects = []
	for p in data:
		if p is Dictionary:
			projects.append((p as Dictionary).duplicate(true))
