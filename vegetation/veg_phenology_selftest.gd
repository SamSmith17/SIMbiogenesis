extends SceneTree

## Headless self-test for the Phase 6 phenology work: latitude damping of the
## seasonal signals, the species climate envelope's cold-hardiness gate, the
## leaf-fall drop window, and the ground-litter mask + its seasonal strength.
## Pure / offline / deterministic — the weather service is stubbed, so nothing
## here touches the network or a live scene.
## Run with:
##   godot --headless --path . --script vegetation/veg_phenology_selftest.gd

var _failures := 0
var _checks := 0

const _DAYS_BEFORE_MONTH := [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]


func _initialize() -> void:
	_test_latitude_damping()
	_test_hemisphere_flip_survives_damping()
	_test_winter_min_estimate()
	_test_cold_hardiness_gate()
	_test_drop_window()
	_test_litter_mask()
	_test_litter_strength()
	_test_impostor_night_floor()
	if _failures == 0:
		print("VEG PHENOLOGY SELFTEST PASS  (%d checks)" % _checks)
		quit(0)
	else:
		print("VEG PHENOLOGY SELFTEST FAIL  (%d of %d checks failed)" % [_failures, _checks])
		quit(1)


func _check(label: String, ok: bool, detail: String = "") -> void:
	_checks += 1
	if not ok:
		_failures += 1
		print("  FAIL: %s  %s" % [label, detail])


func _doy(month: int, day: int) -> int:
	return int(_DAYS_BEFORE_MONTH[month - 1]) + day


## --- Latitude damping -------------------------------------------------------

func _test_latitude_damping() -> void:
	_check("seasonality zero at the equator",
		is_zero_approx(SeasonModel.seasonality_strength(0.0)))
	_check("seasonality zero inside the tropics",
		is_zero_approx(SeasonModel.seasonality_strength(12.0)))
	_check("seasonality full at mid latitude",
		is_equal_approx(SeasonModel.seasonality_strength(48.0), 1.0))
	_check("seasonality full in the far south",
		is_equal_approx(SeasonModel.seasonality_strength(-55.0), 1.0))
	# Monotone through the subtropical ramp — a site 5° further from the equator
	# is never LESS seasonal.
	var prev := -1.0
	for lat in [0.0, 10.0, 15.0, 20.0, 25.0, 30.0, 35.0, 40.0]:
		var s := SeasonModel.seasonality_strength(lat)
		_check("seasonality non-decreasing at %.0f" % lat, s >= prev - 1e-6,
			"%.3f -> %.3f" % [prev, s])
		prev = s

	# The headline requirement: a tropical broadleaf never turns red, never goes
	# bare, and never reads as dormant, on the date a temperate one peaks.
	var trop := SeasonModel.season_signals(_doy(10, 25), 5.0)
	_check("no autumn colour in the tropics", float(trop["autumn"]) < 0.001,
		str(trop["autumn"]))
	_check("tropical canopy stays full", float(trop["leaf_coverage"]) > 0.999,
		str(trop["leaf_coverage"]))
	var trop_win := SeasonModel.season_signals(_doy(1, 15), 5.0)
	_check("no winter dormancy in the tropics", float(trop_win["winter"]) < 0.001)
	_check("tropics stay lush", float(trop_win["summer"]) > 0.999)
	_check("tropical grass keeps growing", float(trop_win["grass_growth"]) > 0.999)
	_check("tropical canopy bare-season is still full",
		float(trop_win["leaf_coverage"]) > 0.999)

	# Temperate behaviour is untouched by the damping (seasonality == 1).
	var temp := SeasonModel.season_signals(_doy(10, 25), 48.0)
	_check("temperate autumn still peaks", float(temp["autumn"]) > 0.7)
	_check("temperate seasonality reported 1", is_equal_approx(float(temp["seasonality"]), 1.0))
	var temp_win := SeasonModel.season_signals(_doy(1, 15), 48.0)
	_check("temperate canopy still goes bare", float(temp_win["leaf_coverage"]) < 0.05)

	# Subtropics: partial, and strictly between the two.
	var sub := SeasonModel.season_signals(_doy(10, 25), 25.0)
	_check("subtropical autumn is partial",
		float(sub["autumn"]) > float(trop["autumn"]) and float(sub["autumn"]) < float(temp["autumn"]),
		"%.3f" % float(sub["autumn"]))


func _test_hemisphere_flip_survives_damping() -> void:
	# Damping keys off ABSOLUTE latitude, so the southern-hemisphere half-year
	# flip has to still work at full strength.
	var sh_jan := SeasonModel.season_signals(_doy(1, 15), -42.0)
	_check("SH January is summer", float(sh_jan["summer"]) > 0.5
		and float(sh_jan["leaf_coverage"]) > 0.9)
	var sh_jul := SeasonModel.season_signals(_doy(7, 15), -42.0)
	_check("SH July is winter", float(sh_jul["winter"]) > 0.5)
	var sh_apr := SeasonModel.season_signals(_doy(4, 25), -42.0)
	_check("SH autumn is in April", float(sh_apr["autumn"]) > 0.3,
		str(sh_apr["autumn"]))
	# ...and a southern TROPICAL site is still damped flat.
	var sh_trop := SeasonModel.season_signals(_doy(4, 25), -8.0)
	_check("southern tropics have no autumn", float(sh_trop["autumn"]) < 0.001)


## --- Winter minimum + cold hardiness ---------------------------------------

## Duck-typed stand-in for WeatherService: a sinusoidal year with a known
## minimum, so the estimator can be pinned without touching the network.
class StubWeather:
	extends Object
	var mean_c := 10.0
	var amplitude_c := 15.0
	var peak_doy := 200.0
	var finite := true

	func temperature_c(month: int, day: int, hour: float) -> float:
		if not finite:
			return NAN
		var days_before := [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334]
		var doy := float(days_before[clampi(month, 1, 12) - 1] + clampi(day, 1, 31))
		var diurnal := -3.0 if hour < 8.0 else 0.0
		return mean_c + amplitude_c * cos(TAU * (doy - peak_doy) / 365.25) + diurnal


func _test_winter_min_estimate() -> void:
	_check("no weather service -> NAN", is_nan(SeasonModel.estimate_winter_min_c(null, 48.0)))

	var ws := StubWeather.new()
	ws.mean_c = 10.0
	ws.amplitude_c = 15.0
	# NH: coldest around the new year. mean - amplitude - the pre-dawn offset.
	var nh := SeasonModel.estimate_winter_min_c(ws, 48.0)
	_check("NH winter min near the January trough", nh > -10.0 and nh < -5.0, "%.2f" % nh)

	# SH: the estimator must sample JULY, not January. The stub's warm peak is in
	# July, so a southern site reads far WARMER than the same northern one —
	# which is exactly the mistake (reporting a Patagonian winter as mild) that
	# an unflipped window would make.
	var sh := SeasonModel.estimate_winter_min_c(ws, -48.0)
	_check("SH winter min sampled half a year away", sh - nh > 25.0,
		"nh=%.2f sh=%.2f" % [nh, sh])

	ws.finite = false
	_check("all-NAN series -> NAN", is_nan(SeasonModel.estimate_winter_min_c(ws, 48.0)))
	ws.free()


func _test_cold_hardiness_gate() -> void:
	# Spruce is listed to -45 °C, cedar only to -25 °C. A brutal continental
	# site keeps the spruce and loses the cedar; a mild one keeps both.
	_check("spruce survives -40 site",
		VegSpeciesRegistry.species_allowed_at("spruce", 55.0, -40.0))
	_check("cedar refused at a -40 site",
		not VegSpeciesRegistry.species_allowed_at("cedar", 45.0, -40.0))
	_check("cedar kept at a -10 site",
		VegSpeciesRegistry.species_allowed_at("cedar", 45.0, -10.0))
	# The tolerance is real slack, not a rounding epsilon: a site 1° below the
	# listed minimum is still a valid (marginal) planting.
	_check("marginal site inside the tolerance is allowed",
		VegSpeciesRegistry.species_allowed_at("cedar", 45.0, -26.0))
	_check("well past the tolerance is refused",
		not VegSpeciesRegistry.species_allowed_at("cedar", 45.0, -30.0))
	# Unknown winter minimum must not gate at all — an offline session keeps
	# exactly the forest it had before this feature existed.
	_check("NAN winter min leaves the latitude gate alone",
		VegSpeciesRegistry.species_allowed_at("cedar", 45.0, NAN))
	_check("NAN is the default",
		VegSpeciesRegistry.species_allowed_at("cedar", 45.0))
	# Latitude still gates independently of temperature.
	_check("latitude gate still applies at a mild site",
		not VegSpeciesRegistry.species_allowed_at("coconut_palm", 60.0, 5.0))

	var w := {"spruce": 0.5, "cedar": 0.5}
	var cold := VegSpeciesRegistry.filter_weights_by_climate(w, 55.0, -40.0)
	_check("cold site drops the tender conifer", cold.has("spruce") and not cold.has("cedar"))
	var mild := VegSpeciesRegistry.filter_weights_by_climate(w, 45.0, -8.0)
	_check("mild site keeps both", mild.has("spruce") and mild.has("cedar"))
	# Never empty a forest, whatever the data says.
	var only_tender := {"cedar": 1.0}
	_check("never empties a forest on temperature",
		VegSpeciesRegistry.filter_weights_by_climate(only_tender, 45.0, -60.0).has("cedar"))


## --- Leaf fall --------------------------------------------------------------

func _test_drop_window() -> void:
	# Mid-autumn at a temperate site: colour up, canopy partway down.
	var oct := SeasonModel.season_signals(_doy(10, 30), 48.0)
	_check("drop window open in late October",
		VegLeafFall.is_drop_window(float(oct["autumn"]), float(oct["leaf_coverage"])),
		"autumn=%.2f cover=%.2f" % [float(oct["autumn"]), float(oct["leaf_coverage"])])
	var nov := SeasonModel.season_signals(_doy(11, 15), 48.0)
	_check("drop window still open mid November",
		VegLeafFall.is_drop_window(float(nov["autumn"]), float(nov["leaf_coverage"])),
		"autumn=%.2f cover=%.2f" % [float(nov["autumn"]), float(nov["leaf_coverage"])])
	var jul := SeasonModel.season_signals(_doy(7, 15), 48.0)
	_check("no leaf fall at midsummer",
		not VegLeafFall.is_drop_window(float(jul["autumn"]), float(jul["leaf_coverage"])))
	var jan := SeasonModel.season_signals(_doy(1, 15), 48.0)
	_check("no leaf fall off a bare winter canopy",
		not VegLeafFall.is_drop_window(float(jan["autumn"]), float(jan["leaf_coverage"])))
	# Spring leaf-OUT passes through the same coverage range in the other
	# direction; autumn is what tells the two apart.
	var apr := SeasonModel.season_signals(_doy(4, 20), 48.0)
	_check("spring leaf-out is not a drop window",
		not VegLeafFall.is_drop_window(float(apr["autumn"]), float(apr["leaf_coverage"])),
		"autumn=%.2f cover=%.2f" % [float(apr["autumn"]), float(apr["leaf_coverage"])])
	# Tropics: damping zeroes autumn, so the window never opens all year.
	var any_tropical := false
	for m in range(1, 13):
		var s := SeasonModel.season_signals(_doy(m, 15), 6.0)
		if VegLeafFall.is_drop_window(float(s["autumn"]), float(s["leaf_coverage"])):
			any_tropical = true
	_check("tropical site never enters a drop window", not any_tropical)


## --- Ground litter ----------------------------------------------------------

func _test_litter_mask() -> void:
	_check("empty layer -> no mask", VegLitterMask.build({}, 1000.0) == null)
	_check("zero extent -> no mask",
		VegLitterMask.build({"deciduous": [{"x": 0.0, "z": 0.0}]}, 0.0) == null)
	# Conifers alone must not brown the ground — needle drop is a different
	# thing, and including them turned every evergreen slope brown.
	var pines := {"pine": []}
	for i in 200:
		(pines["pine"] as Array).append({"x": float(i) - 100.0, "z": 0.0})
	_check("conifer-only map has no litter", VegLitterMask.build(pines, 1000.0) == null)

	var mixed := {"pine": pines["pine"], "deciduous": []}
	for i in 200:
		(mixed["deciduous"] as Array).append({"x": float(i) * 0.5 - 50.0, "z": 20.0})
	var tex := VegLitterMask.build(mixed, 1000.0)
	_check("mixed map builds a mask", tex != null)
	if tex != null:
		var img := tex.get_image()
		var side := VegLitterMask.mask_px_for_extent(1000.0)
		_check("mask sized from the extent",
			img.get_width() == side and img.get_height() == side)
		# The stand runs east-west 20 m north of centre; sample it and a corner.
		var cx := int((0.0 + 500.0) / 1000.0 * float(side - 1))
		var cz := int((20.0 + 500.0) / 1000.0 * float(side - 1))
		_check("litter present under the stand", img.get_pixel(cx, cz).r > 0.05,
			"%.3f" % img.get_pixel(cx, cz).r)
		_check("no litter in an empty corner", img.get_pixel(2, 2).r < 0.001)

	# Resolution tracks the map so one tree never browns a hillside: a 30 km map
	# must not land on the same texel budget as a 1 km one.
	_check("small map clamps to the floor",
		VegLitterMask.mask_px_for_extent(500.0) == VegLitterMask.MIN_MASK_PX)
	_check("huge map clamps to the ceiling",
		VegLitterMask.mask_px_for_extent(60000.0) == VegLitterMask.MAX_MASK_PX)
	var big := VegLitterMask.mask_px_for_extent(30000.0)
	_check("30 km map texel stays near canopy scale", 30000.0 / float(big) < 40.0,
		"%.0f m/texel" % (30000.0 / float(big)))

	# Instances entirely off-map yield nothing rather than a blank mask.
	var far_away := {"deciduous": [{"x": 9000.0, "z": 9000.0}]}
	_check("all-off-map deciduous -> no mask", VegLitterMask.build(far_away, 1000.0) == null)


func _test_litter_strength() -> void:
	_check("no season -> no litter", is_zero_approx(VegLitterMask.strength_for_season({}, 0.0)))
	var bare := SeasonModel.season_signals(_doy(12, 10), 48.0)
	var s_bare := VegLitterMask.strength_for_season(bare, 0.0)
	_check("litter peaks once the canopy is down", s_bare > 0.9, "%.3f" % s_bare)
	var summer := SeasonModel.season_signals(_doy(7, 15), 48.0)
	_check("no litter under a full canopy",
		VegLitterMask.strength_for_season(summer, 0.0) < 0.01)
	# Snow buries it.
	_check("snow hides the litter",
		VegLitterMask.strength_for_season(bare, 1.0) < 0.01)
	_check("partial snow partly hides it",
		VegLitterMask.strength_for_season(bare, 0.5) < s_bare * 0.75)
	# Spring: last year's leaves rot away as the new canopy comes out.
	var spring := SeasonModel.season_signals(_doy(4, 10), 48.0)
	var s_spring := VegLitterMask.strength_for_season(spring, 0.0)
	_check("spring litter fades under bud break", s_spring < s_bare * 0.6,
		"%.3f vs %.3f" % [s_spring, s_bare])
	# Tropics: seasonality 0 means the ground never browns.
	var trop := SeasonModel.season_signals(_doy(12, 10), 6.0)
	_check("no litter in the tropics",
		is_zero_approx(VegLitterMask.strength_for_season(trop, 0.0)))


## Unshaded impostor night floor: must land where a LIT tree lands, at both
## ends. The hard-coded 0.30 floor it replaced left the far forest ~2 orders
## of magnitude brighter than the near tier at full night — the reported
## "trees glow in the dark at distance".
func _test_impostor_night_floor() -> void:
	# Full daylight: ambient == day_ambient -> floor is exactly the lit
	# tiers' night_darkness leftover (0.35), so a daytime night_factor of 1
	# (eclipse) matches the near tier's darkening.
	_check("day floor == night_darkness leftover",
		is_equal_approx(VegetationRuntime.impostor_night_floor(0.3), 0.35))
	# Moonless night: main.gd's night_ambient is 0.003 -> ~0.0035, i.e. the
	# same order as albedo × 0.35 × ambient on a lit leaf. NOT 0.30.
	var night := VegetationRuntime.impostor_night_floor(0.003)
	_check("moonless-night floor is dark", night < 0.006, "%.4f" % night)
	_check("moonless-night floor stays nonzero", night > 0.0009, "%.4f" % night)
	# Full-moon night (ambient 0.011): brighter than moonless, still dark.
	var moon := VegetationRuntime.impostor_night_floor(0.011)
	_check("moonlit floor between", moon > night and moon < 0.02, "%.4f" % moon)
	# Monotonic in ambient, clamped above.
	var prev := -1.0
	for a in [0.0, 0.001, 0.01, 0.05, 0.1, 0.2, 0.3, 0.5]:
		var v := VegetationRuntime.impostor_night_floor(float(a))
		_check("night floor monotonic at %.3f" % a, v >= prev)
		prev = v
	_check("night floor caps at the darkness leftover",
		is_equal_approx(VegetationRuntime.impostor_night_floor(9.9), 0.35))
