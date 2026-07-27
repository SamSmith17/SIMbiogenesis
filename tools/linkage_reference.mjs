// ============================================================================
// LinkageLab JS reference-value generator for core/linkage/linkage_selftest.gd
//
// Runs the REAL LinkageLab web-app solver (js/linkage/*.js from the sibling
// LinkageLab repo) headlessly in node and prints reference numbers that the
// GDScript port pins against. Re-run whenever the upstream solver changes:
//
//   node tools/linkage_reference.mjs [path-to-LinkageLab-repo]
//
// Default repo path: ../LinkageLab relative to this repo root.
// ============================================================================

import { pathToFileURL } from 'url';
import path from 'path';

const repo = process.argv[2] || path.join(process.cwd(), '..', 'LinkageLab');
const mod = (p) => import(pathToFileURL(path.join(repo, 'js', 'linkage', p)).href);

// --- Mock the hardware-detail globals the solver probes (all disabled) ------
globalThis.hwAnyAssemblyEnabled = () => false;
globalThis.hwUseFullDetailAssemblies = () => false;
globalThis.hwUseInnerDetailAssemblies = () => false;
globalThis.hwAssemblyEnabled = () => false;
globalThis.hwAssemblyHasParts = () => false;
globalThis.hwAddAssemblyPlacement = () => {};
// hwResolveStructureSpacing left undefined -> solver falls back to state gaps.

// --- Minimal state (defaults copied from app-state.js; washers OFF) ---------
function makeState() {
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
        showBrackets: true, showBolts: false, showHardwareFullDetail: false,
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
    };
}
globalThis.state = makeState();

// --- Import real modules (order matters: constants/math first) --------------
await mod('constants.js');
await mod('math.js');
await mod('geometry-classes.js');
await mod('beam-bolt-helpers.js');
const jk = await mod('joint-kinematics.js');
const solver = await mod('solver.js');

const f = (x) => Number(x).toFixed(9);
const v3s = (v) => `Vector3(${f(v.x)}, ${f(v.y)}, ${f(v.z)})`;
const v2s = (v) => `Vector2(${f(v.x)}, ${f(v.y)})`;

function resetAnimCache() {
    state.animation.cachedClosedAngle = undefined;
    state.animation.cachedModules = null;
    state.animation.cachedPivotPct = null;
}

console.log('# --- Joint positions (calculateJointPositions) ---');
const jointCases = [
    { fold: 135.4 * Math.PI / 180, hActiveIn: 93.0, pivotPct: 41.5, hoberman: 0, pivotAng: 0 },
    { fold: 90 * Math.PI / 180, hActiveIn: 93.0, pivotPct: 41.5, hoberman: 0, pivotAng: 0 },
    { fold: 60 * Math.PI / 180, hActiveIn: 80.0, pivotPct: 50.0, hoberman: 10.0, pivotAng: -5.0 },
    { fold: 170 * Math.PI / 180, hActiveIn: 120.0, pivotPct: 30.0, hoberman: -8.0, pivotAng: 12.0 },
];
for (const c of jointCases) {
    const r = jk.calculateJointPositions(c.fold, {
        hActiveIn: c.hActiveIn, pivotPct: c.pivotPct,
        hobermanAng: c.hoberman, pivotAng: c.pivotAng,
    });
    console.log(`case fold=${f(c.fold)} h=${c.hActiveIn} pct=${c.pivotPct} hob=${c.hoberman} pa=${c.pivotAng}`);
    console.log(`  bl=${v2s(r.joints.bl)} br=${v2s(r.joints.br)}`);
    console.log(`  tl=${v2s(r.joints.tl)} tr=${v2s(r.joints.tr)}`);
    console.log(`  rel=${f(r.relativeRotation)} act=${f(r.activeLength)} pas=${f(r.passiveLength)}`);
}

console.log('# --- Closed angle + min fold (default 8-module) ---');
resetAnimCache();
const closed8 = jk.getOptimalClosedAngleForAnimation();
console.log(`closed8=${f(closed8)}`);
const minFold8 = solver.computeMinFoldAngleVBeamOverlap();
console.log(`minFold8=${f(minFold8)}`);

state.modules = 12; state.pivotPct = 35.0; resetAnimCache();
console.log(`closed12_35=${f(jk.getOptimalClosedAngleForAnimation())}`);
state.modules = 8; state.pivotPct = 41.5; resetAnimCache();

// --- Full solve summaries ----------------------------------------------------
function summarize(label, data) {
    let cornerSum = { x: 0, y: 0, z: 0 };
    let nCorners = 0;
    const typeCounts = {};
    for (const b of data.beams) {
        typeCounts[b.stackType] = (typeCounts[b.stackType] || 0) + 1;
        for (const c of b.corners) { cornerSum.x += c.x; cornerSum.y += c.y; cornerSum.z += c.z; nCorners++; }
    }
    console.log(`solve ${label}:`);
    console.log(`  beams=${data.beams.length} brackets=${data.brackets.length} bolts=${data.bolts.length}`);
    console.log(`  types=${JSON.stringify(typeCounts)}`);
    console.log(`  maxRad=${f(data.maxRad)} maxHeight=${f(data.maxHeight)}`);
    console.log(`  cornerSum=${v3s(cornerSum)} nCorners=${nCorners}`);
    const b0 = data.beams[0];
    console.log(`  beam0 p1=${v3s(b0.p1)} p2=${v3s(b0.p2)} w=${f(b0.w)} t=${f(b0.t)} type=${b0.stackType}`);
    const bl = data.beams[data.beams.length - 1];
    console.log(`  beamN p1=${v3s(bl.p1)} p2=${v3s(bl.p2)} type=${bl.stackType}`);
    if (data.brackets.length) {
        const br0 = data.brackets[0];
        console.log(`  bracket0 pos=${v3s(br0.pos)} isBottom=${br0.isBottom}`);
        console.log(`  bracket0 basis x=${v3s(br0.basis.x)} y=${v3s(br0.basis.y)} z=${v3s(br0.basis.z)}`);
    }
    if (data.bolts.length) {
        const bo0 = data.bolts[0];
        console.log(`  bolt0 start=${v3s(bo0.start)} end=${v3s(bo0.end)} r=${f(bo0.radius)} type=${bo0.boltType}/${bo0.boltSubType ?? ''}`);
        let boltSum = { x: 0, y: 0, z: 0 };
        for (const b of data.bolts) { boltSum.x += b.center.x; boltSum.y += b.center.y; boltSum.z += b.center.z; }
        console.log(`  boltCenterSum=${v3s(boltSum)}`);
    }
}

console.log('# --- solveLinkage: default cylinder, brackets on, bolts off ---');
summarize('cyl_default', solver.solveLinkage(state.foldAngle));

console.log('# --- solveLinkage: cylinder with bolts on ---');
state.showBolts = true;
summarize('cyl_bolts', solver.solveLinkage(state.foldAngle));
state.showBolts = false;

console.log('# --- solveLinkage: cylinder with gaps + reversed stack (starshade-like) ---');
Object.assign(state, {
    pivotPct: 41.4, offsetTopIn: 1.75, offsetBotIn: 2.0, vertEndOffset: 1.0,
    hStackGap: 0.1, vStackGap: 0.45, vStackReverse: true,
    bracketWidth: 2.17, bracketDepth: 1.6, bracketHeight: 3.82,
    bracketWallThickness: 0.18, bracketInnerWidth: 1.8,
    bracketHoleDiameter: 0.3125, bracketHoleDistance: 2.69,
    boltDiameter: 0.5, vBoltLength: 6.4, hBoltLength: 3.0,
});
resetAnimCache();
summarize('cyl_starshade', solver.solveLinkage(134.9 * Math.PI / 180));

console.log('# --- solveLinkage: arch mode (vertical) with cap uprights ---');
globalThis.state = makeState();
Object.assign(state, { orientation: 'vertical', archCapUprights: true, modules: 6 });
resetAnimCache();
summarize('arch_caps', solver.solveLinkage(120 * Math.PI / 180));

console.log('# --- solveLinkage: arch array x3 ---');
state.arrayCount = 3;
summarize('arch_array3', solver.solveLinkage(120 * Math.PI / 180));

console.log('# --- solveLinkage: fixed beams cylinder ---');
globalThis.state = makeState();
Object.assign(state, { useFixedBeams: true });
resetAnimCache();
summarize('cyl_fixed', solver.solveLinkage(100 * Math.PI / 180));

console.log('# --- done ---');
