class_name MpTransfer
extends RefCounted

## Chunked reliable payload transfer helpers for multiplayer design packages.

const CHUNK_BYTES := 12_000
const MAX_PAYLOAD_BYTES := 2_500_000


static func encode_dict(data: Dictionary) -> Dictionary:
	var raw := JSON.stringify(data).to_utf8_buffer()
	if raw.size() > MAX_PAYLOAD_BYTES:
		return {"ok": false, "error": "Payload too large (%d bytes)" % raw.size()}
	var compressed := raw.compress(FileAccess.COMPRESSION_GZIP)
	return {
		"ok": true,
		"bytes": compressed,
		"raw_size": raw.size(),
		"compressed_size": compressed.size(),
	}


static func decode_bytes(compressed: PackedByteArray) -> Dictionary:
	if compressed.is_empty():
		return {"ok": false, "error": "Empty payload"}
	var raw := compressed.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
	if raw.is_empty():
		return {"ok": false, "error": "Decompress failed"}
	var parsed: Variant = JSON.parse_string(raw.get_string_from_utf8())
	if not (parsed is Dictionary):
		return {"ok": false, "error": "Invalid JSON payload"}
	return {"ok": true, "data": parsed as Dictionary}


static func chunk_bytes(bytes: PackedByteArray) -> Array:
	var out: Array = []
	if bytes.is_empty():
		return out
	var i := 0
	while i < bytes.size():
		var end := mini(i + CHUNK_BYTES, bytes.size())
		out.append(bytes.slice(i, end))
		i = end
	return out


static func assemble_chunks(chunks: Dictionary, total: int) -> PackedByteArray:
	## chunks: index(int) -> PackedByteArray
	if total <= 0:
		return PackedByteArray()
	var parts: Array = []
	parts.resize(total)
	for idx in range(total):
		if not chunks.has(idx):
			return PackedByteArray()
		parts[idx] = chunks[idx]
	var out := PackedByteArray()
	for p in parts:
		out.append_array(p as PackedByteArray)
	return out
