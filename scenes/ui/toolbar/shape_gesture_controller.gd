class_name ShapeGestureController
extends RefCounted

## Region-selection gesture state machine for the unified edit toolbar:
## circle / rect drag, freehand lasso, click-to-place polygon (plus "brush",
## which is a no-op here — the brush tools stroke directly).
##
## Pure logic over WORLD-XZ coordinates: it never picks rays, reads a viewport
## or touches a Node, so the whole gesture ladder is assertable headless. The
## caller does screen->world picking and hands the result in. Screen positions
## are carried only for the lasso, whose preview is drawn in screen space
## (projecting a freehand trail back through the terrain every frame is both
## slower and jitterier than keeping the pixels it was sampled at).
##
## Deliberately built fresh for the toolbar rather than extracted from the two
## legacy docks: they are being retired, and refactoring 1,500-line files
## mid-transition is risk without payoff.

const MAX_RADIUS_M := 150.0
const MAX_AREA_M2 := 90000.0
## Minimum pointer travel between lasso samples. Sampling every motion event
## makes a polygon with thousands of near-duplicate vertices.
const LASSO_SAMPLE_PX := 8.0

## begin() outcomes — the caller reacts differently to each.
enum { NONE, DRAG_STARTED, POLY_POINT, POLY_CLOSED }

var mode: String = "brush"

var _dragging := false
var _anchor := Vector2.ZERO
## Rubber-band preview while a circle/rect drag is live (world XZ).
var _preview := PackedVector2Array()
var _lasso_world := PackedVector2Array()
var _lasso_screen := PackedVector2Array()
var _last_lasso_px := Vector2(-1e9, -1e9)
var _poly_points := PackedVector2Array()


func set_mode(m: String) -> void:
	if mode == m:
		return
	mode = m
	reset()


## Drop every transient gesture (a tool switch or a completed lock).
func reset() -> void:
	_dragging = false
	_preview = PackedVector2Array()
	_lasso_world = PackedVector2Array()
	_lasso_screen = PackedVector2Array()
	_last_lasso_px = Vector2(-1e9, -1e9)
	_poly_points = PackedVector2Array()


func is_dragging() -> bool:
	return _dragging


## True when something is mid-gesture — what Esc peels before closing the UI.
func has_pending() -> bool:
	return _dragging or _poly_points.size() > 0


func is_region_mode() -> bool:
	return mode != "brush" and not mode.is_empty()


## LMB press. `close_tol_m` is how near the first vertex a polygon click has to
## land to close the ring instead of adding another point.
func begin(world: Vector2, screen: Vector2, close_tol_m: float = 3.0) -> int:
	match mode:
		"circle", "rect":
			_dragging = true
			_anchor = world
			_preview = PackedVector2Array()
			return DRAG_STARTED
		"lasso":
			_dragging = true
			_lasso_world = PackedVector2Array([world])
			_lasso_screen = PackedVector2Array([screen])
			_last_lasso_px = screen
			return DRAG_STARTED
		"polygon":
			if _poly_points.size() >= 3 \
					and world.distance_to(_poly_points[0]) < maxf(close_tol_m, 1.0):
				return POLY_CLOSED
			_poly_points.append(world)
			return POLY_POINT
	return NONE


## Pointer motion. Returns true when the lasso actually took a sample, so the
## caller only redraws on a real change.
func motion(world: Vector2, screen: Vector2) -> bool:
	if not _dragging or mode != "lasso":
		return false
	if screen.distance_to(_last_lasso_px) < LASSO_SAMPLE_PX:
		return false
	_last_lasso_px = screen
	_lasso_world.append(world)
	_lasso_screen.append(screen)
	return true


## Live rubber band for circle/rect, driven from the hovered ground point.
func update_drag(world: Vector2) -> void:
	if not _dragging:
		return
	if mode == "circle":
		var radius := clampf(maxf(1.0, _anchor.distance_to(world)), 1.0, MAX_RADIUS_M)
		_preview = VegetationPaint.circle_polygon(_anchor, radius)
	elif mode == "rect":
		var corner := world
		var d := corner - _anchor
		if d.length() > MAX_RADIUS_M * 2.0:
			corner = _anchor + d.normalized() * MAX_RADIUS_M * 2.0
		_preview = VegetationPaint.rect_to_polygon(_anchor, corner)


## LMB release — returns the finished outline, or empty when the gesture does
## not complete on release (polygon needs an explicit close).
func release() -> PackedVector2Array:
	if not _dragging:
		return PackedVector2Array()
	_dragging = false
	var out := PackedVector2Array()
	if mode == "circle" or mode == "rect":
		out = _preview.duplicate()
		_preview = PackedVector2Array()
	elif mode == "lasso":
		out = _lasso_world.duplicate()
		_lasso_world = PackedVector2Array()
		_lasso_screen = PackedVector2Array()
	return out


## Enter / RMB / click-on-first-vertex closes a polygon.
func finish_polygon() -> PackedVector2Array:
	var out := _poly_points.duplicate()
	_poly_points = PackedVector2Array()
	return out


## Peel ONE gesture layer (Esc). True when something was actually cancelled.
func cancel() -> bool:
	if _dragging:
		_dragging = false
		_preview = PackedVector2Array()
		_lasso_world = PackedVector2Array()
		_lasso_screen = PackedVector2Array()
		return true
	if _poly_points.size() > 0:
		_poly_points = PackedVector2Array()
		return true
	return false


func preview_world() -> PackedVector2Array:
	return _preview


func lasso_screen() -> PackedVector2Array:
	return _lasso_screen


func poly_points() -> PackedVector2Array:
	return _poly_points


## Why an outline cannot be used, or "" when it is fine. Returning the REASON
## (not a bool) is what lets the toolbar say something useful in the status bar
## instead of silently ignoring a drawn shape.
static func rejection_reason(poly: PackedVector2Array) -> String:
	if poly.size() < 3:
		return "Selection too small — draw again"
	if VegetationPaint.polygon_area(poly) > MAX_AREA_M2:
		return "Area too large — shrink the selection"
	return ""
