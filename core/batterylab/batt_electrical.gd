class_name BattElectrical
extends RefCounted

## Conductor sizing and resistance for battery packs: wire by ampacity,
## busbars and nickel strip by current, resistances by ρL/A.
##
## Sources:
##  - Wire: NEC (NFPA 70) Table 310.16, copper, 75 °C column (conductors in
##    raceway or cable, 30 °C ambient) — the conservative table for a closed
##    battery box. Cross-sections from ASTM B258 (AWG) and the kcmil
##    definition (1 kcmil = 0.5067 mm²).
##  - Busbar ampacity: fitted to DIN 43671 bare copper flat bars (35 °C
##    ambient, 30 K rise): I ≈ 3.88 · √(A · P) with A in mm², P the
##    perimeter in mm (20 × 3 → 204 A, 40 × 5 → ~520 A, 12 × 2 → ~100 A).
##    Aluminium carries 0.78 × (its conductivity ratio to the 1/2 power);
##    inside a closed box × 0.8. An ESTIMATE, not the table.
##  - Nickel strip: ~5 A/mm² is the common pack-builder rule for pure nickel
##    (0.15 × 8 mm ≈ 6 A per strip); ESTIMATE.
##  - Resistivities at 20 °C: copper 1.72e-8, aluminium 2.82e-8, nickel
##    6.99e-8 Ω·m (CRC Handbook).

const RHO := {"copper": 1.72e-8, "aluminium": 2.82e-8, "nickel": 6.99e-8}
const DENSITY_KG_M3 := {"copper": 8960.0, "aluminium": 2700.0, "nickel": 8908.0,
	"steel": 7850.0, "abs": 1050.0}

## [name, mm², amps at 75 °C] from NEC 310.16.
const WIRES: Array = [
	["14 AWG", 2.08, 20.0], ["12 AWG", 3.31, 25.0], ["10 AWG", 5.26, 35.0],
	["8 AWG", 8.37, 50.0], ["6 AWG", 13.3, 65.0], ["4 AWG", 21.2, 85.0],
	["3 AWG", 26.7, 100.0], ["2 AWG", 33.6, 115.0], ["1 AWG", 42.4, 130.0],
	["1/0 AWG", 53.5, 150.0], ["2/0 AWG", 67.4, 175.0], ["3/0 AWG", 85.0, 200.0],
	["4/0 AWG", 107.2, 230.0], ["250 kcmil", 126.7, 255.0], ["300 kcmil", 152.0, 285.0],
	["350 kcmil", 177.3, 310.0], ["500 kcmil", 253.4, 380.0],
]

## Balance leads: 22 AWG silicone, the usual harness wire (0.33 mm²).
const BALANCE_MM2 := 0.33

## Standard flat busbar sizes, [width, thickness] mm.
const BUSBARS: Array = [
	[12.0, 2.0], [15.0, 2.0], [20.0, 2.0], [20.0, 3.0], [25.0, 3.0], [30.0, 3.0],
	[25.0, 5.0], [30.0, 5.0], [40.0, 5.0], [50.0, 5.0], [50.0, 10.0],
]

## Nickel strip: [width, thickness] mm.
const STRIP := [8.0, 0.15]
const NICKEL_A_PER_MM2 := 5.0

## DC breaker frame sizes (A).
const BREAKERS: Array = [32.0, 50.0, 63.0, 80.0, 100.0, 125.0, 150.0, 200.0, 250.0, 300.0, 400.0]


## The smallest wire carrying `amps` (× `derate`); the largest when none does.
static func wire_for(amps: float, derate: float = 1.0) -> Dictionary:
	for w in WIRES:
		if float(w[2]) * derate >= amps:
			return {"name": str(w[0]), "mm2": float(w[1]), "amps": float(w[2]) * derate}
	var last: Array = WIRES[WIRES.size() - 1]
	return {"name": str(last[0]), "mm2": float(last[1]), "amps": float(last[2]) * derate,
		"short": true}


## Wire ampacity of a cross-section (the largest table row not above it).
static func wire_amps(mm2: float) -> float:
	var a := 0.0
	for w in WIRES:
		if float(w[1]) <= mm2 + 1e-6:
			a = float(w[2])
	return a


static func busbar_amps(w_mm: float, t_mm: float, material: String = "copper",
		enclosed: bool = true) -> float:
	if w_mm <= 0.0 or t_mm <= 0.0:
		return 0.0
	var a := w_mm * t_mm
	var p := 2.0 * (w_mm + t_mm)
	var amps := 3.88 * sqrt(a * p)
	if material == "aluminium":
		amps *= 0.78
	elif material == "nickel":
		return a * NICKEL_A_PER_MM2
	return amps * (0.8 if enclosed else 1.0)


## The smallest standard busbar (no wider than `max_w`) carrying `amps`.
static func busbar_for(amps: float, material: String = "copper", max_w: float = 1e9) -> Array:
	var best: Array = []
	for b in BUSBARS:
		if float(b[0]) > max_w + 1e-6:
			continue
		best = b
		if busbar_amps(float(b[0]), float(b[1]), material) >= amps:
			return b
	return best if not best.is_empty() else BUSBARS[0]


## Nickel strips stacked to carry `amps` (at least 1).
static func strips_for(amps: float) -> int:
	var per := float(STRIP[0]) * float(STRIP[1]) * NICKEL_A_PER_MM2
	return maxi(1, int(ceilf(amps / per - 1e-9)))


## Resistance (Ω) of `len_mm` of conductor of `area_mm2` cross-section.
static func resistance(material: String, len_mm: float, area_mm2: float) -> float:
	if area_mm2 <= 0.0:
		return 0.0
	return float(RHO.get(material, RHO["copper"])) * (len_mm * 0.001) / (area_mm2 * 1e-6)


## The smallest breaker frame at or above `amps`.
static func breaker_for(amps: float) -> float:
	for b in BREAKERS:
		if float(b) >= amps - 1e-6:
			return float(b)
	return float(BREAKERS[BREAKERS.size() - 1])


## Mass (kg) of a conductor.
static func mass_kg(material: String, len_mm: float, area_mm2: float) -> float:
	return float(DENSITY_KG_M3.get(material, 8960.0)) * len_mm * area_mm2 * 1e-9
