class_name StructureMaterials
extends Object

## Shared PBR material facade for parametrically generated structures, machines,
## enclosures and vehicles. Delegates to `ParametricMaterialLibrary`, which
## supplies rich procedural + CC0 + user-uploaded PBR maps (albedo grain,
## tangent-space normals, micro-roughness, AO and clearcoat) and live-updates
## every existing `StandardMaterial3D` in the world when tuned in
## `MaterialLibraryModal`.
##
## Enum indices `0..12` are preserved verbatim; new finishes are appended.

enum Kind {
	PAINTED_METAL,
	HARDWARE_METAL,
	WOOD,
	PLYWOOD,
	PANEL,
	GALVANISED,
	ALUMINIUM,
	PLASTIC,
	GLAZING,
	FABRIC,
	WEATHERING_STEEL,
	STAINLESS,
	RUBBER,
	COPPER,
	BRASS_BRONZE,
	CORRUGATED_METAL,
	REFLECTOR,
	PMMA,
	CONCRETE,
	CAR_PAINT,
}


static func id_for_kind(kind: int) -> String:
	match kind:
		Kind.PAINTED_METAL: return "powder_coat"
		Kind.HARDWARE_METAL: return "hardware_steel"
		Kind.WOOD: return "lumber"
		Kind.PLYWOOD: return "plywood"
		Kind.PANEL: return "pv_cell"
		Kind.GALVANISED: return "galvanised"
		Kind.ALUMINIUM: return "aluminium"
		Kind.PLASTIC: return "plastic"
		Kind.GLAZING: return "glass"
		Kind.FABRIC: return "fabric"
		Kind.WEATHERING_STEEL: return "corten"
		Kind.STAINLESS: return "stainless"
		Kind.RUBBER: return "rubber"
		Kind.COPPER: return "copper"
		Kind.BRASS_BRONZE: return "brass_bronze"
		Kind.CORRUGATED_METAL: return "metal_roofing"
		Kind.REFLECTOR: return "reflector"
		Kind.PMMA: return "pmma"
		Kind.CONCRETE: return "concrete"
		Kind.CAR_PAINT: return "car_paint"
	return "powder_coat"


static func make(kind: int, base_color: Color, world_triplanar: bool = false) -> StandardMaterial3D:
	return ParametricMaterialLibrary.make(id_for_kind(kind), base_color, {"world_triplanar": world_triplanar})


static func make_by_id(mat_id: String, base_color: Color, opts: Dictionary = {}) -> StandardMaterial3D:
	return ParametricMaterialLibrary.make(mat_id, base_color, opts)


## Infer the closest library material ID from legacy `(color, metallic, roughness)` triples
## used by older builders (`BattBuilder`, `ShowerHouseBuilder`, `ToiletBankBuilder`, etc.).
static func infer_id(col: Color, metallic: float, roughness: float, alpha: float = 1.0) -> String:
	if alpha < 0.88 or roughness <= 0.14:
		return "pmma" if metallic < 0.2 else "reflector"
	if metallic >= 0.72:
		if col.r > col.b * 1.45 and col.r > 0.65:
			return "copper" if col.r > col.g * 1.22 else "brass_bronze"
		return "aluminium" if roughness < 0.42 else "galvanised"
	if metallic >= 0.45:
		return "galvanised" if roughness >= 0.48 else "hardware_steel"
	if metallic >= 0.08:
		return "powder_coat"
	if roughness >= 0.86:
		if col.r > col.b * 1.35 and col.g > col.b * 1.12:
			return "lumber"
		return "rubber" if (col.r + col.g + col.b) < 0.75 else "concrete"
	if col.r > col.b * 1.35 and col.g > col.b * 1.12 and roughness >= 0.68:
		return "plywood" if (col.r + col.g) > 1.25 else "lumber"
	return "plastic"
