// ============================================================================
// LinkageLab HARDWARE-DETAIL reference-value generator for
// core/linkage/linkage_selftest.gd (_test_hw_layout_reference).
//
// Runs the REAL web-app hardware layout maths (js/linkage/hardware-detail.js
// from the sibling LinkageLab repo) headlessly in node and prints the numbers
// the GDScript port (LinkageHwLayout) pins against: per-axis layouts
// (base_start / part_base / len / rank), origins, spans, sandwich gaps,
// centre offsets, bracket hole heights and part axial lengths — for every
// DEFAULT assembly. Re-run whenever the upstream hardware maths changes:
//
//   node tools/linkage_hw_reference.mjs [path-to-LinkageLab-repo]
//
// Default repo path: ../LinkageLab relative to this repo root.
//
// TWO outputs. Part 1 prints the axis-layout JSON to stdout (paste into
// _test_hw_layout_reference's HW_REF). Part 2 WRITES
// core/linkage/testdata/hw_placement_ref.json in place — the placement frames
// pinned by _test_hw_placement_reference — so run this from the repo root.
//
// Unlike tools/linkage_reference.mjs (which mocks the hw* globals OFF to pin
// the hardware-disabled solver), this generator exercises the hardware module
// itself, with the default assemblies exactly as getDefaultHardwareAssemblies
// ships them.
// ============================================================================

import { pathToFileURL } from 'url';
import path from 'path';
import fs from 'fs';

const repo = process.argv[2] || path.join(process.cwd(), '..', 'LinkageLab');
const mod = (p) => import(pathToFileURL(path.join(repo, 'js', 'linkage', p)).href);
const modCore = (p) => import(pathToFileURL(path.join(repo, 'js', 'core', p)).href);

// --- Browser stubs -----------------------------------------------------------
// hardware-detail.js and its import chain (config-persistence, project-store,
// feedback) touch document / window / localStorage at call time; the layout
// functions we exercise do not, but module evaluation must not explode.
const nullEl = () => null;
globalThis.document = {
    getElementById: nullEl,
    querySelector: nullEl,
    querySelectorAll: () => [],
    createElement: () => ({ style: {}, classList: { add() {}, remove() {} },
        addEventListener() {}, setAttribute() {}, appendChild() {} }),
    addEventListener() {},
    body: { appendChild() {}, removeChild() {}, style: {} },
};
globalThis.window = globalThis;
globalThis.addEventListener = () => {};
globalThis.removeEventListener = () => {};
globalThis.localStorage = { getItem: () => null, setItem() {}, removeItem() {} };
globalThis.requestAnimationFrame = () => 0;
// Minimal THREE: hwGetPartStackContext and friends construct Vector3s.
class V3 {
    constructor(x = 0, y = 0, z = 0) { this.x = x; this.y = y; this.z = z; }
    set(x, y, z) { this.x = x; this.y = y; this.z = z; return this; }
    copy(v) { this.x = v.x; this.y = v.y; this.z = v.z; return this; }
    clone() { return new V3(this.x, this.y, this.z); }
    normalize() {
        const l = Math.hypot(this.x, this.y, this.z) || 1;
        this.x /= l; this.y /= l; this.z /= l; return this;
    }
    addScaledVector(v, s) { this.x += v.x * s; this.y += v.y * s; this.z += v.z * s; return this; }
    add(v) { this.x += v.x; this.y += v.y; this.z += v.z; return this; }
    sub(v) { this.x -= v.x; this.y -= v.y; this.z -= v.z; return this; }
    applyQuaternion() { return this; }
}
globalThis.THREE = {
    Vector3: V3,
    Quaternion: class { setFromAxisAngle() { return this; } multiply() { return this; } },
    Plane: class { constructor() { this.constant = 0; } },
};

// --- Minimal state (mirrors linkage_reference.mjs, hardware ON) --------------
globalThis.state = {
    modules: 8, hLengthFt: 8.0, vLengthFt: 8.0, pivotPct: 41.5,
    vertEndOffset: 1.5, hStackCount: 2, vStackCount: 3,
    hBeamW: 3.5, hBeamT: 1.5, vBeamW: 1.5, vBeamT: 3.5,
    vBeamOuterW: 1.5, vBeamOuterT: 3.5,
    bracketZRotation: 0, boltDiameter: 0.375,
    showHardwareFullDetail: true,
    hwDetailMode: false,
    hardwareAssemblies: null,   // seeded from the module's own defaults below
};

const hw = await mod('hardware-detail.js');
// hwComputeAxisLayout itself is not exported; hwGetPartStackContext wraps it
// and exposes everything the pins need (stackBase / stackOrigin / rank).
const {
    getDefaultHardwareAssemblies, ensureHardwareAssemblies,
    hwGetAssemblySandwichGap,
    // hwSumCenterAxisGap is the exported back-compat alias for the centre span.
    hwSumCenterAxisGap, hwGetBracketHoleY, hwGetPartAxialLength,
    hwGetPartStackContext, hwAxisPosFromPart,
} = hw;

state.hardwareAssemblies = getDefaultHardwareAssemblies();
ensureHardwareAssemblies();

const AXES = ['up', 'down', 'right', 'left', 'center'];
const HW_HORIZONTAL_AXES = ['right', 'left', 'front', 'back'];
const round = (v) => +Number(v).toFixed(9);

const out = { assemblies: {} };
for (const [id, asm] of Object.entries(state.hardwareAssemblies.assemblies)) {
    const bracketPart = asm.parts.find((p) => p.type === 'bracket');
    const holeY = bracketPart ? hwGetBracketHoleY(bracketPart) : 0;
    const entry = {
        sandwich_gap: round(hwGetAssemblySandwichGap(asm)),
        center_span: round(hwSumCenterAxisGap(asm)),
        bracket_hole_y: round(holeY),
        axes: {},
        parts: {},
    };
    for (const part of asm.parts) {
        entry.parts[part.id] = round(hwGetPartAxialLength(part));
    }
    for (const axis of AXES) {
        const parts = asm.parts
            .filter((p) => p.type !== 'bracket' && (p.axis || 'right') === axis)
            .sort((a, b) => (a.seq || 0) - (b.seq || 0));
        if (!parts.length) continue;
        const axisEntry = { items: [] };
        for (const part of parts) {
            // Final assembled placement, exactly as hwLayoutAxisParts computes
            // it: blended start (explode 0 => base), centred on the part's
            // axial midpoint, plus the bracket-hole lift on horizontal chains.
            const ctx = hwGetPartStackContext(part, asm, 0);
            if (!ctx) continue;
            const axisPos = hwAxisPosFromPart(part, ctx);
            let crossPos = part.crossOffset || 0;
            if (HW_HORIZONTAL_AXES.includes(ctx.renderAxis) && bracketPart) {
                crossPos += holeY;
            }
            axisEntry.origin = round(ctx.stackOrigin);
            axisEntry.center = !!ctx.center;
            axisEntry.items.push({
                id: part.id,
                part_base: round(ctx.stackBase),
                len: round(hwGetPartAxialLength(part)),
                rank: ctx.rank,
                axis_pos_centered: round(axisPos),
                cross_pos: round(crossPos),
                render_axis: ctx.renderAxis,
            });
        }
        if (axisEntry.items.length) entry.axes[axis] = axisEntry;
    }
    out.assemblies[id] = entry;
}

console.log(JSON.stringify(out, null, 2));

// ============================================================================
// PART 2 — placement frames (pins _test_hw_placement_reference)
//
// Where each detailed assembly SITS on the solved structure: the anchor point,
// the per-joint orientation basis, and the flipStackAxis decision. These pin
// LinkageHwPlacement, which the port originally got wrong three ways at once
// (anchored on the H-ring pivot instead of the V-stack pivot, no flipStackAxis,
// and an hCenter frame yawed 90 degrees).
//
// THE CONFIGURATION BELOW IS LOAD-BEARING. `hwDetailMode: true` makes
// hwAssemblyEnabled return true for every detailed assembly regardless of
// showHardwareFullDetail (hardware-detail.js:1760), so placements are emitted;
// `showHardwareFullDetail: false` keeps hwIsDetailStructureSpacingActive false
// (hw-structure-spacing.js:98), so the assemblies do NOT rewrite stack gaps and
// the beams stay byte-identical to linkage_reference.mjs's own `cyl_default`.
// That is the exact arrangement linkage_hardware_modal.gd solves its placement
// frame with. Any other combination re-pins these numbers to a structure that
// is not the one the rest of the suite describes — the cornerSum printed with
// each case exists so that can be checked rather than assumed.
// ============================================================================

// The layout dump above ran on a deliberately minimal state; the solver needs
// the full one. Rebuild it here rather than widening the state above, so the
// Part 1 numbers cannot shift as a side effect.
function makePlacementState() {
    return {
        modules: 8, hLengthFt: 8.0, vLengthFt: 8.0, pivotPct: 41.5,
        hobermanAng: 0.0, pivotAng: 0.0,
        hStackCount: 2, vStackCount: 3, vStackReverse: false,
        offsetTopIn: 1.5, offsetBotIn: 1.5, vertEndOffset: 1.5,
        hStackGap: 0.0, vStackGap: 0.0,
        hBeamW: 3.5, hBeamT: 1.5, vBeamW: 1.5, vBeamT: 3.5,
        vBeamDimensionsLinked: true,
        vBeamInnerW: 1.5, vBeamInnerT: 3.5, vBeamOuterW: 1.5, vBeamOuterT: 3.5,
        bracketWidth: 2.0, bracketDepth: 3.0, bracketHeight: 3.0,
        bracketWallThickness: 0.25, bracketInnerWidth: 1.5,
        bracketHoleDiameter: 0.375, bracketHoleDistance: 1.5, bracketZRotation: 0,
        boltDiameter: 0.375, vBoltLength: 3.0, vBoltInnerLength: 3.0,
        vBoltOuterLength: 2.0, hBoltLength: 3.0, hPivotBoltLength: 4.0,
        vBoltAuto: false, hBoltAuto: false, hPivotBoltAuto: false,
        vWasherEnabled: false, hWasherEnabled: false,
        vWasherID: 0.4375, vWasherOD: 1.0, vWasherThickness: 0.0, vWasherAuto: false,
        hWasherID: 0.4375, hWasherOD: 1.0, hWasherThickness: 0.0, hWasherAuto: false,
        autoLumberPricing: false,
        refBeamWidth: 3.5, refBeamThick: 1.5, refBeamLength: 8, refBeamPrice: 5.48,
        costHBeam: 12, costVBeam: 10, costBolt: 0.75, costBracket: 5, costSolarPanel: 150,
        woodDensity: 0.018, weightBracket: 0.5, weightBolt: 0.01,
        foldAngle: 135.4 * Math.PI / 180,
        isRing: false, enforceCollision: false, hasCollision: false,
        // Brackets AND bolts on: the V joints come off the bracket array, the
        // centre joints off the crossing bolts.
        showBrackets: true, showBolts: true,
        showHardwareFullDetail: false, hwDetailMode: true,
        orientation: 'horizontal', archCapUprights: false, useFixedBeams: false,
        fixedBeamLength: null, fixedBeamHeight: null,
        structureRotation: 0, archFlipVertical: false, archRotation: 0, arrayCount: 1,
        supportBeams: { enabled: false, showRadial: false },
        light: { x: 0, y: -1, z: 0 },
        animation: {
            playing: false, stopAngle: null, minFoldAngle: null,
            radialVisibleAngle: 90, rcpVisibleAngle: 90, panelsVisibleAngle: null,
            cachedClosedAngle: undefined, cachedModules: null, cachedPivotPct: null,
        },
        solarPanels: { enabled: false, topPanels: {}, sidePanels: {} },
        measurePoints: [], collisions: [], history: [], historyIndex: -1,
        hardwareAssemblies: null,
    };
}

// Wire the REAL gating functions. linkage_reference.mjs mocks these OFF because
// it pins the hardware-disabled solver; this file is the opposite pin, so it
// must use the genuine article. hwResolveStructureSpacing stays undefined —
// the solver's own typeof guard then falls back to the state gaps, which is
// what showHardwareFullDetail:false means anyway.
globalThis.hwAssemblyEnabled = hw.hwAssemblyEnabled;
globalThis.hwAnyAssemblyEnabled = hw.hwAnyAssemblyEnabled;
globalThis.hwAssemblyHasParts = hw.hwAssemblyHasParts;
globalThis.hwUseFullDetailAssemblies = hw.hwUseFullDetailAssemblies;
globalThis.hwUseInnerDetailAssemblies = hw.hwUseInnerDetailAssemblies;
globalThis.hwAddAssemblyPlacement = hw.hwAddAssemblyPlacement;

await mod('constants.js');
await mod('math.js');
await mod('geometry-classes.js');
await mod('beam-bolt-helpers.js');
const jk = await mod('joint-kinematics.js');
const solver = await mod('solver.js');

const r9 = (x) => +Number(x).toFixed(9);
const jv3 = (v) => [r9(v.x), r9(v.y), r9(v.z)];

// Anchor identity, computed by hand rather than through THREE. This IS the
// expression hwComputeAssemblyTransform evaluates on its vBoltPivot branch
// (hardware-detail.js:2091-2096): back the assembly origin off the pivot by the
// bracket's hole height along the rotated up axis, then apply the bracket's own
// local nudge in the same rotated frame. Doing it directly avoids teaching the
// THREE stub about Matrix4 and Quaternion, and it is the identity the GDScript
// implements, so a divergence shows up as a failing pin rather than as two
// stubs agreeing with each other.
function assemblyOrigin(pl, asm) {
    const F = pl.frame;
    const p = pl.vBoltPivot || pl.pos;
    const bracket = (asm.parts || []).find((q) => q.type === 'bracket');
    if (!bracket) return { x: p.x, y: p.y, z: p.z };
    const holeY = hwGetBracketHoleY(bracket);
    const bp = bracket.params || {};
    const nx = bp.posX || 0, ny = bp.posY || 0, nz = bp.posZ || 0;
    // basis * (nx, ny, nz) - basis * (0, holeY, 0), columns x/y/z.
    return {
        x: p.x + F.x.x * nx + F.y.x * (ny - holeY) + F.z.x * nz,
        y: p.y + F.x.y * nx + F.y.y * (ny - holeY) + F.z.y * nz,
        z: p.z + F.x.z * nx + F.y.z * (ny - holeY) + F.z.z * nz,
    };
}

// Deterministic order, matching the GDScript side's sort. moduleIndex first so
// the two centre joints of a module stay adjacent; y, x and then z separate a
// module's rings and its two radial lines. All THREE coordinates are needed:
// the arch's mirrored pairs sit at the same height and the same x, differing
// only in z, and leaving z out made row i mean a different joint on each side.
function placementKey(pl, origin) {
    const c = (v) => v.toFixed(4).padStart(14, '0');
    return [
        pl.assemblyId,
        String(pl.moduleIndex ?? -1).padStart(4, '0'),
        pl.isBottom ? '0' : '1',
        c(origin.y), c(origin.x), c(origin.z),
    ].join('|');
}

const placementCases = [
    { id: 'cyl_default', apply: () => {} },
    { id: 'cyl_reversed', apply: (s) => { s.vStackReverse = true; } },
    {
        id: 'cyl_centers',
        // vCenter ships empty, so nothing is stamped at the V crossing until a
        // part exists there. One washer is enough to turn the joint on.
        apply: (s) => {
            const vc = s.hardwareAssemblies.assemblies.vCenter;
            vc.parts.push({
                id: 'vc-w1', type: 'washer', label: 'Centre washer', axis: 'center',
                seq: 1, qty: 1, perModule: 1, cost: 0.1,
                params: { id: 0.3125, od: 1.0, thickness: 0.0625 },
                posAssembled: 0, posExploded: 0, crossOffset: 0, flipAxis: false,
            });
        },
    },
    {
        id: 'cyl_nudge',
        // The bracket's local nudge must be applied in the ROTATED frame, not
        // world axes — a nudge of zero cannot tell the two apart.
        apply: (s) => {
            const b = s.hardwareAssemblies.assemblies.outerVBeam.parts
                .find((q) => q.type === 'bracket');
            b.params.posX = 0.13; b.params.posY = -0.07; b.params.posZ = 0.21;
        },
    },
    {
        id: 'arch_caps',
        apply: (s) => {
            s.orientation = 'vertical';
            s.archCapUprights = true;
            s.modules = 6;
        },
    },
];

const placementOut = {
    _note: 'GENERATED by tools/linkage_hw_reference.mjs from the real LinkageLab '
        + 'web app. Do not hand-edit. Pinned by _test_hw_placement_reference. '
        + 'Solved with showHardwareFullDetail=false + hwDetailMode=true, which '
        + 'emits placements while leaving the beams identical to '
        + "linkage_reference.mjs's cyl_default (compare corner_sum).",
    cases: {},
};

for (const c of placementCases) {
    const s = makePlacementState();
    globalThis.state = s;
    s.hardwareAssemblies = getDefaultHardwareAssemblies();
    ensureHardwareAssemblies();
    c.apply(s);

    s.animation.cachedClosedAngle = undefined;
    s.animation.cachedModules = null;
    s.animation.cachedPivotPct = null;
    // The solver logs per-module diagnostics; muzzle it so the output pastes.
    const realLog = console.log;
    console.log = () => {};
    const closed = jk.getOptimalClosedAngleForAnimation();
    s.foldAngle = closed;
    const data = solver.solveLinkage(closed);
    console.log = realLog;

    // Proof the beams did not move: diff this against linkage_reference.mjs's
    // own cornerSum for the same configuration.
    let cs = { x: 0, y: 0, z: 0 }, n = 0;
    for (const b of data.beams) {
        for (const q of b.corners) { cs.x += q.x; cs.y += q.y; cs.z += q.z; n++; }
    }

    // In detail mode the web emits a placement even for a PARTLESS assembly and
    // then renders nothing at it (buildHardwareAssemblyGroup bails on an empty
    // parts list, scene-render.js:163). LinkageHwPlacement skips those outright
    // — same result, one fewer empty seat — so drop them here to keep the two
    // sides directly comparable. `cyl_centers` is the case that gives vCenter a
    // part and therefore a seat.
    const pls = (data.hardwareAssemblyPlacements || [])
        .filter((pl) => {
            const a = state.hardwareAssemblies.assemblies[pl.assemblyId];
            return a && a.detailed !== false && (a.parts || []).length > 0;
        })
        .map((pl) => {
            const asm = state.hardwareAssemblies.assemblies[pl.assemblyId];
            const origin = assemblyOrigin(pl, asm);
            return { pl, asm, origin, key: placementKey(pl, origin) };
        });
    pls.sort((a, b) => (a.key < b.key ? -1 : a.key > b.key ? 1 : 0));

    const rows = [];
    for (const { pl, origin } of pls) {
        const stackReversed = !!state.vStackReverse;
        const role = pl.pivotRole;
        const flip = role === 'center' ? false
            : pl.assemblyId === 'innerVBeam' ? ((role === 'inner') !== stackReversed)
            : (pl.isBottom !== stackReversed);
        // Two hCenter frames the port deliberately does not pin. In both cases
        // the GDScript still pins the ORIGIN and asserts orthonormality — only
        // the basis columns are skipped, and `skip_basis` records why.
        //
        //  · degenerate — module 0 is built AT the construction origin, so its
        //    radial is (0,0) and the direction that survives is float noise.
        //    JS doubles and Godot float32 cannot agree, and there is no right
        //    answer to agree on.
        //  · arch — the web hardcodes world up as the hCenter stack axis on the
        //    claim that the H-ring bolt never tilts (solver.js:2790), but the
        //    arch's 90 degree X-rotation makes that bolt horizontal, so every
        //    arch hCenter joint collapses to the same +-X yaw. The port takes
        //    the axis from the bolt's own (correctly transformed) direction
        //    instead. Identical in cylinder mode; better here.
        const p = pl.vBoltPivot || pl.pos;
        let skip_basis = '';
        if (pl.assemblyId === 'hCenter') {
            if (Math.hypot(p.x, p.z) < 1e-6) skip_basis = 'degenerate';
            else if (state.orientation === 'vertical') skip_basis = 'arch';
        }
        rows.push({
            id: pl.assemblyId, role, module: pl.moduleIndex ?? -1,
            bottom: !!pl.isBottom, flip, skip_basis,
            pivot: jv3(p), origin: jv3(origin),
            bx: jv3(pl.frame.x), by: jv3(pl.frame.y), bz: jv3(pl.frame.z),
        });
    }
    placementOut.cases[c.id] = {
        closed_angle: r9(closed),
        corner_sum: jv3(cs),
        n_corners: n,
        placements: rows,
    };
    process.stderr.write(`  ${c.id}: ${rows.length} placements, `
        + `cornerSum=(${jv3(cs).join(', ')})\n`);
}

const refPath = path.join(process.cwd(), 'core', 'linkage', 'testdata',
    'hw_placement_ref.json');
fs.writeFileSync(refPath, JSON.stringify(placementOut, null, '\t') + '\n');
process.stderr.write(`wrote ${refPath}\n`);
