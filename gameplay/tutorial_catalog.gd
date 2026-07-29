class_name TutorialCatalog
extends RefCounted

## Solar Bootcamp level catalog (data only — the director owns flow).
## Levels 1–7 are build puzzles on the DC electrical layer; the run-levels
## (8–12: 24 h bakes, loads, automation, hybrid merge) land with the bake
## engine phase and slot in here as plain content additions.

const BATTERY := "12V 100Ah AGM"
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
]
