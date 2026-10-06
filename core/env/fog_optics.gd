class_name FogOptics
extends RefCounted

## Pure fog maths shared by the player's fog slider, the microclimate ground-fog
## layer and their selftests. Everything here is expressed through VISIBILITY,
## because that is the one fog number a person can check against what they saw
## ("I could not see the trees 100 m away") and the one every data source
## reports (METAR, HRRR `visibility`, Koschmieder from aerosol).
##
## Koschmieder (1924): V = 3.912 / sigma for a 2 % contrast threshold
## (WMO-No. 8, 2018, Vol. I, ch. 9). Godot's exponential fog and volumetric fog
## are both Beer-Lambert extinction, `1 - exp(-sigma * d)`, so sigma converts
## directly into `fog_density` / `volumetric_fog_density`.

const KOSCHMIEDER := 3.912

## The slider's two ends. 0 is "no added fog" EXACTLY (not "very thin fog") —
## that identity is the whole of the original bug report. Just above 0 the fog
## is barely-there haze; 1.0 is a dense radiation fog where a tree line 40 m
## off is lost (the "dense fog" band of the WMO visibility table is < 50 m).
const AMOUNT_VIS_THIN_M := 20000.0
const AMOUNT_VIS_DENSE_M := 40.0

## How far the volumetric froxel grid reaches. Short enough to keep the froxels
## fine where they matter, long enough that a light haze still builds up
## visibly; beyond it the exponential depth fog carries the distance.
const VOL_LENGTH_MIN_M := 96.0
const VOL_LENGTH_MAX_M := 640.0


## Extinction coefficient (1/m) for a visibility. Infinite / non-positive
## visibility is clear air (0).
static func sigma_for_visibility(vis_m: float) -> float:
	if not is_finite(vis_m) or vis_m <= 0.0:
		return 0.0
	return KOSCHMIEDER / vis_m


static func visibility_for_sigma(sigma: float) -> float:
	if not is_finite(sigma) or sigma <= 0.0:
		return INF
	return KOSCHMIEDER / sigma


## The fog-amount slider (0..1) as a visibility, log-interpolated so equal
## slider steps look like equal steps in density. 0 → INF (no fog).
static func visibility_for_amount(amount: float) -> float:
	if not is_finite(amount) or amount <= 0.0:
		return INF
	var a := clampf(amount, 0.0, 1.0)
	return exp(lerpf(log(AMOUNT_VIS_THIN_M), log(AMOUNT_VIS_DENSE_M), a))


## The slider as a volumetric_fog_density. amount 0 → exactly 0.
static func volumetric_density_for_amount(amount: float) -> float:
	return sigma_for_visibility(visibility_for_amount(amount))


## A volumetric_fog_length that fits the fog: about four visibilities (by then
## the fog has hidden everything anyway), clamped to the froxel budget.
static func volumetric_length_for_visibility(vis_m: float) -> float:
	if not is_finite(vis_m):
		return VOL_LENGTH_MAX_M
	return clampf(vis_m * 4.0, VOL_LENGTH_MIN_M, VOL_LENGTH_MAX_M)
