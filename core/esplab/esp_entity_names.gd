class_name EspEntityNames
extends RefCounted

## The ONE naming contract between the YAML the designer writes, the twin
## that simulates it and the matcher that finds the real board in Home
## Assistant.
##
## ESPHome gives each entity `has_entity_name`, and Home Assistant builds the
## entity_id as  <domain>.<slugify(device name + " " + entity name)>  where
## the device name is the node's `friendly_name`. HA's slugify (python-slugify
## with separator "_"): lowercase, transliterate, every run of characters that
## is not a-z / 0-9 becomes one "_", no leading or trailing "_".
##
## The node `name` (hostname) is a separate rule: lowercase a-z, 0-9 and "-",
## at most 24 characters so the MAC suffix still fits a 31-character hostname.

const NODE_MAX := 24

const _TRANSLIT := {
	"ä": "a", "à": "a", "á": "a", "â": "a", "ã": "a", "å": "a", "æ": "ae", "ç": "c",
	"è": "e", "é": "e", "ê": "e", "ë": "e", "ì": "i", "í": "i", "î": "i", "ï": "i",
	"ñ": "n", "ò": "o", "ó": "o", "ô": "o", "õ": "o", "ö": "o", "ø": "o", "ù": "u",
	"ú": "u", "û": "u", "ü": "u", "ý": "y", "ß": "ss", "²": "2", "³": "3", "₂": "2", "₃": "3", "µ": "u",
}


## Home Assistant's slugify, as used for entity ids.
static func ha_slug(s: String) -> String:
	var o := ""
	var gap := false
	for ch in s.to_lower():
		var c: String = _TRANSLIT.get(ch, ch)
		for sub in c:
			var u := sub.unicode_at(0)
			if (u >= 97 and u <= 122) or (u >= 48 and u <= 57):
				if gap and o != "":
					o += "_"
				gap = false
				o += sub
			else:
				gap = true
	return o if o != "" else "unknown"


## The ESPHome node (hostname) name for a friendly name.
static func node_name(friendly: String) -> String:
	var o := ""
	for ch in friendly.to_lower():
		var c: String = _TRANSLIT.get(ch, ch)
		for sub in c:
			var u := sub.unicode_at(0)
			if (u >= 97 and u <= 122) or (u >= 48 and u <= 57):
				o += sub
			elif not o.ends_with("-") and o != "":
				o += "-"
	o = o.trim_suffix("-")
	if o.length() > NODE_MAX:
		o = o.substr(0, NODE_MAX).trim_suffix("-")
	return o if o != "" else "esp-board"


## The entity name an instance's entity gets in YAML ("BME280 Temperature").
static func entity_name(inst_label: String, ent_name: String) -> String:
	if ent_name == "":
		return inst_label
	if inst_label == "" or inst_label.to_lower().ends_with(ent_name.to_lower()):
		return ent_name if inst_label == "" else inst_label
	return "%s %s" % [inst_label, ent_name]


## The entity_id Home Assistant gives it.
static func entity_id(domain: String, friendly: String, name: String) -> String:
	return "%s.%s" % [domain, ha_slug("%s %s" % [friendly, name])]


## An ESPHome id (C++ identifier) for an instance's entity.
static func esphome_id(iid: String, k: String) -> String:
	var s := ha_slug("%s_%s" % [iid, k])
	if s[0] >= "0" and s[0] <= "9":
		s = "e_" + s
	return s
