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
##     189" on a 25 ft, 25,000–30,000 lb, 60–100 gal diesel). `body_len_m`
##     on an integral chassis is the length its body is built to.
##   Freightliner M2 106 (212" WB box truck, 26,000 lb, 50–70 gal).
##   Isuzu NPR gas (150" WB, 14,500 lb, 30 gal).
##   Freightliner Cascadia day cab (~180" WB tractor, 2 × 100 gal tanks).
##   Mercedes Sprinter 3500 cab chassis 170" (11,030 lb GVWR, dual rear
##     wheels) — what a Class C is really built on.
## `curb_kg` is the BARE chassis (cab, frame, axles, a full tank is counted
## separately) for a cab-chassis / stripped chassis, and the whole vehicle for
## an integral one (a cargo van, a school bus): the body sheet's own
## estimate adds the box. `gawr_f_kg` / `gawr_r_kg` are the gross axle
## weight ratings the same sheets publish (the rear figure covers every rear
## axle together); `tow_kg` the conventional (ball hitch) tow rating and
## `gcwr_kg` the gross combination rating; `roof_kg` the roof load a van
## maker allows (a body's own `roof_kg` where the roof is the body's);
## `brakes` on a trailer chassis = it has its own (electric) brakes; `cg_wb`
## where the curb mass sits along the wheelbase (0 = the front axle) from
## the sheet's empty axle weights — a cab-chassis is engine-heavy (0.38),
## a cargo van even, a school bus rear-heavy (VehicleDesign.CHASSIS_CG_WB
## is the cab-chassis default).
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
		"cab_w_m": 2.03, "curb_kg": 2650.0, "gvwr_kg": 14500.0 * LB,
		"gawr_f_kg": 5000.0 * LB, "gawr_r_kg": 9600.0 * LB, "tow_kg": 10000.0 * LB, "gcwr_kg": 22000.0 * LB,
		"fuel": "gasoline", "tank_l": 55.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 38.0, "top_speed_mps": 33.0, "mpg": [7.0, 11.0],
	},
	"chevy_express_3500": {
		"label": "Chevrolet Express 3500 cutaway", "cab": "cutaway",
		"wheelbase_m": 159.0 * IN, "track_m": 1.73, "front_overhang_m": 0.98,
		"tyre_d_m": 0.75, "tyre_w_m": 0.225, "dually": true, "rear_axles": 1,
		"frame_h_m": 0.72, "hood_len_m": 1.0, "cab_len_m": 2.1, "cab_h_m": 2.2,
		"cab_w_m": 2.01, "curb_kg": 2500.0, "gvwr_kg": 14200.0 * LB,
		"gawr_f_kg": 4600.0 * LB, "gawr_r_kg": 9600.0 * LB, "tow_kg": 10000.0 * LB, "gcwr_kg": 20000.0 * LB,
		"fuel": "gasoline", "tank_l": 31.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 36.0, "top_speed_mps": 33.0, "mpg": [7.5, 12.0],
	},
	"ford_transit_250_hr": {
		"label": "Ford Transit 250 high roof, 148\" extended", "cab": "full_van",
		"wheelbase_m": 148.0 * IN, "track_m": 1.71, "front_overhang_m": 0.98, "rear_overhang_m": 1.96,
		"tyre_d_m": 0.71, "tyre_w_m": 0.235, "dually": false, "rear_axles": 1,
		"frame_h_m": 0.62, "hood_len_m": 0.95, "cab_len_m": 2.6, "cab_h_m": 2.0,
		"cab_w_m": 2.07, "curb_kg": 2450.0, "gvwr_kg": 9070.0 * LB,
		"gawr_f_kg": 4130.0 * LB, "gawr_r_kg": 5360.0 * LB, "tow_kg": 7500.0 * LB, "gcwr_kg": 13500.0 * LB,
		"roof_kg": 300.0, "shell_h_m": 2.78, "cg_wb": 0.5,
		"fuel": "gasoline", "tank_l": 25.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 40.0, "top_speed_mps": 38.0, "mpg": [13.0, 18.0],
	},
	"ram_promaster_3500": {
		"label": "Ram ProMaster 3500 high roof, 159\" extended", "cab": "full_van",
		"wheelbase_m": 159.0 * IN, "track_m": 1.81, "front_overhang_m": 0.96, "rear_overhang_m": 1.36,
		"tyre_d_m": 0.71, "tyre_w_m": 0.225, "dually": false, "rear_axles": 1,
		"frame_h_m": 0.55, "hood_len_m": 0.85, "cab_len_m": 2.25, "cab_h_m": 1.95,
		"cab_w_m": 2.1, "curb_kg": 2350.0, "gvwr_kg": 9350.0 * LB,
		"gawr_f_kg": 4630.0 * LB, "gawr_r_kg": 5860.0 * LB, "tow_kg": 6910.0 * LB, "gcwr_kg": 16220.0 * LB,
		"roof_kg": 150.0, "shell_h_m": 2.52, "cg_wb": 0.5,
		"fuel": "gasoline", "tank_l": 24.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 40.0, "top_speed_mps": 38.0, "mpg": [14.0, 18.0],
	},
	"sprinter_170": {
		"label": "Mercedes Sprinter 2500 170\" high roof (diesel)", "cab": "full_van",
		"wheelbase_m": 170.0 * IN, "track_m": 1.72, "front_overhang_m": 1.0, "rear_overhang_m": 2.05,
		"tyre_d_m": 0.72, "tyre_w_m": 0.235, "dually": false, "rear_axles": 1,
		"frame_h_m": 0.6, "hood_len_m": 0.95, "cab_len_m": 3.0, "cab_h_m": 2.0,
		"cab_w_m": 2.02, "curb_kg": 2600.0, "gvwr_kg": 9050.0 * LB,
		"gawr_f_kg": 3748.0 * LB, "gawr_r_kg": 5360.0 * LB, "tow_kg": 5000.0 * LB, "gcwr_kg": 13550.0 * LB,
		"roof_kg": 300.0, "shell_h_m": 2.75, "cg_wb": 0.5,
		"fuel": "diesel", "tank_l": 24.5 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 40.0, "top_speed_mps": 38.0, "mpg": [16.0, 22.0],
	},
	"sprinter_cab_chassis": {
		"label": "Mercedes Sprinter 3500 cab chassis, 170\" (diesel, duals)", "cab": "cutaway",
		"wheelbase_m": 170.0 * IN, "track_m": 1.73, "front_overhang_m": 1.0,
		"tyre_d_m": 0.72, "tyre_w_m": 0.215, "dually": true, "rear_axles": 1,
		"frame_h_m": 0.62, "hood_len_m": 0.95, "cab_len_m": 2.3, "cab_h_m": 2.0,
		"cab_w_m": 2.02, "curb_kg": 2500.0, "gvwr_kg": 11030.0 * LB,
		"gawr_f_kg": 4080.0 * LB, "gawr_r_kg": 7720.0 * LB, "tow_kg": 5000.0 * LB, "gcwr_kg": 15250.0 * LB,
		"fuel": "diesel", "tank_l": 24.5 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 40.0, "top_speed_mps": 36.0, "mpg": [10.0, 15.0],
	},
	"ford_etransit": {
		"label": "Ford E-Transit high roof (electric, 89 kWh)", "cab": "full_van",
		"wheelbase_m": 148.0 * IN, "track_m": 1.71, "front_overhang_m": 0.98, "rear_overhang_m": 1.96,
		"tyre_d_m": 0.71, "tyre_w_m": 0.235, "dually": false, "rear_axles": 1,
		"frame_h_m": 0.62, "hood_len_m": 0.95, "cab_len_m": 2.6, "cab_h_m": 2.0,
		"cab_w_m": 2.07, "curb_kg": 2950.0, "gvwr_kg": 9500.0 * LB,
		"gawr_f_kg": 4130.0 * LB, "gawr_r_kg": 5500.0 * LB, "tow_kg": 0.0, "gcwr_kg": 9500.0 * LB,
		"roof_kg": 300.0, "shell_h_m": 2.78, "cg_wb": 0.52,
		"fuel": "electric", "tank_l": 0.0, "battery_kwh": 89.0,
		"max_steer_deg": 40.0, "top_speed_mps": 36.0, "mpg": [],
	},
	"ford_f59_stripped": {
		"label": "Ford F-59 stripped chassis (step van)", "cab": "forward",
		"wheelbase_m": 178.0 * IN, "track_m": 1.88, "front_overhang_m": 0.85,
		"tyre_d_m": 0.86, "tyre_w_m": 0.245, "dually": true, "rear_axles": 1,
		"frame_h_m": 0.85, "hood_len_m": 0.0, "cab_len_m": 1.6, "cab_h_m": 2.9,
		"cab_w_m": 2.3, "curb_kg": 2900.0, "gvwr_kg": 22000.0 * LB,
		"gawr_f_kg": 7000.0 * LB, "gawr_r_kg": 15000.0 * LB, "tow_kg": 5000.0 * LB, "gcwr_kg": 30000.0 * LB,
		"fuel": "gasoline", "tank_l": 60.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 40.0, "top_speed_mps": 30.0, "mpg": [7.0, 10.5],
	},
	"ford_f53_class_a": {
		"label": "Ford F-53 motorhome chassis (Class A, 232\" WB)", "cab": "forward",
		"wheelbase_m": 232.0 * IN, "track_m": 2.0, "front_overhang_m": 0.95,
		"tyre_d_m": 0.95, "tyre_w_m": 0.25, "dually": true, "rear_axles": 1,
		"frame_h_m": 0.95, "hood_len_m": 0.0, "cab_len_m": 1.4, "cab_h_m": 3.3,
		"cab_w_m": 2.54, "curb_kg": 3350.0, "gvwr_kg": 24000.0 * LB,
		"gawr_f_kg": 8000.0 * LB, "gawr_r_kg": 17000.0 * LB, "tow_kg": 5000.0 * LB, "gcwr_kg": 30000.0 * LB,
		"fuel": "gasoline", "tank_l": 80.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 45.0, "top_speed_mps": 33.0, "mpg": [6.0, 10.0],
	},
	"intl_3800": {
		"label": "International 3800 school bus (diesel, 35 ft)", "cab": "cowl",
		"wheelbase_m": 276.0 * IN, "track_m": 2.0, "front_overhang_m": 1.0,
		"tyre_d_m": 1.0, "tyre_w_m": 0.25, "dually": true, "rear_axles": 1,
		"frame_h_m": 1.0, "hood_len_m": 1.6, "cab_len_m": 2.2, "cab_h_m": 3.0,
		"cab_w_m": 2.44, "curb_kg": 8400.0, "gvwr_kg": 29000.0 * LB,
		"gawr_f_kg": 10000.0 * LB, "gawr_r_kg": 19000.0 * LB, "tow_kg": 10000.0 * LB, "gcwr_kg": 40000.0 * LB,
		"cg_wb": 0.57,
		"fuel": "diesel", "tank_l": 60.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 45.0, "top_speed_mps": 29.0, "mpg": [6.0, 10.0],
	},
	"intl_ce_short": {
		"label": "IC CE school bus, short (diesel, 25 ft)", "cab": "cowl",
		"wheelbase_m": 189.0 * IN, "body_len_m": 7.0, "track_m": 2.0, "front_overhang_m": 1.0,
		"tyre_d_m": 0.98, "tyre_w_m": 0.25, "dually": true, "rear_axles": 1,
		"frame_h_m": 1.0, "hood_len_m": 1.5, "cab_len_m": 2.1, "cab_h_m": 3.0,
		"cab_w_m": 2.44, "curb_kg": 6400.0, "gvwr_kg": 23500.0 * LB,
		"gawr_f_kg": 8000.0 * LB, "gawr_r_kg": 15500.0 * LB, "tow_kg": 10000.0 * LB, "gcwr_kg": 33500.0 * LB,
		"cg_wb": 0.52,
		"fuel": "diesel", "tank_l": 60.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 45.0, "top_speed_mps": 29.0, "mpg": [7.0, 10.0],
	},
	"freightliner_m2": {
		"label": "Freightliner M2 106 box truck (diesel, 212\" WB)", "cab": "cowl",
		"wheelbase_m": 212.0 * IN, "track_m": 2.03, "front_overhang_m": 1.05,
		"tyre_d_m": 1.0, "tyre_w_m": 0.25, "dually": true, "rear_axles": 1,
		"frame_h_m": 1.05, "hood_len_m": 1.45, "cab_len_m": 2.5, "cab_h_m": 2.75,
		"cab_w_m": 2.4, "curb_kg": 4800.0, "gvwr_kg": 26000.0 * LB,
		"gawr_f_kg": 10000.0 * LB, "gawr_r_kg": 19000.0 * LB, "tow_kg": 10000.0 * LB, "gcwr_kg": 35000.0 * LB,
		"fuel": "diesel", "tank_l": 70.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 45.0, "top_speed_mps": 30.0, "mpg": [7.5, 11.0],
	},
	"isuzu_npr": {
		"label": "Isuzu NPR gas (cab-over, 150\" WB)", "cab": "forward",
		"wheelbase_m": 150.0 * IN, "track_m": 1.67, "front_overhang_m": 1.0,
		"tyre_d_m": 0.78, "tyre_w_m": 0.215, "dually": true, "rear_axles": 1,
		"frame_h_m": 0.8, "hood_len_m": 0.0, "cab_len_m": 1.75, "cab_h_m": 2.3,
		"cab_w_m": 2.0, "curb_kg": 2850.0, "gvwr_kg": 14500.0 * LB,
		"gawr_f_kg": 6830.0 * LB, "gawr_r_kg": 9880.0 * LB, "tow_kg": 6000.0 * LB, "gcwr_kg": 20500.0 * LB,
		"cg_wb": 0.35,
		"fuel": "gasoline", "tank_l": 30.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 45.0, "top_speed_mps": 31.0, "mpg": [6.5, 10.0],
	},
	"cascadia_day_cab": {
		"label": "Freightliner Cascadia day cab + 40 ft container chassis", "cab": "tractor",
		"wheelbase_m": 180.0 * IN, "track_m": 2.07, "front_overhang_m": 1.1,
		"tyre_d_m": 1.04, "tyre_w_m": 0.28, "dually": true, "rear_axles": 2,
		"frame_h_m": 1.1, "hood_len_m": 1.9, "cab_len_m": 3.2, "cab_h_m": 3.3,
		"cab_w_m": 2.48, "curb_kg": 8400.0 + 3100.0, "gvwr_kg": 36287.0,
		# US bridge-law axle limits: 12,000 lb on the steer, 34,000 lb on each
		# tandem (the tractor's and the chassis'), 80,000 lb gross.
		"gawr_f_kg": 12000.0 * LB, "gawr_r_kg": 68000.0 * LB, "tow_kg": 0.0, "gcwr_kg": 36287.0,
		"fuel": "diesel", "tank_l": 200.0 * GAL, "battery_kwh": 0.0,
		"max_steer_deg": 45.0, "top_speed_mps": 30.0, "mpg": [5.5, 9.0],
	},
	"trailer_tandem": {
		"label": "Tandem-axle trailer (7,000 lb)", "cab": "none",
		"wheelbase_m": 0.0, "track_m": 1.9, "front_overhang_m": 1.2,
		"tyre_d_m": 0.72, "tyre_w_m": 0.205, "dually": false, "rear_axles": 2,
		"frame_h_m": 0.55, "hood_len_m": 0.0, "cab_len_m": 0.0, "cab_h_m": 0.0,
		"cab_w_m": 0.0, "curb_kg": 600.0, "gvwr_kg": 7000.0 * LB,
		"gawr_f_kg": 0.0, "gawr_r_kg": 7000.0 * LB, "tow_kg": 0.0, "gcwr_kg": 0.0, "brakes": true,
		"fuel": "none", "tank_l": 0.0, "battery_kwh": 0.0,
		"max_steer_deg": 0.0, "top_speed_mps": 29.0, "mpg": [],
	},
	"trailer_single": {
		"label": "Single-axle trailer (3,500 lb)", "cab": "none",
		"wheelbase_m": 0.0, "track_m": 1.75, "front_overhang_m": 1.1,
		"tyre_d_m": 0.68, "tyre_w_m": 0.205, "dually": false, "rear_axles": 1,
		"frame_h_m": 0.5, "hood_len_m": 0.0, "cab_len_m": 0.0, "cab_h_m": 0.0,
		"cab_w_m": 0.0, "curb_kg": 350.0, "gvwr_kg": 3500.0 * LB,
		"gawr_f_kg": 0.0, "gawr_r_kg": 3500.0 * LB, "tow_kg": 0.0, "gcwr_kg": 0.0, "brakes": false,
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
## `wall_t_m` / `ceiling_t_m` = what the living space loses to the finished
## wall and ceiling: a converted van's ribs + insulation + panelling take
## ~0.12 m a side and 0.15 m of headroom, a bus ~0.08, a dry box's plywood
## liner 0.05. `roof_kg` = the load the roof carries (racks, modules, an AC).
## Shuttle-bus shaping (an E-450 cutaway under a fiberglass body, measured
## off a SketchUp model of an Aerotech-class bus and a 25 ft TriMet one):
## `front_cap` = the fiberglass wedge over the cab, `cap_len_m` how far it
## reaches forward of the box; `end_r_m` = how round the box's vertical
## corners are in plan (the roof edge rounds down over the same radius);
## `skirt_h_m` = the side panels hang down to this height above the ground
## (wheel arches are cut round the tyres), 0 = they stop at the floor;
## `lift_door` = a wheelchair lift's double doors on the curb side: none |
## front (right behind the entry door) | mid | rear (behind the rear axle),
## `lift_door_w_m` their width and `lift_door_at_m` their front edge from
## the living box's front when typed (beats `lift_door`'s position);
## `door_w_m` = the entry door's width (0 = by style).
## The ISO container sits on a GOOSENECK chassis (deck ~1.2 m at the tunnel):
## a high cube on a flat deck would stand over 13' 6".
const BODIES := {
	"van_shell": {
		"label": "Van shell (as built)", "length_m": 0.0, "width_m": 2.03,
		"height_m": 2.75, "floor_h_m": 0.55, "roof": "high_top", "cd": 0.42,
		"wall_kg_m2": 9.0, "windows": "few", "rear_door": "barn", "side_door": "slider",
		"corner_r_m": 0.18, "integral": true, "in_curb": true,
		"wall_t_m": 0.12, "ceiling_t_m": 0.15, "roof_kg": 300.0,
		"color": [0.92, 0.93, 0.94],
	},
	"shuttle_aerotech": {
		"label": "Fiberglass \"aerotech\" shuttle body", "length_m": 5.6, "width_m": 2.39,
		"height_m": 2.85, "floor_h_m": 0.74, "roof": "crown", "cd": 0.6,
		"wall_kg_m2": 14.0, "windows": "band", "rear_door": "none", "side_door": "bus",
		"corner_r_m": 0.18, "wall_t_m": 0.08, "ceiling_t_m": 0.1, "roof_kg": 250.0,
		"front_cap": true, "cap_len_m": 0.7, "end_r_m": 0.3, "skirt_h_m": 0.33,
		"lift_door": "rear", "lift_door_w_m": 1.15, "door_w_m": 0.85,
		"color": [0.95, 0.95, 0.95],
	},
	"skoolie": {
		"label": "School bus body (Blue Bird / Thomas)", "length_m": 8.4, "width_m": 2.44,
		"height_m": 3.15, "floor_h_m": 1.0, "roof": "arched", "cd": 0.65,
		"wall_kg_m2": 18.0, "windows": "bus", "rear_door": "barn", "side_door": "bus",
		"corner_r_m": 0.12, "integral": true, "in_curb": true,
		"wall_t_m": 0.08, "ceiling_t_m": 0.12, "roof_kg": 500.0,
		"color": [0.98, 0.72, 0.06],
	},
	"step_van_alu": {
		"label": "Aluminium step van body (P1000)", "length_m": 6.6, "width_m": 2.3,
		"height_m": 3.15, "floor_h_m": 0.75, "roof": "flat", "cd": 0.72,
		"wall_kg_m2": 12.0, "windows": "none", "rear_door": "roll_up", "side_door": "sliding_step",
		"corner_r_m": 0.08, "integral": true,
		"wall_t_m": 0.06, "ceiling_t_m": 0.08, "roof_kg": 300.0,
		"color": [0.9, 0.9, 0.88],
	},
	"ambulance_type3": {
		"label": "Ambulance module (Type III)", "length_m": 4.0, "width_m": 2.36,
		"height_m": 2.95, "floor_h_m": 0.82, "roof": "flat", "cd": 0.66,
		"wall_kg_m2": 16.0, "windows": "few", "rear_door": "barn", "side_door": "hinged",
		"corner_r_m": 0.06, "wall_t_m": 0.06, "ceiling_t_m": 0.08, "roof_kg": 250.0,
		"color": [0.97, 0.97, 0.97],
	},
	"class_c_rv": {
		"label": "Class C RV body (cab-over)", "length_m": 5.4, "width_m": 2.44,
		"height_m": 3.4, "floor_h_m": 0.9, "roof": "cabover", "cd": 0.62,
		"wall_kg_m2": 13.0, "windows": "few", "rear_door": "none", "side_door": "hinged",
		"corner_r_m": 0.18, "wall_t_m": 0.06, "ceiling_t_m": 0.08, "roof_kg": 150.0,
		"color": [0.94, 0.93, 0.9],
	},
	"class_a_motorhome": {
		"label": "Class A motorhome body", "length_m": 9.6, "width_m": 2.54,
		"height_m": 3.75, "floor_h_m": 1.0, "roof": "crown", "cd": 0.58,
		"wall_kg_m2": 20.0, "windows": "few", "rear_door": "none", "side_door": "hinged",
		"corner_r_m": 0.25, "integral": true,
		"wall_t_m": 0.08, "ceiling_t_m": 0.1, "roof_kg": 250.0,
		"color": [0.9, 0.88, 0.84],
	},
	"dry_box_16": {
		"label": "Dry van box (16 ft)", "length_m": 4.88, "width_m": 2.44,
		"height_m": 3.35, "floor_h_m": 1.05, "roof": "flat", "cd": 0.72,
		"wall_kg_m2": 11.0, "windows": "none", "rear_door": "roll_up", "side_door": "none",
		"corner_r_m": 0.03, "wall_t_m": 0.05, "ceiling_t_m": 0.06, "roof_kg": 300.0,
		"color": [0.96, 0.96, 0.96],
	},
	"travel_trailer": {
		"label": "Travel trailer (fiberglass, 20 ft)", "length_m": 6.1, "width_m": 2.4,
		"height_m": 3.1, "floor_h_m": 0.7, "roof": "crown", "cd": 0.55,
		"wall_kg_m2": 11.0, "windows": "few", "rear_door": "none", "side_door": "hinged",
		"corner_r_m": 0.35, "wall_t_m": 0.06, "ceiling_t_m": 0.08, "roof_kg": 150.0,
		"color": [0.95, 0.95, 0.93],
	},
	"cargo_trailer": {
		"label": "Enclosed cargo trailer (V-nose, 16 ft)", "length_m": 4.9, "width_m": 7.0 * 12.0 * IN,
		"height_m": 2.85, "floor_h_m": 0.55, "roof": "crown", "cd": 0.6,
		"wall_kg_m2": 9.0, "windows": "none", "rear_door": "lift", "side_door": "hinged",
		"corner_r_m": 0.1, "wall_t_m": 0.05, "ceiling_t_m": 0.06, "roof_kg": 150.0,
		"color": [0.1, 0.1, 0.11],
	},
	"iso_40hc": {
		"label": "ISO 40 ft high-cube container", "length_m": 12.19, "width_m": 2.44,
		"height_m": 4.1, "floor_h_m": 1.35, "roof": "flat", "cd": 0.62,
		"wall_kg_m2": 50.0, "windows": "few", "rear_door": "barn", "side_door": "hinged",
		"corner_r_m": 0.0, "mass_kg": 3900.0, "wall_t_m": 0.1, "ceiling_t_m": 0.1, "roof_kg": 1000.0,
		"color": [0.55, 0.16, 0.12],
	},
}

## The eleven vehicle types: their default chassis + body and the bodies /
## chassis that fit them (the designer offers these first, any combination
## of a compatible cab is allowed). A chassis is listed only where the
## solved vehicle is a real one: vehiclelab_selftest holds every listed
## combination to a rear overhang of 0.6 m to two thirds of the wheelbase
## and the box behind the cab. The Freightliner M2 ambulance (its 212" WB
## puts the rear axle at the back wall of a 4 m module) and a Class C box on
## the Sprinter VAN shell failed it and were dropped; the Class C is offered
## on the Sprinter CAB CHASSIS instead, which is what it is built on.
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
		"chassis_ok": ["ford_e450_drw", "chevy_express_3500"]},
	"rv": {"label": "RV (Class C)", "chassis": "ford_e450_drw", "body": "class_c_rv",
		"chassis_ok": ["ford_e450_drw", "chevy_express_3500", "sprinter_cab_chassis"]},
	"motorhome": {"label": "Motorhome (Class A)", "chassis": "ford_f53_class_a", "body": "class_a_motorhome",
		"chassis_ok": ["ford_f53_class_a"]},
	"box_truck": {"label": "Box truck", "chassis": "isuzu_npr", "body": "dry_box_16",
		"chassis_ok": ["isuzu_npr", "freightliner_m2", "ford_e450_drw"]},
	# (A 20 ft travel trailer weighs more than a 3,500 lb single axle carries,
	# so that chassis is offered as "other" — pick it under a cargo box.)
	"trailer": {"label": "Trailer (travel / cargo)", "chassis": "trailer_tandem", "body": "travel_trailer",
		"chassis_ok": ["trailer_tandem"]},
	"semi_container": {"label": "Semi truck with container", "chassis": "cascadia_day_cab", "body": "iso_40hc",
		"chassis_ok": ["cascadia_day_cab"]},
}

const TYPE_ORDER := ["van", "cargo_van", "shuttle_bus", "school_bus", "step_van", "ambulance",
	"rv", "motorhome", "box_truck", "trailer", "semi_container"]


## Interior element types: their default size (w across, l along, h = the
## TOP above the inside floor), what they provide and their mass. A bed
## sleeps floor(w / BED_SLEEPER_W) people (1–2) along its own long axis.
## `load_w` is a load's average draw (a 12 V compressor fridge ~45 W over a
## day, an LED ceiling light ~8 W, a 24" monitor ~25 W — typical nameplate
## figures, estimates): the vehicle's graph node bills them.
## A battery's mass and box follow its kWh (LiFePO4 ~12 kg/kWh and
## ~0.018 m³/kWh with the case — a 100 Ah 12.8 V drop-in is ~13 kg), a tank's
## shell its litres (a rotomoulded tank ~0.065 kg/L of capacity), scaled from
## the type's default size (VehicleDesign.resolve_interior_element); the
## water itself is counted when the vehicle is laden. A propane element is
## bottles of `lb` of gas (a 20 lb bottle: 8 kg tare + 9 kg of propane).
const BED_SLEEPER_W := 0.62
const BATTERY_KG_PER_KWH := 12.0
const BATTERY_M3_PER_KWH := 0.018
const TANK_KG_PER_L := 0.065
const PROPANE_TARE_KG_PER_LB := 0.4
const PROPANE_KG_PER_LB := 0.4536
## What the water and fuel weigh (kg/L): water 1.0, gasoline 0.74, diesel
## 0.84 (US DOE AFDC fuel properties).
const FUEL_KG_L := {"gasoline": 0.74, "diesel": 0.84}
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
		"provides": [], "color": [0.86, 0.87, 0.88], "load_w": 45.0},
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
	"inverter": {"label": "Inverter / charger (2 kW)", "w": 0.3, "l": 0.45, "h": 0.25, "mass_kg": 15.0,
		"provides": ["inverter"], "color": [0.2, 0.35, 0.55], "wall_hung": 1.2, "supply_w": 2000.0},
	"water_tank": {"label": "Fresh water tank", "w": 0.45, "l": 0.8, "h": 0.4, "mass_kg": 8.0,
		"provides": ["water"], "color": [0.85, 0.88, 0.9], "litres": 120.0},
	"grey_tank": {"label": "Grey water tank", "w": 0.45, "l": 0.7, "h": 0.35, "mass_kg": 7.0,
		"provides": ["grey"], "color": [0.45, 0.47, 0.5], "litres": 90.0},
	"black_tank": {"label": "Black / cassette tank", "w": 0.45, "l": 0.6, "h": 0.3, "mass_kg": 6.0,
		"provides": ["black"], "color": [0.3, 0.3, 0.32], "litres": 60.0},
	"propane": {"label": "Propane bottles (2 × 20 lb)", "w": 0.32, "l": 0.64, "h": 0.5, "mass_kg": 34.0,
		"provides": ["propane"], "color": [0.9, 0.9, 0.88], "lb": 40.0},
	"heater": {"label": "Air heater (diesel / propane)", "w": 0.15, "l": 0.35, "h": 0.15, "mass_kg": 3.0,
		"provides": ["heat"], "color": [0.2, 0.2, 0.22], "load_w": 25.0},
	"water_heater": {"label": "Water heater (propane)", "w": 0.35, "l": 0.35, "h": 0.5, "mass_kg": 12.0,
		"provides": ["hot_water"], "color": [0.88, 0.88, 0.86]},
	"shore_inlet": {"label": "Shore-power inlet (15 A)", "w": 0.1, "l": 0.12, "h": 0.15, "mass_kg": 1.0,
		"provides": ["shore"], "color": [0.2, 0.22, 0.25], "wall_hung": 0.5, "supply_w": 1800.0},
	"light": {"label": "Ceiling light", "w": 0.2, "l": 0.2, "h": 0.03, "mass_kg": 0.3,
		"provides": [], "color": [1.0, 0.96, 0.85], "ceiling": true, "load_w": 8.0},
	"monitor": {"label": "Monitor", "w": 0.06, "l": 0.6, "h": 0.35, "mass_kg": 4.0,
		"provides": [], "color": [0.08, 0.08, 0.09], "wall_hung": 1.2, "load_w": 25.0},
	"mirror": {"label": "Mirror", "w": 0.02, "l": 0.4, "h": 0.6, "mass_kg": 2.0,
		"provides": [], "color": [0.75, 0.8, 0.85], "wall_hung": 1.1},
}


## The factory wheelbases a chassis is sold in (inches, from the makers'
## order guides): the designer offers these, never a free number. A chassis
## not listed is built in one wheelbase, its own `wheelbase_m`.
##   E-450 cutaway 138 / 158 / 176; Express 3500 cutaway 139 / 159 / 177;
##   ProMaster 3500 high roof 136 / 159; Sprinter 144 / 170 (van and cab
##   chassis); Isuzu NPR 132 / 150 / 176.
const WHEELBASES_IN := {
	"ford_e450_drw": [138.0, 158.0, 176.0],
	"chevy_express_3500": [139.0, 159.0, 177.0],
	"ram_promaster_3500": [136.0, 159.0],
	"sprinter_170": [144.0, 170.0],
	"sprinter_cab_chassis": [144.0, 170.0],
	"isuzu_npr": [132.0, 150.0, 176.0],
}


## The wheelbases (m) a chassis is offered in, its own first when it is not
## a factory one.
static func wheelbases_m(id: String) -> Array:
	var own := float(chassis(id).get("wheelbase_m", 0.0))
	var out: Array = []
	for wi in WHEELBASES_IN.get(id, []):
		out.append(float(wi) * IN)
	var has_own := false
	for w in out:
		if absf(float(w) - own) < 0.005:
			has_own = true
	if not has_own and own > 0.0:
		out.push_front(own)
	return out


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
