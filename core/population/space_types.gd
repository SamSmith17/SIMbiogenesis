class_name SpaceTypes
extends RefCounted

## Space-type vocabulary for the NPC population system: what kind of human
## activity a tagged building / placed prop / area serves. The player tags
## world objects with one of these; NPC agents wayfind to the nearest space
## matching the need they want to satisfy (see NEED_TO_SPACE).
## Extending: add an id to TYPES + a label — SpaceRegistry and the tagging
## UIs pick it up generically.

const TYPES: Array = [
	"restroom", "kitchen", "sleep", "water_point", "shower",
	"fire_circle", "movement", "quiet", "workshop_social",
]

## Enrichment spaces: where people go once their needs are met and they have
## free time. Gathering is what lifts morale past BASELINE_CEILING — a camp
## that only functions never gets past "Pretty Good".
const ENRICHMENT_TYPES: Array = ["fire_circle", "movement", "quiet", "workshop_social"]

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
}

## Need id -> the space type that satisfies it. Enrichment is satisfied by ANY
## ENRICHMENT_TYPES space, so it maps to the most iconic one for labelling and
## the selector widens the search (see NpcAgent._pick_enrichment).
const NEED_TO_SPACE: Dictionary = {
	"hunger": "kitchen",
	"bladder": "restroom",
	"sleep": "sleep",
	"thirst": "water_point",
	"hygiene": "shower",
	"enrichment": "fire_circle",
}


static func is_enrichment(space_type: String) -> bool:
	return space_type in ENRICHMENT_TYPES

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
}


static func color(space_type: String) -> Color:
	return COLORS.get(space_type, Color(0.7, 0.75, 0.8)) as Color


static func icon(space_type: String) -> String:
	return str(ICONS.get(space_type, "?"))


static func is_valid(space_type: String) -> bool:
	return space_type in TYPES


static func label(space_type: String) -> String:
	return str(LABELS.get(space_type, space_type.capitalize()))
