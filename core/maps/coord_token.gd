class_name CoordToken
extends RefCounted

## Stable lat/lon token for user:// sidecar filenames.


static func token(v: float) -> String:
	var s := "%.4f" % absf(v)
	return ("n" if v < 0.0 else "") + s.replace(".", "p")
