class_name ClosureMetrics
extends RefCounted

## Rolling-window closure / autonomy scoreboard for the playable puzzle loop.
##
## Per need channel {energy, water, food, waste}:
##   closure_pct = clamp(supply_local / demand, 0, 1)
##   autonomy_days = stock / daily_demand
## Imports (`specs.counts_as_import`) count against closure (not local supply).
##
## Aggregate score (documented constants):
##   score = autonomy_person_days * SCORE_AUTONOMY_WEIGHT
##         + mean_closure_pct * SCORE_CLOSURE_WEIGHT

const WINDOW_HOURS := 24.0
const SCORE_AUTONOMY_WEIGHT := 100.0
const SCORE_CLOSURE_WEIGHT := 50.0

## Battery round-trip efficiency: SolarUI CHARGE_EFFICIENCY (0.95) ×
## DISCHARGE_EFFICIENCY (0.95) — keep in sync with scenes/ui/solar_ui.gd:68-69.
## Stored energy arrived via the charge leg and must exit via the discharge leg,
## so usable stock for autonomy = nameplate stock × round trip.
const BATTERY_ROUND_TRIP_EFF := 0.95 * 0.95

const STATUS_OK := "ok"
const STATUS_WARN := "warn"
const STATUS_CRITICAL := "critical"
const STATUS_IDLE := "idle"


static func compute(model: GraphModel, resource_flow: RefCounted,
		energy_timeline: RefCounted, abs_hours: float,
		window_hours: float = WINDOW_HOURS,
		battery_round_trip: float = BATTERY_ROUND_TRIP_EFF) -> Dictionary:
	var t1: float = abs_hours
	var t0: float = abs_hours - maxf(window_hours, 0.1)
	var span: float = maxf(t1 - t0, 0.1)

	var occupants := _total_occupants(model)
	var habitat_demand := _habitat_demand_rates(model)

	var energy := _compute_energy(model, energy_timeline, t0, t1, span, battery_round_trip)
	var water := _compute_resource_channel(model, resource_flow, "water",
			float(habitat_demand.get("water", 0.0)), t0, t1, span)
	var food := _compute_resource_channel(model, resource_flow, "food",
			float(habitat_demand.get("food", 0.0)), t0, t1, span)
	var waste := _compute_waste_channel(model, resource_flow, habitat_demand, t0, t1, span)

	energy["status"] = channel_status(energy)
	water["status"] = channel_status(water)
	food["status"] = channel_status(food)
	waste["status"] = channel_status(waste)

	var channels := {
		"energy": energy,
		"water": water,
		"food": food,
		"waste": waste,
	}
	var mean_closure := _mean_active_closure(channels)
	var min_autonomy := _min_active_autonomy(channels)
	# Without mouths to feed, autonomy score stays 0 (battery-only must not inflate).
	var autonomy_person_days := 0.0
	if occupants > 0:
		autonomy_person_days = min_autonomy * float(occupants)
	elif min_autonomy < 90.0:
		# Non-habitat free-play: count only finite autonomy (not the 99 d sentinel).
		autonomy_person_days = min_autonomy
	var score := autonomy_person_days * SCORE_AUTONOMY_WEIGHT \
			+ mean_closure * SCORE_CLOSURE_WEIGHT

	return {
		"abs_hours": abs_hours,
		"window_hours": span,
		"occupants": occupants,
		"channels": channels,
		"mean_closure_pct": mean_closure,
		"min_autonomy_days": min_autonomy,
		"autonomy_person_days": autonomy_person_days,
		"score": score,
		"any_starved": _any_habitat_starved(model),
	}


static func channel_status(ch: Dictionary) -> String:
	if not bool(ch.get("active", false)):
		return STATUS_IDLE
	if bool(ch.get("starved", false)):
		return STATUS_CRITICAL
	var days: float = float(ch.get("autonomy_days", 0.0))
	var closure: float = float(ch.get("closure_pct", 0.0))
	if days < 0.5 or closure < 0.25:
		return STATUS_CRITICAL
	if days < 2.0 or closure < 0.55:
		return STATUS_WARN
	return STATUS_OK


static func status_color(status: String) -> Color:
	match status:
		STATUS_OK:
			return Color(0.27, 0.90, 0.42)
		STATUS_WARN:
			return Color(0.95, 0.72, 0.20)
		STATUS_CRITICAL:
			return Color(0.90, 0.35, 0.30)
		_:
			return Color(0.55, 0.58, 0.65)


static func status_label(status: String) -> String:
	match status:
		STATUS_OK:
			return "OK"
		STATUS_WARN:
			return "WARN"
		STATUS_CRITICAL:
			return "CRIT"
		_:
			return "—"


static func _compute_energy(model: GraphModel, energy_timeline: RefCounted,
		t0: float, t1: float, span: float,
		battery_round_trip: float = BATTERY_ROUND_TRIP_EFF) -> Dictionary:
	var demand_kwh := 0.0
	var supply_local_kwh := 0.0
	var supply_import_kwh := 0.0
	var stock_kwh := 0.0

	if energy_timeline != null and energy_timeline.has_method("integrate_channel") \
			and not bool(energy_timeline.call("is_empty")):
		demand_kwh = float(energy_timeline.call("integrate_channel", t0, t1, "load"))
		supply_local_kwh = float(energy_timeline.call("integrate_channel", t0, t1, "solar")) \
				+ float(energy_timeline.call("integrate_channel", t0, t1, "aux"))
		if energy_timeline.has_method("soc_at"):
			stock_kwh = maxf(float(energy_timeline.call("soc_at", t1)), 0.0)

	if stock_kwh <= 0.0 and model != null:
		for item: Dictionary in model.items:
			var ty: String = str(item.get("type", ""))
			if ty != "battery" and ty != "smartbattery":
				continue
			var specs: Dictionary = item.get("specs", {}) as Dictionary
			var kwh: float = float(specs.get("kwh", 0.0))
			if kwh <= 0.0:
				var ah: float = float(specs.get("ah", 0.0))
				var v: float = float(specs.get("voltage", 12.0))
				kwh = ah * v / 1000.0
			var soc: float = float(specs.get("soc", specs.get("level", 0.5)))
			if soc > 1.0:
				soc /= 100.0
			stock_kwh += kwh * clampf(soc, 0.0, 1.0)

	supply_import_kwh += _import_rate_sum(model, "electric") * span

	var active := demand_kwh > 0.01 or supply_local_kwh > 0.01 or stock_kwh > 0.01 \
			or supply_import_kwh > 0.01 or _has_energy_hardware(model)

	# Autonomy runs on USABLE stock — nameplate kWh discounted by battery
	# round-trip losses (otherwise autonomy is overstated ~10%).
	var usable_stock_kwh := stock_kwh * clampf(battery_round_trip, 0.0, 1.0)
	var daily_demand := demand_kwh * (24.0 / span) if demand_kwh > 0.0 else 0.0
	var autonomy_days := 0.0
	if daily_demand > 0.01:
		autonomy_days = usable_stock_kwh / daily_demand
	elif stock_kwh > 0.01 and _has_energy_hardware(model):
		autonomy_days = 99.0

	var closure := 0.0
	if demand_kwh > 0.01:
		closure = clampf(supply_local_kwh / demand_kwh, 0.0, 1.0)
	elif supply_import_kwh > 0.01:
		closure = 0.0
	elif supply_local_kwh > 0.01 or stock_kwh > 0.01:
		closure = 1.0

	return {
		"kind": "energy",
		"active": active,
		"demand": demand_kwh,
		"supply_local": supply_local_kwh,
		"supply_import": supply_import_kwh,
		"stock": stock_kwh,
		"stock_usable": usable_stock_kwh,
		"closure_pct": closure,
		"autonomy_days": autonomy_days,
		"unit": "kWh",
		"starved": false,
	}


static func _has_energy_hardware(model: GraphModel) -> bool:
	if model == null:
		return false
	for item: Dictionary in model.items:
		var ty: String = str(item.get("type", ""))
		if ty in ["panel", "battery", "smartbattery", "wind", "hydro", "controller"]:
			return true
	return false


static func _compute_resource_channel(model: GraphModel, resource_flow: RefCounted,
		kind: String, demand_rate_ph: float, t0: float, t1: float, span: float) -> Dictionary:
	var demand := demand_rate_ph * span
	var supply_local := 0.0
	var supply_import := 0.0
	var stock := 0.0

	if model != null:
		for item: Dictionary in model.items:
			var ty: String = str(item.get("type", ""))
			var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
			if ty == "resource":
				ResourceKinds.new().migrate_resource_specs(specs)
				if ResourceKinds.normalize_kind(str(specs.get("resource_kind", ""))) != kind:
					continue
				var cap: float = float(specs.get("capacity_qty", 0.0))
				var lvl: float = clampf(float(specs.get("level", 0.0)), 0.0, 1.0)
				stock += cap * lvl
				var iid: String = str(item.get("id", ""))
				var tl: RefCounted = _timeline_for(resource_flow, iid)
				if tl != null and tl.has_method("integrate_channel") and not bool(tl.call("is_empty")):
					supply_local += maxf(float(tl.call("integrate_channel", t0, t1, "inflow")), 0.0)
			elif ty == "processor":
				if not bool(specs.get("counts_as_import", false)):
					continue
				var import_kind: String = ResourceKinds.normalize_kind(
						str(specs.get("import_kind", "")))
				if import_kind.is_empty():
					var outs: Array = specs.get("outputs", []) as Array
					if not outs.is_empty() and outs[0] is Dictionary:
						import_kind = ResourceKinds.normalize_kind(
								str((outs[0] as Dictionary).get("kind", "")))
				if import_kind != kind:
					continue
				supply_import += _processor_output_rate(specs, kind) * span

	supply_local = maxf(supply_local - supply_import, 0.0)

	var daily_demand := demand_rate_ph * 24.0
	var autonomy_days := stock / daily_demand if daily_demand > 0.01 else \
			(99.0 if stock > 0.01 else 0.0)

	var closure := 0.0
	if demand > 0.01:
		closure = clampf(supply_local / demand, 0.0, 1.0)
	elif supply_import > 0.01:
		closure = 0.0
	elif stock > 0.01:
		closure = 1.0

	var starved := false
	if model != null and demand_rate_ph > 0.0:
		for item: Dictionary in model.items:
			if str(item.get("type", "")) != "processor":
				continue
			var specs2: Dictionary = item.get("specs", {}) as Dictionary
			if str(specs2.get("role", "")) != "habitat":
				continue
			var sk: Array = specs2.get("starved_kinds", []) as Array
			if sk.has(kind):
				starved = true
				break

	var active := demand > 0.01 or stock > 0.01 or supply_local > 0.01 \
			or supply_import > 0.01 or demand_rate_ph > 0.0

	return {
		"kind": kind,
		"active": active,
		"demand": demand,
		"supply_local": supply_local,
		"supply_import": supply_import,
		"stock": stock,
		"closure_pct": closure,
		"autonomy_days": autonomy_days,
		"unit": ResourceKinds.default_unit(kind),
		"starved": starved,
	}


## Waste: demand = produced waste; supply_local = recycled (processor outflows of nutrients/water from waste).
## Closure = recycled / produced. Autonomy = remaining waste tank headroom / daily production.
static func _compute_waste_channel(model: GraphModel, resource_flow: RefCounted,
		habitat_demand: Dictionary, t0: float, t1: float, span: float) -> Dictionary:
	var water_ph: float = float(habitat_demand.get("water", 0.0))
	var food_ph: float = float(habitat_demand.get("food", 0.0))
	var produced_ph: float = water_ph + food_ph * 0.20
	var produced := produced_ph * span

	var recycled := 0.0
	var waste_stock := 0.0
	var waste_capacity := 0.0
	const WASTE_KINDS := ["greywater", "blackwater", "biomass"]

	if model != null:
		for item: Dictionary in model.items:
			var ty: String = str(item.get("type", ""))
			var specs: Dictionary = (item.get("specs", {}) as Dictionary).duplicate(true)
			if ty == "resource":
				ResourceKinds.new().migrate_resource_specs(specs)
				var rk: String = ResourceKinds.normalize_kind(str(specs.get("resource_kind", "")))
				if not WASTE_KINDS.has(rk):
					continue
				var cap: float = float(specs.get("capacity_qty", 0.0))
				var lvl: float = clampf(float(specs.get("level", 0.0)), 0.0, 1.0)
				waste_stock += cap * lvl
				waste_capacity += cap
			elif ty == "processor":
				if str(specs.get("role", "")) == "habitat":
					continue
				if bool(specs.get("counts_as_import", false)):
					continue
				var inputs: Array = specs.get("inputs", []) as Array
				var takes_waste := false
				for inp: Variant in inputs:
					if inp is Dictionary:
						var ik: String = ResourceKinds.normalize_kind(
								str((inp as Dictionary).get("kind", "")))
						if WASTE_KINDS.has(ik):
							takes_waste = true
							break
				if not takes_waste:
					continue
				var outs: Array = specs.get("outputs", []) as Array
				for outp: Variant in outs:
					if outp is Dictionary:
						recycled += float((outp as Dictionary).get("rate", 0.0)) * span

	var headroom := maxf(waste_capacity - waste_stock, 0.0)
	var daily_prod := produced_ph * 24.0
	var autonomy_days := headroom / daily_prod if daily_prod > 0.01 else \
			(99.0 if waste_capacity > 0.01 else 0.0)

	var closure := 0.0
	if produced > 0.01:
		closure = clampf(recycled / produced, 0.0, 1.0)
	elif recycled > 0.01:
		closure = 1.0

	var active := produced > 0.01 or waste_capacity > 0.01 or recycled > 0.01
	var starved := waste_capacity > 0.01 and headroom / maxf(waste_capacity, 0.001) < 0.05 \
			and produced_ph > 0.0

	return {
		"kind": "waste",
		"active": active,
		"demand": produced,
		"supply_local": recycled,
		"supply_import": 0.0,
		"stock": headroom,
		"closure_pct": closure,
		"autonomy_days": autonomy_days,
		"unit": "L+kg",
		"starved": starved,
	}


static func _timeline_for(resource_flow: RefCounted, item_id: String) -> RefCounted:
	if resource_flow == null or item_id.is_empty():
		return null
	if resource_flow.has_method("get_timeline"):
		return resource_flow.call("get_timeline", item_id) as RefCounted
	return null


static func _processor_output_rate(specs: Dictionary, kind: String) -> float:
	var outs: Array = specs.get("outputs", []) as Array
	for outp: Variant in outs:
		if outp is Dictionary:
			var od: Dictionary = outp as Dictionary
			if ResourceKinds.normalize_kind(str(od.get("kind", ""))) == kind:
				return float(od.get("rate", 0.0))
	return 0.0


static func _import_rate_sum(model: GraphModel, kind: String) -> float:
	if model == null:
		return 0.0
	var total := 0.0
	for item: Dictionary in model.items:
		if str(item.get("type", "")) != "processor":
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if not bool(specs.get("counts_as_import", false)):
			continue
		var import_kind: String = ResourceKinds.normalize_kind(str(specs.get("import_kind", "")))
		if import_kind.is_empty():
			var outs: Array = specs.get("outputs", []) as Array
			if not outs.is_empty() and outs[0] is Dictionary:
				import_kind = ResourceKinds.normalize_kind(
						str((outs[0] as Dictionary).get("kind", "")))
		if import_kind != kind:
			continue
		total += _processor_output_rate(specs, kind)
	return total


static func _total_occupants(model: GraphModel) -> int:
	if model == null:
		return 0
	var n := 0
	for item: Dictionary in model.items:
		if str(item.get("type", "")) != "processor":
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if str(specs.get("role", "")) != "habitat":
			continue
		n += maxi(int(specs.get("occupants", 1)), 1)
	return n


static func _habitat_demand_rates(model: GraphModel) -> Dictionary:
	var rates: Dictionary = {}
	if model == null:
		return rates
	for item: Dictionary in model.items:
		if str(item.get("type", "")) != "processor":
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if str(specs.get("role", "")) != "habitat":
			continue
		var occ: float = maxf(float(specs.get("occupants", 1.0)), 1.0)
		var inputs: Array = specs.get("inputs", []) as Array
		for inp: Variant in inputs:
			if inp is Dictionary:
				var d: Dictionary = inp as Dictionary
				var kind: String = ResourceKinds.normalize_kind(str(d.get("kind", "")))
				if kind.is_empty():
					continue
				rates[kind] = float(rates.get(kind, 0.0)) + float(d.get("rate", 0.0)) * occ
	return rates


static func _any_habitat_starved(model: GraphModel) -> bool:
	if model == null:
		return false
	for item: Dictionary in model.items:
		if str(item.get("type", "")) != "processor":
			continue
		var specs: Dictionary = item.get("specs", {}) as Dictionary
		if str(specs.get("role", "")) != "habitat":
			continue
		if bool(specs.get("is_starved", false)):
			return true
		var sk: Array = specs.get("starved_kinds", []) as Array
		if not sk.is_empty():
			return true
	return false


static func _mean_active_closure(channels: Dictionary) -> float:
	var sum := 0.0
	var n := 0
	for key: String in channels.keys():
		var ch: Dictionary = channels[key] as Dictionary
		if not bool(ch.get("active", false)):
			continue
		sum += float(ch.get("closure_pct", 0.0))
		n += 1
	return sum / float(n) if n > 0 else 0.0


static func _min_active_autonomy(channels: Dictionary) -> float:
	var m := INF
	var any := false
	for key: String in ["energy", "water", "food"]:
		if not channels.has(key):
			continue
		var ch: Dictionary = channels[key] as Dictionary
		if not bool(ch.get("active", false)):
			continue
		m = minf(m, float(ch.get("autonomy_days", 0.0)))
		any = true
	return m if any else 0.0
