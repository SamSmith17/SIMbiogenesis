class_name SpaceTypes
extends RefCounted

## Space-type vocabulary for the NPC population system: what kind of human
## activity a tagged building / placed prop / area serves. The player tags
## world objects with one of these; NPC agents wayfind to the nearest space
## matching the need they want to satisfy (see NEED_TO_SPACE).
## Extending: add an id to TYPES + a label — SpaceRegistry and the tagging
## UIs pick it up generically.
##
## The festival types (stage / temple / center_camp / art / vendor / medical)
## are VENUES: a stage pulls a crowd when its programme says a set is on, a
## temple at dawn and dusk, center camp all day. A portapotty bank is a
## `restroom` with a `units` count; a water station is a `water_point` — the
## existing need types already name what a festival provides.

const TYPES: Array = [
	"restroom", "kitchen", "sleep", "water_point", "shower",
	"fire_circle", "movement", "quiet", "workshop_social",
	"stage", "temple", "center_camp", "art", "vendor", "medical",
	"effigy", "shade",
]

## Enrichment spaces: where people go once their needs are met and they have
## free time. Gathering is what lifts morale past BASELINE_CEILING — a camp
## that only functions never gets past "Pretty Good".
const ENRICHMENT_TYPES: Array = ["fire_circle", "movement", "quiet", "workshop_social",
	"stage", "temple", "center_camp", "art", "effigy"]

## The flavour of each enrichment space, matched against a person's TASTE
## (NpcVenueChoice): music / quiet / social / art. Two stages pull the same
## people; a stage and the temple pull different ones.
const ENRICHMENT_KIND: Dictionary = {
	"fire_circle": "social", "movement": "music", "quiet": "quiet",
	"workshop_social": "art", "stage": "music", "temple": "quiet",
	"center_camp": "social", "art": "art",
	# The effigy is art until it is lit; the burn itself is the one event no
	# taste sits out (NpcVenueState gives it an EVENT pull on top of taste).
	"effigy": "art",
}
const TASTE_KINDS: Array = ["music", "quiet", "social", "art"]

## Types that can carry a PROGRAMME (time windows with a draw): every
## enrichment venue plus the vendors (a food truck has hours too).
const VENUE_TYPES: Array = ["fire_circle", "movement", "quiet", "workshop_social",
	"stage", "temple", "center_camp", "art", "vendor", "effigy"]

## Venues whose crowd stands in the open (weather exposure).
const OUTDOOR_TYPES: Array = ["fire_circle", "stage", "art", "center_camp", "effigy"]

## Venues whose crowd has CHOREOGRAPHY (VenueCrowd): slots that depend on
## the venue's live state and move with it.
const LIVE_VENUE_TYPES: Array = ["effigy", "stage", "fire_circle"]

const LABELS: Dictionary = {
	"restroom": "Restroom",
	"kitchen": "Kitchen / Eating",
	"sleep": "Sleeping",
	"water_point": "Water Point",
	"shower": "Shower / Wash",
	"fire_circle": "Fire Circle",
	"movement": "Dance / Movement",
	"quiet": "Quiet / Reflection",
	"workshop_social": "Making / Craft",
	"stage": "Bass Stage",
	"temple": "Temple",
	"center_camp": "Center Camp",
	"art": "Art Piece",
	"vendor": "Food Vendor",
	"medical": "Medical",
	"effigy": "Effigy",
	"shade": "Shade / Shelter",
}

## Not a venue and not a need: SHADE is where people go to get out of the
## midday sun or a downpour (NpcComfort). Camp shade structures, tarps and
## StarShades count on their own; tagging a prop or an area adds one.
const COMFORT_TYPES: Array = ["shade"]

## Need id -> the space type that satisfies it. Enrichment is satisfied by ANY
## ENRICHMENT_TYPES space, so it maps to the most iconic one for labelling and
## the selector widens the search (see NpcAgent._begin_enrichment).
const NEED_TO_SPACE: Dictionary = {
	"hunger": "kitchen",
	"bladder": "restroom",
	"sleep": "sleep",
	"thirst": "water_point",
	"hygiene": "shower",
	"enrichment": "fire_circle",
}

## Other space types that ALSO satisfy a need, tried after the primary one
## (a vendor feeds people whose camp has no kitchen; it bills `meal`).
const NEED_ALTERNATIVES: Dictionary = {
	"hunger": ["vendor"],
}


static func is_enrichment(space_type: String) -> bool:
	return space_type in ENRICHMENT_TYPES


static func is_venue(space_type: String) -> bool:
	return space_type in VENUE_TYPES


static func enrichment_kind(space_type: String) -> String:
	return str(ENRICHMENT_KIND.get(space_type, "social"))


## Every space type that can serve a need, primary first.
static func spaces_for_need(need: String) -> Array:
	var out: Array = []
	var primary := str(NEED_TO_SPACE.get(need, ""))
	if not primary.is_empty():
		out.append(primary)
	for alt in NEED_ALTERNATIVES.get(need, []):
		if not out.has(str(alt)):
			out.append(str(alt))
	return out

## Site Plan / marker colors per space type (semantic registry, like the
## graph's PORT_COLORS — not UITheme palette entries).
const COLORS: Dictionary = {
	"restroom": Color(0.85, 0.62, 0.30),
	"kitchen": Color(0.90, 0.42, 0.38),
	"sleep": Color(0.55, 0.50, 0.88),
	"water_point": Color(0.32, 0.72, 0.92),
	"shower": Color(0.36, 0.84, 0.74),
	"fire_circle": Color(0.98, 0.55, 0.22),
	"movement": Color(0.88, 0.44, 0.78),
	"quiet": Color(0.62, 0.70, 0.86),
	"workshop_social": Color(0.78, 0.72, 0.36),
	"stage": Color(0.95, 0.30, 0.65),
	"temple": Color(0.92, 0.88, 0.70),
	"center_camp": Color(0.98, 0.75, 0.30),
	"art": Color(0.55, 0.85, 0.95),
	"vendor": Color(0.95, 0.55, 0.40),
	"medical": Color(0.95, 0.35, 0.35),
	"effigy": Color(1.0, 0.45, 0.15),
	"shade": Color(0.55, 0.78, 0.62),
}

## Short glyph for map markers / crosshair prompts.
const ICONS: Dictionary = {
	"restroom": "WC",
	"kitchen": "EAT",
	"sleep": "BED",
	"water_point": "H2O",
	"shower": "WASH",
	"fire_circle": "FIRE",
	"movement": "DANCE",
	"quiet": "CALM",
	"workshop_social": "CRAFT",
	"stage": "BASS",
	"temple": "TEMPLE",
	"center_camp": "CENTER",
	"art": "ART",
	"vendor": "FOOD",
	"medical": "MED",
	"effigy": "BURN",
	"shade": "SHADE",
}


static func color(space_type: String) -> Color:
	return COLORS.get(space_type, Color(0.7, 0.75, 0.8)) as Color


static func icon(space_type: String) -> String:
	return str(ICONS.get(space_type, "?"))


static func is_valid(space_type: String) -> bool:
	return space_type in TYPES


static func label(space_type: String) -> String:
	return str(LABELS.get(space_type, space_type.capitalize()))
