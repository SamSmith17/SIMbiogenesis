class_name ContainerCatalog
extends RefCounted
## Real transport + storage volumes — PACKING_PLAN.md Phase 1. Pure data, the
## target volumes the PackSolver (Phase 2) packs into.
##
## Every entry records the INTERIOR load space, the DOOR APERTURE (fitting the
## volume is not fitting through the opening — a hot tub fits a 6x12 trailer's
## volume but not its door), payload, and (for droppable containers) exterior
## dims + tare so the container itself has a packed spec.
##
## Dims are METRES internally (project convention; display via
## PackedSpec._ft_in style helpers). `l_m` = load length (into the box),
## `w_m` = width, `h_m` = height. `door: null` = open-top (pickup bed, pallet,
## lidded totes) — no aperture constraint.
##
## Sources (fetched 2026-08-03): U-Haul published equipment specs
## (uhaul.com/Truck-Rentals, /Trailers); ISO 668 series-1 freight containers;
## GMA pallet spec; manufacturer datasheets for totes/drums. Payloads are the
## rental/rated max load, NOT what suspension comfort allows.

const KINDS := ["vehicle", "trailer", "container", "sub"]

## kind: "vehicle" = drives, "trailer" = towed (tongue-weight matters),
## "container" = droppable ISO box, "sub" = nests inside another volume
## (Phase 3 boxes-within-boxes).
const CONTAINERS: Array = [
	# --- Vehicles (U-Haul published inside dims / door / max load) ---
	{"id": "pickup_bed", "label": "Pickup (8' bed)", "icon": "🛻",
		"kind": "vehicle",
		"interior": {"l_m": 2.39, "w_m": 1.57, "h_m": 0.53},  # 7'10" x 5'2" x 1'9" rail
		"door": null,  # open top
		"payload_kg": 900.0,  # ~1,990 lb
		"notes": "Open bed — weather exposure; rail height limits stacking."},
	{"id": "cargo_van", "label": "Cargo Van (9')", "icon": "🚐",
		"kind": "vehicle",
		"interior": {"l_m": 2.90, "w_m": 1.70, "h_m": 1.42},  # 9'6" x 5'7" x 4'8"
		"door": {"w_m": 1.55, "h_m": 1.24},                   # 5'1" x 4'1"
		"payload_kg": 1760.0,  # ~3,880 lb
		"notes": "Wheel wells intrude on floor width."},
	{"id": "uhaul_10", "label": "10' Box Truck", "icon": "🚚",
		"kind": "vehicle",
		"interior": {"l_m": 3.02, "w_m": 1.91, "h_m": 1.85},  # 9'11" x 6'3" x 6'1"
		"door": {"w_m": 1.80, "h_m": 1.70},                   # 5'11" x 5'7"
		"payload_kg": 1293.0,  # 2,850 lb
		"notes": "No Mom's Attic; smallest true box truck."},
	{"id": "uhaul_15", "label": "15' Box Truck", "icon": "🚚",
		"kind": "vehicle",
		"interior": {"l_m": 4.57, "w_m": 2.34, "h_m": 2.18},  # 15' x 7'8" x 7'2"
		"door": {"w_m": 2.21, "h_m": 1.96},                   # 7'3" x 6'5"
		"payload_kg": 2896.0,  # 6,385 lb — yes, more than the 20'
		"notes": "Highest payload/volume ratio in the U-Haul fleet."},
	{"id": "uhaul_20", "label": "20' Box Truck", "icon": "🚚",
		"kind": "vehicle",
		"interior": {"l_m": 5.92, "w_m": 2.34, "h_m": 2.16},  # 19'5" x 7'8" x 7'1"
		"door": {"w_m": 2.21, "h_m": 1.96},                   # 7'3" x 6'5"
		"payload_kg": 2585.0,  # 5,700 lb
		"notes": "More floor than the 15' but LESS payload — check both."},
	{"id": "uhaul_26", "label": "26' Box Truck", "icon": "🚚",
		"kind": "vehicle",
		"interior": {"l_m": 7.98, "w_m": 2.46, "h_m": 2.51},  # 26'2" x 8'1" x 8'3"
		"door": {"w_m": 2.36, "h_m": 2.08},                   # 7'9" x 6'10"
		"payload_kg": 5832.0,  # 12,859 lb
		"notes": "The classic full-camp mover."},
	# --- Trailers (tongue weight ~10-15% of load — Phase 2 CoM check) ---
	{"id": "trailer_5x8", "label": "5x8 Cargo Trailer", "icon": "🛺",
		"kind": "trailer",
		"interior": {"l_m": 2.44, "w_m": 1.42, "h_m": 1.63},  # 8' x 4'8" x 5'4"
		"door": {"w_m": 1.22, "h_m": 1.47},                   # 4'0" x 4'10"
		"payload_kg": 816.0,  # 1,800 lb
		"notes": "Aim ~10-15% of cargo mass on the tongue."},
	{"id": "trailer_6x12", "label": "6x12 Cargo Trailer", "icon": "🛺",
		"kind": "trailer",
		"interior": {"l_m": 3.73, "w_m": 1.93, "h_m": 1.65},  # 12'3" x 6'4" x 5'5"
		"door": {"w_m": 1.55, "h_m": 1.45},                   # ~5'1" x 4'9"
		"payload_kg": 1125.0,  # 2,480 lb
		"notes": "Ramp door; aim ~10-15% of cargo mass on the tongue."},
	# --- ISO containers (ISO 668 series 1; the burner storage classic) ---
	{"id": "container_20", "label": "20' Shipping Container", "icon": "📦",
		"kind": "container",
		"interior": {"l_m": 5.898, "w_m": 2.352, "h_m": 2.393},
		"door": {"w_m": 2.343, "h_m": 2.280},
		"exterior": {"l_m": 6.058, "w_m": 2.438, "h_m": 2.591},
		"tare_kg": 2300.0, "payload_kg": 28200.0,
		"notes": "1CC/20GP. Rated payload far exceeds what any truck hauls."},
	{"id": "container_40", "label": "40' Shipping Container", "icon": "📦",
		"kind": "container",
		"interior": {"l_m": 12.032, "w_m": 2.352, "h_m": 2.393},
		"door": {"w_m": 2.343, "h_m": 2.280},
		"exterior": {"l_m": 12.192, "w_m": 2.438, "h_m": 2.591},
		"tare_kg": 3750.0, "payload_kg": 26700.0,
		"notes": "1AA/40GP."},
	{"id": "container_40hc", "label": "40' High-Cube Container", "icon": "📦",
		"kind": "container",
		"interior": {"l_m": 12.032, "w_m": 2.352, "h_m": 2.698},
		"door": {"w_m": 2.343, "h_m": 2.585},
		"exterior": {"l_m": 12.192, "w_m": 2.438, "h_m": 2.896},
		"tare_kg": 3900.0, "payload_kg": 26460.0,
		"notes": "1AAA/40HC — the extra foot of height is where lofts go."},
	# --- Sub-containers (nest inside the above — Phase 3) ---
	{"id": "pallet_48x40", "label": "Pallet (48x40 GMA)", "icon": "🟫",
		"kind": "sub",
		# Open-top: h = a typical 6' stack limit, not a wall.
		"interior": {"l_m": 1.219, "w_m": 1.016, "h_m": 1.83},
		"door": null,
		"exterior": {"l_m": 1.219, "w_m": 1.016, "h_m": 0.145},
		"tare_kg": 17.0, "payload_kg": 2087.0,  # 4,600 lb dynamic
		"notes": "Stack height is convention (~72\"), not structure."},
	{"id": "crate_8x4", "label": "Crate (8'x4'x2')", "icon": "🪵",
		"kind": "sub",
		"interior": {"l_m": 2.36, "w_m": 1.14, "h_m": 0.53},
		"door": null,
		"exterior": {"l_m": 2.44, "w_m": 1.22, "h_m": 0.61},
		"tare_kg": 45.0, "payload_kg": 500.0,
		"notes": "Plywood shipping crate on 4x8 sheet dims — the StarShade kit box."},
	{"id": "tote_27gal", "label": "27-gal Tote", "icon": "🧰",
		"kind": "sub",
		"interior": {"l_m": 0.61, "w_m": 0.44, "h_m": 0.32},
		"door": null,
		"exterior": {"l_m": 0.68, "w_m": 0.51, "h_m": 0.38},
		"tare_kg": 2.5, "payload_kg": 45.0,
		"notes": "The standard camp tote; lids stack."},
	{"id": "action_packer_35", "label": "35-gal Action Packer", "icon": "🧰",
		"kind": "sub",
		"interior": {"l_m": 1.02, "w_m": 0.43, "h_m": 0.37},
		"door": null,
		"exterior": {"l_m": 1.11, "w_m": 0.51, "h_m": 0.44},
		"tare_kg": 5.5, "payload_kg": 50.0,
		"notes": "Long-item tote — poles, stakes, conduit."},
	{"id": "job_box", "label": "Job Box (48\")", "icon": "🧰",
		"kind": "sub",
		"interior": {"l_m": 1.15, "w_m": 0.56, "h_m": 0.60},
		"door": null,
		"exterior": {"l_m": 1.22, "w_m": 0.61, "h_m": 0.71},
		"tare_kg": 40.0, "payload_kg": 120.0,
		"notes": "Lockable steel — tools + the expensive stuff."},
	{"id": "drum_55gal", "label": "55-gal Drum", "icon": "🛢",
		"kind": "sub",
		"interior": {"l_m": 0.56, "w_m": 0.56, "h_m": 0.85},
		"door": null,
		"exterior": {"l_m": 0.572, "w_m": 0.572, "h_m": 0.851},
		"tare_kg": 9.5, "payload_kg": 208.0,
		"notes": "Water/greywater ~208 L; strap upright."},
]


static func all_containers() -> Array:
	return CONTAINERS


static func find(container_id: String) -> Dictionary:
	for c in CONTAINERS:
		if str(c.get("id", "")) == container_id:
			return c
	return {}


static func containers_of_kind(kind: String) -> Array:
	var out: Array = []
	for c in CONTAINERS:
		if str(c.get("kind", "")) == kind:
			out.append(c)
	return out


static func interior_volume_m3(entry: Dictionary) -> float:
	var i: Dictionary = entry.get("interior", {})
	return float(i.get("l_m", 0.0)) * float(i.get("w_m", 0.0)) * float(i.get("h_m", 0.0))


## Can a packed unit pass the door in SOME axis-aligned 90° orientation?
## Two dims present as the cross-section, the third passes through. Ignores
## diagonal tilting (conservative — the "pivot the couch" manoeuvre is a
## bonus, never the plan). Open-top entries (door null) always pass.
static func fits_through_door(entry: Dictionary, packed: Dictionary) -> bool:
	var door = entry.get("door")
	if door == null:
		return true
	var dw := float((door as Dictionary).get("w_m", 0.0))
	var dh := float((door as Dictionary).get("h_m", 0.0))
	var lo := minf(dw, dh)
	var hi := maxf(dw, dh)
	var dims := [float(packed.get("w_m", 0.0)), float(packed.get("d_m", 0.0)),
		float(packed.get("h_m", 0.0))]
	for skip in 3:
		var pair: Array = []
		for i in 3:
			if i != skip:
				pair.append(float(dims[i]))
		if minf(pair[0], pair[1]) <= lo and maxf(pair[0], pair[1]) <= hi:
			return true
	return false


## The container ITSELF as a packed unit (exterior dims + tare) — a dropped
## 20' box or an empty tote occupies truck space too. Entries without
## exterior/tare (vehicles, trailers) return {}: they are not cargo.
static func packed_spec_for(container_id: String) -> Dictionary:
	var entry := find(container_id)
	if entry.is_empty() or not entry.has("exterior"):
		return {}
	var e: Dictionary = entry.get("exterior", {})
	return PackedSpec.normalize({
		"w_m": float(e.get("l_m", 0.0)), "d_m": float(e.get("w_m", 0.0)),
		"h_m": float(e.get("h_m", 0.0)),
		"mass_kg": float(entry.get("tare_kg", PackedSpec.MASS_UNKNOWN)),
		"form": "container", "source": "curated",
		# A container sits on its floor — keep authored l/w/h, don't let
		# normalize() re-sort height into a lying-down orientation.
		"this_side_up": true,
	})
