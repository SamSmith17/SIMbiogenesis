class_name VegTierRings
extends RefCounted

## Static SoI-centred detail rings (veg overhaul Phase 3). Canopy LOD tier is
## assigned PER 256 m CHUNK at build time from the chunk's distance to the
## Sphere-of-Influence centre — NOT from the camera:
##
##   NEAR ring  (≤ veg_near_ring_m)  → full leaf-shell/fur tier + far pair
##   MID ring   (≤ veg_mid_ring_m)   → FAR card mesh only
##   OUTER ring (beyond)             → cheapest representation (FAR cards for
##                                     now; the Phase 3b impostor quad)
##
## This is the user-requested model: a high-cost region around the site core
## that does NOT move with the player, with cheap-but-convincing vegetation at
## distance. It also bounds the prim cost structurally — the expensive leaf
## tier can only ever exist in the handful of core-ring chunks, instead of
## following the camera across a 30 km map. All visibility ranges stay
## build-time-only (AMD Vulkan constraint); moving the SoI pin re-rings on the
## next rebuild.

const RING_NEAR := 0
const RING_MID := 1
const RING_OUTER := 2

const DEFAULT_NEAR_RING_M := 250.0
const DEFAULT_MID_RING_M := 700.0


static func enabled(settings: Dictionary) -> bool:
	return bool(settings.get("veg_tier_rings_enabled", true))


static func params_from_settings(settings: Dictionary) -> Dictionary:
	var near_m := maxf(float(settings.get("veg_near_ring_m", DEFAULT_NEAR_RING_M)), 0.0)
	return {
		"center": Vector2(float(settings.get("veg_ring_center_x", 0.0)),
			float(settings.get("veg_ring_center_z", 0.0))),
		"near_m": near_m,
		"mid_m": maxf(float(settings.get("veg_mid_ring_m", DEFAULT_MID_RING_M)), near_m),
	}


## Ring for chunk (cx, cz) of size chunk_size_m. Classified by the chunk's
## CLOSEST point to the centre, so a chunk straddling a boundary errs toward
## the higher-detail ring — the ring edge never bisects a chunk visibly.
static func ring_for_chunk(cx: int, cz: int, chunk_size_m: float,
		center: Vector2, near_m: float, mid_m: float) -> int:
	var min_x := float(cx) * chunk_size_m
	var min_z := float(cz) * chunk_size_m
	var px := clampf(center.x, min_x, min_x + chunk_size_m)
	var pz := clampf(center.y, min_z, min_z + chunk_size_m)
	var d := Vector2(px, pz).distance_to(center)
	if d <= near_m:
		return RING_NEAR
	if d <= mid_m:
		return RING_MID
	return RING_OUTER


## Convenience: ring for a chunk under `settings` (reads params + enable flag;
## disabled → everything NEAR, i.e. the pre-ring behavior).
static func ring_for_chunk_settings(cx: int, cz: int, chunk_size_m: float,
		settings: Dictionary) -> int:
	if not enabled(settings):
		return RING_NEAR
	var p := params_from_settings(settings)
	return ring_for_chunk(cx, cz, chunk_size_m, p["center"], p["near_m"], p["mid_m"])
