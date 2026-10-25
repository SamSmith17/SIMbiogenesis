class_name NpcFriends
extends RefCounted

## Friend groups: who in a camp hangs out TOGETHER.
##
## Real festival-goers are not 855 individuals making 855 choices — they move
## in twos, threes and fours. A group here is the unit of LEISURE decisions:
## the hourly SOCIAL choice (venue / circle / wander), the evening venue's
## taste and the comfort responses (shade, the fire, a tarp in the rain) are
## all hashed from the GROUP key instead of the person, so friends end up in
## the same place at the same time, while needs (eat, drink, sleep, the
## toilet) stay personal — a friend who needs the portapotty splits off and
## rejoins.
##
## Pure and stateless, and identical in both tiers by construction: a group
## is a function of the person's id ("<camp seed>_npc_<i>") alone. The camp's
## index line is cut into consecutive groups whose sizes are hashed per camp,
## so camp-mates who share a tent are usually also friends.

## Group sizes and their weights (a solo festival-goer is real but rare).
const SIZES: Array = [1, 2, 3, 4, 5]
const WEIGHTS: Array = [0.12, 0.30, 0.28, 0.20, 0.10]
const MAX_SIZE := 5
## Partitions are cached per camp seed up to this many people (a camp is at
## most a few hundred; the light tier clamps at 5000).
const MAX_INDEX := 5000

static var _cut_cache: Dictionary = {}   # seed -> PackedInt32Array of group starts


## {key, size, k (index within the group, 0 = whoever leads), camp} for a person.
## A malformed id is a group of one keyed on itself.
static func group_of(agent_id: String) -> Dictionary:
	var cut := agent_id.rfind("_npc_")
	if cut <= 0:
		return {"key": agent_id, "size": 1, "k": 0, "camp": agent_id}
	var seed := agent_id.substr(0, cut)
	var idx_s := agent_id.substr(cut + 5)
	if not idx_s.is_valid_int():
		return {"key": agent_id, "size": 1, "k": 0, "camp": seed}
	var idx := clampi(int(idx_s), 0, MAX_INDEX - 1)
	var starts := _starts_for(seed, idx)
	# Binary search for the group holding idx.
	var lo := 0
	var hi := starts.size() - 2
	while lo < hi:
		var mid := (lo + hi + 1) >> 1
		if starts[mid] <= idx:
			lo = mid
		else:
			hi = mid - 1
	var g := lo
	var a := starts[g]
	var size := starts[g + 1] - a
	return {"key": group_key(seed, g), "size": size, "k": idx - a, "camp": seed, "g": g}


## The key of camp `seed`'s g-th group (what group_of returns as "key").
static func group_key(seed: String, g: int) -> String:
	return "%s_grp_%d" % [seed, g]


## How many groups a camp of `n` people is cut into.
static func group_count(seed: String, n: int) -> int:
	if n <= 0:
		return 0
	return _starts_for(seed, n - 1).size() - 1


static func key_of(agent_id: String) -> String:
	return str(group_of(agent_id)["key"])


## Group start indices for a camp, long enough to cover `idx` (extended on
## demand; the tail entry is the END of the last group).
static func _starts_for(seed: String, idx: int) -> PackedInt32Array:
	var starts: PackedInt32Array = _cut_cache.get(seed, PackedInt32Array([0]))
	while starts[starts.size() - 1] <= idx:
		var g := starts.size() - 1
		starts.append(starts[g] + size_for(seed, g))
	_cut_cache[seed] = starts
	return starts


## The hashed size of group `g` in camp `seed`.
static func size_for(seed: String, g: int) -> int:
	var u := NpcHash.unit01(seed, "grp%d" % g)
	var acc := 0.0
	for i in SIZES.size():
		acc += float(WEIGHTS[i])
		if u < acc:
			return int(SIZES[i])
	return int(SIZES[SIZES.size() - 1])


## Where member `k` of a group of `size` stands in its F-FORMATION (Kendon:
## the shared space a conversation holds between its members) round
## `centre`: evenly round a small ring, its radius growing with the group,
## the ring's phase hashed per group so two groups never line up. A pair
## stands face to face, a solo person just off the centre.
static func formation_offset(group_key: String, k: int, size: int, seed01: float = 0.5) -> Vector2:
	var n := maxi(size, 1)
	var r := 0.45 + 0.22 * float(n)
	if n == 1:
		r = 0.0
	var a0 := NpcHash.unit01(group_key, "ff") * TAU
	var a := a0 + TAU * float(k) / float(n) + (seed01 - 0.5) * 0.35
	return Vector2(cos(a), sin(a)) * (r + (seed01 - 0.5) * 0.18)


## Side-by-side offset for a group walking somewhere together (a wander):
## members spread across the direction of travel, 0.9 m apart.
static func abreast_offset(k: int, size: int, dir: Vector2) -> Vector2:
	var d := dir.normalized() if dir.length() > 1e-6 else Vector2(1.0, 0.0)
	var side := Vector2(-d.y, d.x)
	return side * ((float(k) - float(maxi(size, 1) - 1) * 0.5) * 0.9)


## Drop the partition cache (tests).
static func clear_cache() -> void:
	_cut_cache = {}
