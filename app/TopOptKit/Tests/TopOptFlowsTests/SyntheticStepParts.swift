// SyntheticStepParts — the STEP parts StepMeshRepairTests and FlexibleStepRepairHookTests import, written
// by the tests themselves at run time. They replace his seven squish-rig STEPs, removed from the tree on his
// order of 2026-10-24 ("Remove the rig step files"; the files stay in git history at 9b11b6dc).
//
// Each part reproduces, through core's own STEP import (core/src/io/step.cpp: OCCT 7.9.3, BRepMesh at
// 0.1 mm / 0.5 rad, then the 1e-6 mm weld, no clean-up), one of the two defects StepMeshRepair exists for,
// or neither. Every number below is chosen here; nothing is read from his files.
//
//   (a) POLE SLIVERS — `filletedBlock`. A fillet corner is a sphere octant. Its sphere's axis ends at one
//       of the octant's three corners: a POLE, which OCCT's reader closes with a DEGENERATED edge. BRepMesh
//       gives the pole two nodes (distinct in UV, one 3D point); the triangle on both welds to (a, a, b):
//       zero area, a self-edge used once and an edge used four times. The block's eight corners give eight
//       slivers, one on each corner face (ids 18-25), as his Carriage Arms had on its fillet corners.
//       T1 (drop them) closes it.
//   (b) ONE BROKEN FACE — `lippedPlateAndCorner`. A planar face (id 1) with a thin curved LIP: the strip
//       between two concentric arcs 0.02 mm apart, whose tip is a 0.032 mm edge. At 0.1 mm BRepMesh
//       triangulates that face with a hole AND triangles over the air beside the lip (72.50 mm² of
//       triangles on a 70.10 mm² face) and the import reports no error; at 0.05 mm the same face meshes
//       correctly. A second solid in the same file, a small fillet corner, adds one pole sliver (id 13):
//       both defects in one file, as his 2040 Extrusion Stand had. T1 alone cannot close it; T2 (0.05 mm,
//       then T1) does.
//   (c) CLEAN — `slotPlate`, `roundedBracket` (planes, convex and concave cylinders). Watertight on import:
//       the gate stays closed, nothing is repaired, the mesh and its face ids are exactly today's.
//
// The B-rep volumes, boxes and the broken face's area are exact closed forms of the shapes (OCCT's
// BRepGProp gives the same numbers: 23340.8494, 214.4889 mm³), so the tests make no OCCT call of their own.
import Foundation
import simd

enum SyntheticStepParts {

    struct Part {
        let name: String
        let faces: Int
        /// Exact B-rep volume, mm³.
        let brepVolume: Double
        /// Exact bounding box.
        let lo: SIMD3<Double>
        let hi: SIMD3<Double>
        /// Pole slivers in core's stock 0.1 mm tessellation, and the face ids carrying them (one each).
        let slivers: Int
        let sliverFaces: [Int32]
        /// The face BRepMesh breaks at 0.1 mm, and its exact area (mm²); nil when there is none.
        let brokenFace: Int32?
        let brokenFaceArea: Double
        /// The STEP file's text.
        let text: String
    }

    /// Refused by core's stock import; StepMeshRepair closes each (the block at T1, the plate at T2).
    static let refused: [Part] = [filletedBlock, lippedPlateAndCorner]
    /// Watertight on import: the gate stays closed.
    static let accepted: [Part] = [slotPlate, roundedBracket]

    /// A 40 × 30 × 20 mm block, every edge filleted at 3 mm: 6 planes (ids 0-5), 12 quarter cylinders
    /// (6-17), 8 sphere-octant corners (18-25), each corner's pole a degenerated edge.
    static let filletedBlock: Part = {
        let size: SIMD3<Double> = [40, 30, 20], r = 3.0
        let inner = size - SIMD3(repeating: 2 * r)
        let (p, q, s) = (inner.x, inner.y, inner.z)
        // Steiner: the inner box grown by a ball of radius r.
        let faces: Double = 2 * (p * q + q * s + s * p) * r
        let edges: Double = Double.pi * (p + q + s) * r * r
        let corners: Double = 4.0 / 3.0 * Double.pi * r * r * r
        var w = StepWriter()
        let solid = w.filletedBox(size: size, r: r, at: [0, 0, 0])
        return Part(name: "filleted_block", faces: 26, brepVolume: p * q * s + faces + edges + corners,
                    lo: [0, 0, 0], hi: size, slivers: 8, sliverFaces: Array(18...25),
                    brokenFace: nil, brokenFaceArea: 0, text: w.file(solids: [solid], name: "filleted_block"))
    }()

    /// The lip plate (ids 0-9; its top, id 1, is the face that breaks) and, 10 mm beside it, a 2 mm ball
    /// octant (ids 10-13; its sphere face, 13, carries the sliver).
    static let lippedPlateAndCorner: Part = {
        let plate = LipPlate.standard
        let r = 2.0, at: SIMD3<Double> = [plate.width + 10, 0, 0]
        var w = StepWriter()
        let s1 = w.prism(plate.outline, h: plate.height)
        let s2 = w.ballOctant(r: r, at: at)
        return Part(name: "lipped_plate_and_corner", faces: 14,
                    brepVolume: plate.area * plate.height + Double.pi * r * r * r / 6,
                    lo: [0, -plate.depth, 0], hi: [at.x + r, max(plate.maxY, r), max(plate.height, r)],
                    slivers: 1, sliverFaces: [13], brokenFace: 1, brokenFaceArea: plate.area,
                    text: w.file(solids: [s1, s2], name: "lipped_plate_and_corner"))
    }()

    /// A 30 × 20 × 5 mm slot plate with half-round ends (4 planes + 2 half cylinders).
    static let slotPlate: Part = {
        var o = Outline()
        o.add([0, 0]); o.add([30, 0], .arc(center: [30, 10], ccw: true)); o.add([30, 20])
        o.add([0, 20], .arc(center: [0, 10], ccw: true))
        let h = 5.0
        var w = StepWriter()
        let solid = w.prism(o, h: h)
        return Part(name: "slot_plate", faces: 6, brepVolume: (30 * 20 + Double.pi * 100) * h,
                    lo: [-10, 0, 0], hi: [40, 20, h], slivers: 0, sliverFaces: [],
                    brokenFace: nil, brokenFaceArea: 0, text: w.file(solids: [solid], name: "slot_plate"))
    }()

    /// An L bracket, 12 mm thick: a 3 mm inner (concave) round where the legs meet and a half-round top
    /// on the upright (2 planes + 5 flat sides + 2 cylinders).
    static let roundedBracket: Part = {
        var o = Outline()
        o.add([0, 0]); o.add([36, 0]); o.add([36, 8]); o.add([11, 8], .arc(center: [11, 11], ccw: false))
        o.add([8, 11]); o.add([8, 26], .arc(center: [4, 26], ccw: true)); o.add([0, 26])
        let h = 12.0
        let legs: Double = 36 * 8 + 8 * 18                   // the two legs
        let innerRound: Double = 9 - Double.pi * 9 / 4       // a 3 mm square less its quarter disc
        let topRound: Double = Double.pi * 16 / 2            // a half disc, radius 4
        var w = StepWriter()
        let solid = w.prism(o, h: h)
        return Part(name: "rounded_bracket", faces: 9, brepVolume: (legs + innerRound + topRound) * h,
                    lo: [0, 0, 0], hi: [36, 30, h], slivers: 0, sliverFaces: [],
                    brokenFace: nil, brokenFaceArea: 0, text: w.file(solids: [solid], name: "rounded_bracket"))
    }()

    // MARK: - files

    /// The part's file, written once per process into a temporary folder, for core's importer to read.
    static func path(_ part: Part) -> String { files.path(part) }

    private static let files = Files()
    private final class Files: @unchecked Sendable {
        private let lock = NSLock()
        private var written: [String: String] = [:]
        private let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "topopt-synthetic-step-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        func path(_ part: Part) -> String {
            lock.lock(); defer { lock.unlock() }
            if let p = written[part.name] { return p }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let p = dir.appendingPathComponent("\(part.name).step").path
            try! part.text.write(toFile: p, atomically: true, encoding: .utf8)
            written[part.name] = p
            return p
        }
    }
}

// The helpers live inside SyntheticStepParts so their names (Outline, …) stay out of the test module.
extension SyntheticStepParts {

    // MARK: - the lip plate (defect b)

    /// A 14 × 5 mm plate, 3 mm thick, with a thin curved LIP rising from its top edge: the strip between two
    /// concentric arcs (radii 5 and 4.98 mm, about (4, 0)) over 1 rad, whose tip is one straight edge from the
    /// outer arc to the inner one 0.005 rad further on, 0.032 mm long. Found by a sweep over lip radius, width
    /// and sweep (2026-10-24, 1,560 lips): every lip 0.02 mm wide swept 1 rad with an outer radius of 4.5, 5,
    /// 5.5 or 6 mm breaks the top face at 0.1 mm the same way (a hole plus triangles over the air) and meshes
    /// it correctly at 0.05 mm, so this one is not a knife-edge case.
    struct LipPlate {
        let ro: Double, gap: Double, sweep: Double, tipTwist: Double
        let cx: Double, width: Double, depth: Double, height: Double

        static let standard = LipPlate(ro: 5, gap: 0.02, sweep: 1.0, tipTwist: 0.005,
                                       cx: 4, width: 14, depth: 5, height: 3)

        var ri: Double { ro - gap }
        var center: SIMD2<Double> { [cx, 0] }
        var outerTip: SIMD2<Double> { center + ro * SIMD2(cos(sweep), sin(sweep)) }
        var innerTip: SIMD2<Double> { center + ri * SIMD2(cos(sweep + tipTwist), sin(sweep + tipTwist)) }
        var tipLength: Double { simd_length(outerTip - innerTip) }
        var maxY: Double { max(outerTip.y, innerTip.y) }

        /// Counter-clockwise: the plate's bottom and right side, the top edge to the lip, out along the outer
        /// arc, across the tip, back along the inner arc, the rest of the top edge.
        var outline: Outline {
            var o = Outline()
            o.add([0, -depth]); o.add([width, -depth]); o.add([width, 0])
            o.add([cx + ro, 0], .arc(center: center, ccw: true))
            o.add(outerTip)
            o.add(innerTip, .arc(center: center, ccw: false))
            o.add([cx + ri, 0]); o.add([0, 0])
            return o
        }
        /// The top face's exact area: the plate, plus the lip by Green's theorem about its centre (outer
        /// sector + the tip's triangle − inner sector).
        var area: Double {
            let lip = 0.5 * (ro * ro * sweep + ro * ri * sin(tipTwist) - ri * ri * (sweep + tipTwist))
            return width * depth + lip
        }
    }

    // MARK: - the writer

    /// A closed outline in the XY plane, counter-clockwise, to extrude along +z.
    struct Outline {
        enum Seg { case line, arc(center: SIMD2<Double>, ccw: Bool) }
        var points: [SIMD2<Double>] = []
        var segs: [Seg] = []      // segs[i] runs points[i] → points[(i + 1) % n]
        mutating func add(_ p: SIMD2<Double>, _ s: Seg = .line) { points.append(p); segs.append(s) }
    }

    /// A small AP214 writer for analytic B-reps: planes, cylinders and spheres bounded by lines and circles.
    /// A face is given as its edges and its outward normal; the loop's order and every orientation flag are
    /// worked out here (the Newell normal of the loop against the outward normal).
    struct StepWriter {
        typealias P = SIMD3<Double>
        private(set) var entities: [String] = [
            "(GEOMETRIC_REPRESENTATION_CONTEXT(3)GLOBAL_UNCERTAINTY_ASSIGNED_CONTEXT((#5))"
                + "GLOBAL_UNIT_ASSIGNED_CONTEXT((#2,#3,#4))REPRESENTATION_CONTEXT('',''))",
            "(LENGTH_UNIT()NAMED_UNIT(*)SI_UNIT(.MILLI.,.METRE.))",
            "(NAMED_UNIT(*)PLANE_ANGLE_UNIT()SI_UNIT($,.RADIAN.))",
            "(NAMED_UNIT(*)SI_UNIT($,.STERADIAN.)SOLID_ANGLE_UNIT())",
            "UNCERTAINTY_MEASURE_WITH_UNIT(LENGTH_MEASURE(1.E-07),#2,'distance_accuracy_value','')",
        ]
        private let context = 1

        private struct Edge { let id: Int; let v1: Int; let v2: Int; let mid: P }
        private var points: [Int: P] = [:]   // VERTEX_POINT id → its point
        private var edges: [Int: Edge] = [:] // EDGE_CURVE id → its ends and midpoint

        @discardableResult
        private mutating func put(_ s: String) -> Int { entities.append(s); return entities.count }

        static func num(_ x: Double) -> String {
            if x == 0 { return "0." }
            let s = String(format: "%.17G", x)
            if s.contains(".") { return s }
            return s.contains("E") ? s.replacingOccurrences(of: "E", with: ".E") : s + "."
        }
        private static func tuple(_ p: P) -> String { "(\(num(p.x)),\(num(p.y)),\(num(p.z)))" }

        private mutating func point(_ p: P) -> Int { put("CARTESIAN_POINT('',\(Self.tuple(p)))") }
        private mutating func direction(_ d: P) -> Int { put("DIRECTION('',\(Self.tuple(simd_normalize(d))))") }
        private mutating func placement(_ o: P, z: P, x: P) -> Int {
            let a = point(o), b = direction(z), c = direction(x)
            return put("AXIS2_PLACEMENT_3D('',#\(a),#\(b),#\(c))")
        }

        // MARK: vertices and edges

        mutating func vertex(_ p: P) -> Int {
            let id = put("VERTEX_POINT('',#\(point(p)))")
            points[id] = p
            return id
        }
        /// A straight edge v1 → v2.
        mutating func line(_ v1: Int, _ v2: Int) -> Int {
            let a = points[v1]!, b = points[v2]!
            let vec = put("VECTOR('',#\(direction(b - a)),\(Self.num(simd_length(b - a))))")
            let curve = put("LINE('',#\(point(a)),#\(vec))")
            let id = put("EDGE_CURVE('',#\(v1),#\(v2),#\(curve),.T.)")
            edges[id] = Edge(id: id, v1: v1, v2: v2, mid: (a + b) / 2)
            return id
        }
        /// A circular edge v1 → v2 about `center`, counter-clockwise about `normal` (default: the short way).
        mutating func arc(_ v1: Int, _ v2: Int, center c: P, normal: P? = nil) -> Int {
            let a = points[v1]!, b = points[v2]!
            let r = simd_length(a - c)
            let n = simd_normalize(normal ?? simd_cross(a - c, b - c))
            let x = simd_normalize(a - c), y = simd_cross(n, x)
            let circle = put("CIRCLE('',#\(placement(c, z: n, x: x)),\(Self.num(r)))")
            let id = put("EDGE_CURVE('',#\(v1),#\(v2),#\(circle),.T.)")
            let bl = simd_normalize(b - c)
            let sweep = atan2(simd_dot(bl, y), simd_dot(bl, x))
            let half = (sweep <= 0 ? sweep + 2 * .pi : sweep) / 2
            edges[id] = Edge(id: id, v1: v1, v2: v2, mid: c + r * (cos(half) * x + sin(half) * y))
            return id
        }

        // MARK: surfaces and faces

        mutating func plane(_ o: P, normal: P, x: P) -> Int {
            put("PLANE('',#\(placement(o, z: normal, x: x)))")
        }
        mutating func cylinder(_ o: P, axis: P, x: P, r: Double) -> Int {
            put("CYLINDRICAL_SURFACE('',#\(placement(o, z: axis, x: x)),\(Self.num(r)))")
        }
        mutating func sphere(_ c: P, axis: P, x: P, r: Double) -> Int {
            put("SPHERICAL_SURFACE('',#\(placement(c, z: axis, x: x)),\(Self.num(r)))")
        }

        /// A one-loop face. `loop` lists its edges in any order and direction; they are chained and wound
        /// counter-clockwise about `outward`. `sense` is false when the surface's own normal points inward.
        mutating func face(_ loop: [Int], surface: Int, outward: P, sense: Bool = true) -> Int {
            var left = loop.map { edges[$0]! }
            var chain: [(edge: Edge, forward: Bool)] = [(left.removeFirst(), true)]
            while !left.isEmpty {
                let end = chain.last!.forward ? chain.last!.edge.v2 : chain.last!.edge.v1
                guard let k = left.firstIndex(where: { $0.v1 == end || $0.v2 == end }) else {
                    preconditionFailure("StepWriter: the face's edges do not close")
                }
                let e = left.remove(at: k)
                chain.append((e, e.v1 == end))
            }
            var poly: [P] = []
            for (e, forward) in chain { poly.append(points[forward ? e.v1 : e.v2]!); poly.append(e.mid) }
            var newell = P(repeating: 0)
            for i in poly.indices { newell += simd_cross(poly[i], poly[(i + 1) % poly.count]) }
            if simd_dot(newell, outward) < 0 { chain = chain.reversed().map { ($0.edge, !$0.forward) } }
            let oes = chain.map { put("ORIENTED_EDGE('',*,*,#\($0.edge.id),\($0.forward ? ".T." : ".F."))") }
            let loopID = put("EDGE_LOOP('',(\(oes.map { "#\($0)" }.joined(separator: ","))))")
            let bound = put("FACE_OUTER_BOUND('',#\(loopID),.T.)")
            return put("ADVANCED_FACE('',(#\(bound)),#\(surface),\(sense ? ".T." : ".F."))")
        }

        // MARK: shapes (each returns its faces in the order core numbers them)

        /// One eighth of a ball at `o`: the planes z = 0, x = 0, y = 0 (relative to `o`), then the octant,
        /// whose axis runs along +z so its pole is the top corner.
        mutating func ballOctant(r: Double, at o: P) -> [Int] {
            let vO = vertex(o), vX = vertex(o + [r, 0, 0]), vY = vertex(o + [0, r, 0]), vZ = vertex(o + [0, 0, r])
            let eOX = line(vO, vX), eOY = line(vO, vY), eOZ = line(vO, vZ)
            let eXY = arc(vX, vY, center: o), eYZ = arc(vY, vZ, center: o), eZX = arc(vZ, vX, center: o)
            return [
                face([eOX, eXY, eOY], surface: plane(o, normal: [0, 0, -1], x: [1, 0, 0]), outward: [0, 0, -1]),
                face([eOY, eYZ, eOZ], surface: plane(o, normal: [-1, 0, 0], x: [0, 1, 0]), outward: [-1, 0, 0]),
                face([eOZ, eZX, eOX], surface: plane(o, normal: [0, -1, 0], x: [1, 0, 0]), outward: [0, -1, 0]),
                face([eXY, eYZ, eZX], surface: sphere(o, axis: [0, 0, 1], x: [1, 0, 0], r: r), outward: [1, 1, 1]),
            ]
        }

        /// A box at `o` with every edge filleted at `r`: 6 planes (−x, +x, −y, +y, −z, +z), 12 quarter cylinders
        /// (along x, then y, then z), 8 sphere-octant corners. Each corner's sphere axis runs along ±z, so its
        /// pole is the corner's point on the top or bottom face's fillet.
        mutating func filletedBox(size: P, r: Double, at o: P) -> [Int] {
            let e: [P] = [[1, 0, 0], [0, 1, 0], [0, 0, 1]]
            let signs: [Double] = [-1, 1]
            func center(_ s: P) -> P { o + size / 2 + s * (size / 2 - P(repeating: r)) }
            var corners: [P] = []
            for sz in signs { for sy in signs { for sx in signs { corners.append([sx, sy, sz]) } } }
            // V[s][i]: corner s's vertex on the plane face of axis i.
            var V: [P: [Int]] = [:]
            for s in corners { V[s] = (0..<3).map { vertex(center(s) + r * s[$0] * e[$0]) } }
            // arcs[s][j]: corner s's arc shared with the cylinder along j (between its vertices on i and k).
            var arcs: [P: [Int]] = [:]
            for s in corners {
                arcs[s] = (0..<3).map { j in arc(V[s]![(j + 1) % 3], V[s]![(j + 2) % 3], center: center(s)) }
            }
            // lines: on the plane face of axis i, between the two corners that differ along j.
            func key(_ i: Int, _ s: P, _ j: Int) -> String { var t = s; t[j] = 0; return "\(i)|\(t)" }
            var lines: [String: Int] = [:]
            for s in corners { for i in 0..<3 { for j in 0..<3 where j != i && s[j] < 0 {
                var t = s; t[j] = 1
                lines[key(i, s, j)] = line(V[s]![i], V[t]![i])
            }}}
            var faces: [Int] = []
            for i in 0..<3 { for si in signs {
                var loop: [Int] = []
                for s in corners where s[i] == si { for j in 0..<3 where j != i && s[j] < 0 { loop.append(lines[key(i, s, j)]!) } }
                let n = si * e[i]
                faces.append(face(loop, surface: plane(o + size / 2 + n * size / 2, normal: n, x: e[(i + 1) % 3]),
                                  outward: n))
            }}
            for j in 0..<3 {
                let i = (j + 1) % 3, k = (j + 2) % 3
                for sk in signs { for si in signs {
                    var s0 = P(repeating: 0); s0[i] = si; s0[k] = sk; s0[j] = -1
                    var s1 = s0; s1[j] = 1
                    // u runs from x to the axis × x: start on the face of i or k so the quarter is [0, π/2].
                    var x = si * e[i]
                    if simd_dot(simd_cross(e[j], x), sk * e[k]) < 0 { x = sk * e[k] }
                    faces.append(face([lines[key(i, s0, j)]!, lines[key(k, s0, j)]!, arcs[s0]![j], arcs[s1]![j]],
                                      surface: cylinder(center(s0), axis: e[j], x: x, r: r), outward: si * e[i] + sk * e[k]))
                }}
            }
            for s in corners {
                let axis = s.z * e[2]
                var x = s.x * e[0]
                if simd_dot(simd_cross(axis, x), s.y * e[1]) < 0 { x = s.y * e[1] }
                faces.append(face(arcs[s]!, surface: sphere(center(s), axis: axis, x: x, r: r), outward: s))
            }
            return faces
        }

        /// The outline extruded from z = 0 to z = h: bottom (id 0), top (id 1), then one side per segment
        /// (a plane per line, a cylinder per arc).
        mutating func prism(_ o: Outline, h: Double) -> [Int] {
            let n = o.points.count
            func p3(_ q: SIMD2<Double>, _ z: Double) -> P { [q.x, q.y, z] }
            let vb = o.points.map { vertex(p3($0, 0)) }, vt = o.points.map { vertex(p3($0, h)) }
            let ev = (0..<n).map { line(vb[$0], vt[$0]) }
            var eb: [Int] = [], et: [Int] = []
            for i in 0..<n {
                let j = (i + 1) % n
                switch o.segs[i] {
                case .line:
                    eb.append(line(vb[i], vb[j])); et.append(line(vt[i], vt[j]))
                case .arc(let c, let ccw):
                    let nz: P = [0, 0, ccw ? 1 : -1]
                    eb.append(arc(vb[i], vb[j], center: p3(c, 0), normal: nz))
                    et.append(arc(vt[i], vt[j], center: p3(c, h), normal: nz))
                }
            }
            var faces = [
                face(eb, surface: plane([0, 0, 0], normal: [0, 0, -1], x: [1, 0, 0]), outward: [0, 0, -1]),
                face(et, surface: plane([0, 0, h], normal: [0, 0, 1], x: [1, 0, 0]), outward: [0, 0, 1]),
            ]
            for i in 0..<n {
                let j = (i + 1) % n
                let loop = [eb[i], ev[j], et[i], ev[i]]
                let a = o.points[i], b = o.points[j]
                switch o.segs[i] {
                case .line:
                    let d = b - a, outward: P = [d.y, -d.x, 0]
                    faces.append(face(loop, surface: plane(p3(a, 0), normal: outward, x: [d.x, d.y, 0]), outward: outward))
                case .arc(let c, let ccw):
                    let r = simd_length(a - c), x = (a - c) / r
                    let mid = simd_normalize((a + b) / 2 - c)
                    let outward: P = (ccw ? 1 : -1) * P(mid.x, mid.y, 0)
                    faces.append(face(loop, surface: cylinder(p3(c, 0), axis: [0, 0, 1], x: [x.x, x.y, 0], r: r),
                                      outward: outward, sense: ccw))
                }
            }
            return faces
        }

        /// The file: each solid a closed shell, all in one AP214 product.
        mutating func file(solids: [[Int]], name: String) -> String {
            var items: [Int] = []
            for faces in solids {
                let shell = put("CLOSED_SHELL('',(\(faces.map { "#\($0)" }.joined(separator: ","))))")
                items.append(put("MANIFOLD_SOLID_BREP('',#\(shell))"))
            }
            items.append(placement([0, 0, 0], z: [0, 0, 1], x: [1, 0, 0]))
            let rep = put("ADVANCED_BREP_SHAPE_REPRESENTATION('\(name)',(\(items.map { "#\($0)" }.joined(separator: ","))),#\(context))")
            let app = put("APPLICATION_CONTEXT('automotive design')")
            put("APPLICATION_PROTOCOL_DEFINITION('international standard','automotive_design',2000,#\(app))")
            let pc = put("PRODUCT_CONTEXT('',#\(app),'mechanical')")
            let prod = put("PRODUCT('\(name)','\(name)','',(#\(pc)))")
            let pdc = put("PRODUCT_DEFINITION_CONTEXT('part definition',#\(app),'design')")
            let pdf = put("PRODUCT_DEFINITION_FORMATION('','',#\(prod))")
            let pd = put("PRODUCT_DEFINITION('design','',#\(pdf),#\(pdc))")
            let pds = put("PRODUCT_DEFINITION_SHAPE('','',#\(pd))")
            put("SHAPE_DEFINITION_REPRESENTATION(#\(pds),#\(rep))")
            var s = "ISO-10303-21;\nHEADER;\nFILE_DESCRIPTION(('\(name)'),'2;1');\n"
                + "FILE_NAME('\(name).step','2026-10-24T00:00:00',(''),(''),'','','');\n"
                + "FILE_SCHEMA(('AUTOMOTIVE_DESIGN { 1 0 10303 214 1 1 1 1 }'));\nENDSEC;\nDATA;\n"
            for (i, e) in entities.enumerated() { s += "#\(i + 1)=\(e);\n" }
            return s + "ENDSEC;\nEND-ISO-10303-21;\n"
        }
    }
}
