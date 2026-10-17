class_name GraphTheme
extends RefCounted

## The graph canvas's design tokens, derived from UITheme so the canvas and the
## rest of the UI speak one visual language. Card surfaces, the per-type accent
## (a node's identity colour), the Lucide icon per type, and the state colours.
##
## Accents follow what the thing IS, not an arbitrary palette: sun gold for
## generation from the sun, green for storage, violet for power electronics,
## amber for loads, water blue for water. Cyan is reserved for SELECTION — the
## old table gave panels the selection cyan, so a selected panel looked
## unselected.

const CARD_BG := Color(0.058, 0.078, 0.130, 0.97)
const CARD_HEADER := Color(0.085, 0.112, 0.180, 1.0)
const CARD_BORDER := Color(0.200, 0.262, 0.380, 0.95)
const CARD_SHADOW := Color(0.0, 0.0, 0.0, 0.38)
const CARD_TRACK := Color(0.11, 0.14, 0.21, 1.0)
const TEXT := UITheme.C_TEXT
const TEXT_DIM := UITheme.C_TEXT_S
const TEXT_MUTED := UITheme.C_TEXT_M
const SELECTED := UITheme.C_PRIMARY
const OK := GraphNodeState.C_RUNNING
const WARN := GraphNodeState.C_OVERFLOW
const ERROR := UITheme.C_ERROR

const ACCENTS := {
	"panel": Color(1.00, 0.78, 0.26),
	"wind": Color(0.36, 0.84, 0.78),
	"hydro": Color(0.25, 0.62, 0.95),
	"battery": Color(0.20, 0.86, 0.52),
	"smartbattery": Color(0.20, 0.86, 0.52),
	"controller": Color(0.62, 0.52, 1.00),
	"appliance": Color(0.98, 0.62, 0.20),
	"acload": Color(0.98, 0.62, 0.20),
	"processor": Color(0.70, 0.58, 0.95),
	"resource": Color(0.30, 0.66, 0.98),
	"compound": Color(0.56, 0.62, 0.78),
}

const ICONS := {
	"panel": "sun", "wind": "wind", "hydro": "waves",
	"battery": "battery", "smartbattery": "battery", "controller": "cpu",
	"appliance": "plug", "acload": "plug", "processor": "hammer",
	"resource": "droplet", "compound": "layers",
}

## Small-caps type chip text per type ("" = no chip).
const CHIPS := {
	"panel": "PV", "wind": "WIND", "hydro": "HYDRO", "battery": "BATTERY",
	"smartbattery": "BATTERY", "controller": "CONTROLLER", "appliance": "LOAD",
	"acload": "LOAD", "processor": "MACHINE", "compound": "GROUP",
}


static func accent(itype: String) -> Color:
	return ACCENTS.get(itype, UITheme.C_TEXT_S)


static func icon(itype: String) -> String:
	return str(ICONS.get(itype, "box"))


static func chip(itype: String) -> String:
	return str(CHIPS.get(itype, ""))
