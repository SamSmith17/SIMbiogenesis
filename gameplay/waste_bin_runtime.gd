class_name WasteBinRuntime
extends Node3D
## The waste bin's visible pile (plans/FOOD_WASTE_REALISM_PLAN.md Phase 8):
## polls the bound store's ITEM LEDGER (the flow engine's, duck-typed —
## naming the engine class here would break every --script compile that
## loads a placed prop) and draws its counts as real bottle / can / box
## meshes in the bin, one MultiMeshInstance3D per mesh family. The layout
## is WasteBinBuilder.layout — pure and deterministic in the ledger, so
## the pile GROWS as the unpack sorts, FALLS on a scrub back, and renders
## identically after a reload. A store with kg but no ledger (old saves,
## bulk unpacks) shows its kind's representative item from the kg alone.
##
## MultiMesh rules (the two traps): each family's instance buffer is sized
## ONCE (MAX_PER_MESH) and never resized — unused slots hold a zero basis;
## custom_aabb covers the bin plus the over-rim heap, because the engine's
## own instance AABB is taken while few items show.

const NODE_NAME := "WasteBinRuntime"
const POLL_S := 0.25

var _prop: Node = null            # PlacedProp
var _model: Node3D = null
var _main: Node = null
var _poll := 0.0
var _sig := "?"
var _mmis: Dictionary = {}        # mesh_id -> MultiMeshInstance3D
var _piles: Node3D = null
var _label: Label3D = null
var _inter: Dictionary = {}
var _capacity_l := 360.0
var _kind := "pet_waste"


static func attach(prop: Node, rec: Dictionary) -> void:
	if prop == null or prop.get_node_or_null(NODE_NAME) != null:
		return
	if str(rec.get("model_id", "")) != WasteBinBuilder.MODEL_ID:
		return
	var s := WasteBinRuntime.new()
	s.name = NODE_NAME
	prop.add_child(s)


func _ready() -> void:
	_prop = get_parent()
	_model = _prop.get_node_or_null("ModelRoot") as Node3D
	_main = get_tree().current_scene
	var rec := _record()
	var r := WasteBinBuilder.resolve(rec.get("bin_spec", {}) as Dictionary)
	_inter = WasteBinBuilder.interior(r)
	_capacity_l = float(r["capacity_l"])
	_kind = str(r["kind"])
	# Piles under the MODEL root, so they turn with the bin's yaw.
	_piles = Node3D.new()
	_piles.name = "Piles"
	(_model if _model != null else self).add_child(_piles)
	_label = Label3D.new()
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.font_size = 40
	_label.pixel_size = 0.004
	_label.modulate = Color(1.0, 0.8, 0.3)
	_label.position = Vector3(0, float(_inter.get("rim_y", 1.0)) + 0.5, 0)
	_label.visible = false
	(_model if _model != null else self).add_child(_label)
	_poll = POLL_S   # poll on the first frame


func _record() -> Dictionary:
	if _main == null or _prop == null:
		return {}
	return PlacedPropService.get_prop_record(_main, str(_prop.get("prop_id")))


func _process(delta: float) -> void:
	_poll += delta
	if _poll < POLL_S:
		return
	_poll = 0.0
	_refresh()


func _refresh() -> void:
	var rec := _record()
	var gid := str(rec.get("graph_item_id", ""))
	var counts: Dictionary = {}
	var sig := "none"
	if not gid.is_empty():
		var view: Node = ServiceLocator.graph()
		var engine = view.get("_resource_flow") if view != null else null
		var h := float(_main.call("get_absolute_hours")) if _main != null and _main.has_method("get_absolute_hours") else 0.0
		var led = engine.call("item_ledger", gid) if engine != null and engine.has_method("item_ledger") else null
		if led != null and not bool(led.call("is_empty")):
			counts = led.call("counts_at", h)
			# The ledger is a pure function of t: between events the counts
			# are constant, so fold THEM into the signature, not the hour.
			sig = "led|%d|%s" % [int(led.get("rev")), str(counts.hash())]
		else:
			# No ledger: the store's kg as its kind's representative piece.
			var model = view.get("model") if view != null else null
			var item: Dictionary = model.get_item(gid) if model != null else {}
			var sp: Dictionary = item.get("specs", {})
			var kg := clampf(float(sp.get("level", 0.0)), 0.0, 1.0) \
				* maxf(float(sp.get("capacity_qty", 0.0)), 0.0)
			counts = WasteBinBuilder.counts_from_kg(_kind, kg)
			sig = "kg|%s" % str(counts.hash())
	if sig == _sig:
		return
	_sig = sig
	_redraw(counts)


func _redraw(counts: Dictionary) -> void:
	var items := WasteBinBuilder.layout(str(_prop.get("prop_id")), counts, _inter, _capacity_l)
	# Group item transforms per mesh family, in pile order.
	var per: Dictionary = {}
	var over := false
	for it in items:
		var d := it as Dictionary
		var arr: Array = per.get(d["mesh_id"], [])
		arr.append(d["xform"])
		per[d["mesh_id"]] = arr
		over = over or bool(d.get("over_rim", false))
	var hidden := Transform3D(Basis.from_scale(Vector3.ZERO), Vector3(0, -50, 0))
	for mesh_id in per:
		var mmi := _ensure_mmi(str(mesh_id))
		var xs: Array = per[mesh_id]
		var n := mini(xs.size(), WasteBinBuilder.MAX_PER_MESH)
		# Past the budget draw the TOP of the pile (the layout is in pile
		# order): the heap's surface — and the over-rim overflow — is what
		# reads; the buried bottom is invisible anyway.
		var off := xs.size() - n
		for i in WasteBinBuilder.MAX_PER_MESH:
			mmi.multimesh.set_instance_transform(i, xs[off + i] if i < n else hidden)
	for mesh_id in _mmis:
		if not per.has(mesh_id):
			var mm: MultiMesh = (_mmis[mesh_id] as MultiMeshInstance3D).multimesh
			for i in WasteBinBuilder.MAX_PER_MESH:
				mm.set_instance_transform(i, hidden)
	# Fill readout: litres against the bin's capacity.
	var litres := 0.0
	for aid in counts:
		litres += PackagingArchetypes.loose_l(str(aid)) * int(counts[aid])
	if _label != null:
		_label.visible = over or litres > _capacity_l * 0.6
		_label.text = I18n.t("Overflowing") if over \
			else I18n.f("{pct} full", {"pct": "%d %%" % int(round(litres / _capacity_l * 100.0))})
		_label.modulate = Color(1.0, 0.35, 0.3) if over else Color(1.0, 0.8, 0.3)


func _ensure_mmi(mesh_id: String) -> MultiMeshInstance3D:
	if _mmis.has(mesh_id):
		return _mmis[mesh_id]
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = WasteItemMeshes.mesh(mesh_id)
	mm.instance_count = WasteBinBuilder.MAX_PER_MESH   # sized ONCE, never resized
	var hidden := Transform3D(Basis.from_scale(Vector3.ZERO), Vector3(0, -50, 0))
	for i in WasteBinBuilder.MAX_PER_MESH:
		mm.set_instance_transform(i, hidden)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Pile_" + mesh_id
	mmi.multimesh = mm
	mmi.set_meta("skip_prop_collision", true)
	# The engine measures the instance AABB while few items show: cover the
	# whole bin plus the over-rim heap by hand.
	var w := float(_inter.get("w", 0.6))
	var d := float(_inter.get("d", 0.6))
	var rim := float(_inter.get("rim_y", 1.0))
	mmi.custom_aabb = AABB(Vector3(-w, 0, -d), Vector3(w * 2.0, rim * 3.0, d * 2.0))
	_piles.add_child(mmi)
	_mmis[mesh_id] = mmi
	return mmi


## What the pile currently draws, for the harness: {mesh_id: shown count}.
func drawn_counts() -> Dictionary:
	var out: Dictionary = {}
	for mesh_id in _mmis:
		var mm: MultiMesh = (_mmis[mesh_id] as MultiMeshInstance3D).multimesh
		var n := 0
		for i in WasteBinBuilder.MAX_PER_MESH:
			if mm.get_instance_transform(i).basis.x.length_squared() > 1e-8:
				n += 1
		if n > 0:
			out[mesh_id] = n
	return out
