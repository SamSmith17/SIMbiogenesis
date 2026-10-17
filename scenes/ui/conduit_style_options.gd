extends RefCounted

## The conduit option lists, ONE way: the run's style modal and a port's
## preferred-wire settings (connection port modal) fill their dropdowns here,
## so a kind, a size, a routing style and an elbow angle read and order the
## same in both. Preloaded (no class_name) — UI scripts are swept by the
## compile selftest, not registered at import.
##
## Metadata: types → kind id ("" = Auto by resource); route → route-mode id
## ("" = the kind's own); fitting → degrees as float (0 = Auto); size → inches.

const LABEL_TYPE := "Kind"
const LABEL_SIZE := "Size"
const LABEL_ROUTE := "Routing"
const LABEL_FITTING := "Elbow angle"


static func fill_types(opt: OptionButton, auto_label: String = "Auto (by resource)") -> void:
	opt.clear()
	if not auto_label.is_empty():
		opt.add_item(auto_label)
		opt.set_item_metadata(0, "")
	# Conceptual flow first (the "no physical conduit" choice), then the
	# physical kinds alphabetically.
	var ids: Array = ["conceptual_flow"]
	for tid: Variant in ConduitKinds.all_types():
		if str(tid) != "conceptual_flow":
			ids.append(str(tid))
	for id in ids:
		opt.add_item(ConduitKinds.display_name(str(id)))
		opt.set_item_metadata(opt.item_count - 1, str(id))


static func fill_route_modes(opt: OptionButton) -> void:
	opt.clear()
	for o: Variant in ConduitKinds.route_mode_options():
		var od: Dictionary = o
		opt.add_item(str(od.get("label", "")))
		opt.set_item_metadata(opt.item_count - 1, str(od.get("id", "")))


static func fill_fittings(opt: OptionButton) -> void:
	opt.clear()
	for fs: float in [0.0, 30.0, 45.0, 60.0, 90.0]:
		opt.add_item("Auto" if fs < 0.5 else "%d°" % int(fs))
		opt.set_item_metadata(opt.item_count - 1, fs)


## Sizes the kind is made in (pipe kit / culvert / penstock tables), else Sch40.
static func fill_sizes(opt: OptionButton, type_id: String) -> void:
	opt.clear()
	var sizes: Array = ConduitKinds.pipe_kit_sizes_in(type_id)
	if sizes.is_empty():
		sizes = PipeKit.SCH40_SIZES_IN.duplicate()
	for sz: Variant in sizes:
		var s := float(sz)
		var label := CulvertKit.size_label(s) if ConduitKinds.uses_culvert_kit(type_id) \
				else PipeKit.size_label(s)
		opt.add_item(label)
		opt.set_item_metadata(opt.item_count - 1, s)


## Select the item whose metadata equals `v` (floats compared to 0.01).
static func select_meta(opt: OptionButton, v: Variant) -> void:
	for i: int in opt.item_count:
		var m: Variant = opt.get_item_metadata(i)
		if (m is float or m is int) and (v is float or v is int):
			if absf(float(m) - float(v)) < 0.01:
				opt.select(i)
				return
		elif str(m) == str(v):
			opt.select(i)
			return
	if opt.item_count > 0:
		opt.select(0)
