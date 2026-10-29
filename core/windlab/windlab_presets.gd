class_name WindLabPresets
extends RefCounted

## Built-in wind turbines and the player's library (user://windlab_library.json).

const LIBRARY_PATH := "user://windlab_library.json"
const IN := 25.4


static func builtins() -> Array:
	return [
		{"id": "lawn_sign", "label": "Lawn-sign Ugrinsky (18 × 24 in correx, NEMA 17)",
			"blurb": "Two S-blades and two 8 in hub discs cut and scored from ONE 18 × 24 in corrugated plastic sign; the discs clamp a NEMA 17's face, its shaft sits in a coupler on a 24 in rod, and the motor's body turns with the rotor.",
			"spec": lawn_sign_spec()},
		{"id": "ugrinsky_1m", "label": "Ugrinsky 0.6 × 1.2 m (correx sheet, belt to a NEMA 23)",
			"blurb": "The published optimum (S = 0.35 D, L = 1.0 R) scaled up from a 4 × 8 ft corrugated sheet, end plates with tabs, its own shaft and bearings, a GT2 belt up to a NEMA 23 stepper.",
			"spec": ugrinsky_1m_spec()},
		{"id": "oil_drum", "label": "Savonius from a 200 L drum",
			"blurb": "Two half-drums with 15 % overlap in two stages a quarter turn apart, belted up to a 400 W wind PMA.",
			"spec": oil_drum_spec()},
		{"id": "lenz2", "label": "Lenz2, 1.3 m (three aluminium wings)",
			"blurb": "Ed Lenz's lift + drag wings, 30 % chord at 15°, on a 1.3 m rotor 1.2 m tall, belted to a 400 W PMA.",
			"spec": lenz2_spec()},
		{"id": "darrieus_h", "label": "Darrieus H-rotor, 1.2 m (printed blades)",
			"blurb": "Three NACA 0018 blades of 120 mm chord on two sets of arms; it needs a push to start.",
			"spec": darrieus_spec()},
		{"id": "helical", "label": "Helical (Gorlov), 1 × 1.6 m",
			"blurb": "Three printed blades wrapping 120° round, smooth torque, an easier start than a straight Darrieus.",
			"spec": helical_spec()},
		{"id": "hawt_printed", "label": "HAWT 1.2 m, three printed SG6043 blades",
			"blurb": "A blade element design at tip speed ratio 6: twisted, tapered SG6043 blades printed in PETG, on a 400 W PMA's shaft.",
			"spec": hawt_printed_spec()},
		{"id": "hawt_pvc", "label": "HAWT 1.5 m cut from 160 mm PVC pipe",
			"blurb": "Three blades traced from the cut template onto a PVC pipe — the classic low-cost build — on a 400 W PMA, 24 V.",
			"spec": hawt_pvc_spec()},
		{"id": "air30_class", "label": "Small HAWT 1.17 m (Air 30 class)",
			"blurb": "The size of the shipped small HAWT model: three blades at λ 7 on a 24 V PMA, 10 m mast.",
			"spec": air30_spec()},
		{"id": "farm", "label": "Farm windmill 1.8 m (18 plates)",
			"blurb": "A water-pumper's high-solidity rotor of curved galvanised plates, here turning a hub motor through an MPPT into 48 V.",
			"spec": farm_spec()},
	]


## The lawn-sign build, measured off its model: blades Ø 181 mm tip to tip,
## 455 mm tall (a sign's 18 in less the kerf), semicircle S = 0.36 D, tail
## arc L = 0.84 R swept 72°; two 8 in hub discs 2 in apart round the motor;
## a 40 mm NEMA 17; a 24 in rod mast. The sign is 24 in wide: two ~7.8 in
## blade strips and an 8 in strip for the two discs.
static func lawn_sign_spec() -> Dictionary:
	return WindLabSpec.resolve({
		"name": "Lawn-sign Ugrinsky",
		"type": "ugrinsky",
		"rotor": {"d_mm": 181.2, "h_mm": 455.5, "blades": 2, "s_ratio": 0.36, "l_ratio": 0.84, "sweep_deg": 72.0,
			"hub": {"style": "mid_discs", "count": 2, "spacing_mm": 2.0 * IN, "overhang": 8.0 * IN / 181.2}},
		"build": {"sheet": "correx_4", "sheet_size": "sign_18x24", "score_tol_mm": 1.0, "slot_clear_mm": 0.3,
			"tabs": false, "kerf_mm": 1.0, "margin_mm": 0.0},
		"mount": {"style": "body_spins", "mast": "rod_8", "mast_h_mm": 24.0 * IN, "guyed": false},
		"drive": {"type": "direct"},
		"generator": {"id": "nema17_40"},
		"load": {"type": "mppt", "battery_v": 3.7, "mppt_min_v": 2.0, "mppt_eff": 0.85},
		"site": {"mean_wind_ms": 4.5, "design_wind_ms": 6.0, "survival_ms": 12.0},
		"colors": {"blade": [0.95, 0.95, 0.93, 1.0], "hub": [0.86, 0.86, 0.84, 1.0]},
	})


static func ugrinsky_1m_spec() -> Dictionary:
	return WindLabSpec.resolve({
		"name": "Ugrinsky 0.6 x 1.2 m",
		"type": "ugrinsky",
		"rotor": {"d_mm": 600.0, "h_mm": 1200.0, "blades": 2, "s_ratio": 0.35, "l_ratio": 1.0, "sweep_deg": 69.0,
			"hub": {"style": "end_plates", "overhang": 1.08}},
		"build": {"sheet": "correx_4", "sheet_size": "sheet_4x8", "tabs": true},
		"mount": {"style": "bearings", "mast": "pipe_48", "mast_h_mm": 2500.0, "shaft_d_mm": 12.0},
		"drive": {"type": "gt2", "driver_teeth": 80, "driven_teeth": 20},
		"generator": {"id": "nema23_76"},
		"load": {"type": "battery", "battery_v": 12.0},
	})


static func oil_drum_spec() -> Dictionary:
	return WindLabSpec.resolve({
		"name": "Oil-drum Savonius",
		"type": "savonius",
		"rotor": {"d_mm": 1060.0, "h_mm": 1760.0, "blades": 2, "overlap": 0.15, "stages": 2,
			"hub": {"style": "end_plates", "overhang": 1.06}},
		"build": {"sheet": "galv_0_6", "sheet_size": "sheet_4x8", "tabs": true},
		"mount": {"style": "bearings", "mast": "pipe_60", "mast_h_mm": 2500.0, "shaft_d_mm": 25.0},
		"drive": {"type": "htd5", "driver_teeth": 120, "driven_teeth": 20},
		"generator": {"id": "pma400"},
		"load": {"type": "battery", "battery_v": 12.0},
		"colors": {"blade": [0.62, 0.64, 0.66, 1.0]},
	})


static func lenz2_spec() -> Dictionary:
	return WindLabSpec.resolve({
		"name": "Lenz2 1.3 m",
		"type": "lenz2",
		"rotor": {"d_mm": 1300.0, "h_mm": 1200.0, "blades": 3, "chord_frac": 0.30, "camber_frac": 0.14, "set_deg": 15.0,
			"hub": {"style": "spokes"}},
		"build": {"sheet": "alu_1", "sheet_size": "sheet_4x8", "tabs": true},
		"mount": {"style": "bearings", "mast": "pipe_60", "mast_h_mm": 3000.0, "shaft_d_mm": 20.0},
		"drive": {"type": "htd5", "driver_teeth": 100, "driven_teeth": 20},
		"generator": {"id": "pma400"},
		"load": {"type": "battery", "battery_v": 12.0},
		"colors": {"blade": [0.8, 0.81, 0.83, 1.0]},
	})


static func darrieus_spec() -> Dictionary:
	return WindLabSpec.resolve({
		"name": "Darrieus H 1.2 m",
		"type": "darrieus_h",
		"rotor": {"d_mm": 1200.0, "h_mm": 1500.0, "blades": 3, "chord_mm": 120.0, "airfoil": "naca0018", "arms": 2,
			"start_assist": true, "hub": {"style": "spokes"}},
		"build": {"sheet": "alu_1", "sheet_size": "sheet_4x8", "solid": "petg", "print_max_mm": 250.0},
		"mount": {"style": "bearings", "mast": "pipe_60", "mast_h_mm": 3000.0, "shaft_d_mm": 20.0},
		"drive": {"type": "gt2", "driver_teeth": 60, "driven_teeth": 20},
		"generator": {"id": "pma400"},
		"load": {"type": "battery", "battery_v": 24.0},
		"colors": {"blade": [0.92, 0.92, 0.95, 1.0]},
	})


static func helical_spec() -> Dictionary:
	return WindLabSpec.resolve({
		"name": "Helical 1 x 1.6 m",
		"type": "helical",
		"rotor": {"d_mm": 1000.0, "h_mm": 1600.0, "blades": 3, "chord_mm": 110.0, "airfoil": "naca0018",
			"helix_deg": 120.0, "arms": 2, "hub": {"style": "spokes"}},
		"build": {"sheet": "alu_1", "sheet_size": "sheet_4x8", "solid": "asa", "print_max_mm": 250.0},
		"mount": {"style": "bearings", "mast": "pipe_60", "mast_h_mm": 3000.0, "shaft_d_mm": 20.0},
		"drive": {"type": "gt2", "driver_teeth": 72, "driven_teeth": 20},
		"generator": {"id": "pma400"},
		"load": {"type": "battery", "battery_v": 24.0},
		"colors": {"blade": [0.2, 0.45, 0.7, 1.0]},
	})


static func hawt_printed_spec() -> Dictionary:
	return WindLabSpec.resolve({
		"name": "HAWT 1.2 m printed",
		"type": "hawt",
		"rotor": {"d_mm": 1200.0, "blades": 3, "tsr": 6.0, "airfoil": "sg6043", "hub_frac": 0.12, "construction": "printed"},
		"build": {"sheet": "ply_12", "sheet_size": "sheet_4x8", "solid": "petg", "print_max_mm": 250.0},
		"mount": {"style": "on_shaft", "mast": "pipe_48", "mast_h_mm": 6000.0},
		"generator": {"id": "pma400"},
		"load": {"type": "battery", "battery_v": 24.0},
		"site": {"mean_wind_ms": 5.0},
	})


static func hawt_pvc_spec() -> Dictionary:
	return WindLabSpec.resolve({
		"name": "HAWT 1.5 m PVC",
		"type": "hawt",
		"rotor": {"d_mm": 1500.0, "blades": 3, "tsr": 5.0, "hub_frac": 0.14, "construction": "pvc_pipe", "pipe_d_mm": 160.0},
		"build": {"sheet": "ply_12", "sheet_size": "sheet_4x8"},
		"mount": {"style": "on_shaft", "mast": "pipe_48", "mast_h_mm": 6000.0},
		"generator": {"id": "pma400"},
		"load": {"type": "battery", "battery_v": 24.0},
		"colors": {"blade": [0.85, 0.85, 0.82, 1.0]},
	})


static func air30_spec() -> Dictionary:
	return WindLabSpec.resolve({
		"name": "Small HAWT 1.17 m",
		"type": "hawt",
		"rotor": {"d_mm": 1170.0, "blades": 3, "tsr": 7.0, "airfoil": "sg6043", "hub_frac": 0.1, "construction": "printed"},
		"build": {"solid": "nylon_cf"},
		"mount": {"style": "on_shaft", "mast": "pipe_60", "mast_h_mm": 10000.0},
		"generator": {"id": "pma400"},
		"load": {"type": "battery", "battery_v": 24.0},
		"site": {"mean_wind_ms": 5.0},
		"colors": {"blade": [0.15, 0.16, 0.18, 1.0]},
	})


static func farm_spec() -> Dictionary:
	return WindLabSpec.resolve({
		"name": "Farm windmill 1.8 m",
		"type": "multiblade",
		"rotor": {"d_mm": 1800.0, "blades": 18, "hub_frac": 0.22},
		"build": {"sheet": "galv_0_6", "sheet_size": "sheet_4x8"},
		"mount": {"style": "on_shaft", "mast": "pipe_60", "mast_h_mm": 6000.0},
		"generator": {"id": "hub500"},
		"load": {"type": "mppt", "battery_v": 48.0, "mppt_min_v": 10.0},
		"colors": {"blade": [0.62, 0.64, 0.66, 1.0]},
	})


static func by_id(id: String) -> Dictionary:
	for b in builtins():
		if str(b["id"]) == id:
			return (b["spec"] as Dictionary).duplicate(true)
	return {}


static func load_library(path: String = LIBRARY_PATH) -> Array:
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return []
	var out: Array = []
	for e in (parsed as Dictionary).get("designs", []):
		if e is Dictionary and (e as Dictionary).get("spec", null) is Dictionary:
			out.append(e)
	return out


static func save_library(designs: Array, path: String = LIBRARY_PATH) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": 1, "designs": designs}, "  "))
	return true
