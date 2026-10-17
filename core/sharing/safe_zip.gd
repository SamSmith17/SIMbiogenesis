class_name SafeZip
extends RefCounted

## The one rule for reading a zip somebody else made: every entry must stay
## inside the folder it is extracted into. Shared by the OpenSCAD installer
## (a downloaded archive) and asset packs (a friend's archive) — both are
## untrusted, and a crafted entry such as "../../AppData/x" or "C:/x" would
## otherwise write anywhere on the disk.


## An entry is safe when it is relative and has no ".." segment, no absolute
## POSIX/Windows root, no drive letter and no UNC prefix.
static func entry_is_safe(entry: String) -> bool:
	if entry.is_empty():
		return false
	if entry.begins_with("/") or entry.begins_with("\\"):
		return false
	if entry.length() >= 2 and entry[1] == ":":
		return false
	var norm := entry.replace("\\", "/")
	for seg in norm.split("/", false):
		if seg == ".." or seg.contains(":"):
			return false
	return true


## The absolute target of `entry` under `dest_abs`, or "" when it would land
## outside it (a zip-slip that `entry_is_safe` did not catch).
static func target_under(dest_abs: String, entry: String) -> String:
	if not entry_is_safe(entry):
		return ""
	var root := dest_abs.replace("\\", "/").simplify_path().trim_suffix("/")
	var target := root.path_join(entry.replace("\\", "/")).simplify_path()
	if target == root or target.begins_with(root + "/"):
		return target
	return ""
