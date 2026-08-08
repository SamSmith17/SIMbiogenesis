class_name NpcHash
extends RefCounted

## One avalanche hash for every per-agent scatter in the population system.
##
## Godot's String hash for a sequence like "hab_npc_0".."hab_npc_23" is nearly
## SEQUENTIAL, so taking it modulo a small number lands the whole camp in a
## handful of buckets. Measured over 64 ids in 8 bins: the `% 997` form leaves
## FIVE BINS EMPTY with 30 of the 64 in one of them; the avalanche below fills
## every bin (4-11 each). A "random per-person" value drawn the naive way is
## therefore not random at all — it is three or four values shared by everybody,
## which is exactly the lockstep it was added to prevent.
##
## `NpcRoutine.offset_for` discovered this the hard way (24 people, 4 distinct
## schedule offsets) and fixed it locally. This is that fix, extracted, so the
## other sites of the same bug can adopt it verbatim instead of each re-deriving
## it — or, more often, not.
##
## ⚠ The arithmetic is BIT-IDENTICAL to the original on purpose. Routine offsets
## shift every agent's whole day, so a change of one ULP here would move every
## sim golden in the suite. `_test_hash_distribution` pins `offset_for` against
## a frozen literal captured from the pre-extraction code for that reason.
##
## Two deliberate NON-adopters, both load-bearing:
##   - `NpcAgent.name_for` — `snapshot()` only persists `display_name` when it
##     differs from `name_for(id)`, so changing that hash would silently RENAME
##     every unnamed person in every existing save.
##   - `NpcPopulationEngine.color_for_agent` — the golden-ratio multiply is
##     already the avalanche there, and it is the documented
##     `RemotePlayerAvatar.color_for_peer` idiom.


## The murmur3 finaliser variant. Neighbouring inputs land far apart.
static func mix(key: String) -> int:
	var h := absi(hash(key))
	h = (h ^ (h >> 16)) * 0x7feb352d
	h = (h ^ (h >> 15)) * 0x846ca68b
	return absi(h ^ (h >> 16))


## 0..1 inclusive. `salt` gives one agent independent draws for independent
## purposes — without it, "which gait" and "which stance" would be perfectly
## correlated across the whole camp.
static func unit01(key: String, salt: String = "") -> float:
	var k := key if salt.is_empty() else key + "|" + salt
	# The modulus is prime and far larger than any bucket count we take from it,
	# so the residual bias is well under a rendering frame's worth of anything.
	return float(mix(k) % 10007) / 10006.0


## A stable index in 0..n-1. Returns 0 for n <= 1 rather than dividing by zero.
static func pick(key: String, salt: String, n: int) -> int:
	if n <= 1:
		return 0
	return mini(int(unit01(key, salt) * float(n)), n - 1)
