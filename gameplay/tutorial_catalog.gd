class_name TutorialCatalog
extends RefCounted

## Solar Bootcamp level catalog (data only — the director owns flow).
## Levels 1–7 are build puzzles on the DC electrical layer; the run-levels
## (8–12: 24 h bakes, loads, automation, hybrid merge) land with the bake
## engine phase and slot in here as plain content additions.

const BATTERY := "12V 100Ah AGM"
const BATTERY_48V := "48V 100Ah LiFePO4"
const PANEL := "Trainer 300W"
const PWM := "Trainer PWM 10A"
const MPPT := "Trainer MPPT 150/30"


static func all_levels() -> Array:
	var out: Array = []
	for d in _LEVELS:
		out.append(TutorialLevelDef.from_dict(d))
	return out


static func by_id(level_id: String) -> TutorialLevelDef:
	for d in _LEVELS:
		if str((d as Dictionary).get("id", "")) == level_id:
			return TutorialLevelDef.from_dict(d)
	return null


static func ordered_ids() -> Array:
	var out: Array = []
	for d in _LEVELS:
		out.append(str((d as Dictionary).get("id", "")))
	return out


static func next_after(level_id: String) -> String:
	var ids := ordered_ids()
	var i := ids.find(level_id)
	if i < 0 or i + 1 >= ids.size():
		return ""
	return str(ids[i + 1])


## Find a library preset by its label across every category (labels are the
## stable preset key — see ProgressStore).
static func find_preset(label: String) -> Dictionary:
	for cat in ComponentPresets.CATEGORIES:
		for p in ComponentPresets.presets_for_category(str((cat as Dictionary).get("id", ""))):
			if str((p as Dictionary).get("label", "")) == label:
				return p
	return {}


const _LEVELS: Array = [
	{
		"id": "bootcamp_01_short", "index": 1, "title": "Don't Do This",
		"brief_bbcode": "Here's a [b]12 V battery[/b]. Your first mission is to do the one thing " +
			"you must never do with a battery: wire its [color=#e05555]+[/color] terminal " +
			"straight to its [color=#55aaff]−[/color] terminal.\n\n" +
			"Drag a wire between the two ports on top of the battery. Yes, really.",
		"debrief_bbcode": "[b]That[/b] is a short circuit. With nothing in the loop but wire, " +
			"the battery's full voltage drives hundreds of amps through a few milliohms of " +
			"copper (I = V/R) — the wire ignites, then the battery follows.\n\n" +
			"Real systems put a [b]fuse[/b] on every battery so a mistake melts a 50¢ part " +
			"instead. Every other lesson here is about putting something [i]useful[/i] " +
			"between + and −.\n\n[color=#22d3ee]Unlocked: solar panels.[/color]",
		"seed": [{"preset_label": BATTERY, "x": -60.0, "y": 60.0}],
		"allowed_presets": [],
		"goal": {"kind": "fault_observed", "reason": "short_circuit"},
		"unlocks": ["cat:panels", "preset:Trainer 300W"],
	},
	{
		"id": "bootcamp_02_overvolt", "index": 2, "title": "Panels Push Too Hard",
		"brief_bbcode": "Reset the battery (RESET button on the node), then wire this " +
			"[b]300 W solar panel[/b] directly to it — panel [color=#e05555]+[/color] to " +
			"battery [color=#e05555]+[/color], panel [color=#55aaff]−[/color] to battery " +
			"[color=#55aaff]−[/color].\n\nSeems reasonable. The sun charges the battery, right?",
		"debrief_bbcode": "The panel's [b]open-circuit voltage (Voc)[/b] is 40 V, but a 12 V " +
			"battery must never be charged past ~14.6 V. Wired directly, the panel drives the " +
			"cells past their ceiling — electrolyte boils, cells swell, battery ruined.\n\n" +
			"Panels are [i]never[/i] wired straight to batteries. A [b]charge controller[/b] " +
			"regulates the panel down to what the battery can accept.\n\n" +
			"[color=#22d3ee]Unlocked: charge controllers.[/color]",
		"seed": [
			{"preset_label": BATTERY, "x": -60.0, "y": 120.0},
			{"preset_label": PANEL, "x": -60.0, "y": -160.0},
		],
		"allowed_presets": [PANEL],
		"goal": {"kind": "fault_observed", "reason": "battery_overvoltage"},
		"unlocks": ["cat:controllers", "preset:Trainer PWM 10A"],
	},
	{
		"id": "bootcamp_03_pwm", "index": 3, "title": "You've Got Power… Some of It",
		"brief_bbcode": "Now do it right: wire the panel into the [b]PWM charge controller[/b]'s " +
			"PV inputs (top), and the controller's battery outputs (bottom) to the battery. " +
			"Reset anything still smoking first.\n\n" +
			"Watch the controller node once it's wired — check the amber readout.",
		"debrief_bbcode": "You're charging! But look: [b]120 W of your 300 W panel[/b]. A " +
			"controller delivers at the [i]battery's[/i] voltage, capped at its rated current " +
			"— 12 V × 10 A = 120 W. The other 180 W never gets made.\n\n" +
			"The controller's amp rating and the battery voltage decide how much of your " +
			"array you can actually use.\n\n" +
			"[color=#22d3ee]Unlocked: Trainer MPPT 150/30 — a bigger controller.[/color]",
		"seed": [
			{"preset_label": BATTERY, "x": -60.0, "y": 200.0},
			{"preset_label": PANEL, "x": -60.0, "y": -220.0},
			{"preset_label": PWM, "x": -70.0, "y": -20.0},
		],
		"allowed_presets": [PANEL, PWM],
		"goal": {"kind": "build", "min_deliverable_w": 100.0},
		"unlocks": ["preset:Trainer MPPT 150/30"],
	},
	{
		"id": "bootcamp_04_array", "index": 4, "title": "Scale the Array",
		"brief_bbcode": "Four panels (1200 W) and the new [b]MPPT 150/30[/b]. Wire the array " +
			"to the controller and the controller to the battery.\n\n" +
			"[b]Series[/b] (+ to −) adds voltage. [b]Parallel[/b] (+ to +, − to −) adds " +
			"current. The controller's input limit is [b]150 V[/b]… and four 40 Voc panels " +
			"in series is 160 V. Choose wisely — or don't, and see what happens.",
		"debrief_bbcode": "In parallel the string stays at 40 V — safe — and you still only " +
			"get [b]360 W of 1200 W[/b] (12 V × 30 A). The controller isn't the bottleneck " +
			"anymore; the [b]12 V battery[/b] is.\n\n" +
			"To use more of the array: raise the battery voltage, buy a bigger controller, " +
			"or parallel a second controller.\n\n" +
			"[color=#22d3ee]Unlocked: a second battery.[/color]",
		"seed": [
			{"preset_label": BATTERY, "x": -60.0, "y": 240.0},
			{"preset_label": PANEL, "x": -420.0, "y": -240.0},
			{"preset_label": PANEL, "x": -230.0, "y": -240.0},
			{"preset_label": PANEL, "x": -40.0, "y": -240.0},
			{"preset_label": PANEL, "x": 150.0, "y": -240.0},
			{"preset_label": MPPT, "x": -70.0, "y": 0.0},
		],
		"allowed_presets": [PANEL, PWM, MPPT],
		"goal": {"kind": "build", "min_deliverable_w": 350.0},
		"unlocks": ["preset:12V 100Ah AGM"],
	},
	{
		"id": "bootcamp_05_24v", "index": 5, "title": "Raise the Voltage",
		"brief_bbcode": "Here's a [b]second 12 V battery[/b]. Two ways to add it:\n\n" +
			"[b]Parallel[/b] (+ to +, − to −): still 12 V, twice the storage — and still " +
			"360 W charging.\n[b]Series[/b] (+ to −): a [b]24 V bank[/b] — same controller " +
			"now delivers 24 V × 30 A = [b]720 W[/b].\n\n" +
			"Wire the bank in series and rewire the controller's battery leads across the " +
			"whole 24 V string (bottom battery − and top battery +).",
		"debrief_bbcode": "[b]720 W of 1200 W[/b] — doubling the bus voltage doubled the power " +
			"the same 30 A controller can move. This is why serious off-grid systems run " +
			"24 V or 48 V: [b]watts = volts × amps[/b], and amps are what cost money in " +
			"copper and hardware.\n\n[color=#22d3ee]Unlocked: two more batteries.[/color]",
		"seed": [
			{"preset_label": BATTERY, "x": -170.0, "y": 240.0},
			{"preset_label": BATTERY, "x": 40.0, "y": 240.0},
			{"preset_label": PANEL, "x": -420.0, "y": -240.0},
			{"preset_label": PANEL, "x": -230.0, "y": -240.0},
			{"preset_label": PANEL, "x": -40.0, "y": -240.0},
			{"preset_label": PANEL, "x": 150.0, "y": -240.0},
			{"preset_label": MPPT, "x": -70.0, "y": 0.0},
		],
		"allowed_presets": [PANEL, PWM, MPPT, BATTERY],
		"goal": {"kind": "build", "min_bus_v": 24.0, "min_deliverable_w": 700.0},
		"unlocks": [],
	},
	{
		"id": "bootcamp_06_48v", "index": 6, "title": "48 Volts, Full Array",
		"brief_bbcode": "Four batteries now. Wire all four in [b]series[/b] — a 48 V bank — " +
			"and hook the controller across the whole string.\n\n" +
			"48 V × 30 A = 1440 W of controller headroom… and your array is only 1200 W.",
		"debrief_bbcode": "[b]The full 1200 W flows.[/b] For the first time the controller " +
			"isn't clipping — the array itself is the limit. This is why 48 V became the " +
			"off-grid standard: it keeps currents low enough that ordinary wire and " +
			"affordable controllers can move serious power.\n\n" +
			"[color=#22d3ee]Unlocked: two more panels.[/color]",
		"seed": [
			{"preset_label": BATTERY, "x": -280.0, "y": 240.0},
			{"preset_label": BATTERY, "x": -70.0, "y": 240.0},
			{"preset_label": BATTERY, "x": 140.0, "y": 240.0},
			{"preset_label": BATTERY, "x": 350.0, "y": 240.0},
			{"preset_label": PANEL, "x": -420.0, "y": -240.0},
			{"preset_label": PANEL, "x": -230.0, "y": -240.0},
			{"preset_label": PANEL, "x": -40.0, "y": -240.0},
			{"preset_label": PANEL, "x": 150.0, "y": -240.0},
			{"preset_label": MPPT, "x": -70.0, "y": 0.0},
		],
		"allowed_presets": [PANEL, PWM, MPPT, BATTERY],
		"goal": {"kind": "build", "min_bus_v": 48.0, "min_deliverable_w": 1100.0},
		"unlocks": [],
	},
	{
		"id": "bootcamp_07_3s2p", "index": 7, "title": "String Theory",
		"brief_bbcode": "Two more panels — [b]six[/b] now, 1800 W. The 48 V bank is pre-wired; " +
			"so is the controller's battery side.\n\n" +
			"Max out the array [i]without[/i] blowing the controller's 150 V input limit. " +
			"Six 40 Voc panels all in series is 240 V — boom. All parallel wastes nothing " +
			"but needs thick wire. The sweet spot mixes both: [b]strings of panels in " +
			"series, strings paralleled together[/b].",
		"debrief_bbcode": "[b]3S2P[/b]: two parallel strings of three panels — 120 Voc per " +
			"string, safely under 150 V, all six panels working. String sizing under the " +
			"controller's Voc ceiling is THE design skill of real PV arrays (cold mornings " +
			"push Voc even higher — leave margin).\n\n" +
			"[color=#22d3ee]Unlocked: 48 V batteries — one box instead of four.[/color]",
		"seed": [
			{"preset_label": BATTERY, "x": -280.0, "y": 260.0},
			{"preset_label": BATTERY, "x": -70.0, "y": 260.0},
			{"preset_label": BATTERY, "x": 140.0, "y": 260.0},
			{"preset_label": BATTERY, "x": 350.0, "y": 260.0},
			{"preset_label": PANEL, "x": -510.0, "y": -260.0},
			{"preset_label": PANEL, "x": -320.0, "y": -260.0},
			{"preset_label": PANEL, "x": -130.0, "y": -260.0},
			{"preset_label": PANEL, "x": 60.0, "y": -260.0},
			{"preset_label": PANEL, "x": 250.0, "y": -260.0},
			{"preset_label": PANEL, "x": 440.0, "y": -260.0},
			{"preset_label": MPPT, "x": -70.0, "y": 20.0},
		],
		"seed_wires": [
			{"from": 0, "from_handle": "positive", "to": 1, "to_handle": "negative"},
			{"from": 1, "from_handle": "positive", "to": 2, "to_handle": "negative"},
			{"from": 2, "from_handle": "positive", "to": 3, "to_handle": "negative"},
			{"from": 10, "from_handle": "batteryPositive", "to": 3, "to_handle": "positive"},
			{"from": 10, "from_handle": "batteryNegative", "to": 0, "to_handle": "negative"},
		],
		"allowed_presets": [PANEL, PWM, MPPT, BATTERY],
		"goal": {"kind": "build", "series": 3, "parallel": 2, "min_deliverable_w": 1400.0},
		"unlocks": ["preset:48V 100Ah LiFePO4", "preset:48V 50Ah LiFePO4"],
	},
	{
		"id": "bootcamp_08_first_run", "index": 8, "title": "First Light",
		"brief_bbcode": "Your system, upgraded: [b]one 48 V battery[/b] replaces the four-pack " +
			"(same voltage, one box, one BMS), pre-wired to your 3S2P array.\n\n" +
			"Time to actually RUN it. Press [b]▶ Run 24 h[/b] in the objective bar — the sim " +
			"computes a full day in seconds and plays it back on the timeline. Watch the " +
			"battery charge as the sun crosses the sky.",
		"debrief_bbcode": "A full day, no failures — but look at the [b]sun you wasted[/b]. " +
			"Once the battery filled, every extra watt had nowhere to go and was thrown " +
			"away at the panel. A battery-only system is 'optimized' only until it's full.\n\n" +
			"Generation without CONSUMPTION is only half a system.\n\n" +
			"[color=#22d3ee]Unlocked: appliances & loads.[/color]",
		"seed": [
			{"preset_label": BATTERY_48V, "x": -70.0, "y": 280.0},
			{"preset_label": PANEL, "x": -510.0, "y": -260.0},
			{"preset_label": PANEL, "x": -320.0, "y": -260.0},
			{"preset_label": PANEL, "x": -130.0, "y": -260.0},
			{"preset_label": PANEL, "x": 60.0, "y": -260.0},
			{"preset_label": PANEL, "x": 250.0, "y": -260.0},
			{"preset_label": PANEL, "x": 440.0, "y": -260.0},
			{"preset_label": MPPT, "x": -70.0, "y": 20.0},
		],
		"seed_wires": [
			{"from": 1, "from_handle": "positive", "to": 2, "to_handle": "negative"},
			{"from": 2, "from_handle": "positive", "to": 3, "to_handle": "negative"},
			{"from": 4, "from_handle": "positive", "to": 5, "to_handle": "negative"},
			{"from": 5, "from_handle": "positive", "to": 6, "to_handle": "negative"},
			{"from": 3, "from_handle": "positive", "to": 7, "to_handle": "pvPositive"},
			{"from": 6, "from_handle": "positive", "to": 7, "to_handle": "pvPositive"},
			{"from": 1, "from_handle": "negative", "to": 7, "to_handle": "pvNegative"},
			{"from": 4, "from_handle": "negative", "to": 7, "to_handle": "pvNegative"},
			{"from": 7, "from_handle": "batteryPositive", "to": 0, "to_handle": "positive"},
			{"from": 7, "from_handle": "batteryNegative", "to": 0, "to_handle": "negative"},
		],
		"allowed_presets": [PANEL, MPPT, BATTERY, BATTERY_48V],
		"goal": {"kind": "run_clean"},
		"run": {"span": "day", "fail_on_power_failure": true},
		"unlocks": ["cat:appliances", "preset:Custom Load"],
	},
	{
		"id": "bootcamp_09_loads", "index": 9, "title": "Something to Power",
		"brief_bbcode": "Batteries store DC, but your kettle, fridge, and laptop chargers all " +
			"want [b]AC[/b] — that conversion is an [b]inverter[/b]'s job. Your MPPT unit is a " +
			"hybrid: charge controller and inverter in one box, with an [b]AC output[/b] on " +
			"its lower edge.\n\n" +
			"Grab an appliance from the Library and wire it to the controller's AC output.",
		"debrief_bbcode": "Powered! The inverter draws DC from the battery bus and serves AC " +
			"to the load — day or night, sun or not, as long as the battery holds out.\n\n" +
			"Standalone inverters exist too (battery → inverter → loads); hybrids just save " +
			"a box and some wiring. Either way, [i]every[/i] AC watt still comes out of your " +
			"battery.\n\n[color=#22d3ee]Unlocked: the appliance catalog.[/color]",
		"seed": [
			{"preset_label": BATTERY_48V, "x": -70.0, "y": 280.0},
			{"preset_label": PANEL, "x": -510.0, "y": -260.0},
			{"preset_label": PANEL, "x": -320.0, "y": -260.0},
			{"preset_label": PANEL, "x": -130.0, "y": -260.0},
			{"preset_label": PANEL, "x": 60.0, "y": -260.0},
			{"preset_label": PANEL, "x": 250.0, "y": -260.0},
			{"preset_label": PANEL, "x": 440.0, "y": -260.0},
			{"preset_label": MPPT, "x": -70.0, "y": 20.0},
		],
		"seed_wires": [
			{"from": 1, "from_handle": "positive", "to": 2, "to_handle": "negative"},
			{"from": 2, "from_handle": "positive", "to": 3, "to_handle": "negative"},
			{"from": 4, "from_handle": "positive", "to": 5, "to_handle": "negative"},
			{"from": 5, "from_handle": "positive", "to": 6, "to_handle": "negative"},
			{"from": 3, "from_handle": "positive", "to": 7, "to_handle": "pvPositive"},
			{"from": 6, "from_handle": "positive", "to": 7, "to_handle": "pvPositive"},
			{"from": 1, "from_handle": "negative", "to": 7, "to_handle": "pvNegative"},
			{"from": 4, "from_handle": "negative", "to": 7, "to_handle": "pvNegative"},
			{"from": 7, "from_handle": "batteryPositive", "to": 0, "to_handle": "positive"},
			{"from": 7, "from_handle": "batteryNegative", "to": 0, "to_handle": "negative"},
		],
		"allowed_presets": [PANEL, MPPT, BATTERY_48V, "Custom Load", "LED Light",
			"Laptop", "Patio String Lights"],
		"goal": {"kind": "ac_load_wired"},
		"unlocks": ["cat:breakers", "cat:spiderbox", "cat:monitors"],
	},
	{
		"id": "bootcamp_10_score", "index": 10, "title": "Run the Numbers",
		"brief_bbcode": "Same system, now with loads attached. [b]▶ Run 24 h[/b] again — this " +
			"time you get a [b]score[/b]: how much of the energy the sky offered actually did " +
			"something (loads served + charge banked).\n\n" +
			"If your loads are too hungry the battery dies overnight; too timid and the sun " +
			"goes to waste. Run it and see where you land.",
		"debrief_bbcode": "That percentage is THE off-grid design number. Raise it with " +
			"[b]dump loads[/b] — things that switch on only when there's surplus (water " +
			"heating, pumping, charging the e-bike) — and [b]automations[/b] that shed load " +
			"before the battery empties.\n\n" +
			"Click a load and look for its automation section in the inspector: rules like " +
			"'ON above 80% battery, OFF below 40%' turn wasted noon sun into useful work.\n\n" +
			"[color=#22d3ee]Next: push that score.[/color]",
		"seed": [],
		"carry_graph": true,
		"allowed_presets": [PANEL, MPPT, BATTERY_48V, "Custom Load", "LED Light",
			"Laptop", "Patio String Lights"],
		"goal": {"kind": "run_clean"},
		"run": {"span": "day", "fail_on_power_failure": true},
		"unlocks": [],
	},
	{
		"id": "bootcamp_11_optimize", "index": 11, "title": "Soak Up the Sun",
		"brief_bbcode": "The replay loop is the whole game now: [b]run the day, read the " +
			"score, tune, run again[/b]. Add loads, size them, automate them.\n\n" +
			"Target: [b]60% useful utilization[/b] with no overnight power failure. The " +
			"same day replays every attempt — pure cause and effect.",
		"debrief_bbcode": "That's a tuned system: most of the available sun became work, and " +
			"the battery never hit the floor. This bake–replay loop is exactly how the full " +
			"challenge mode works (🎯 in the toolbar) — a day, a month, or a year, " +
			"pre-computed and replayed until your design survives.\n\n" +
			"[color=#22d3ee]Unlocked: hybrid inverters and big-system hardware.[/color]",
		"seed": [],
		"carry_graph": true,
		"allowed_presets": [PANEL, MPPT, BATTERY_48V, "Custom Load", "LED Light",
			"Laptop", "Patio String Lights"],
		"goal": {"kind": "run_clean", "min_useful_utilization_pct": 60.0},
		"run": {"span": "day", "fail_on_power_failure": true},
		"unlocks": ["preset:EcoWorthy SL3500", "preset:PowMR 5000W Hybrid", "preset:EG4 6000XP"],
	},
	{
		"id": "bootcamp_12_hybrid", "index": 12, "title": "One Box to Rule Them",
		"brief_bbcode": "Real installs don't leave parts strewn across the bench. Your " +
			"controller-inverter and battery want to be [b]one unit[/b] — a power station.\n\n" +
			"Drag a box-select around the [b]controller and battery[/b] (or Ctrl-click " +
			"both), then press [b]Ctrl+G[/b] to combine them into a super-node. " +
			"Double-click it to look inside; Esc backs out.",
		"debrief_bbcode": "You just built an [b]all-in-one[/b] — functionally an EcoFlow-style " +
			"power station: charge controller + inverter + battery in one box, one warranty, " +
			"three wires. Cheaper per part to build yourself; simpler to buy.\n\n" +
			"Super-nodes are how big systems stay readable: group a subsystem, name it, " +
			"drill in when you care. The whole component Library — hybrid inverters, " +
			"all-in-ones, everything — is now yours.\n\n" +
			"[b][color=#26e577]🎓 Solar Bootcamp complete![/color][/b]",
		"seed": [],
		"carry_graph": true,
		"allowed_presets": [PANEL, MPPT, BATTERY_48V, "Custom Load", "LED Light",
			"Laptop", "Patio String Lights"],
		"goal": {"kind": "compound_containing", "types": ["controller", "battery"]},
		"unlocks": ["unlock_all"],
	},
]
