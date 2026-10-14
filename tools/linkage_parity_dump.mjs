// ============================================================================
// LinkageLab -> game PARITY fixtures (LINKAGE_PARITY.md)
//
// Runs the REAL LinkageLab web app (a git ref of the sibling repo, default
// `main`) inside its OWN test environment — vitest + happy-dom + its
// tests/setup.js — and writes one JSON per shipped JS preset to
// core/linkage/testdata/parity/<preset>.json. The GDScript port pins against
// these files (linkage_selftest.gd, and the build-step / radial / coverings
// suites as those ports land).
//
//   node tools/linkage_parity_dump.mjs [path-to-LinkageLab] [git-ref]
//
// Why vitest and not the bare-node stubs `linkage_reference.mjs` uses: the
// modules this dump covers (geometry assembly, radial arrays, coverings, build
// steps) reach for `document`, `window` and a dozen bridged globals. The JS
// repo's own suite already provides exactly that environment, and a dump that
// runs where the JS tests run cannot drift from what those tests trust.
//
// The ref is EXPORTED (git archive) into a temp folder — the sibling repo's
// working tree is never checked out or touched. Its node_modules is junctioned
// in, so `npm install` must have been run in the sibling repo once.
// ============================================================================

import { execFileSync, spawnSync } from 'child_process';
import fs from 'fs';
import os from 'os';
import path from 'path';

const here = process.cwd();
const repo = path.resolve(process.argv[2] || path.join(here, '..', 'LinkageLab'));
const ref = process.argv[3] || 'main';
const outDir = path.join(here, 'core', 'linkage', 'testdata', 'parity');

const git = (...args) => execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8' }).trim();
const sha = git('rev-parse', ref);
const tmp = path.join(os.tmpdir(), `linkage_parity_${sha.slice(0, 10)}`);

if (!fs.existsSync(path.join(tmp, 'package.json'))) {
    fs.mkdirSync(tmp, { recursive: true });
    const tar = path.join(tmp, '_export.tar');
    git('archive', '--format=tar', '-o', tar, sha);
    // Relative paths: GNU tar (Git for Windows) reads "C:" as a remote host.
    execFileSync('tar', ['-xf', path.basename(tar)], { cwd: tmp });
    fs.rmSync(tar);
}
const nm = path.join(tmp, 'node_modules');
if (!fs.existsSync(nm)) {
    const src = path.join(repo, 'node_modules');
    if (!fs.existsSync(src)) {
        console.error(`no node_modules in ${repo} — run "npm install" there once`);
        process.exit(2);
    }
    fs.symlinkSync(src, nm, 'junction');
}

fs.mkdirSync(outDir, { recursive: true });
writePresets();
fs.writeFileSync(path.join(tmp, 'tests', 'zz-parity-dump.test.js'), SPEC());

const vitest = path.join(nm, 'vitest', 'vitest.mjs');
const r = spawnSync(process.execPath, [vitest, 'run', 'tests/zz-parity-dump.test.js'], {
    cwd: tmp,
    stdio: 'inherit',
    env: { ...process.env, PARITY_OUT: outDir, PARITY_SHA: sha, PARITY_REF: ref },
});
process.exit(r.status ?? 1);

// ---------------------------------------------------------------------------
// The JS presets, shipped as core/linkage/presets/ll_<name>.json.
//
// Everything a config carries is kept (the game's LinkageParams round-trips
// unknown keys losslessly) EXCEPT the export-time snapshots — the same list as
// LinkageParams.DERIVED_EXPORT_KEYS — which are derived, stale after any edit,
// and most of the file size (~1 MB -> ~70 KB for Constellation).
//
// The game's own `starshade_soak_2026.json` is NOT replaced: it is the Lab's
// default and carries hand-corrected values that tests pin (see
// LINKAGE_PARITY.md). The JS copy ships beside it under a distinct name.
// ---------------------------------------------------------------------------
function writePresets() {
    const DERIVED = ['timestamp', 'geometrySnapshot', 'hardwareAssemblyDebug', 'appVersion',
        'exportType', 'summary', 'schemaVersion', 'updatedAt', 'handoff', 'circuit'];
    const RENAME = { 'StarShade V1 - SOAK 2026': 'StarShade V1 - SOAK 2026 (LinkageLab)' };
    const presetDir = path.join(here, 'core', 'linkage', 'presets');
    const list = JSON.parse(fs.readFileSync(path.join(tmp, 'configs', 'presets.json'), 'utf8'));
    for (const p of list) {
        const cfg = JSON.parse(fs.readFileSync(path.join(tmp, 'configs', p.file), 'utf8'));
        for (const k of DERIVED) delete cfg[k];
        cfg.name = RENAME[p.name] || p.name;
        cfg.linkagelabSource = { file: p.file, sha };
        const slug = p.file.replace(/\.json$/i, '').replace(/[^\w.-]+/g, '_').toLowerCase();
        fs.writeFileSync(path.join(presetDir, `ll_${slug}.json`), JSON.stringify(cfg, null, '\t') + '\n');
        console.log(`preset ll_${slug}.json  (${cfg.name})`);
    }
}

// ---------------------------------------------------------------------------
// The spec, written into the exported tree's tests/ folder.
// ---------------------------------------------------------------------------
function SPEC() {
    return String.raw`
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it, beforeAll } from 'vitest';
import { createTestState } from './helpers/state-fixture.js';
import { collectParts, jointKey, partKey, resolveTargets } from '../js/linkage/part-keys.js';
import {
    generateDefaultBuildSteps, groupBeamsForBench, planBench, normalizeBuildSteps,
} from '../js/linkage/build-steps.js';
import { computeCoveringCutPlan, coveringBomItems, resetCoveringPlanCache } from '../js/linkage/coverings-plan.js';
import { shadeBomItems } from '../js/linkage/shade-cloth.js';
import { computeFloorBomContribution, describeFloorSeating } from '../js/linkage/floor-geometry.js';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const presets = JSON.parse(fs.readFileSync(path.join(root, 'configs', 'presets.json'), 'utf8'));
const OUT = process.env.PARITY_OUT;

let applyConfig, ensureHardwareAssemblies, getBeamBoltIntersections, buildLinkageGeometry;
// The REAL app's defaults (app-state.js), deep-copied before anything mutates
// them. tests/helpers/state-fixture.js is a unit-test fixture, not the app: it
// lacks e.g. vBoltInnerLength / vBoltOuterLength, so JS fell back to the full
// V-bolt length there and drilled holes the app never drills.
let APP_DEFAULTS;
let getStructureFoldedAngle, getStructureDeployedAngle;

beforeAll(async () => {
    globalThis.resetSupportBeamsToDefaults = () => {};
    globalThis.applyLegacyPanelsSupport = () => {};
    globalThis.applySupportBeamsConfig = (cfg) => { Object.assign(globalThis.state.supportBeams, cfg); };
    globalThis.getOptimalClosedAngleForAnimation = () => 0;
    globalThis.invalidateGeometryCache = () => {};
    globalThis.threeRenderer = null;
    await import('../js/linkage/beam-bolt-helpers.js');
    const hw = await import('../js/linkage/hardware-detail.js');
    ensureHardwareAssemblies = hw.ensureHardwareAssemblies || globalThis.ensureHardwareAssemblies;
    // tests/setup.js MOCKS hwResolveStructureSpacing to the legacy gaps; the
    // real module bridges the real one over it, so full-detail designs get the
    // assembly-driven stack gaps and bracket the app solves with.
    await import('../js/linkage/hw-structure-spacing.js');
    // app-state.js must load after hardware-detail.js (its header says so).
    const appState = await import('../js/linkage/app-state.js');
    APP_DEFAULTS = structuredClone(appState.state);
    ({ applyConfig } = await import('../js/linkage/config-persistence.js'));
    ({ getBeamBoltIntersections } = await import('../js/linkage/renderer-3d.js'));
    ({ buildLinkageGeometry } = await import('../js/linkage/linkage-geometry.js'));
    ({ getStructureFoldedAngle, getStructureDeployedAngle } = await import('../js/linkage/geometry-classes.js'));
    // tests/setup stubs the closed-angle scan to 0 (a flat ring); the app uses
    // the real one for the deployed pose, applyConfig's stop angle and steps.
    const jk = await import('../js/linkage/joint-kinematics.js');
    globalThis.getOptimalClosedAngleForAnimation = jk.getOptimalClosedAngleForAnimation;
});

const r4 = (v) => (typeof v === 'number' && Number.isFinite(v)) ? Math.round(v * 1e4) / 1e4 : v;
const deg = (rad) => r4((rad * 180) / Math.PI);
const vec = (p) => p ? [r4(p.x), r4(p.y), r4(p.z)] : null;

// Strip the volatile id (random per generation) and round numbers deep.
function clean(v) {
    if (Array.isArray(v)) return v.map(clean);
    if (v && typeof v === 'object') {
        const o = {};
        for (const k of Object.keys(v)) { if (k !== 'id') o[k] = clean(v[k]); }
        return o;
    }
    return r4(v);
}

function solveStats(data) {
    const n = (a) => (Array.isArray(a) ? a.length : 0);
    const byType = {};
    for (const b of data.beams || []) byType[b.stackType || '?'] = (byType[b.stackType || '?'] || 0) + 1;
    return {
        beams: n(data.beams), baseBeams: n(data.baseBeams), brackets: n(data.brackets),
        bolts: n(data.bolts), washers: n(data.washers), placements: n(data.hwPlacements || data.placements),
        panels: n(data.solarPanels || data.panels), beamsByStackType: byType,
        maxRad: r4(data.maxRad), maxHeight: r4(data.maxHeight),
    };
}

// Mirrors build-steps-ui.js buildGenerationInput: a drill solve with legacy
// bolts, then the configured solve, both at the deployed angle.
function generationInput() {
    const st = globalThis.state;
    const prev = { bolts: st.showBolts, full: st.showHardwareFullDetail, mode: st.hwDetailMode };
    let data, drillBolts;
    try {
        const deployedRad = getStructureDeployedAngle();
        st.showBolts = true;
        st.showHardwareFullDetail = false;
        st.hwDetailMode = false;
        drillBolts = buildLinkageGeometry({ useCache: false, foldAngle: deployedRad, includePanels: false }).bolts || [];
        st.showHardwareFullDetail = prev.full;
        st.hwDetailMode = prev.mode;
        data = buildLinkageGeometry({ useCache: false, foldAngle: deployedRad });
    } finally {
        st.showBolts = prev.bolts;
        st.showHardwareFullDetail = prev.full;
        st.hwDetailMode = prev.mode;
    }
    const folded = (getStructureFoldedAngle() * 180) / Math.PI;
    const deployed = (getStructureDeployedAngle() * 180) / Math.PI;
    const assemblyPose = (Number.isFinite(folded) && Number.isFinite(deployed)) ? folded + (deployed - folded) * 0.45 : folded;
    return {
        data, drillBolts,
        opts: {
            modules: st.modules,
            useFixedBeams: !!st.useFixedBeams,
            archCapUprights: !!st.archCapUprights,
            foldedAngleDeg: Number.isFinite(assemblyPose) ? assemblyPose : null,
            deployedAngleDeg: Number.isFinite(deployed) ? deployed : null,
            intersectionsFor: (beam) => getBeamBoltIntersections(beam, drillBolts),
        },
        foldedDeg: r4(folded), deployedDeg: r4(deployed), assemblyPoseDeg: r4(assemblyPose),
    };
}

function partsDump(data) {
    const parts = collectParts(data);
    const byKind = {};
    for (const p of parts) byKind[p.kind] = (byKind[p.kind] || 0) + 1;
    return {
        count: parts.length,
        byKind,
        keys: parts.map(p => p.key),
        joints: parts.map(p => { try { return jointKey(p.obj, p.kind) || null; } catch (e) { return null; } }),
    };
}

// A4: the floor, the coverings and the shade of ONE structure (the base copy),
// in the same frame as the beams (compare relative to the anchor), plus the
// cut plan and the enclosure / floor BOM rows the web computes from them.
function a4Dump(data) {
    const st = globalThis.state;
    const beam = (b) => clean({
        key: partKey(b, 'beam'), stackType: b.stackType, stackId: b.stackId, patternId: b.patternId,
        moduleIndex: b.moduleIndex, p1: vec(b.p1), p2: vec(b.p2), w: b.w, t: b.t,
    });
    const shape = (sh) => {
        const o = clean(sh);
        o.key = partKey(sh, 'wall');
        return o;
    };
    const fl = data.floor || null;
    const cov = data.coverings || null;
    const sh = data.shade || null;
    let plan = null;
    try {
        resetCoveringPlanCache();
        if (st.coverings || (fl && fl.deck)) {
            plan = computeCoveringCutPlan(cov, st.coverings || {}, fl && fl.deck ? fl.deck : null);
        }
    } catch (e) { plan = { error: String(e) }; }
    const nestOf = (w) => w && w.nest ? clean({
        sheetCount: w.nest.sheetCount, seamCount: w.nest.seamCount, seamLinearIn: w.nest.seamLinearIn,
        polygonAreaIn2: w.nest.polygonAreaIn2, stockAreaIn2: w.nest.stockAreaIn2,
        pieces: (w.nest.pieces || []).map(pc => ({ isFullSheet: !!pc.isFullSheet, areaIn2: pc.areaIn2,
            poly: pc.poly || pc.polygon || null, sheetIndex: pc.sheetIndex })),
        warnings: (w.nest.warnings || []).map(x => x.code),
    }) : null;
    return {
        floor: fl ? {
            supported: !!fl.supported,
            beams: (fl.beams || []).map(beam),
            deck: fl.deck ? shape(fl.deck) : null,
            deckCopies: (fl.deckCopies || []).length,
            seating: clean(describeFloorSeating(data, fl.beams || [], st.modules)),
            bom: clean(computeFloorBomContribution(st.floor, st.modules, st)),
        } : null,
        coverings: cov ? {
            supported: !!cov.supported,
            reason: cov.reason || null,
            baseShapes: (cov.baseShapes || cov.shapes || []).map(shape),
            copies: (cov.shapes || []).length,
            totals: clean(cov.totals || null),
        } : null,
        shade: sh ? {
            supported: !!sh.supported,
            baseShapes: (sh.baseShapes || sh.shapes || []).map(shape),
            copies: (sh.shapes || []).length,
            summary: clean(Object.fromEntries(Object.entries(sh).filter(([k]) => k !== 'shapes' && k !== 'baseShapes'))),
            bom: clean(shadeBomItems(sh, st)),
        } : null,
        plan: plan && !plan.error ? {
            totals: clean(plan.totals),
            walls: plan.walls.map(w => ({ key: partKey(w.shape, 'wall'), nest: nestOf(w) })),
            tables: plan.tables.map(w => ({ key: partKey(w.shape, 'wall'), nest: nestOf(w) })),
            floor: plan.floor ? nestOf(plan.floor) : null,
            fabric: plan.fabric.map(f => ({ key: partKey(f.shape, 'wall'), pattern: clean(f.pattern) })),
            bom: clean(coveringBomItems(plan, st)),
        } : plan,
    };
}

function holesDump(beams, drillBolts) {
    // Base structure only (one copy), every beam: the port pins its hole finder here.
    return (beams || []).map(b => ({
        key: partKey(b, 'beam'),
        stackType: b.stackType || null,
        holes: getBeamBoltIntersections(b, drillBolts).map(h => clean(h)),
    }));
}

describe('linkage parity dump', () => {
    it.each(presets)('dump $name', (preset) => {
        const config = JSON.parse(fs.readFileSync(path.join(root, 'configs', preset.file), 'utf8'));
        globalThis.state = structuredClone(APP_DEFAULTS);
        applyConfig(config, false);
        if (globalThis.state.showHardwareFullDetail && ensureHardwareAssemblies) ensureHardwareAssemblies();

        // As saved (the preset's own fold angle, everything the viewer draws).
        const saved = buildLinkageGeometry({ useCache: false, includeSupportBeams: true, includePanels: true });
        const gi = generationInput();
        const steps = generateDefaultBuildSteps(gi.data, gi.opts);
        const bench = planBench(groupBeamsForBench(gi.data.beams), { stock: true });
        const ra = gi.data.radialArray;

        const out = {
            preset: preset.name,
            file: preset.file,
            linkagelab: { sha: process.env.PARITY_SHA, ref: process.env.PARITY_REF },
            savedFoldDeg: deg(globalThis.state.foldAngle),
            foldedDeg: gi.foldedDeg, deployedDeg: gi.deployedDeg, assemblyPoseDeg: gi.assemblyPoseDeg,
            saved: { stats: solveStats(saved), parts: partsDump(saved) },
            deployed: { stats: solveStats(gi.data), parts: partsDump(gi.data) },
            radialArray: ra ? {
                copyCount: ra.copyCount, maxRad: r4(ra.maxRad),
                slots: clean(ra.slots || ra.copies || null),
            } : null,
            foldSchedule: gi.data.foldSchedule ? { sequential: !!gi.data.foldSchedule.sequential } : null,
            coverings: gi.data.coverings ? {
                supported: !!gi.data.coverings.supported,
                shapes: (gi.data.coverings.shapes || []).length,
                baseShapes: (gi.data.coverings.baseShapes || gi.data.coverings.shapes || []).length,
            } : null,
            floor: gi.data.floor ? {
                supported: !!gi.data.floor.supported,
                beams: (gi.data.floor.beams || []).length,
                deck: !!gi.data.floor.deck,
                deckCopies: (gi.data.floor.deckCopies || []).length,
            } : null,
            shade: gi.data.shade ? {
                supported: !!gi.data.shade.supported,
                shapes: (gi.data.shade.shapes || []).length,
                baseShapes: (gi.data.shade.baseShapes || gi.data.shade.shapes || []).length,
            } : null,
            bench: {
                items: bench.items.map(i => clean({
                    length: i.group.length, w: i.group.w, t: i.group.t, count: i.group.count,
                    stackTypes: i.group.stackTypes, stockLength: i.stockLength, z: i.z,
                })),
                bounds: clean(bench.bounds),
            },
            generatedSteps: clean(steps),
            savedSteps: config.buildSteps ? clean(normalizeBuildSteps(config.buildSteps)) : null,
            // Parts each saved step's selectors resolve to in JS (per step, per
            // target) — stale or quirk selectors legitimately resolve to 0.
            savedTargetCounts: config.buildSteps ? normalizeBuildSteps(config.buildSteps).steps.map(st =>
                (st.targets || []).map(sel => resolveTargets(gi.data, [sel]).items.length)) : null,
            // The first array copy, in the frame the bolts are in (copy 0 leads data.beams).
            drillBolts: gi.drillBolts.length,
            // Every drill bolt (key, centre, axis, length) and the frame anchor:
            // JS recentres the ring on the origin (shiftGeometryXZ), the game
            // does not, so geometry pins compare relative to beam 0's p1.
            anchor: vec(gi.data.beams[0].p1),
            drillBoltList: gi.drillBolts.map(b => clean({
                key: partKey(b, 'bolt'), center: vec(b.center), dir: vec(b.dir), length: b.length, radius: b.radius,
            })),
            effective: { hStackGap: globalThis.hwResolveStructureSpacing ? clean(globalThis.hwResolveStructureSpacing()) : null,
                vBoltLength: r4(globalThis.state.vBoltLength), vBoltInnerLength: r4(globalThis.state.vBoltInnerLength),
                vBoltOuterLength: r4(globalThis.state.vBoltOuterLength), hBoltLength: r4(globalThis.state.hBoltLength),
                hPivotBoltLength: r4(globalThis.state.hPivotBoltLength) },
            rcpBolts: gi.drillBolts.filter(b => b && (b.boltType === 'rcp-ring' || b.boltType === 'rcp-cross')).map(b => clean({
                key: partKey(b, 'bolt'), center: vec(b.center), dir: vec(b.dir), length: b.length,
            })),
            holes: holesDump((gi.data.beams || []).slice(0, (gi.data.baseBeams || gi.data.beams).length), gi.drillBolts),
            a4: a4Dump(gi.data),
        };
        const name = preset.file.replace(/\.json$/i, '').replace(/[^\w.-]+/g, '_').toLowerCase();
        fs.writeFileSync(path.join(OUT, name + '.json'), JSON.stringify(out, null, 1) + '\n');
        expect(out.deployed.parts.count).toBeGreaterThan(0);
    });
});
`;
}
