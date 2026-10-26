class_name GantryLabParts
extends RefCounted

## The standardised parts a CNC gantry is built from — the OpenBuilds /
## RepRap vocabulary: V-slot extrusion, V-wheels and linear rails, GT2 belts,
## trapezoidal lead screws and ball screws, NEMA steppers, 32-bit boards,
## hotends, spindles and lasers. Every number carries its source in a comment;
## none is invented. Prices are typical 2025 single-unit USD from the
## OpenBuilds Part Store / common vendors, rounded — a budget, not a quote.
##
## Everything here is DATA. The physics that reads it lives in
## GantryLabKinematics; the geometry in GantryLabFrame.

## Aluminium 6063-T5 (the V-slot alloy): density 2700 kg/m³, E = 68.9 GPa
## (ASM handbook). I = second moment about the profile's centroid; the
## V-slot values are OpenBuilds' published section properties (Ix in cm⁴),
## with the rectangular profiles' strong/weak axes listed separately.
const ALU_E_PA := 68.9e9
const ALU_DENSITY := 2700.0

## key → {label, w_mm, h_mm, kg_m, ix_cm4 (strong), iy_cm4 (weak), usd_m, slots}
const PROFILES := {
	# OpenBuilds V-Slot 20x20: 0.42 kg/m, Ix = Iy ≈ 0.72 cm⁴ (OpenBuilds
	# "V-Slot 20x20 Linear Rail" spec sheet). Slots: one each face.
	"2020": {"label": "V-slot 2020", "w_mm": 20.0, "h_mm": 20.0, "kg_m": 0.42,
		"ix_cm4": 0.72, "iy_cm4": 0.72, "usd_m": 7.0, "slots": 4},
	# V-Slot 20x40: 0.75 kg/m; Ix ≈ 4.0 cm⁴ (about the 40 mm height),
	# Iy ≈ 1.4 cm⁴ (OpenBuilds 20x40 spec sheet). Slots: 2 long + 1 short each side = 6.
	"2040": {"label": "V-slot 2040", "w_mm": 20.0, "h_mm": 40.0, "kg_m": 0.75,
		"ix_cm4": 4.0, "iy_cm4": 1.4, "usd_m": 12.0, "slots": 6},
	# V-Slot 20x60: 1.05 kg/m; Ix ≈ 12.9 cm⁴, Iy ≈ 2.1 cm⁴ (OpenBuilds 20x60).
	"2060": {"label": "V-slot 2060", "w_mm": 20.0, "h_mm": 60.0, "kg_m": 1.05,
		"ix_cm4": 12.9, "iy_cm4": 2.1, "usd_m": 18.0, "slots": 8},
	# V-Slot 40x40: 1.3 kg/m; I ≈ 5.9 cm⁴ each axis (OpenBuilds 40x40).
	"4040": {"label": "V-slot 4040", "w_mm": 40.0, "h_mm": 40.0, "kg_m": 1.3,
		"ix_cm4": 5.9, "iy_cm4": 5.9, "usd_m": 22.0, "slots": 8},
	# OpenBuilds C-Beam 40x80: 2.0 kg/m; Ix ≈ 22 cm⁴ strong, ≈ 7.5 cm⁴ weak
	# (OpenBuilds C-Beam Linear Rail spec). The channel carries a lead screw.
	"c_beam_4080": {"label": "C-Beam 4080", "w_mm": 40.0, "h_mm": 80.0, "kg_m": 2.0,
		"ix_cm4": 22.0, "iy_cm4": 7.5, "usd_m": 36.0, "slots": 10},
	# 30x30 B-type (Misumi HFS6-3030): 0.96 kg/m, I ≈ 2.9 cm⁴ — the Voron frame.
	"3030": {"label": "T-slot 3030", "w_mm": 30.0, "h_mm": 30.0, "kg_m": 0.96,
		"ix_cm4": 2.9, "iy_cm4": 2.9, "usd_m": 14.0, "slots": 4},
}
const PROFILE_ORDER := ["2020", "2040", "2060", "4040", "c_beam_4080", "3030"]

## Linear guides. kg_m is the moving part's mass per metre of travel it adds
## to the frame (rail + blocks amortised), load_n the rated load per carriage,
## play_mm the achievable backlash. usd_m = cost per metre including blocks.
const GUIDES := {
	# OpenBuilds Xtreme solid V-wheel on 2040: 3-wheel mini gantry plate
	# ≈ 0.25 kg, Delrin wheels; the slot IS the rail (no extra rail mass).
	"v_wheel": {"label": "V-wheels on the slot", "kg_m": 0.0, "kg_carriage": 0.25,
		"load_n": 300.0, "play_mm": 0.05, "usd_m": 0.0, "usd_carriage": 28.0,
		"note": "Delrin wheels ride the V-slot itself: cheap, quiet, 0.05 mm of play when the eccentric nuts are set, wears in dust."},
	# Hiwin MGN12H: rail 0.65 kg/m, block 0.034 kg, C = 7.8 kN dynamic (Hiwin MG catalogue).
	"mgn12": {"label": "MGN12 linear rail", "kg_m": 0.65, "kg_carriage": 0.07,
		"load_n": 2000.0, "play_mm": 0.005, "usd_m": 45.0, "usd_carriage": 10.0,
		"note": "Recirculating-ball rail on the extrusion face: stiff, no play, needs a straight face and grease."},
	# Hiwin MGN9H: rail 0.38 kg/m, block 0.015 kg.
	"mgn9": {"label": "MGN9 linear rail", "kg_m": 0.38, "kg_carriage": 0.04,
		"load_n": 1200.0, "play_mm": 0.005, "usd_m": 32.0, "usd_carriage": 8.0,
		"note": "The light rail of the Voron toolhead: fine for a hotend, too light for a router."},
	# 8 mm smooth rod + LM8UU: rod 0.39 kg/m, bearing 0.015 kg.
	"rod_8": {"label": "8 mm rod + LM8UU", "kg_m": 0.78, "kg_carriage": 0.08,
		"load_n": 400.0, "play_mm": 0.02, "usd_m": 14.0, "usd_carriage": 4.0,
		"note": "The Prusa i3 guide: two rods and linear bearings; sags past ~400 mm."},
	# Hiwin HGR15: rail 1.45 kg/m, block 0.19 kg, C = 11 kN.
	"hgr15": {"label": "HGR15 linear rail", "kg_m": 1.45, "kg_carriage": 0.25,
		"load_n": 5000.0, "play_mm": 0.003, "usd_m": 60.0, "usd_carriage": 18.0,
		"note": "Router-class rail: takes cutting forces without chatter."},
}
const GUIDE_ORDER := ["v_wheel", "mgn9", "mgn12", "rod_8", "hgr15"]

## Drives. Belt pitch / width from the GT2 standard (Gates PowerGrip GT2);
## belt stiffness from Gates: GT2 6 mm ≈ 5.6 N per 1 % strain per cm width…
## expressed here as spring rate per metre of belt. Lead screws: Tr8 trapezoidal,
## lead = starts × pitch. Ball screws SFU1605 / SFU1610 (16 mm, lead 5 / 10).
## eff = drive efficiency (Tr8 brass nut ~0.3–0.4; ball screw ~0.9; belt ~0.95).
const DRIVES := {
	"belt_gt2_6": {"label": "GT2 belt, 6 mm", "kind": "belt", "pitch_mm": 2.0, "width_mm": 6.0,
		"kg_m": 0.011, "usd_m": 2.5, "eff": 0.95, "k_n_per_m_at_1m": 11000.0, "max_n": 60.0,
		"note": "The 3D-printer belt. Fast, quiet, ~0.1 mm of stretch per metre under a 100 g toolhead's acceleration."},
	"belt_gt2_9": {"label": "GT2 belt, 9 mm", "kind": "belt", "pitch_mm": 2.0, "width_mm": 9.0,
		"kg_m": 0.016, "usd_m": 3.5, "eff": 0.95, "k_n_per_m_at_1m": 16500.0, "max_n": 90.0,
		"note": "Half again as stiff as 6 mm; what a 350 mm CoreXY wants."},
	"belt_gt3_15": {"label": "GT3 belt, 15 mm", "kind": "belt", "pitch_mm": 3.0, "width_mm": 15.0,
		"kg_m": 0.03, "usd_m": 6.0, "eff": 0.95, "k_n_per_m_at_1m": 40000.0, "max_n": 250.0,
		"note": "Router / laser gantry belt: takes a spindle's cutting force."},
	"leadscrew_t8_8": {"label": "Tr8 lead screw, 8 mm lead", "kind": "screw", "lead_mm": 8.0, "d_mm": 8.0,
		"root_mm": 6.2, "kg_m": 0.32, "usd_m": 9.0, "eff": 0.40, "max_n": 400.0,
		"note": "4-start Tr8×8: the common Z screw. Back-drives, so a heavy bed sinks when the motors are off."},
	"leadscrew_t8_2": {"label": "Tr8 lead screw, 2 mm lead", "kind": "screw", "lead_mm": 2.0, "d_mm": 8.0,
		"root_mm": 6.2, "kg_m": 0.32, "usd_m": 9.0, "eff": 0.30, "max_n": 500.0,
		"note": "Single-start: four times the force and resolution, a quarter of the speed. Self-locking."},
	"leadscrew_t12_3": {"label": "Tr12 lead screw, 3 mm lead", "kind": "screw", "lead_mm": 3.0, "d_mm": 12.0,
		"root_mm": 9.8, "kg_m": 0.75, "usd_m": 14.0, "eff": 0.35, "max_n": 1200.0,
		"note": "Stiffer screw for a long Z or a router axis; still a friction nut."},
	"ballscrew_1605": {"label": "SFU1605 ball screw", "kind": "screw", "lead_mm": 5.0, "d_mm": 16.0,
		"root_mm": 12.7, "kg_m": 1.35, "usd_m": 45.0, "eff": 0.90, "max_n": 3000.0,
		"note": "Recirculating balls: 90 % efficient, no backlash with a preloaded nut, the router's axis drive."},
	"ballscrew_1610": {"label": "SFU1610 ball screw", "kind": "screw", "lead_mm": 10.0, "d_mm": 16.0,
		"root_mm": 12.7, "kg_m": 1.35, "usd_m": 48.0, "eff": 0.90, "max_n": 2500.0,
		"note": "Twice the lead of the 1605: fast rapids, half the force."},
	"rack_pinion": {"label": "Rack and pinion (mod 1)", "kind": "rack", "lead_mm": 62.8, "d_mm": 20.0,
		"kg_m": 1.1, "usd_m": 40.0, "eff": 0.85, "max_n": 1500.0,
		"note": "Mod 1 rack with a 20-tooth pinion: 62.8 mm per turn, any length, needs a geared motor to keep resolution."},
}
const DRIVE_ORDER := ["belt_gt2_6", "belt_gt2_9", "belt_gt3_15", "leadscrew_t8_8", "leadscrew_t8_2",
	"leadscrew_t12_3", "ballscrew_1605", "ballscrew_1610", "rack_pinion"]

## Motors. Holding torque / rated current / mass from typical data sheets
## (StepperOnline 17HS19-2004S1 = 0.59 N·m, 2 A, 0.4 kg; 17HS08-1004S pancake
## 0.16 N·m, 0.15 kg; 23HS30-2804S 1.9 N·m, 1.05 kg; 23HS45-4204S 3.0 N·m,
## 1.2 kg; NEMA 34 86HS156 8.5 N·m, 3.8 kg). All 200 full steps (1.8°).
const MOTORS := {
	"nema17_pancake": {"label": "NEMA 17 pancake (0.16 N·m)", "torque_nm": 0.16, "amps": 1.0,
		"kg": 0.15, "steps": 200, "frame_mm": 42.0, "len_mm": 20.0, "usd": 14.0},
	"nema17": {"label": "NEMA 17 (0.4 N·m)", "torque_nm": 0.40, "amps": 1.5,
		"kg": 0.28, "steps": 200, "frame_mm": 42.0, "len_mm": 40.0, "usd": 12.0},
	"nema17_hi": {"label": "NEMA 17 high-torque (0.59 N·m)", "torque_nm": 0.59, "amps": 2.0,
		"kg": 0.40, "steps": 200, "frame_mm": 42.0, "len_mm": 48.0, "usd": 16.0},
	"nema17_09": {"label": "NEMA 17 0.9° (0.4 N·m)", "torque_nm": 0.40, "amps": 1.5,
		"kg": 0.30, "steps": 400, "frame_mm": 42.0, "len_mm": 40.0, "usd": 18.0},
	"nema23": {"label": "NEMA 23 (1.9 N·m)", "torque_nm": 1.9, "amps": 2.8,
		"kg": 1.05, "steps": 200, "frame_mm": 57.0, "len_mm": 76.0, "usd": 24.0},
	"nema23_hi": {"label": "NEMA 23 high-torque (3.0 N·m)", "torque_nm": 3.0, "amps": 4.2,
		"kg": 1.2, "steps": 200, "frame_mm": 57.0, "len_mm": 112.0, "usd": 34.0},
	"nema34": {"label": "NEMA 34 (8.5 N·m)", "torque_nm": 8.5, "amps": 6.0,
		"kg": 3.8, "steps": 200, "frame_mm": 86.0, "len_mm": 118.0, "usd": 70.0},
}
const MOTOR_ORDER := ["nema17_pancake", "nema17", "nema17_hi", "nema17_09", "nema23", "nema23_hi", "nema34"]

## Controller boards. max_step_hz is the sustained step rate per axis the
## firmware reaches on the board's MCU (Marlin on 8-bit AVR ≈ 10 kHz usable
## with multistepping to 40 kHz; 32-bit Marlin ≈ 150–200 kHz; Klipper's MCU
## step queue ≈ 500 kHz+ on an STM32F4 / RP2040; grbl on a 328P 30 kHz;
## grblHAL 300 kHz; Duet 3 / RRF ≈ 300 kHz). drivers = axis slots.
const BOARDS := {
	"ramps_14": {"label": "RAMPS 1.4 (8-bit)", "max_step_hz": 10000.0, "drivers": 5, "usd": 25.0,
		"firmware": ["marlin"], "volts": [12], "mcu": "ATmega2560 16 MHz",
		"note": "The 2011 RepRap board. Fine for a slow Cartesian; a CoreXY at 300 mm/s runs out of steps."},
	"skr_mini_e3": {"label": "BTT SKR Mini E3 V3 (32-bit)", "max_step_hz": 150000.0, "drivers": 4, "usd": 35.0,
		"firmware": ["marlin", "klipper"], "volts": [12, 24], "mcu": "STM32G0B1 64 MHz",
		"note": "Four TMC2209 on board, 24 V, Klipper or Marlin: the default bed-slinger brain."},
	"skr_3": {"label": "BTT SKR 3 EZ (32-bit)", "max_step_hz": 250000.0, "drivers": 5, "usd": 55.0,
		"firmware": ["marlin", "klipper"], "volts": [12, 24], "mcu": "STM32H743 480 MHz",
		"note": "Five driver sockets, a fast MCU: CoreXY with dual Z."},
	"octopus": {"label": "BTT Octopus (32-bit)", "max_step_hz": 400000.0, "drivers": 8, "usd": 60.0,
		"firmware": ["marlin", "klipper"], "volts": [24, 48], "mcu": "STM32F446 180 MHz",
		"note": "Eight drivers: four Z motors, two extruders, and 48 V on the motor rail if you want it."},
	"duet3_mini": {"label": "Duet 3 Mini 5+ (RRF)", "max_step_hz": 300000.0, "drivers": 5, "usd": 150.0,
		"firmware": ["rrf"], "volts": [12, 24], "mcu": "SAME54 120 MHz",
		"note": "RepRapFirmware's web interface and config.g; input shaping and pressure advance built in."},
	"grbl_uno": {"label": "Arduino Uno + grbl shield", "max_step_hz": 30000.0, "drivers": 4, "usd": 20.0,
		"firmware": ["grbl"], "volts": [12, 24], "mcu": "ATmega328P 16 MHz",
		"note": "The classic router / laser brain: $ settings, no SD card, three axes."},
	"blackbox_x32": {"label": "OpenBuilds BlackBox X32 (grblHAL)", "max_step_hz": 300000.0, "drivers": 4, "usd": 190.0,
		"firmware": ["grbl"], "volts": [24], "mcu": "ESP32 240 MHz",
		"note": "OpenBuilds' CNC controller: grblHAL, spindle and laser outputs, sold with the LEAD and WorkBee."},
	"rp2040_klipper": {"label": "Raspberry Pi + RP2040 MCU (Klipper)", "max_step_hz": 500000.0, "drivers": 6, "usd": 90.0,
		"firmware": ["klipper"], "volts": [24, 48], "mcu": "RP2040 133 MHz + Pi host",
		"note": "Klipper: the host computes the moves, the MCU just steps. Input shaping measured with an accelerometer."},
}
const BOARD_ORDER := ["ramps_14", "skr_mini_e3", "skr_3", "octopus", "duet3_mini", "grbl_uno", "blackbox_x32", "rp2040_klipper"]

const FIRMWARE_LABELS := {"marlin": "Marlin", "klipper": "Klipper", "rrf": "RepRapFirmware", "grbl": "grbl / grblHAL"}

## Tools. kg = toolhead mass the X carriage carries; watts = tool draw at
## full load; process = additive / subtractive / mark; feed_mm_s = the
## sensible working feed; nozzle_mm or kerf_mm = line width on the work.
## Material kinds match ResourceKinds (filament / plastic_flake / mud) so the
## graph can bill a feedstock tank; "" = no feedstock (router, laser, pen).
const TOOLS := {
	# E3D V6 + a 30 W heater and a 5015 part fan; a complete direct-drive
	# toolhead (Stealthburner-class) is ~350 g.
	"hotend_04": {"label": "Hotend, 0.4 mm (PLA/PETG)", "process": "additive", "kg": 0.35, "watts": 60.0,
		"nozzle_mm": 0.4, "layer_mm": 0.2, "feed_mm_s": 100.0, "max_feed_mm_s": 300.0, "usd": 90.0,
		"material": "filament", "material_unit": "kg/h", "filament_mm": 1.75, "density_g_cm3": 1.24,
		"bed": "heated_pcb", "note": "The 1.75 mm filament printer. 0.2 mm layers, 100 mm/s, 60 °C bed."},
	"hotend_08": {"label": "Volcano hotend, 0.8 mm", "process": "additive", "kg": 0.42, "watts": 80.0,
		"nozzle_mm": 0.8, "layer_mm": 0.4, "feed_mm_s": 60.0, "max_feed_mm_s": 150.0, "usd": 110.0,
		"material": "filament", "material_unit": "kg/h", "filament_mm": 1.75, "density_g_cm3": 1.24,
		"bed": "heated_pcb", "note": "Big nozzle, long melt zone: four times the flow for structural parts."},
	# Pellet extruder (Mahor / Pulsar class): 1.2 kg, 150 W screw motor + 200 W heaters.
	"pellet_extruder": {"label": "Pellet extruder (recycled flake)", "process": "additive", "kg": 1.6, "watts": 400.0,
		"nozzle_mm": 3.0, "layer_mm": 1.5, "feed_mm_s": 40.0, "max_feed_mm_s": 80.0, "usd": 900.0,
		"material": "plastic_flake", "material_unit": "kg/h", "filament_mm": 3.0, "density_g_cm3": 0.95,
		"bed": "alu_plate", "note": "Prints shredded flake straight from the Trash Printer's hopper: 3 mm beads, 1.5 mm layers."},
	# Clay / mud extruder (WASP / Potterbot style): a 2 L cartridge on the head
	# or a hose from a pump; ~3 kg on the carriage with the hose.
	"clay_extruder": {"label": "Clay / mud extruder", "process": "additive", "kg": 3.0, "watts": 150.0,
		"nozzle_mm": 8.0, "layer_mm": 4.0, "feed_mm_s": 30.0, "max_feed_mm_s": 60.0, "usd": 600.0,
		"material": "mud", "material_unit": "L/h", "filament_mm": 8.0, "density_g_cm3": 1.8,
		"bed": "none", "note": "A screw-fed clay nozzle: slow, heavy, no heat. The Mud Printer's tool on a smaller frame."},
	"spindle_500w": {"label": "500 W DC spindle (ER11)", "process": "subtractive", "kg": 1.2, "watts": 500.0,
		"nozzle_mm": 3.175, "layer_mm": 1.0, "feed_mm_s": 15.0, "max_feed_mm_s": 40.0, "usd": 80.0,
		"material": "", "material_unit": "", "filament_mm": 0.0, "density_g_cm3": 0.0,
		"bed": "spoilboard", "note": "Wood, plastics, PCBs. 1/8\" bits, 1 mm passes at 15 mm/s."},
	# Makita RT0701C: 1.25 kW, 1.8 kg — the WorkBee / LEAD router.
	"router_1250w": {"label": "Makita trim router (1.25 kW)", "process": "subtractive", "kg": 1.8, "watts": 1250.0,
		"nozzle_mm": 6.35, "layer_mm": 3.0, "feed_mm_s": 30.0, "max_feed_mm_s": 60.0, "usd": 110.0,
		"material": "", "material_unit": "", "filament_mm": 0.0, "density_g_cm3": 0.0,
		"bed": "spoilboard", "note": "Plywood and hardwood at 3 mm a pass with a 1/4\" bit. Needs a stiff gantry — cutting force 50–100 N."},
	"spindle_2200w": {"label": "2.2 kW water-cooled spindle", "process": "subtractive", "kg": 5.5, "watts": 2200.0,
		"nozzle_mm": 6.35, "layer_mm": 5.0, "feed_mm_s": 40.0, "max_feed_mm_s": 80.0, "usd": 300.0,
		"material": "", "material_unit": "", "filament_mm": 0.0, "density_g_cm3": 0.0,
		"bed": "spoilboard", "note": "Aluminium and deep hardwood passes. 5.5 kg on the Z axis wants ball screws and HGR rails."},
	"laser_10w": {"label": "10 W diode laser", "process": "mark", "kg": 0.35, "watts": 60.0,
		"nozzle_mm": 0.1, "layer_mm": 0.0, "feed_mm_s": 50.0, "max_feed_mm_s": 400.0, "usd": 180.0,
		"material": "", "material_unit": "", "filament_mm": 0.0, "density_g_cm3": 0.0,
		"bed": "honeycomb", "note": "Engraves wood and leather, cuts 3 mm ply in a few passes. 0.1 mm spot, no cutting force at all."},
	"laser_40w_co2": {"label": "40 W CO₂ laser tube", "process": "mark", "kg": 0.2, "watts": 250.0,
		"nozzle_mm": 0.2, "layer_mm": 0.0, "feed_mm_s": 80.0, "max_feed_mm_s": 600.0, "usd": 350.0,
		"material": "", "material_unit": "", "filament_mm": 0.0, "density_g_cm3": 0.0,
		"bed": "honeycomb", "note": "The tube stays in the frame; only a mirror and lens ride the gantry, so it is the lightest head of all."},
	"pen": {"label": "Pen / vinyl knife", "process": "mark", "kg": 0.08, "watts": 0.0,
		"nozzle_mm": 0.5, "layer_mm": 0.0, "feed_mm_s": 150.0, "max_feed_mm_s": 500.0, "usd": 15.0,
		"material": "", "material_unit": "", "filament_mm": 0.0, "density_g_cm3": 0.0,
		"bed": "alu_plate", "note": "A plotter or drag-knife cutter: the cheapest way to learn the kinematics."},
}
const TOOL_ORDER := ["hotend_04", "hotend_08", "pellet_extruder", "clay_extruder", "spindle_500w",
	"router_1250w", "spindle_2200w", "laser_10w", "laser_40w_co2", "pen"]

## Beds. kg_m2 = mass per m² of build area; watts_m2 = heater draw.
const BEDS := {
	"heated_pcb": {"label": "Heated bed (PCB / silicone, 24 V)", "kg_m2": 9.0, "watts_m2": 4000.0, "usd_m2": 500.0,
		"thick_mm": 6.0, "note": "A 220 mm bed is ~200 W; a 350 mm bed wants an AC silicone heater and an SSR."},
	"alu_plate": {"label": "Aluminium plate (unheated)", "kg_m2": 16.0, "watts_m2": 0.0, "usd_m2": 180.0,
		"thick_mm": 6.0, "note": "Flat and cold: pens, pellets with a hot room, laser."},
	"spoilboard": {"label": "MDF spoilboard on a T-slot deck", "kg_m2": 14.0, "watts_m2": 0.0, "usd_m2": 120.0,
		"thick_mm": 18.0, "note": "The router bed: surfaced flat by the machine itself, screwed-down stock."},
	"honeycomb": {"label": "Honeycomb laser bed", "kg_m2": 4.0, "watts_m2": 0.0, "usd_m2": 90.0,
		"thick_mm": 20.0, "note": "Lets the beam through; nothing to scorch under the cut."},
	"none": {"label": "The ground (no bed)", "kg_m2": 0.0, "watts_m2": 0.0, "usd_m2": 0.0,
		"thick_mm": 0.0, "note": "A clay printer prints onto a slab or the earth itself."},
}
const BED_ORDER := ["heated_pcb", "alu_plate", "spoilboard", "honeycomb", "none"]

## Small parts, per unit.
const HARDWARE := {
	"corner_bracket": {"label": "Cast corner bracket (90°)", "usd": 1.6, "kg": 0.02},
	"inside_corner": {"label": "Inside hidden corner connector", "usd": 1.2, "kg": 0.01},
	"tnut_m5": {"label": "M5 drop-in T-nut", "usd": 0.25, "kg": 0.003},
	"bolt_m5": {"label": "M5×8 low-profile bolt", "usd": 0.12, "kg": 0.003},
	"gantry_plate": {"label": "Gantry plate (aluminium)", "usd": 22.0, "kg": 0.25},
	"pulley_gt2": {"label": "GT2 pulley (bore 5 mm)", "usd": 3.5, "kg": 0.01},
	"idler_gt2": {"label": "GT2 smooth / toothed idler", "usd": 2.5, "kg": 0.01},
	"coupler": {"label": "Flexible shaft coupler 5→8 mm", "usd": 3.0, "kg": 0.02},
	"anti_backlash_nut": {"label": "Anti-backlash Tr8 nut", "usd": 4.0, "kg": 0.03},
	"ballscrew_nut": {"label": "Ball screw nut + housing", "usd": 25.0, "kg": 0.3},
	"bearing_block": {"label": "Screw end bearing block (BK/BF)", "usd": 12.0, "kg": 0.15},
	"endstop": {"label": "Microswitch endstop", "usd": 2.0, "kg": 0.01},
	"driver_tmc2209": {"label": "TMC2209 stepper driver", "usd": 8.0, "kg": 0.005},
	"psu_24v_350": {"label": "24 V 350 W PSU", "usd": 28.0, "kg": 0.9},
	"psu_24v_600": {"label": "24 V 600 W PSU", "usd": 45.0, "kg": 1.4},
	"psu_48v_600": {"label": "48 V 600 W PSU", "usd": 55.0, "kg": 1.4},
	"ssr": {"label": "Solid-state relay (bed / spindle)", "usd": 8.0, "kg": 0.1},
	"cable_chain_m": {"label": "Cable chain, per metre", "usd": 6.0, "kg": 0.2},
	"wiring_m": {"label": "Wiring + crimps, per motor metre", "usd": 1.5, "kg": 0.03},
	"delta_rod": {"label": "Delta arm (carbon rod + rod ends)", "usd": 9.0, "kg": 0.03},
	"delta_effector": {"label": "Delta effector plate", "usd": 15.0, "kg": 0.08},
	"delta_carriage": {"label": "Delta tower carriage", "usd": 14.0, "kg": 0.1},
	"spoilboard_sheet": {"label": "MDF sheet 18 mm", "usd": 30.0, "kg": 12.0},
	"enclosure_panel_m2": {"label": "Enclosure panel (acrylic / ACM), per m²", "usd": 35.0, "kg": 3.6},
}


static func profile(id: String) -> Dictionary:
	return PROFILES.get(id, PROFILES["2020"])


static func guide(id: String) -> Dictionary:
	return GUIDES.get(id, GUIDES["v_wheel"])


static func drive(id: String) -> Dictionary:
	return DRIVES.get(id, DRIVES["belt_gt2_6"])


static func motor(id: String) -> Dictionary:
	return MOTORS.get(id, MOTORS["nema17"])


static func board(id: String) -> Dictionary:
	return BOARDS.get(id, BOARDS["skr_mini_e3"])


static func tool(id: String) -> Dictionary:
	return TOOLS.get(id, TOOLS["hotend_04"])


static func bed(id: String) -> Dictionary:
	return BEDS.get(id, BEDS["alu_plate"])


## The I (m⁴) of a profile about the axis that resists bending in `strong`
## (true) or the weak direction. Published cm⁴ → m⁴ is × 1e-8.
static func profile_i_m4(id: String, strong: bool = true) -> float:
	var p := profile(id)
	return float(p["ix_cm4" if strong else "iy_cm4"]) * 1e-8


static func label_list(order: Array, table: Dictionary) -> Array:
	var out: Array = []
	for id in order:
		out.append([id, str((table[id] as Dictionary)["label"])])
	return out
