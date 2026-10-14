class_name GraphElevFrame
extends RefCounted

## The ONE mapping between Elevation-section metres and canvas pixels.
##
## Why this exists: the Elevation view used to have two frames that only agreed
## by coincidence. The 2D overlays and the 3D section camera followed the metre
## ANCHORS (the along/elev point shown at the canvas centre, moved by pan, cursor
## zoom and the siphon auto-framing), while the circular mask that bounds the 3D
## disc, its label and the reveal fade were pinned to the canvas centre. Any pan
## or zoom slid the sphere inside a window that never moved — "the bubble is
## misaligned from its circle". Every consumer now reads this frame:
## the canvas disc layout, the preview container placement, and the section
## camera's look point (the world point under the container's centre).
##
## A frame is a plain Dictionary so it is cheap to build once per draw:
##   s        px per metre (GraphSiteLayout.px_per_m(zoom))
##   vc       canvas centre (px)
##   aa, ae   anchor along / elevation (m) — what sits at vc
##   ex       vertical exaggeration (1 whenever the 3D section is requested)
##   cy       SoI centre elevation (world Y of SoiService.world_center)
##   r_m      SoI radius (m)
##   d        CT slice depth along the cross axis (m, + toward the camera)
##   soi_px   where the SoI centre (along 0, elevation cy) lands on screen
##   chord_m  radius of the cut circle on the slice plane, √(R² − d²)
##   sil_m    radius of the remaining half's silhouette: R while the kept half
##            still contains the equator (d ≥ 0), else the chord (a cap)
## Pure static, no engine state: pinned by graph_elev_frame_selftest.gd.


static func make(canvas_size: Vector2, s: float, anchor_along: float,
		anchor_elev: float, ex: float, center_y: float, r_m: float,
		slice_d: float) -> Dictionary:
	var r := maxf(r_m, 0.0)
	var d := clampf(slice_d, -r, r)
	var chord := sqrt(maxf(r * r - d * d, 0.0))
	var f := {
		"s": maxf(s, 1e-6),
		"vc": canvas_size * 0.5,
		"aa": anchor_along,
		"ae": anchor_elev,
		"ex": maxf(ex, 0.001),
		"cy": center_y,
		"r_m": r,
		"d": d,
		"chord_m": chord,
		"sil_m": r if d >= 0.0 else chord,
	}
	f["soi_px"] = to_screen(f, 0.0, center_y)
	return f


## Section metres (along the cut from the SoI centre, absolute elevation) → px.
static func to_screen(f: Dictionary, along_m: float, elev_m: float) -> Vector2:
	var s := float(f["s"])
	var vc: Vector2 = f["vc"]
	return Vector2(
		vc.x + (along_m - float(f["aa"])) * s,
		vc.y - (elev_m - float(f["ae"])) * s * float(f["ex"]))


## Exact inverse of to_screen: px → Vector2(along_m, elev_m).
static func to_metres(f: Dictionary, px: Vector2) -> Vector2:
	var s := float(f["s"])
	var vc: Vector2 = f["vc"]
	return Vector2(
		float(f["aa"]) + (px.x - vc.x) / s,
		float(f["ae"]) - (px.y - vc.y) / (s * float(f["ex"])))


## On-screen radii of the silhouette and the cut circle.
static func sil_px(f: Dictionary) -> float:
	return float(f["sil_m"]) * float(f["s"])


static func chord_px(f: Dictionary) -> float:
	return float(f["chord_m"]) * float(f["s"])


## Orthographic frustum HEIGHT (m) that keeps the 3D section at the canvas's
## px/m for a container `container_h_px` tall, floored at the Hydro Lab's
## minimum so the 2D and 3D clamps can never disagree.
static func ortho_height_m(f: Dictionary, container_h_px: float) -> float:
	return maxf(container_h_px / float(f["s"]), GraphSiteLayout.LAB_MIN_ORTHO_H_M)
