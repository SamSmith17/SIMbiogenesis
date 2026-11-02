class_name VehicleCatalog
extends RefCounted

## The living-vehicle designer's parts tables: chassis (what is under it: cab,
## axles, tyres, fuel) and body styles (the box people live in), picked
## independently — a 2006 Ford E-450 dual-rear-wheel cutaway under a
## fiberglass "aerotech" shuttle box is CHASSIS ford_e450_drw + BODY
## shuttle_aerotech. Units are metres, kilograms, litres.
##
## Sources for the chassis numbers (manufacturer body-builder guides / spec
## sheets, as published; rounded):
##   Ford E-Series cutaway body builder's layout book (E-450 158"/176" WB,
##     14,500 lb GVWR, 55 gal tank, LT225/75R16 duals).
##   Ford Transit 2020+ spec sheet (250 high roof 148" EL, 9,070 lb GVWR,
##     25 gal tank, 235/65R16).
##   Ram ProMaster 3500 159" EXT (9,350 lb GVWR, 24 gal tank).
##   Mercedes Sprinter 2500 170" (9,050 lb GVWR, 24.5 gal diesel tank).
##   Chevrolet Express 3500 155" (12 ft cutaway WB 159", 31 gal tank).
##   Ford F-59 stripped chassis (step vans: 158–190" WB, 22,000 lb, 60 gal).
##   Ford F-53 motorhome stripped chassis (208–252" WB, 26,000 lb, 80 gal).
##   International 3800 / IC CE school bus chassis (~276" WB on a 35 ft bus,
##     25,000–30,000 lb, 60–100 gal diesel).
##   Freightliner M2 106 (212" WB box truck, 26,000 lb, 50–70 gal).
##   Isuzu NPR gas (150" WB, 14,500 lb, 30 gal).
##   Freightliner Cascadia day cab (~180" WB tractor, 2 × 100 gal tanks).
## Real-world fuel economy bands (`mpg`): owner / fleet reported ranges at a
## 55 mph cruise — vehicles over 8,500 lb GVWR carry no EPA rating. They are
## what VehicleEnergy is calibrated against (vehiclelab_selftest pins it).

const IN := 0.0254
const LB := 0.45359237
const GAL := 3.785411784

## Cab styles: how the front of the vehicle is drawn and where the driver sits.
##   cutaway  — a van nose and cab, the body box bolted on behind (E-450).
##   full_van — the whole van shell is one body (Sprinter, Transit, ProMaster).
##   cowl     — a long bonneted engine in front of a flat windshield (school
##              bus, conventional box truck, ambulance Type I).
##   forward  — flat front, the driver over/behind the front axle (step van,
##              Class A, transit-style bus).
##   tractor  — a semi tractor's bonnet and day cab.
##   none     — a trailer: an A-frame tongue, no cab.
const CAB_STYLES := ["cutaway", "full_van", "cowl", "forward", "tractor", "none"]

const CHASSIS := {
	"ford_e450_drw": {
		"label": "Ford E-450 cutaway, dual rear wheels (2006)", "cab": "cutaway",
		"wheelbase_m": 176.0 * IN, "track_m": 1.75, "front_overhang_m": 0.95,
		"tyre_d_m": 0.75, "tyre_w_m": 0.225, "dually": true, "rear_axles": 1,
		"frame_h_m": 0.72, "hood_len_m": 1.05, "cab_len_m": 2.15, "cab_h_m": 2.25,
		"cab_w_m": 2.03, "curb_kg": 3150.0, "gvwr_kg": 14500.0 * LB,
		"fuel": "gasoline", "tank_l": 55.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 38.0, "top_speed_mps": 33.0, "mpg": [7.0, 11.0],
	},
	"chevy_express_3500": {
		"label": "Chevrolet Express 3500 cutaway", "cab": "cutaway",
		"wheelbase_m": 159.0 * IN, "track_m": 1.73, "front_overhang_m": 0.98,
		"tyre_d_m": 0.75, "tyre_w_m": 0.225, "dually": true, "rear_axles": 1,
		"frame_h_m": 0.72, "hood_len_m": 1.0, "cab_len_m": 2.1, "cab_h_m": 2.2,
		"cab_w_m": 2.01, "curb_kg": 2950.0, "gvwr_kg": 14200.0 * LB,
		"fuel": "gasoline", "tank_l": 31.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 36.0, "top_speed_mps": 33.0, "mpg": [7.5, 12.0],
	},
	"ford_transit_250_hr": {
		"label": "Ford Transit 250 high roof, 148\" extended", "cab": "full_van",
		"wheelbase_m": 148.0 * IN, "track_m": 1.71, "front_overhang_m": 0.98, "rear_overhang_m": 1.96,
		"tyre_d_m": 0.71, "tyre_w_m": 0.235, "dually": false, "rear_axles": 1,
		"frame_h_m": 0.62, "hood_len_m": 0.95, "cab_len_m": 2.6, "cab_h_m": 2.0,
		"cab_w_m": 2.07, "curb_kg": 2450.0, "gvwr_kg": 9070.0 * LB,
		"fuel": "gasoline", "tank_l": 25.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 40.0, "top_speed_mps": 38.0, "mpg": [13.0, 18.0],
	},
	"ram_promaster_3500": {
		"label": "Ram ProMaster 3500 high roof, 159\" extended", "cab": "full_van",
		"wheelbase_m": 159.0 * IN, "track_m": 1.81, "front_overhang_m": 0.96, "rear_overhang_m": 1.36,
		"tyre_d_m": 0.71, "tyre_w_m": 0.225, "dually": false, "rear_axles": 1,
		"frame_h_m": 0.55, "hood_len_m": 0.85, "cab_len_m": 2.25, "cab_h_m": 1.95,
		"cab_w_m": 2.1, "curb_kg": 2350.0, "gvwr_kg": 9350.0 * LB,
		"fuel": "gasoline", "tank_l": 24.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 40.0, "top_speed_mps": 38.0, "mpg": [14.0, 18.0],
	},
	"sprinter_170": {
		"label": "Mercedes Sprinter 2500 170\" high roof (diesel)", "cab": "full_van",
		"wheelbase_m": 170.0 * IN, "track_m": 1.72, "front_overhang_m": 1.0, "rear_overhang_m": 2.05,
		"tyre_d_m": 0.72, "tyre_w_m": 0.235, "dually": false, "rear_axles": 1,
		"frame_h_m": 0.6, "hood_len_m": 0.95, "cab_len_m": 3.0, "cab_h_m": 2.0,
		"cab_w_m": 2.02, "curb_kg": 2600.0, "gvwr_kg": 9050.0 * LB,
		"fuel": "diesel", "tank_l": 24.5 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 40.0, "top_speed_mps": 38.0, "mpg": [16.0, 22.0],
	},
	"ford_etransit": {
		"label": "Ford E-Transit high roof (electric, 89 kWh)", "cab": "full_van",
		"wheelbase_m": 148.0 * IN, "track_m": 1.71, "front_overhang_m": 0.98, "rear_overhang_m": 1.96,
		"tyre_d_m": 0.71, "tyre_w_m": 0.235, "dually": false, "rear_axles": 1,
		"frame_h_m": 0.62, "hood_len_m": 0.95, "cab_len_m": 2.6, "cab_h_m": 2.0,
		"cab_w_m": 2.07, "curb_kg": 2950.0, "gvwr_kg": 9500.0 * LB,
		"fuel": "electric", "tank_l": 0.0, "battery_kwh": 89.0,
		"max_steer_deg": 40.0, "top_speed_mps": 36.0, "mpg": [],
	},
	"ford_f59_stripped": {
		"label": "Ford F-59 stripped chassis (step van)", "cab": "forward",
		"wheelbase_m": 178.0 * IN, "track_m": 1.88, "front_overhang_m": 0.85,
		"tyre_d_m": 0.86, "tyre_w_m": 0.245, "dually": true, "rear_axles": 1,
		"frame_h_m": 0.85, "hood_len_m": 0.0, "cab_len_m": 1.6, "cab_h_m": 2.9,
		"cab_w_m": 2.3, "curb_kg": 4300.0, "gvwr_kg": 22000.0 * LB,
		"fuel": "gasoline", "tank_l": 60.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 40.0, "top_speed_mps": 30.0, "mpg": [7.0, 10.5],
	},
	"ford_f53_class_a": {
		"label": "Ford F-53 motorhome chassis (Class A, 232\" WB)", "cab": "forward",
		"wheelbase_m": 232.0 * IN, "track_m": 2.0, "front_overhang_m": 0.95,
		"tyre_d_m": 0.95, "tyre_w_m": 0.25, "dually": true, "rear_axles": 1,
		"frame_h_m": 0.95, "hood_len_m": 0.0, "cab_len_m": 1.4, "cab_h_m": 3.3,
		"cab_w_m": 2.54, "curb_kg": 3700.0, "gvwr_kg": 24000.0 * LB,
		"fuel": "gasoline", "tank_l": 80.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 45.0, "top_speed_mps": 33.0, "mpg": [6.0, 10.0],
	},
	"intl_3800": {
		"label": "International 3800 school bus (diesel, 35 ft)", "cab": "cowl",
		"wheelbase_m": 276.0 * IN, "track_m": 2.0, "front_overhang_m": 1.0,
		"tyre_d_m": 1.0, "tyre_w_m": 0.25, "dually": true, "rear_axles": 1,
		"frame_h_m": 1.0, "hood_len_m": 1.6, "cab_len_m": 2.2, "cab_h_m": 3.0,
		"cab_w_m": 2.44, "curb_kg": 10400.0, "gvwr_kg": 29000.0 * LB,
		"fuel": "diesel", "tank_l": 60.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 45.0, "top_speed_mps": 29.0, "mpg": [6.0, 9.0],
	},
	"intl_ce_short": {
		"label": "IC CE school bus, short (diesel, 25 ft)", "cab": "cowl",
		"wheelbase_m": 157.0 * IN, "track_m": 2.0, "front_overhang_m": 1.0,
		"tyre_d_m": 0.98, "tyre_w_m": 0.25, "dually": true, "rear_axles": 1,
		"frame_h_m": 1.0, "hood_len_m": 1.5, "cab_len_m": 2.1, "cab_h_m": 3.0,
		"cab_w_m": 2.44, "curb_kg": 7900.0, "gvwr_kg": 23500.0 * LB,
		"fuel": "diesel", "tank_l": 60.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 45.0, "top_speed_mps": 29.0, "mpg": [7.0, 10.0],
	},
	"freightliner_m2": {
		"label": "Freightliner M2 106 box truck (diesel, 212\" WB)", "cab": "cowl",
		"wheelbase_m": 212.0 * IN, "track_m": 2.03, "front_overhang_m": 1.05,
		"tyre_d_m": 1.0, "tyre_w_m": 0.25, "dually": true, "rear_axles": 1,
		"frame_h_m": 1.05, "hood_len_m": 1.45, "cab_len_m": 2.5, "cab_h_m": 2.75,
		"cab_w_m": 2.4, "curb_kg": 6900.0, "gvwr_kg": 26000.0 * LB,
		"fuel": "diesel", "tank_l": 70.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 45.0, "top_speed_mps": 30.0, "mpg": [7.5, 11.0],
	},
	"isuzu_npr": {
		"label": "Isuzu NPR gas (cab-over, 150\" WB)", "cab": "forward",
		"wheelbase_m": 150.0 * IN, "track_m": 1.67, "front_overhang_m": 1.0,
		"tyre_d_m": 0.78, "tyre_w_m": 0.215, "dually": true, "rear_axles": 1,
		"frame_h_m": 0.8, "hood_len_m": 0.0, "cab_len_m": 1.75, "cab_h_m": 2.3,
		"cab_w_m": 2.0, "curb_kg": 3600.0, "gvwr_kg": 14500.0 * LB,
		"fuel": "gasoline", "tank_l": 30.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 45.0, "top_speed_mps": 31.0, "mpg": [6.5, 10.0],
	},
	"cascadia_day_cab": {
		"label": "Freightliner Cascadia day cab + 40 ft container chassis", "cab": "tractor",
		"wheelbase_m": 180.0 * IN, "track_m": 2.07, "front_overhang_m": 1.1,
		"tyre_d_m": 1.04, "tyre_w_m": 0.28, "dually": true, "rear_axles": 2,
		"frame_h_m": 1.1, "hood_len_m": 1.9, "cab_len_m": 3.2, "cab_h_m": 3.3,
		"cab_w_m": 2.48, "curb_kg": 8400.0 + 3100.0, "gvwr_kg": 36287.0,
		"fuel": "diesel", "tank_l": 200.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 45.0, "top_speed_mps": 30.0, "mpg": [5.5, 9.0],
	},
	"trailer_tandem": {
		"label": "Tandem-axle trailer (7,000 lb)", "cab": "none",
		"wheelbase_m": 0.0, "track_m": 1.9, "front_overhang_m": 1.2,
		"tyre_d_m": 0.72, "tyre_w_m": 0.205, "dually": false, "rear_axles": 2,
		"frame_h_m": 0.55, "hood_len_m": 0.0, "cab_len_m": 0.0, "cab_h_m": 0.0,
		"cab_w_m": 0.0, "curb_kg": 600.0, "gvwr_kg": 7000.0 * LB,
		"fuel": "none", "tank_l": 0.0, "battery_kwh": 0.0,
		"max_steer_deg": 0.0, "top_speed_mps": 29.0, "mpg": [],
	},
	"trailer_single": {
		"label": "Single-axle trailer (3,500 lb)", "cab": "none",
		"wheelbase_m": 0.0, "track_m": 1.75, "front_overhang_m": 1.1,
		"tyre_d_m": 0.68, "tyre_w_m": 0.205, "dually": false, "rear_axles": 1,
		"frame_h_m": 0.5, "hood_len_m": 0.0, "cab_len_m": 0.0, "cab_h_m": 0.0,
		"cab_w_m": 0.0, "curb_kg": 350.0, "gvwr_kg": 3500.0 * LB,
		"fuel": "none", "tank_l": 0.0, "battery_kwh": 0.0,
		"max_steer_deg": 0.0, "top_speed_mps": 29.0, "mpg": [],
	},
}

## Body styles. `length_m` = the box from the back of the cab to the rear
## (cutaway / cowl / forward / tractor), the whole shell (full_van, from the
## front bumper), or the box (trailer, behind the tongue). `height_m` = the
## roof above the ground. `floor_h_m` = the inside floor above the ground.
## `roof`: flat | crown | high_top | arched | cabover (an RV's bunk over the
## cab). `cd` = drag coefficient of the whole vehicle in that shape (Hucho,
## "Aerodynamics of Road Vehicles": vans 0.35–0.45, box bodies 0.6–0.75,
## buses 0.6–0.7, tractor-trailers ~0.6). `wall_kg_m2` = shell + framing per
## square metre of skin. `windows`: none | few | band | bus (a full row).
## `rear_door`: barn | roll_up | lift | none. `integral`: the body runs over
## the driver's cab (a van shell, a bus, a step van, a Class A) — its length
## is then the whole vehicle from the front. `in_curb`: the chassis curb mass
## already includes this body (a cargo van, a whole school bus). `mass_kg`
## replaces the skin estimate (an ISO container's published tare).
const BODIES := {
	"van_shell": {
		"label": "Van shell (as built)", "length_m": 0.0, "width_m": 2.03,
		"height_m": 2.75, "floor_h_m": 0.55, "roof": "high_top", "cd": 0.42,
		"wall_kg_m2": 9.0, "windows": "few", "rear_door": "barn", "side_door": "slider",
		"corner_r_m": 0.18, "integral": true, "in_curb": true,
		"color": [0.92, 0.93, 0.94],
	},
	"shuttle_aerotech": {
		"label": "Fiberglass \"aerotech\" shuttle body", "length_m": 4.9, "width_m": 2.36,
		"height_m": 3.05, "floor_h_m": 0.82, "roof": "crown", "cd": 0.6,
		"wall_kg_m2": 14.0, "windows": "band", "rear_door": "none", "side_door": "bus",
		"corner_r_m": 0.22, "color": [0.95, 0.95, 0.95],
	},
	"skoolie": {
		"label": "School bus body (Blue Bird / Thomas)", "length_m": 8.4, "width_m": 2.44,
		"height_m": 3.15, "floor_h_m": 1.0, "roof": "arched", "cd": 0.65,
		"wall_kg_m2": 18.0, "windows": "bus", "rear_door": "barn", "side_door": "bus",
		"corner_r_m": 0.12, "integral": true, "in_curb": true,
		"color": [0.98, 0.72, 0.06],
	},
	"step_van_alu": {
		"label": "Aluminium step van body (P1000)", "length_m": 6.6, "width_m": 2.3,
		"height_m": 3.15, "floor_h_m": 0.75, "roof": "flat", "cd": 0.72,
		"wall_kg_m2": 12.0, "windows": "none", "rear_door": "roll_up", "side_door": "sliding_step",
		"corner_r_m": 0.08, "integral": true,
		"color": [0.9, 0.9, 0.88],
	},
	"ambulance_type3": {
		"label": "Ambulance module (Type III)", "length_m": 4.0, "width_m": 2.36,
		"height_m": 2.95, "floor_h_m": 0.82, "roof": "flat", "cd": 0.66,
		"wall_kg_m2": 16.0, "windows": "few", "rear_door": "barn", "side_door": "hinged",
		"corner_r_m": 0.06, "color": [0.97, 0.97, 0.97],
	},
	"class_c_rv": {
		"label": "Class C RV body (cab-over)", "length_m": 5.4, "width_m": 2.44,
		"height_m": 3.4, "floor_h_m": 0.9, "roof": "cabover", "cd": 0.62,
		"wall_kg_m2": 13.0, "windows": "few", "rear_door": "none", "side_door": "hinged",
		"corner_r_m": 0.18, "color": [0.94, 0.93, 0.9],
	},
	"class_a_motorhome": {
		"label": "Class A motorhome body", "length_m": 9.6, "width_m": 2.54,
		"height_m": 3.75, "floor_h_m": 1.0, "roof": "crown", "cd": 0.58,
		"wall_kg_m2": 20.0, "windows": "few", "rear_door": "none", "side_door": "hinged",
		"corner_r_m": 0.25, "integral": true,
		"color": [0.9, 0.88, 0.84],
	},
	"dry_box_16": {
		"label": "Dry van box (16 ft)", "length_m": 4.88, "width_m": 2.44,
		"height_m": 3.35, "floor_h_m": 1.05, "roof": "flat", "cd": 0.72,
		"wall_kg_m2": 11.0, "windows": "none", "rear_door": "roll_up", "side_door": "none",
		"corner_r_m": 0.03, "color": [0.96, 0.96, 0.96],
	},
	"travel_trailer": {
		"label": "Travel trailer (fiberglass, 20 ft)", "length_m": 6.1, "width_m": 2.4,
		"height_m": 3.1, "floor_h_m": 0.7, "roof": "crown", "cd": 0.55,
		"wall_kg_m2": 11.0, "windows": "few", "rear_door": "none", "side_door": "hinged",
		"corner_r_m": 0.35, "color": [0.95, 0.95, 0.93],
	},
	"cargo_trailer": {
		"label": "Enclosed cargo trailer (V-nose, 16 ft)", "length_m": 4.9, "width_m": 2.3,
		"height_m": 2.85, "floor_h_m": 0.55, "roof": "crown", "cd": 0.6,
		"wall_kg_m2": 9.0, "windows": "none", "rear_door": "lift", "side_door": "hinged",
		"corner_r_m": 0.1, "color": [0.1, 0.1, 0.11],
	},
	"iso_40hc": {
		"label": "ISO 40 ft high-cube container", "length_m": 12.19, "width_m": 2.44,
		"height_m": 4.1, "floor_h_m": 1.35, "roof": "flat", "cd": 0.62,
		"wall_kg_m2": 50.0, "windows": "few", "rear_door": "barn", "side_door": "hinged",
		"corner_r_m": 0.0, "mass_kg": 3900.0,
		"color": [0.55, 0.16, 0.12],
	},
}

## The eleven vehicle types: their default chassis + body and the bodies /
## chassis that fit them (the designer offers these first, any combination
## of a compatible cab is allowed).
const TYPES := {
	"van": {"label": "Van (camper conversion)", "chassis": "sprinter_170", "body": "van_shell",
		"chassis_ok": ["sprinter_170", "ford_transit_250_hr", "ram_promaster_3500", "ford_etransit"]},
	"cargo_van": {"label": "Cargo van", "chassis": "ford_transit_250_hr", "body": "van_shell",
		"chassis_ok": ["ford_transit_250_hr", "ram_promaster_3500", "sprinter_170", "ford_etransit"]},
	"shuttle_bus": {"label": "Shuttle bus", "chassis": "ford_e450_drw", "body": "shuttle_aerotech",
		"chassis_ok": ["ford_e450_drw", "chevy_express_3500"]},
	"school_bus": {"label": "School bus (skoolie)", "chassis": "intl_3800", "body": "skoolie",
		"chassis_ok": ["intl_3800", "intl_ce_short"]},
	"step_van": {"label": "Step van", "chassis": "ford_f59_stripped", "body": "step_van_alu",
		"chassis_ok": ["ford_f59_stripped", "isuzu_npr"]},
	"ambulance": {"label": "Ambulance (Type III)", "chassis": "ford_e450_drw", "body": "ambulance_type3",
		"chassis_ok": ["ford_e450_drw", "chevy_express_3500", "freightliner_m2"]},
	"rv": {"label": "RV (Class C)", "chassis": "ford_e450_drw", "body": "class_c_rv",
		"chassis_ok": ["ford_e450_drw", "chevy_express_3500", "sprinter_170"]},
	"motorhome": {"label": "Motorhome (Class A)", "chassis": "ford_f53_class_a", "body": "class_a_motorhome",
		"chassis_ok": ["ford_f53_class_a"]},
	"box_truck": {"label": "Box truck", "chassis": "isuzu_npr", "body": "dry_box_16",
		"chassis_ok": ["isuzu_npr", "freightliner_m2", "ford_e450_drw"]},
	"trailer": {"label": "Trailer (travel / cargo)", "chassis": "trailer_tandem", "body": "travel_trailer",
		"chassis_ok": ["trailer_tandem", "trailer_single"]},
	"semi_container": {"label": "Semi truck with container", "chassis": "cascadia_day_cab", "body": "iso_40hc",
		"chassis_ok": ["cascadia_day_cab"]},
}

const TYPE_ORDER := ["van", "cargo_van", "shuttle_bus", "school_bus", "step_van", "ambulance",
	"rv", "motorhome", "box_truck", "trailer", "semi_container"]


## Interior element types: their default size (w across, l along, h = the
## TOP above the inside floor), what they provide and their mass. A bed
## sleeps floor(w / BED_SLEEPER_W) people (1–2) along its own long axis.
const BED_SLEEPER_W := 0.62
const INTERIOR_TYPES := {
	"bed": {"label": "Bed (platform)", "w": 1.37, "l": 1.9, "h": 0.62, "mass_kg": 45.0,
		"provides": ["sleep"], "color": [0.55, 0.42, 0.28]},
	"bunk": {"label": "Bunks (two singles)", "w": 0.8, "l": 1.9, "h": 1.45, "mass_kg": 60.0,
		"provides": ["sleep"], "color": [0.55, 0.42, 0.28]},
	"cabover_bed": {"label": "Cab-over bed", "w": 1.9, "l": 1.4, "h": 1.45, "mass_kg": 30.0,
		"provides": ["sleep"], "color": [0.55, 0.42, 0.28]},
	"dinette": {"label": "Dinette (benches + table)", "w": 1.0, "l": 1.6, "h": 0.74, "mass_kg": 40.0,
		"provides": ["seat"], "color": [0.6, 0.47, 0.32]},
	"bench": {"label": "Bench", "w": 0.5, "l": 1.4, "h": 0.45, "mass_kg": 18.0,
		"provides": ["seat"], "color": [0.6, 0.47, 0.32]},
	"table": {"label": "Table", "w": 0.6, "l": 0.8, "h": 0.74, "mass_kg": 10.0,
		"provides": [], "color": [0.62, 0.5, 0.35]},
	"galley": {"label": "Galley (sink + range)", "w": 0.6, "l": 1.3, "h": 0.92, "mass_kg": 55.0,
		"provides": ["kitchen"], "color": [0.65, 0.52, 0.36]},
	"fridge": {"label": "Fridge (12 V)", "w": 0.55, "l": 0.55, "h": 1.2, "mass_kg": 25.0,
		"provides": [], "color": [0.86, 0.87, 0.88]},
	"shower": {"label": "Shower", "w": 0.8, "l": 0.8, "h": 2.0, "mass_kg": 30.0,
		"provides": ["shower"], "color": [0.9, 0.92, 0.93]},
	"toilet": {"label": "Toilet (composting)", "w": 0.5, "l": 0.6, "h": 0.5, "mass_kg": 12.0,
		"provides": ["restroom"], "color": [0.92, 0.92, 0.9]},
	"shoilet": {"label": "Shoilet (wet bath: shower + toilet)", "w": 0.85, "l": 0.95, "h": 2.0,
		"mass_kg": 45.0, "provides": ["shower", "restroom"], "color": [0.9, 0.92, 0.93]},
	"cabinet": {"label": "Cabinet / shelves", "w": 0.45, "l": 1.0, "h": 1.9, "mass_kg": 30.0,
		"provides": [], "color": [0.64, 0.5, 0.34]},
	"cubby": {"label": "Overhead cubbies", "w": 0.4, "l": 1.4, "h": 0.4, "mass_kg": 12.0,
		"provides": [], "color": [0.64, 0.5, 0.34], "wall_hung": 1.5},
	"workbench": {"label": "Workbench", "w": 0.65, "l": 1.6, "h": 0.92, "mass_kg": 50.0,
		"provides": [], "color": [0.5, 0.4, 0.3]},
	"sofa": {"label": "Sofa", "w": 0.75, "l": 1.8, "h": 0.85, "mass_kg": 45.0,
		"provides": ["seat"], "color": [0.35, 0.38, 0.42]},
	"wall": {"label": "Partition wall", "w": 0.05, "l": 1.0, "h": 2.0, "mass_kg": 15.0,
		"provides": [], "color": [0.85, 0.82, 0.76]},
	"battery": {"label": "Battery bank", "w": 0.5, "l": 0.6, "h": 0.3, "mass_kg": 60.0,
		"provides": ["battery"], "color": [0.15, 0.17, 0.2], "kwh": 5.0},
	"inverter": {"label": "Inverter / charger", "w": 0.3, "l": 0.45, "h": 0.25, "mass_kg": 15.0,
		"provides": ["inverter"], "color": [0.2, 0.35, 0.55], "wall_hung": 1.2},
	"water_tank": {"label": "Fresh water tank", "w": 0.45, "l": 0.8, "h": 0.4, "mass_kg": 8.0,
		"provides": ["water"], "color": [0.85, 0.88, 0.9], "litres": 120.0},
	"grey_tank": {"label": "Grey water tank", "w": 0.45, "l": 0.7, "h": 0.35, "mass_kg": 7.0,
		"provides": ["grey"], "color": [0.45, 0.47, 0.5], "litres": 90.0},
	"light": {"label": "Ceiling light", "w": 0.2, "l": 0.2, "h": 0.03, "mass_kg": 0.3,
		"provides": [], "color": [1.0, 0.96, 0.85], "ceiling": true},
	"monitor": {"label": "Monitor", "w": 0.06, "l": 0.6, "h": 0.35, "mass_kg": 4.0,
		"provides": [], "color": [0.08, 0.08, 0.09], "wall_hung": 1.2},
	"mirror": {"label": "Mirror", "w": 0.02, "l": 0.4, "h": 0.6, "mass_kg": 2.0,
		"provides": [], "color": [0.75, 0.8, 0.85], "wall_hung": 1.1},
}


static func chassis(id: String) -> Dictionary:
	return CHASSIS.get(id, CHASSIS["ford_e450_drw"])


static func body(id: String) -> Dictionary:
	return BODIES.get(id, BODIES["van_shell"])


static func type_info(id: String) -> Dictionary:
	return TYPES.get(id, TYPES["van"])


static func interior_type(id: String) -> Dictionary:
	return INTERIOR_TYPES.get(id, {})


## How many people a bed of width `w` sleeps side by side (1–2).
static func bed_sleepers(type: String, w: float) -> int:
	if type == "bunk":
		return 2   # one per bunk, stacked
	return clampi(int(floor(w / BED_SLEEPER_W)), 1, 2)
