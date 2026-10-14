class_name NpcStandIns
extends RefCounted
## People something else is drawing right now (a build site's actors, swarm
## B6): owner key -> {agent id: true}. NpcPopulationHost hides their own
## bodies. Pure and static on purpose — a build site that names the host
## class would pull its autoload dependencies into every `--script`
## selftest that loads a placed prop.

static var _by_owner: Dictionary = {}


## Claim (or, with an empty set, release) the people `owner` draws.
static func set_for(owner: String, ids: Dictionary) -> void:
	if ids.is_empty():
		_by_owner.erase(owner)
	else:
		_by_owner[owner] = ids.duplicate()


static func has(agent_id: String) -> bool:
	for k in _by_owner:
		if (_by_owner[k] as Dictionary).has(agent_id):
			return true
	return false


static func is_empty() -> bool:
	return _by_owner.is_empty()


static func clear() -> void:
	_by_owner.clear()
