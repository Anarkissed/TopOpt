// LatticeOrganicTraceTests — ★★★ ORGANIC IS REACHABLE FROM THE APP, AND HERE IS THE
// EVIDENCE.
//
// ★ THE STANDING NO-GO said organic could not be previewed because it "has no cells at
// all, only traced curves". The curves were never the obstacle. The obstacle was the
// INPUT: `trace_organic_lattice` needs the full per-voxel Cauchy stress TENSOR (6
// components, Voigt, TRUE shear, MPa) and the preview only ever held the von Mises
// SCALAR. The tensor already crosses the bridge for the load-flow overlay, so this is
// plumbing, and these bars are what turn that claim into a measurement.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticeOrganicTraceTests: XCTestCase {

    /// A solid block of voxels under UNIAXIAL tension along x. Principal directions are
    /// then unambiguous, which is what makes the trace's output checkable at all — on a
    /// degenerate field the eigenvector order can swap between neighbours and core
    /// counts that separately (`degenerateFraction`).
    private func block(n: Int, spacing: Double)
        -> (candidate: [Bool], tensor: [Double], sep: [Double]) {
        let count = n * n * n
        var cand = [Bool](repeating: true, count: count)
        var tensor = [Double](repeating: 0, count: 6 * count)
        for i in 0..<count {
            tensor[6 * i] = 10.0          // sigma_xx
            tensor[6 * i + 1] = 3.0       // sigma_yy — ranked below xx, so the frame is determined
            tensor[6 * i + 2] = 1.0       // sigma_zz
        }
        // One voxel of padding is not a candidate, so tracing has a boundary to stop at.
        for k in 0..<n { for j in 0..<n { for i in 0..<n
            where i == 0 || j == 0 || k == 0 || i == n-1 || j == n-1 || k == n-1 {
            cand[(k * n + j) * n + i] = false
        } } }
        return (cand, tensor, [Double](repeating: 4.0 * spacing, count: count))
    }

    /// ★★★ THE HEADLINE: core traces, and the capsules land in the field as SOLID.
    func testTheTracerRunsAndBakesStrutsIntoTheField() throws {
        let n = 24, spacing = 1.0
        let (cand, tensor, sep) = block(n: n, spacing: spacing)
        let f = 48                       // the field is FINER than the design grid
        let fs = Double(n) * spacing / Double(f)

        let t = try XCTUnwrap(
            TopOptKit.organicTrace(
                nx: n, ny: n, nz: n, spacingMM: spacing, origin: .zero,
                candidate: cand, stressTensor: tensor, separationMM: sep,
                minExtrudableWidthMM: 0.42,
                buildDirection: SIMD3(0, 0, 1),
                fieldDims: (f, f, f), fieldOrigin: .zero, fieldSpacingMM: fs,
                bandMM: 3.0),
            "★ core refused the trace — organic is not reachable")

        let inside = t.field.filter { $0 < 0 }.count
        let atBand = t.field.filter { $0 >= t.bandMM - 1e-6 }.count
        print("""

        ── organic trace on a \(n)³ uniaxial block ────────────────────────────
        curves ................. \(t.curveCount)
        connectors ............. \(t.connectorCount)
        spans stamped .......... \(t.spanCount)
        separation achieved .... \(String(format: "%.3f", t.spacingUsedMinMM)) – \
        \(String(format: "%.3f", t.spacingUsedMaxMM)) mm
        degenerate fraction .... \(String(format: "%.4f", t.degenerateFraction))
        field cells ............ \(t.field.count)  (voxel \(String(format: "%.3f", fs)) mm)
        ★ cells INSIDE a strut . \(inside)
        cells clamped at band .. \(atBand)

        """)

        // ★★★ THE PREVIEW MUST SHOW THE **EMITTED** SPANS, NOT THE TRACED CURVES.
        // Four passes mutate the span list after tracing — node merge, free-end tie,
        // support prune to a fixed point, stranded drop — and they are not cosmetic:
        // a preview of the traced set draws struts that are not in the exported file.
        print(String(format: "  traced %d segments -> emitted %d (%.1f%% removed)",
                     t.tracedSegmentCount, t.spanCount,
                     t.tracedSegmentCount > 0
                        ? 100.0 * Double(t.tracedSegmentCount - t.spanCount)
                          / Double(t.tracedSegmentCount) : 0))
        XCTAssertLessThan(t.spanCount, t.tracedSegmentCount,
            "★ the emitted set is not smaller than the traced set — the post-trace "
          + "passes did not run, so the preview is drawing struts the file will not "
          + "contain (node merge / free-end tie / support prune / stranded drop)")
        XCTAssertGreaterThan(t.curveCount, 0, "★ no curves were traced")
        XCTAssertGreaterThan(t.spanCount, 0, "★ curves traced but no capsules stamped")
        XCTAssertEqual(t.field.count, f * f * f)
        XCTAssertGreaterThan(inside, 0,
            "★ the field carries no solid at all — the bake put nothing where the "
          + "tracer put struts, so the preview would render an empty region")
        // ★ AND IT IS A LATTICE, NOT A BLOCK. If the bake filled everything the picture
        // would be a solid slab and the bar above would still pass.
        XCTAssertLessThan(Double(inside) / Double(t.field.count), 0.7,
            "★ the field is \(100 * Double(inside) / Double(t.field.count))% solid — "
          + "that is not a lattice")
    }

    /// ★ THE FIELD IS SAFE TO SPHERE TRACE. Clamping is an UNDER-estimate, so no value
    /// may exceed the band — a value above it would let a march step past a strut.
    func testNoValueExceedsTheBand() throws {
        let n = 20, spacing = 1.0
        let (cand, tensor, sep) = block(n: n, spacing: spacing)
        let f = 40
        let t = try XCTUnwrap(TopOptKit.organicTrace(
            nx: n, ny: n, nz: n, spacingMM: spacing, origin: .zero,
            candidate: cand, stressTensor: tensor, separationMM: sep,
            minExtrudableWidthMM: 0.42, buildDirection: SIMD3(0, 0, 1),
            fieldDims: (f, f, f), fieldOrigin: .zero,
            fieldSpacingMM: Double(n) * spacing / Double(f), bandMM: 2.5))
        XCTAssertEqual(t.field.max() ?? 0, t.bandMM, accuracy: 1e-5)
        XCTAssertLessThanOrEqual(t.field.max() ?? 0, t.bandMM + 1e-5)
    }

    /// ★★ AND IT REFUSES RATHER THAN GUESSES. `min_extrudable_width_mm` of 0 is core's
    /// UNSET refusal — printability is user input, never a default — and a tensor of the
    /// wrong length must not be read as a shorter field.
    func testItRefusesAnUnsetBeadAndAMalformedTensor() throws {
        let n = 12, spacing = 1.0
        let (cand, tensor, sep) = block(n: n, spacing: spacing)
        XCTAssertNil(TopOptKit.organicTrace(
            nx: n, ny: n, nz: n, spacingMM: spacing, origin: .zero,
            candidate: cand, stressTensor: tensor, separationMM: sep,
            minExtrudableWidthMM: 0, buildDirection: SIMD3(0, 0, 1),
            fieldDims: (16, 16, 16), fieldOrigin: .zero, fieldSpacingMM: 0.75,
            bandMM: 2), "★ an unset bead must be refused, not defaulted")
        XCTAssertNil(TopOptKit.organicTrace(
            nx: n, ny: n, nz: n, spacingMM: spacing, origin: .zero,
            candidate: cand, stressTensor: Array(tensor.dropLast(6)), separationMM: sep,
            minExtrudableWidthMM: 0.42, buildDirection: SIMD3(0, 0, 1),
            fieldDims: (16, 16, 16), fieldOrigin: .zero, fieldSpacingMM: 0.75,
            bandMM: 2), "★ a short tensor must be refused")
    }
}
