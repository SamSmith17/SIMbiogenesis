@tool
extends Marker3D
class_name CampStamp

## A point on the map marking where a specific camp class should be placed.
##
## Add these as children (or descendants) of the `CampScatter` node and drag
## them around in the 3D editor viewport to mark popup tents, RVs, etc. When
## the camp scatter bakes, every enabled `CampStamp` becomes one placed
## instance using the corresponding class profile.
##
## Workflow:
##   1. Select the CampScatter node and tick "Add Stamp At Origin" (or just
##      duplicate an existing CampStamp child).
##   2. Drag the marker in the 3D viewport to the location of the real-world
##      object on the aerial photo.
##   3. Set `class_id` to the matching class (popup_tent, rv, car, etc.).
##   4. Pick an orientation mode:
##        - AUTO_DETECT_FROM_IMAGE: scatter looks at the aerial pixels near
##          this point, finds the object's rectangular footprint and rotates
##          the placed instance to match. Use this for RVs/popups/carports.
##        - MANUAL_YAW: this marker's own Y rotation is used as-is.
##        - ALIGN_TO_TERRAIN_NORMAL: keeps the marker's yaw but tilts the
##          placed instance to follow the terrain slope.
##        - RANDOM_YAW: useful for round/square classes (camping tents).
##   5. Bake the camp scatter.

enum OrientationMode {
	AUTO_DETECT_FROM_IMAGE = 0,
	MANUAL_YAW = 1,
	ALIGN_TO_TERRAIN_NORMAL = 2,
	RANDOM_YAW = 3,
}

## Which camp class this marker represents. Must match a class_id in the
## CampScatter's profiles (popup_tent, rv, camping_tent, shade_structure, car).
@export var class_id : StringName = &"popup_tent"
## How the placed instance's heading is determined:
##   AUTO_DETECT_FROM_IMAGE — CampScatter reads the aerial pixels around this
##     marker and fits a rotated bounding box to find the object's long axis.
##     Best for RVs, carports, and any rectangular objects.
##   MANUAL_YAW — uses this Marker3D's own Y rotation. Rotate the marker in
##     the viewport and the instance will match.
##   ALIGN_TO_TERRAIN_NORMAL — same as MANUAL_YAW but the instance also tilts
##     to follow the slope of the terrain at that point.
##   RANDOM_YAW — assigns a fully random heading. Good for round tents.
@export var orientation_mode : OrientationMode = OrientationMode.AUTO_DETECT_FROM_IMAGE
## Snap the final heading to the nearest multiple of this angle (degrees).
## Overrides the class profile's snap value when set above 0.
## 0 = no snap. 5 = gentle snap. 90 = strict cardinal alignment.
@export_range( 0.0, 90.0, 0.5 ) var orientation_snap_degrees : float = 0.0
## Confidence value attached to this stamp's candidate (0–1). Stamps always
## pass the confidence threshold regardless of this value; it is used only for
## preview dot colour and for logging.
@export_range( 0.0, 1.0, 0.01 ) var confidence : float = 1.0
## When non-zero, overrides the footprint used for collision spacing checks.
## Leave at (0, 0) to inherit the auto-detected or profile footprint size.
@export var footprint_size_override : Vector2 = Vector2.ZERO
## Uncheck to temporarily exclude this stamp from the next bake without
## deleting it. Useful for testing layouts.
@export var include_in_bake : bool = true
## Free-text memo. Useful for labelling "north row", "VIP camp", etc.
@export var notes : String = ""

## Read-only. Updated by the "Auto-Orient All Stamps" action. Shows the last
## heading (degrees) written to this marker during auto-orientation.
@export var last_auto_heading_degrees : float = 0.0
## Read-only. Footprint size (metres) returned by the last auto-orient run.
@export var last_auto_footprint : Vector2 = Vector2.ZERO
