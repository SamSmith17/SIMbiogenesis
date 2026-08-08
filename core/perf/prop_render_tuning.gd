class_name PropRenderTuning
extends Object

## Per-prop render-cost tuning for user-placed props (Tier 2 of the perf plan).
##
## A heavy site can carry thousands of individual PlacedProp meshes (each a full
## MeshInstance3D that the renderer frustum-culls, draws, and re-draws into the
## sun shadow map). We offload distance culling to the engine via
## GeometryInstance3D.visibility_range_end, which removes a far prop from BOTH the
## camera pass AND every shadow split at ZERO per-frame script cost (the renderer
## does the distance test).
##
## The cull distance is SIZE-SCALED so it stays imperceptible: small clutter culls
## close, while large landmarks (StarShade, domes, pallet racks) beyond
## LARGE_PROP_RADIUS_M are never culled. `base_distance_m` (the slider) sets the
## floor for the smallest props; `shadows_enabled` is a one-click lever for the
## expensive prop shadow pass. Both persist to user://perf_prefs.cfg.

const CFG_PATH := "user://perf_prefs.cfg"

## Cull-distance floor for the smallest props (metres). User-tunable.
static var base_distance_m: float = 200.0
## When false, placed props stop casting sun/positional shadows entirely (big
## GPU win on shadow-heavy sites; the only perceptible tradeoff).
static var shadows_enabled: bool = true

## Fine-detail shadow culling level (global default). A prop sub-mesh whose
## bounding radius is below the level's threshold stops casting shadows, so tiny
## detail geometry (railings, bolts, trim) drops out of the shadow pass while the
## main structure still shadows correctly — accuracy-preserving, unlike a solid
## proxy. 0 = Full (nothing culled), 3 = Low (only large structural meshes cast).
## A per-prop override (node meta "shadow_mode": "all" | "off") wins over this.
static var shadow_detail: int = 2

## True while a graph SoI/Site-Plan preview disc is showing. The preview camera can
## sit far from the props (needed to frame a tilted/wide top-down without clipping),
## which would distance-cull the small graph-twin placeholders. First-person 3D is
## not rendering while the graph is open, so we simply lift the distance cull for
## every prop while the preview is active — honored in apply_to_prop so even props
## rebuilt mid-preview (e.g. shift-yaw during a drag) stay visible. Restored on close.
static var preview_active: bool = false

## Sub-mesh bounding-radius (metres) below which a mesh is dropped from the shadow
## pass, indexed by shadow_detail level.
const SHADOW_DETAIL_THRESHOLDS: Array[float] = [0.0, 0.12, 0.35, 0.9]

## Props whose bounding radius is at least this never get a cull distance — a few
## large landmarks stay visible across the whole map (they're cheap because there
## are few of them).
const LARGE_PROP_RADIUS_M := 6.0
## Extra cull distance granted per metre of prop bounding radius.
const SIZE_FACTOR := 12.0

static var _loaded := false


static func ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) == OK:
		base_distance_m = float(cfg.get_value("props", "draw_distance_m", base_distance_m))
		shadows_enabled = bool(cfg.get_value("props", "shadows_enabled", shadows_enabled))
		shadow_detail = clampi(int(cfg.get_value("props", "shadow_detail", shadow_detail)), 0, 3)


static func save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG_PATH)  # preserve any other sections
	cfg.set_value("props", "draw_distance_m", base_distance_m)
	cfg.set_value("props", "shadows_enabled", shadows_enabled)
	cfg.set_value("props", "shadow_detail", shadow_detail)
	cfg.save(CFG_PATH)


## Apply the current settings to one prop's meshes. `local_radius` is the prop's
## bounding radius in metres (from its pick AABB); pass <= 0 to have it ignored
## (uses the base distance). Called by PlacedPropRuntime right after a prop is
## built, and by apply_to_all() when the settings change.
static func apply_to_prop(prop: Node, local_radius: float = 0.0) -> void:
	ensure_loaded()
	if prop == null:
		return
	var model := prop.get_node_or_null("ModelRoot") as Node3D
	if model == null:
		return
	var end_d := 0.0 if preview_active else _cull_distance_for_radius(local_radius)
	var margin := clampf(end_d * 0.12, 6.0, 45.0) if end_d > 0.0 else 0.0
	# Per-prop shadow override (set on the node by PlacedPropRuntime from the
	# prop's record): "all" forces every mesh to cast, "off" none, "" uses the
	# global fine-detail threshold.
	var mode := ""
	if prop.has_meta("shadow_mode"):
		mode = str(prop.get_meta("shadow_mode"))
	var threshold := 0.0 if mode == "all" else SHADOW_DETAIL_THRESHOLDS[clampi(shadow_detail, 0, 3)]
	for node in model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi == null or mi.name == "OutlinePass":
			continue
		mi.visibility_range_end = end_d
		mi.visibility_range_end_margin = margin
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		# Remember each mesh's authored shadow setting once, so restoring shadows
		# honours per-mesh intent (glow cards / thin meshes stay OFF).
		var orig: int = mi.cast_shadow
		if mi.has_meta("_perf_shadow_orig"):
			orig = int(mi.get_meta("_perf_shadow_orig"))
		else:
			mi.set_meta("_perf_shadow_orig", orig)
		var want: int = orig
		if not shadows_enabled or mode == "off":
			want = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		elif mi.has_meta("_shadow_proxy"):
			# Coarse shadow-only caster (e.g. rack decks): active unless the user
			# forces full detail with the per-prop "All parts" override.
			want = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if mode == "all" \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
		elif mi.has_meta("_shadow_full"):
			# Detailed mesh that normally defers to its proxy; casts only under "all".
			want = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if mode == "all" \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		elif mode == "all":
			want = orig
		elif orig != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and threshold > 0.0:
			# Drop only fine-detail sub-meshes; large structural meshes still cast.
			if _mesh_prop_local_radius(mi, model) < threshold:
				want = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.cast_shadow = want


## Bounding radius (metres) of one sub-mesh in prop-local space, composed from
## local transforms up to ModelRoot (valid before the prop is in the tree — no
## global_transform). Used to classify fine-detail vs structural meshes.
static func _mesh_prop_local_radius(mi: MeshInstance3D, model: Node3D) -> float:
	if mi.mesh == null:
		return 0.0
	var t := mi.transform
	var p := mi.get_parent()
	while p != null and p != model and p is Node3D:
		t = (p as Node3D).transform * t
		p = p.get_parent()
	t = model.transform * t
	var aabb: AABB = t * mi.mesh.get_aabb()
	return aabb.size.length() * 0.5


## Floor on the cull distance, in metres, for views that sit far above eye
## level (the settlement camera). 0 = off, the ordinary tier behaviour.
##
## Deliberately NOT `preview_active`, which disables distance culling for
## EVERY prop and would undo the Tier-2 perf work wholesale. This keeps the
## distance test running and only widens its reach, so a camera 300 m up still
## sees the camp while the far clutter beyond it stays culled.
static var scale_override_m: float = 0.0


static func _cull_distance_for_radius(local_radius: float) -> float:
	if local_radius >= LARGE_PROP_RADIUS_M:
		return 0.0  # never cull large landmarks (0 = visibility range disabled)
	var d := maxf(base_distance_m, 0.0) + maxf(local_radius, 0.0) * SIZE_FACTOR
	return maxf(d, maxf(scale_override_m, 0.0))


## Re-apply to every placed prop under Terrain/PlacedProps (call after a settings
## change). Reads each prop's pick AABB for its size class.
static func apply_to_all(main: Node) -> int:
	if main == null:
		return 0
	var terrain := main.get_node_or_null("Terrain") as Node3D
	if terrain == null:
		return 0
	var root := terrain.get_node_or_null("PlacedProps")
	if root == null:
		return 0
	var count := 0
	for child in root.get_children():
		apply_to_prop(child, _prop_radius(child))
		count += 1
	return count


static func _prop_radius(prop: Node) -> float:
	if prop != null and prop.has_method("get_local_pick_radius"):
		return float(prop.call("get_local_pick_radius"))
	return 0.0
