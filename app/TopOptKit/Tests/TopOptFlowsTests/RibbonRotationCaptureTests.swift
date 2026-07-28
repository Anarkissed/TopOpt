// RibbonRotationCaptureTests — generates the VISUAL capture for the ribbon-rotation fix by
// driving the REAL shipping path (`ProjectModel.rotateManualPrimitive(from:snap:)`) over a
// smooth ribbon drag and rendering the primitive's stored orientation each frame. Emits an SVG
// filmstrip to evidence/2026-07-27-ribbon-rotation-fix/. This is not a device screenshot — it is
// a render of the actual model output (fix vs the pre-fix snap-back), frame by frame, so the
// rotation is SHOWN happening rather than described. Set CAPTURE_DIR to emit; otherwise skips.

import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

@MainActor
final class RibbonRotationCaptureTests: XCTestCase {

    private func miniProject() -> (ProjectModel, UUID) {
        let p = ProjectModel(id: UUID(), name: "P", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        let verts: [Float] = [-10, -10, 0,  10, -10, 0,  10, 10, 0,  -10, 10, 0]
        let indices: [Int32] = [0, 1, 2, 0, 2, 3]
        let plane = StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1), planeOrigin: .zero)
        p.viewerMesh = ViewerMesh(vertices: verts, indices: indices, faceIDs: [1, 1],
                                  faceGeometry: [StepFaceGeometry(kind: .other), plane])
        var sel = SelectionModel(); sel.addGroup(); sel.pickFaces([1])
        p.selection = sel
        let gid = sel.groups[0].id
        p.seedUndoBaseline()
        return (p, gid)
    }

    /// One frame's stored axis after dragging ribbon `about` to cumulative `deg`, via the real
    /// path. `applyFix` chooses the shipped call (start axis threaded) vs the pre-fix behaviour
    /// (no `from:` → the world-axis magnet snaps small turns back).
    private func frameAxis(about k: SIMD3<Double>, deg: Double, applyFix: Bool) -> SIMD3<Double> {
        let (p, gid) = miniProject()
        let id = p.addManualPrimitive(.bolt, to: gid)!
        let start = p.force.manualPrimitives(for: gid).first { $0.id == id }!.axis
        let ref: SIMD3<Double> = abs(k.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
        let a = simd_normalize(simd_cross(k, ref))
        let b = PrimitiveGizmo.rotate(a, about: k, radians: deg * .pi / 180)
        let drag = PrimitiveGizmo.Drag(handle: .rotate(k), startCenter: .zero, startAxis: start,
                                       grab: .init(origin: a + k * 10, dir: -k))
        let out = drag.resolve(currentRay: .init(origin: b + k * 10, dir: -k))
        p.rotateManualPrimitive(id: id, in: gid, to: out.axis, from: applyFix ? start : nil, snap: true)
        return p.force.manualPrimitives(for: gid).first { $0.id == id }!.axis
    }

    // Isometric projection shared by every frame (a pleasant 3/4 view).
    private var view: simd_double3x3 {
        let qf = simd_quatf(angle: -0.5, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: 0.7, axis: SIMD3(0, 1, 0))
        let m = simd_float3x3(qf)
        return simd_double3x3(SIMD3(Double(m.columns.0.x), Double(m.columns.0.y), Double(m.columns.0.z)),
                              SIMD3(Double(m.columns.1.x), Double(m.columns.1.y), Double(m.columns.1.z)),
                              SIMD3(Double(m.columns.2.x), Double(m.columns.2.y), Double(m.columns.2.z)))
    }
    private func project(_ p: SIMD3<Double>, cx: Double, cy: Double, s: Double) -> (Double, Double) {
        let v = view * p
        return (cx + v.x * s, cy - v.y * s)   // y-down screen
    }

    /// A cylinder drawn as its axis (bold arrow) plus a small end-disc, so the tilt reads clearly.
    private func cylinderSVG(axis: SIMD3<Double>, cx: Double, cy: Double, s: Double, color: String) -> String {
        let L = 1.0
        let (x0, y0) = project(-axis * L, cx: cx, cy: cy, s: s)
        let (x1, y1) = project(axis * L, cx: cx, cy: cy, s: s)
        // A perpendicular tick at the tip to show the end face (any vector ⟂ axis).
        let ref: SIMD3<Double> = abs(axis.z) < 0.9 ? SIMD3(0, 0, 1) : SIMD3(1, 0, 0)
        let perp = simd_normalize(simd_cross(axis, ref)) * 0.28
        let (px0, py0) = project(axis * L + perp, cx: cx, cy: cy, s: s)
        let (px1, py1) = project(axis * L - perp, cx: cx, cy: cy, s: s)
        return """
        <line x1="\(f(x0))" y1="\(f(y0))" x2="\(f(x1))" y2="\(f(y1))" stroke="\(color)" stroke-width="7" stroke-linecap="round"/>
        <line x1="\(f(px0))" y1="\(f(py0))" x2="\(f(px1))" y2="\(f(py1))" stroke="\(color)" stroke-width="4" stroke-linecap="round" opacity="0.85"/>
        <circle cx="\(f(x1))" cy="\(f(y1))" r="5" fill="\(color)"/>
        """
    }

    private func axesSVG(cx: Double, cy: Double, s: Double) -> String {
        var out = ""
        for (v, c) in [(SIMD3<Double>(1, 0, 0), "#c94"), (SIMD3(0, 1, 0), "#4a4"), (SIMD3(0, 0, 1), "#69c")] {
            let (x1, y1) = project(v * 1.15, cx: cx, cy: cy, s: s)
            out += "<line x1=\"\(f(cx))\" y1=\"\(f(cy))\" x2=\"\(f(x1))\" y2=\"\(f(y1))\" stroke=\"\(c)\" stroke-width=\"1\" opacity=\"0.35\"/>"
        }
        return out
    }
    private func f(_ d: Double) -> String { String(format: "%.1f", d) }

    func testEmitRibbonRotationFilmstrip() throws {
        guard let dir = ProcessInfo.processInfo.environment["CAPTURE_DIR"] else {
            throw XCTSkip("set CAPTURE_DIR to emit the capture")
        }
        let frames = 7
        let maxDeg = 30.0
        let ribbons: [(String, SIMD3<Double>)] = [
            ("about X  (tilts +Z → −Y)", SIMD3(1, 0, 0)),
            ("about Y  (tilts +Z → +X)", SIMD3(0, 1, 0)),
            ("about Z  (own axis — no-op by construction)", SIMD3(0, 0, 1)),
        ]
        let cell = 150.0, s = 46.0, labelW = 250.0
        let rowH = cell + 10
        let width = labelW + Double(frames) * cell + 20
        let height = 60 + Double(ribbons.count) * 2 * rowH + 40

        var svg = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(f(width))\" height=\"\(f(height))\" font-family=\"-apple-system,Helvetica,sans-serif\">"
        svg += "<rect width=\"100%\" height=\"100%\" fill=\"#111318\"/>"
        svg += "<text x=\"16\" y=\"32\" fill=\"#eee\" font-size=\"20\" font-weight=\"600\">Ribbon rotation — real ProjectModel.rotateManualPrimitive output (bolt axis)</text>"
        var y = 56.0
        for (name, k) in ribbons {
            for (fixName, applyFix, tint) in [("WITH FIX", true, "#5cc8ff"), ("pre-fix (main): snaps back", false, "#ff7a7a")] {
                svg += "<text x=\"16\" y=\"\(f(y + 24))\" fill=\"#ccc\" font-size=\"13\" font-weight=\"600\">\(name)</text>"
                svg += "<text x=\"16\" y=\"\(f(y + 44))\" fill=\"\(tint)\" font-size=\"12\">\(fixName)</text>"
                for i in 0..<frames {
                    let deg = maxDeg * Double(i) / Double(frames - 1)
                    let axis = frameAxis(about: k, deg: deg, applyFix: applyFix)
                    let cx = labelW + Double(i) * cell + cell / 2
                    let cy = y + cell / 2
                    svg += "<rect x=\"\(f(cx - cell/2 + 4))\" y=\"\(f(y + 4))\" width=\"\(f(cell - 8))\" height=\"\(f(cell - 8))\" rx=\"8\" fill=\"#181b22\" stroke=\"#2a2e38\"/>"
                    svg += axesSVG(cx: cx, cy: cy, s: s)
                    svg += cylinderSVG(axis: axis, cx: cx, cy: cy, s: s, color: tint)
                    let moved = acos(min(1, abs(simd_dot(simd_normalize(axis), SIMD3(0, 0, 1))))) * 180 / .pi
                    svg += "<text x=\"\(f(cx))\" y=\"\(f(y + cell - 10))\" fill=\"#888\" font-size=\"11\" text-anchor=\"middle\">drag \(Int(deg))° → \(String(format: "%.0f", moved))°</text>"
                }
                y += rowH
            }
        }
        svg += "</svg>"

        let url = URL(fileURLWithPath: dir).appendingPathComponent("ribbon-rotation-filmstrip.svg")
        try svg.data(using: .utf8)!.write(to: url)
        print("WROTE \(url.path)")
    }
}
