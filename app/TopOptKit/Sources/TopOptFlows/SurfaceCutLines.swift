// SurfaceCutLines.swift — ★ WHERE THE CUT ACTUALLY FALLS, AS GEOMETRY
// (task 2026-08-15-lattice-and-face-ui, Surface stage; maintainer 2026-08-14:
// "Where are the cut lines? We need to see what it will look like", and "the cuts
// need to be visible in the wireframe view after any cut is made").
//
// ── WHY A FILL CANNOT ANSWER THIS ────────────────────────────────────────────
//
// The two sides of a cut are tinted, and a tint is chosen per TRIANGLE — so the
// boundary between the colours is a staircase along triangle edges, never the
// plane itself. On a B-rep tessellation with big triangles that staircase is
// coarse enough to read as a mistake: "it's stopping at the edge of it and cutting
// down to the corner after".
//
// ★ THE CUT IS A PLANE, SO DRAW THE PLANE'S TRACE. Intersecting each cut plane
// with the triangles it crosses gives the EXACT curve where the cut meets the
// surface — a polyline that follows a curved face around its curvature, ends
// precisely on the face's rim, and is correct at any tessellation. It costs one
// pass over the member triangles and needs no shader.
//
// Two things use it: the committed cuts (so a split face reads as two pieces with
// a real edge between them, in the wireframe too) and the PATTERN preview (so a
// grid can be seen before it is committed rather than after).
//
// Pure geometry over value types — no Metal, no view.

import Foundation
import simd
import TopOptKit

public enum SurfaceCutLines {

    /// ★ A LINE PRIMITIVE IS ONE PIXEL, AND THAT IS NOT A DRAWING.
    ///
    /// Metal rasterises `.line` at exactly one pixel — on a 2064-pixel-wide retina
    /// framebuffer a cut trace is a hairline, and across a big face it reads as
    /// nothing at all. The segments were being produced and drawn correctly the
    /// whole time (55 of them, on a live probe); they simply could not be SEEN.
    ///
    /// So each segment becomes a RIBBON: two triangles, widened in the plane of
    /// the face it lies on. Widening in the FACE's plane rather than towards the
    /// camera is what keeps it looking like a line drawn ON the surface instead of
    /// a card standing up out of it — and it stays put as the part is turned.
    ///
    /// Returns a triangle list (x,y,z per vertex, 3 vertices per triangle).
    public static func ribbon(segments: [Float], widthMM: Double,
                              faceNormal: SIMD3<Double>) -> [Float] {
        guard segments.count >= 6, widthMM > 0,
              simd_length(faceNormal) > 1e-9 else { return [] }
        let n = simd_normalize(faceNormal)
        var out: [Float] = []
        out.reserveCapacity(segments.count * 3)

        var i = 0
        while i + 5 < segments.count {
            let a = SIMD3<Double>(Double(segments[i]), Double(segments[i + 1]),
                                  Double(segments[i + 2]))
            let b = SIMD3<Double>(Double(segments[i + 3]), Double(segments[i + 4]),
                                  Double(segments[i + 5]))
            i += 6
            let d = b - a
            guard simd_length(d) > 1e-9 else { continue }
            // In-plane perpendicular: across the line, along the surface.
            var perp = simd_cross(n, simd_normalize(d))
            guard simd_length(perp) > 1e-9 else { continue }
            perp = simd_normalize(perp) * (widthMM / 2)
            // Lifted a hair off the surface so the ribbon cannot z-fight the face
            // it lies on — the same problem the wireframe's depth bias solves.
            let lift = n * (widthMM * 0.05)
            let p0 = a + perp + lift, p1 = a - perp + lift
            let p2 = b + perp + lift, p3 = b - perp + lift
            func push(_ v: SIMD3<Double>) {
                out.append(Float(v.x)); out.append(Float(v.y)); out.append(Float(v.z))
            }
            push(p0); push(p1); push(p2)
            push(p1); push(p3); push(p2)
        }
        return out
    }


    /// The trace of ONE plane across the given faces, as a flat line list
    /// (x,y,z per vertex, two vertices per segment) in MODEL space.
    ///
    /// A triangle is crossed when its three vertices do not all share a sign
    /// against the plane; the segment joins the two edge crossings. Triangles
    /// entirely on one side contribute nothing, which is why this is cheap.
    public static func trace(plane: RegionCut, faces: Set<FaceID>,
                             in mesh: ViewerMesh) -> [Float] {
        guard !faces.isEmpty, simd_length(plane.normal) > 1e-12 else { return [] }
        let n = simd_normalize(plane.normal)
        var out: [Float] = []

        func signedDistance(_ p: SIMD3<Double>) -> Double { simd_dot(p - plane.point, n) }

        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            let f: Int32 = tri < mesh.faceIDs.count ? mesh.faceIDs[tri] : -1
            guard f >= 0, faces.contains(f) else { t += 3; continue }

            var p = [SIMD3<Double>](); p.reserveCapacity(3)
            var d = [Double](); d.reserveCapacity(3)
            for k in 0..<3 {
                let vi = Int(mesh.indices[t + k]) * 3
                guard vi + 2 < mesh.positions.count else { break }
                let v = SIMD3<Double>(SIMD3<Float>(mesh.positions[vi],
                                                   mesh.positions[vi + 1],
                                                   mesh.positions[vi + 2]))
                p.append(v); d.append(signedDistance(v))
            }
            guard p.count == 3 else { t += 3; continue }

            // Crossings on the three edges. A triangle the plane cuts has exactly
            // two; one that only touches at a vertex has fewer and is skipped —
            // a point is not a segment.
            var hits: [SIMD3<Double>] = []
            for e in 0..<3 {
                let a = e, b = (e + 1) % 3
                let da = d[a], db = d[b]
                guard (da < 0) != (db < 0) else { continue }
                let denom = da - db
                guard abs(denom) > 1e-15 else { continue }
                hits.append(p[a] + (p[b] - p[a]) * (da / denom))
            }
            if hits.count >= 2 {
                for v in [hits[0], hits[1]] {
                    out.append(Float(v.x)); out.append(Float(v.y)); out.append(Float(v.z))
                }
            }
            t += 3
        }
        return out
    }

    /// ★ CLIP EACH SEGMENT TO THE REGION — TRIM IT, DO NOT DROP IT.
    ///
    /// This used to keep or discard a whole segment by testing its MIDPOINT. A
    /// COLUMN line is short and survives; a ROW line runs the full length of the
    /// face and crosses the piece's boundary, so its midpoint lands in the sibling
    /// half and the entire line vanished. That is why a 4 x 2 grid drew its three
    /// column lines and no row line at all: "the two rows I'd selected is not
    /// visible".
    ///
    /// Clipping properly is the same work and exact: against each half-space, a
    /// segment is kept whole, dropped whole, or has its outside END moved to the
    /// crossing. Applied for every cut in turn, what remains is exactly the part of
    /// the line inside the piece.
    static func clip(_ segments: [Float], to cuts: [RegionCut]) -> [Float] {
        guard !cuts.isEmpty else { return segments }
        var out: [Float] = []
        var i = 0
        while i + 5 < segments.count {
            var a = SIMD3<Double>(Double(segments[i]), Double(segments[i + 1]),
                                  Double(segments[i + 2]))
            var b = SIMD3<Double>(Double(segments[i + 3]), Double(segments[i + 4]),
                                  Double(segments[i + 5]))
            i += 6

            var alive = true
            for cut in cuts {
                guard simd_length(cut.normal) > 1e-12 else { continue }
                let n = simd_normalize(cut.normal)
                let da = simd_dot(a - cut.point, n)
                let db = simd_dot(b - cut.point, n)
                if da < 0, db < 0 { alive = false; break }      // wholly outside
                if da >= 0, db >= 0 { continue }                // wholly inside
                let t = da / (da - db)                          // the crossing
                let x = a + (b - a) * t
                if da < 0 { a = x } else { b = x }              // trim the outside end
            }
            guard alive, simd_length(b - a) > 1e-9 else { continue }
            out.append(Float(a.x)); out.append(Float(a.y)); out.append(Float(a.z))
            out.append(Float(b.x)); out.append(Float(b.y)); out.append(Float(b.z))
        }
        return out
    }

    /// ★ EVERY COMMITTED CUT ON THE PART, as one line list — what the wireframe
    /// adds once a face has been divided.
    ///
    /// Only a region's OWN last cut is traced. A child inherits its parent's cuts,
    /// so tracing them all would draw each ancestor's boundary once per descendant
    /// — on a 3x3 pattern, the same nine lines nine times over.
    public static func committed(regions: FaceRegionModel, in mesh: ViewerMesh) -> [Float] {
        // ★ A UNION'S INTERNAL BOUNDARIES ARE NOT EDGES ANY MORE.
        //
        // The parts of a union keep existing — nothing is dissolved, because a
        // union must take only what it was given. But the line BETWEEN two parts
        // stopped being a boundary the moment they became one piece, and drawing it
        // says the opposite: "the split line is gone for a moment, then when you
        // try to select the full unioned face the cut line shows up again."
        var absorbed: Set<RegionID> = []
        for u in regions.regions where u.isUnionOfParts {
            for part in u.parts { absorbed.formUnion(regions.resolvedLeaves(part)) }
        }

        var out: [Float] = []
        for r in regions.regions where r.isCut {
            guard !absorbed.contains(r.id) else { continue }
            let faces = Set(FaceRegionGeometry.members(of: r, in: mesh))
            guard !faces.isEmpty else { continue }
            // ★ THE REGION SAYS WHICH OF ITS CUTS IS AN EDGE, AND THE LINE STOPS AT
            // THE PIECE.
            //
            // This used to be a guess — "the region's last cut, if it isn't strict"
            // — which is right for a two-way manual cut and wrong for every cell of
            // a grid, where the last cut is whichever bound happened to be appended
            // last. And it traced across the whole FACE, so on a curve a wedge plane
            // drew a second phantom line half a turn away. `FaceRegion.edges` names
            // the boundary; clipping to the region's other cuts keeps it on the
            // piece it bounds.
            for cut in r.drawnCuts {
                let others = r.cuts.filter { $0 != cut }
                out += clip(trace(plane: cut, faces: faces, in: mesh), to: others)
            }
        }
        return out
    }

    /// ★ §7 — THE PATTERN, BEFORE IT IS COMMITTED. Each grid cell is bounded by
    /// half-spaces; tracing every distinct bounding plane draws the grid the split
    /// would make, on the surface, so "what it will look like" is a question the
    /// preview answers rather than the result.
    ///
    /// Deduped by plane: adjacent cells share a boundary, and drawing it twice
    /// doubles every interior line (which reads as a thicker, mis-registered line
    /// rather than as one).
    /// `within` clips the trace to a region's own half-spaces — so a grid on ONE
    /// PIECE of a cut face stops at that piece's boundary instead of running on
    /// across its sibling ("The pattern is running across the multiple faces. It
    /// should just be a pattern *only* in the face that is selected").
    public static func preview(cells: [FaceRegionGeometry.GridCell],
                               face: FaceID, in mesh: ViewerMesh,
                               within: [RegionCut] = []) -> [Float] {
        // ★ EACH LINE IS DRAWN BY THE CELL THAT OWNS IT, AND CLIPPED TO THAT CELL.
        //
        // ★ WHY IT CANNOT BE DRAWN GLOBALLY. On a curve every divider is a WEDGE
        // plane hinged on the arc's axis (see `SurfacePatternArc`), and such a plane
        // meets the strip at its own angle AND again half a turn away. Traced across
        // the whole face it therefore draws a second, phantom line through the far
        // arm — the extra marks in the maintainer's screenshots, "three lines where
        // I asked for two". Clipped to the owning cell it can only appear where that
        // cell is, which is the one place it means anything.
        //
        // `drawn` is assigned so each interior boundary belongs to exactly ONE cell
        // (its lower bound), so this neither doubles a line nor drops one. Where a
        // grid has rows, a column divider is drawn once per row band and the bands
        // join up into the full line.
        func key(_ cut: RegionCut) -> String {
            let n = simd_normalize(cut.normal)
            let flip = (n.x + n.y + n.z) < 0
            let nn = flip ? -n : n
            return String(format: "%.4f,%.4f,%.4f,%.4f", nn.x, nn.y, nn.z,
                          simd_dot(cut.point, nn))
        }

        var out: [Float] = []
        for cell in cells {
            for cut in cell.drawnCuts {
                // ★ NOT AGAINST ITSELF. The trace lies exactly ON its own plane, and
                // clipping a segment against the plane it sits in is decided by float
                // noise — half the line survives and half does not.
                let k = key(cut)
                let bounds = cell.cuts.filter { key($0) != k } + within
                out += clip(trace(plane: cut, faces: [face], in: mesh), to: bounds)
            }
        }
        return out
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ §7 — WHICH WAY THE GRID RUNS

public enum SurfacePatternAxis {

    /// ★ A GRID IS SYMMETRIC EVERY 90°, so an angle outside one quarter-turn names
    /// a grid already reachable inside it. The rotate knob accumulated raw drag and
    /// showed **−405°** — a number that means the same thing as −45° and reads as a
    /// bug, because it is one. Folded into [-45, 45): the smallest angle that names
    /// the grid, and the one a person would have typed.
    public static func foldAngle(_ degrees: Double) -> Double {
        var a = degrees.truncatingRemainder(dividingBy: 90)
        if a >= 45 { a -= 90 }
        if a < -45 { a += 90 }
        // -0.0 is a real Double and prints as "-0"; normalise it away.
        return a == 0 ? 0 : a
    }


    /// ★ THE FACE'S LONGEST STRAIGHT EDGE, as an angle (degrees) in the region's
    /// own frame — the rotation that makes the grid run along the shape rather
    /// than across it (maintainer: "Pattern still needs to be in-line with the
    /// longest flat side").
    ///
    /// ★ WHY THE LONGEST EDGE AND NOT THE PCA. `FaceRegionGeometry.frame` orients
    /// itself by the principal axis of the member VERTICES — a good default for a
    /// blob, and the wrong one for a part: on a face with a long straight side and
    /// a curved one, the vertex cloud's principal axis is pulled off by wherever
    /// the tessellation happens to be dense. What a person means by "in line with
    /// the shape" is its longest STRAIGHT EDGE, which is a property of the boundary
    /// and not of the sampling.
    ///
    /// Returns 0 when the face has no boundary long enough to mean anything, which
    /// leaves the frame's own orientation in charge.
    public static func alignmentDegrees(face: FaceID, in mesh: ViewerMesh) -> Double {
        let frame = FaceRegionGeometry.frame(members: [face], in: mesh)
        guard frame.valid else { return 0 }

        // The face's boundary edges: used by exactly one of its own triangles.
        var uses: [EdgeKey: (count: Int, a: SIMD3<Double>, b: SIMD3<Double>)] = [:]
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            if tri < mesh.faceIDs.count, mesh.faceIDs[tri] == face {
                var p = [SIMD3<Double>]()
                for k in 0..<3 {
                    let vi = Int(mesh.indices[t + k]) * 3
                    guard vi + 2 < mesh.positions.count else { continue }
                    p.append(SIMD3<Double>(SIMD3<Float>(mesh.positions[vi],
                                                        mesh.positions[vi + 1],
                                                        mesh.positions[vi + 2])))
                }
                if p.count == 3 {
                    for e in 0..<3 {
                        let a = p[e], b = p[(e + 1) % 3]
                        let k = EdgeKey(a, b)
                        uses[k] = ((uses[k]?.count ?? 0) + 1, a, b)
                    }
                }
            }
            t += 3
        }

        // The longest boundary edge decides. Measured IN THE FRAME's plane, since
        // the grid is laid out in (u, v).
        var bestLen = 0.0
        var bestAngle = 0.0
        for (_, e) in uses where e.count == 1 {
            let d = e.b - e.a
            let du = simd_dot(d, frame.u), dv = simd_dot(d, frame.v)
            let len = (du * du + dv * dv).squareRoot()
            if len > bestLen {
                bestLen = len
                bestAngle = atan2(dv, du) * 180 / .pi
            }
        }
        guard bestLen > 1e-6 else { return 0 }
        return foldAngle(bestAngle)
    }

    /// Two positions on a quantised grid, so float noise cannot split one edge
    /// into two.
    struct EdgeKey: Hashable {
        let lo: SIMD3<Int64>
        let hi: SIMD3<Int64>
        init(_ a: SIMD3<Double>, _ b: SIMD3<Double>) {
            func q(_ v: SIMD3<Double>) -> SIMD3<Int64> {
                SIMD3<Int64>(Int64((v.x * 10_000).rounded()),
                             Int64((v.y * 10_000).rounded()),
                             Int64((v.z * 10_000).rounded()))
            }
            let qa = q(a), qb = q(b)
            let aFirst = (qa.x, qa.y, qa.z) <= (qb.x, qb.y, qb.z)
            lo = aFirst ? qa : qb
            hi = aFirst ? qb : qa
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: ★ §7 — DIVIDING A FACE INTO PIECES THAT ARE ACTUALLY ON IT

extension SurfacePatternAxis {

    /// ★ EQUAL AREA, NOT EQUAL PARAMETER (maintainer, 2026-08-15: "the columns and
    /// rows are not actually situated. There are meant to be 3 columns, only 2 are
    /// mostly visible and the third is barely in the face. You need to ensure that
    /// the rows and columns are limited to *within* the face").
    ///
    /// `FaceRegionGeometry.gridSplitCells` divides the frame's EXTENT evenly — n
    /// equal steps between uLo and uHi. On a rectangle that is also equal area, and
    /// the two ideas were never distinguished. On a real face they come apart hard:
    /// a tapered or curved strip has most of its material at one end, so equal
    /// parameter steps give wildly unequal pieces and the last one is a sliver
    /// clinging to the tip — exactly "the third is barely in the face".
    ///
    /// What a person means by "3 columns" is three pieces of comparable size. So
    /// the dividers go at the k/n QUANTILES of the face's own area along the axis:
    /// each piece then holds a third of the material, wherever the material is.
    ///
    /// Falls back to the frame's even division when the face gives no area to
    /// measure (a degenerate or empty face) — an even guess beats no grid.
    /// `within` confines the whole calculation to a PIECE of the face — its own
    /// half-spaces. Without it the grid is measured and placed over the WHOLE face
    /// while only the part inside the piece is drawn: the panel counts 4 pieces and
    /// three appear, one of them the wrong size. "The pattern still runs all the
    /// way through the full face even after a cut has been made."
    /// ★ REPLACED BY THE ARC SYSTEM (2026-08-16). Kept as the name the page and the
    /// tests call; the geometry now lives in `SurfacePatternArc`, which fits the
    /// strip's own circle and builds every cell as a wedge on its axis. See that
    /// file's header for what was actually wrong with the five rules this had
    /// accumulated — none of them was the division.
    ///
    /// `[]` means refused; `grid` carries the reason.
    public static func areaCells(face: FaceID, frame: FaceRegionGeometry.Frame,
                                 columns: Int, rows: Int,
                                 in mesh: ViewerMesh,
                                 within: [RegionCut] = []) -> [FaceRegionGeometry.GridCell] {
        switch grid(face: face, frame: frame, columns: columns, rows: rows,
                    in: mesh, within: within) {
        case .success(let cells): return cells
        case .failure:            return []
        }
    }

    /// The same split, WITH the reason when it refuses — so the panel can say
    /// "170° per piece is too wide to cut with a plane, use 3 or more" instead of
    /// leaving a disabled checkmark to be interpreted.
    public static func grid(face: FaceID, frame: FaceRegionGeometry.Frame,
                            columns: Int, rows: Int, in mesh: ViewerMesh,
                            within: [RegionCut] = [])
        -> Result<[FaceRegionGeometry.GridCell], SurfacePatternArc.Refusal> {
        guard frame.valid, columns >= 1, rows >= 1 else {
            return .failure(.init("This face cannot be divided."))
        }
        // ★ NO CYLINDRICAL SHORT-CIRCUIT. MEASURED ON HIS OWN PART.
        //
        // This used to hand a `frame.cylindrical` face straight to
        // `FaceRegionGeometry.gridSplitCells`, on the reasoning that "a cylindrical
        // frame is already an angular parametrisation, exactly what the arc system
        // derives — nothing to fit". That was an assumption and it was wrong.
        //
        // The frame's cylinder axis is the axis of the SURFACE — for a fillet band
        // running round a bend, that is the axis the band is swept ABOUT ITS OWN
        // WIDTH, not the axis it curves along. Dividing by angle about it therefore
        // divides the wrong way entirely. Measured on M2_verticalStand face 4, the
        // band the maintainer was actually patterning:
        //
        //     columns   old (cylindrical short-circuit)   arc system
        //        2              88 / 11                    49 / 50
        //        3              52 / 47 /  0               32 / 33 / 34
        //        4              34 / 54 / 11 / 0           24 / 25 / 25 / 25
        //
        // The zero is the whole of "Smallest piece: 0 voxels, floor 16" and of
        // "when I set 3 columns, there is only 1 cut in between, making 2 columns"
        // — the third piece held no surface, so only one divider had anything to
        // separate. Face 17 behaved identically (35 / 64 / 0 → 33 / 32 / 33).
        //
        // Every face goes through the arc system now. It derives the axis the strip
        // actually turns about, from the strip, rather than trusting the one the
        // CAD surface happens to be defined around.

        let polys = piecePolygons(face: face, in: mesh, within: within)
        guard !polys.isEmpty else {
            return .failure(.init("Nothing of this face is left to divide."))
        }

        // ★ TWO CENTRELINES, AND THE FACE DECIDES WHICH.
        //
        // A RIBBON is walked: `ribbonSpine` follows the triangle graph's longest
        // path, which on a strip is its centreline and goes the long way round a U
        // where no swept axis can.
        //
        // A PATCH is SWEPT: on a broad plate that same walk is a diagonal, and
        // equal steps along a diagonal are not equal division. `centroidSpine`
        // builds the line out of the surface's own material instead.
        //
        // ★ THE WALK IS USED WHEREVER IT ANSWERS, INCLUDING ON PATCHES — MEASURED,
        // NOT ASSUMED, AND THE FIRST ANSWER WAS THE WRONG ONE.
        //
        // I built `centroidSpine` expecting it to beat the walk on broad plates,
        // and on two of the three it does. On the third it is far worse, because a
        // slab perpendicular to the frame's axis crosses THAT face twice and the
        // weighted centroid lands between the two crossings — the same failure mode
        // that made a swept axis useless on a U. Measured on his part, three
        // columns:
        //
        //     face   ratio   walked        swept        pick
        //       4    0.02    32/33/34      —            walked   (the arc he reported)
        //      17    0.03    33/32/33      —            walked
        //      69    0.02    33/32/33      —            walked
        //      16    0.06    33/33/33      33/33/33     walked
        //      15    0.17    22/42/34      23/37/38     walked
        //       2    0.13    19/47/33      26/35/38     walked
        //       3    0.19    16/44/38      61/21/16     walked  ← the sweep breaks
        //
        // So the walk everywhere, and the sweep only where the walk declines
        // outright. A broad plate is imperfect (22/42/34 rather than thirds) and
        // that is a KNOWN, RECORDED limitation — its walked spine is a diagonal, so
        // equal steps along it are not equal division. It is not a refusal, not a
        // zero-area piece, and it is better than every alternative measured here.
        // ★ AND IF THE WALK PRODUCES A PIECE HOLDING NOTHING, THE SWEEP GETS A TURN.
        //
        // `SurfacePatternArc.cells` verifies that every piece holds surface and
        // refuses when one does not — measured on face 61 of his part, whose walked
        // spine doubles back so two boundaries landed together at four columns. The
        // two centrelines fail on DIFFERENT faces (the walk on a doubling-back
        // cylinder, the sweep on anything that crosses its own axis twice), so
        // trying the second when the first is refused rescues both without either
        // having to be right about everything.
        let candidates = [ribbonSpine(face: face, in: mesh, within: within),
                          centroidSpine(frame: frame, face: face, in: mesh,
                                        within: within)].compactMap { $0 }
        guard !candidates.isEmpty else {
            return .failure(.init("This face is too small to divide."))
        }
        var refusal = SurfacePatternArc.Refusal("This face is too small to divide.")
        for spine in candidates where spine.count >= 3 {
            switch SurfacePatternArc.cells(spine: spine, polygons: polys,
                                           columns: columns, rows: rows) {
            case .success(let cells): return .success(cells)
            case .failure(let r):     refusal = r
            }
        }
        return .failure(refusal)
    }

    /// ★ THE CENTRELINE OF A BROAD PATCH: the face swept in thin slabs along its
    /// long axis, each slab's AREA-WEIGHTED CENTROID a point on the line.
    ///
    /// ★ WHY A PATCH NEEDS ITS OWN SPINE. `ribbonSpine` walks the triangle graph
    /// for its longest path, which on a narrow strip IS the centreline and on a
    /// broad plate is a DIAGONAL, corner to corner. Equal steps along a diagonal
    /// are not equal division of a plate: measured on M2_verticalStand face 15
    /// (17,100 mm², a curved side wall), three columns came out 22 / 42 / 34.
    ///
    /// ★ AND WHY NOT JUST A STRAIGHT LINE. The obvious alternative — a straight run
    /// down the middle of the frame — is a CHORD, and these plates curve: face 15
    /// sweeps 172°. Equal steps along a chord are not equal along the surface, and
    /// it measured worse still (47 / 22 / 29). The swept centroid follows the bend
    /// because it is made of the surface's own material.
    ///
    /// This construction cannot serve a U — a slab there crosses both arms and the
    /// weighted centroid lands in the opening, on no surface at all — which is
    /// exactly why `ribbonSpine` exists and why the two are chosen between rather
    /// than one being used for everything.
    static func centroidSpine(frame: FaceRegionGeometry.Frame, face: FaceID,
                              in mesh: ViewerMesh,
                              within: [RegionCut]) -> [SIMD3<Double>]? {
        let (uLo, uHi, vLo, vHi) = pieceExtent(face: face, frame: frame,
                                               in: mesh, within: within)
        guard uHi > uLo, vHi > vLo else { return nil }
        let polys = piecePolygons(face: face, in: mesh, within: within)
        guard !polys.isEmpty else { return nil }

        let steps = 48
        let step = (uHi - uLo) / Double(steps)
        var out: [SIMD3<Double>] = []
        for i in 0..<steps {
            let a = uLo + Double(i) * step
            let slab = [RegionCut(point: frame.origin + frame.u * a, normal: frame.u),
                        RegionCut(point: frame.origin + frame.u * (a + step),
                                  normal: -frame.u)]
            var acc = SIMD3<Double>.zero
            var area = 0.0
            for poly in polys {
                let clipped = clipPolygon(poly, to: slab)
                guard clipped.count >= 3 else { continue }
                let w = polygonArea(clipped)
                guard w > 0 else { continue }
                acc += (clipped.reduce(SIMD3<Double>.zero, +) / Double(clipped.count)) * w
                area += w
            }
            if area > 0 { out.append(acc / area) }
        }
        return out.count >= 4 ? out : nil
    }

    /// ★ IS THIS FACE A RIBBON OR A PATCH? How far the surface reaches from the
    /// walked spine, against how long that spine is.
    ///
    /// A strip is everywhere close to its own centreline; a plate walked corner to
    /// corner is not. Measured on his part: the fillet bands 0.02 – 0.06, the broad
    /// side walls 0.13 – 0.19. The threshold sits in the gap, and it is a RATIO so
    /// it means the same thing on a 20 mm bracket and a 400 mm frame.
    static func spineWidthRatio(_ spine: [SIMD3<Double>],
                                polygons: [[SIMD3<Double>]]) -> Double {
        guard spine.count >= 2, !polygons.isEmpty else { return .greatestFiniteMagnitude }
        var length = 0.0
        for i in 1..<spine.count { length += simd_length(spine[i] - spine[i - 1]) }
        guard length > 1e-9 else { return .greatestFiniteMagnitude }
        var farthest = 0.0
        for poly in polygons {
            for p in poly {
                var nearest = Double.greatestFiniteMagnitude
                for q in spine { nearest = Swift.min(nearest, simd_length_squared(q - p)) }
                farthest = Swift.max(farthest, nearest.squareRoot())
            }
        }
        return farthest / length
    }

    /// Above this a face is treated as a PATCH and gets the swept-centroid
    /// centreline instead of the walked one. See `spineWidthRatio`.
    static let ribbonWidthRatio = 0.10


    /// The same plane, facing the other way — the upper bound of a cell.
    static func flip(_ c: RegionCut) -> RegionCut {
        RegionCut(point: c.point, normal: -c.normal, strict: true)
    }


    /// Dividers at equal distance along a spine, each facing along it — so the cut
    /// is square to the strip wherever the strip happens to be pointing.
    static func alongSpine(_ spine: [SIMD3<Double>], parts: Int) -> [RegionCut] {
        guard parts >= 2, spine.count >= 3 else { return [] }
        var cum: [Double] = [0]
        for i in 1..<spine.count {
            cum.append(cum[i - 1] + simd_length(spine[i] - spine[i - 1]))
        }
        guard let total = cum.last, total > 0 else { return [] }

        var out: [RegionCut] = []
        for k in 1..<parts {
            let want = total * Double(k) / Double(parts)
            var idx = spine.count - 1
            var f = 0.0
            for i in 1..<cum.count where cum[i] >= want {
                idx = i
                let d = cum[i] - cum[i - 1]
                f = d > 0 ? (want - cum[i - 1]) / d : 0
                break
            }
            let a = spine[max(0, idx - 1)], b = spine[idx]
            let point = a + (b - a) * f
            let lo = spine[max(0, idx - 1)], hi = spine[min(spine.count - 1, idx + 1)]
            var n = hi - lo
            if simd_length(n) < 1e-12 { n = b - a }
            guard simd_length(n) > 1e-12 else { continue }
            out.append(RegionCut(point: point, normal: simd_normalize(n)))
        }
        return out
    }

    /// ★ THE RIBBON'S SPINE — the face walked as a strip, not sliced by an axis.
    ///
    /// ★ WHY AN AXIS CANNOT DO THIS. Every earlier attempt parametrised the face by
    /// a plane sweeping along a straight axis. On a U-shaped strip — the inside
    /// curve of his part — such a plane cuts the strip TWICE, once through each arm.
    /// The slab then holds material from both, its area-weighted centroid lands out
    /// in the OPENING of the U where there is no surface at all, and the resulting
    /// "centreline" is a path through empty space. Arc measured along it means
    /// nothing: three columns came out as two bunched at the bottom and one at each
    /// end, and two columns put their divider at the far left. His own reading of
    /// the screenshot was exactly right — "it's assuming the two end pieces wrap
    /// around and are the same piece".
    ///
    /// A strip has a spine, and the way to find it is to WALK it: triangles are
    /// nodes, shared edges are links, and the ribbon's length is the longest path
    /// through that graph. Double-BFS finds it — farthest node from anywhere, then
    /// farthest from there — which is the standard way to find a graph's diameter
    /// and is exact on a ribbon. A U is then a U: the walk goes down one arm, round
    /// the bend and up the other, never jumping the gap.
    ///
    /// Returns nil when the face is not ribbon-like enough to have a spine (a broad
    /// patch, where the caller's axis walk is the better answer).
    static func ribbonSpine(face: FaceID, in mesh: ViewerMesh,
                            within: [RegionCut]) -> [SIMD3<Double>]? {
        // Triangles of this face, with their centroids — clipped to the piece.
        var centres: [SIMD3<Double>] = []
        var corners: [[SIMD3<Double>]] = []
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            guard tri < mesh.faceIDs.count, mesh.faceIDs[tri] == face else {
                t += 3; continue
            }
            var p = [SIMD3<Double>]()
            for k in 0..<3 {
                let vi = Int(mesh.indices[t + k]) * 3
                guard vi + 2 < mesh.positions.count else { break }
                p.append(SIMD3<Double>(SIMD3<Float>(mesh.positions[vi],
                                                    mesh.positions[vi + 1],
                                                    mesh.positions[vi + 2])))
            }
            t += 3
            guard p.count == 3 else { continue }
            let poly = within.isEmpty ? p : clipPolygon(p, to: within)
            guard poly.count >= 3, polygonArea(poly) > 0 else { continue }
            corners.append(p)
            centres.append(poly.reduce(SIMD3<Double>.zero, +) / Double(poly.count))
        }
        guard centres.count >= 4 else { return nil }

        // Adjacency: triangles sharing an edge.
        func q(_ v: SIMD3<Double>) -> SIMD3<Int64> {
            SIMD3<Int64>(Int64((v.x * 1e4).rounded()), Int64((v.y * 1e4).rounded()),
                         Int64((v.z * 1e4).rounded()))
        }
        var byEdge: [EdgeKey: [Int]] = [:]
        for (i, c) in corners.enumerated() {
            for e in 0..<3 {
                byEdge[EdgeKey(c[e], c[(e + 1) % 3]), default: []].append(i)
            }
        }
        var links = [[Int]](repeating: [], count: corners.count)
        for (_, tris) in byEdge where tris.count == 2 {
            links[tris[0]].append(tris[1])
            links[tris[1]].append(tris[0])
        }
        _ = q

        // ★ FARTHEST BY DISTANCE, NOT BY HOP COUNT.
        //
        // Breadth-first search finds the path with the FEWEST EDGES, and on a
        // triangulated ribbon that is not the longest path — it cuts corners
        // wherever the mesh offers a shortcut across the width, so the "spine"
        // stops short of the real ends and its arc is wrong. Weighting each link by
        // the distance between triangle centroids and sweeping by shortest-path
        // distance instead gives the ribbon's true geometric length.
        func sweep(_ from: Int) -> (farthest: Int, parent: [Int], dist: [Double]) {
            var dist = [Double](repeating: .greatestFiniteMagnitude, count: links.count)
            var parent = [Int](repeating: -1, count: links.count)
            var done = [Bool](repeating: false, count: links.count)
            dist[from] = 0
            // The graph is a few hundred nodes at most; a linear scan is simpler
            // than a heap and costs nothing here.
            for _ in 0..<links.count {
                var best = -1
                var bestD = Double.greatestFiniteMagnitude
                for i in links.indices where !done[i] && dist[i] < bestD {
                    bestD = dist[i]; best = i
                }
                guard best >= 0 else { break }
                done[best] = true
                for m in links[best] {
                    let step = simd_length(centres[m] - centres[best])
                    if dist[best] + step < dist[m] {
                        dist[m] = dist[best] + step
                        parent[m] = best
                    }
                }
            }
            var far = from
            var farD = 0.0
            for i in links.indices where dist[i] < .greatestFiniteMagnitude && dist[i] > farD {
                farD = dist[i]; far = i
            }
            return (far, parent, dist)
        }
        let a = sweep(0).farthest
        let (b, parent, _) = sweep(a)

        var path: [Int] = []
        var cur = b
        var guard_ = 0
        while cur >= 0, guard_ <= links.count {
            path.append(cur)
            cur = parent[cur]
            guard_ += 1
        }
        guard path.count >= 6, path.count * 3 >= corners.count else { return nil }

        // ★ SMOOTHED, BECAUSE THE WALK ZIGZAGS. A quad strip is two triangles per
        // step, and the adjacency path hops between them — so the raw spine
        // saw-tooths across the strip's width and its arc is inflated unevenly. On
        // a tapered strip that alone pushed three columns to 19% / 25% / 55%. A
        // three-point average removes the saw-tooth without moving the line.
        let raw = path.map { centres[$0] }
        var smooth = raw
        for _ in 0..<2 {
            var next = smooth
            for i in 1..<(smooth.count - 1) {
                next[i] = (smooth[i - 1] + smooth[i] * 2 + smooth[i + 1]) / 4
            }
            smooth = next
        }
        return smooth
    }



    /// The piece's own polygons: each of the face's triangles clipped to it, built
    /// once so the bisection is cheap.
    static func piecePolygons(face: FaceID, in mesh: ViewerMesh,
                              within: [RegionCut]) -> [[SIMD3<Double>]] {
        var out: [[SIMD3<Double>]] = []
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            guard tri < mesh.faceIDs.count, mesh.faceIDs[tri] == face else {
                t += 3; continue
            }
            var p = [SIMD3<Double>]()
            for k in 0..<3 {
                let vi = Int(mesh.indices[t + k]) * 3
                guard vi + 2 < mesh.positions.count else { break }
                p.append(SIMD3<Double>(SIMD3<Float>(mesh.positions[vi],
                                                    mesh.positions[vi + 1],
                                                    mesh.positions[vi + 2])))
            }
            t += 3
            guard p.count == 3 else { continue }
            let poly = within.isEmpty ? p : clipPolygon(p, to: within)
            if poly.count >= 3 { out.append(poly) }
        }
        return out
    }

    /// How much of those polygons lies below a line along `axis`.
    static func areaBelow(_ polys: [[SIMD3<Double>]], origin: SIMD3<Double>,
                          axis: SIMD3<Double>, below: Double) -> Double {
        let limit = RegionCut(point: origin + axis * below, normal: -axis)
        var total = 0.0
        for poly in polys {
            total += polygonArea(clipPolygon(poly, to: [limit]))
        }
        return total
    }

    /// ★ HOW MUCH OF THE PIECE LIES BELOW A LINE — the exact quantity the grid is
    /// divided by. Each triangle is clipped to the piece AND to the half-space
    /// below the line, and the surviving polygon's area is summed.
    static func clippedArea(face: FaceID, frame: FaceRegionGeometry.Frame,
                            in mesh: ViewerMesh, within: [RegionCut],
                            axis: SIMD3<Double>, below: Double) -> Double {
        // "Below `below` along `axis`" as a half-space: normal points BACK down the
        // axis, so the kept side is the one nearer the origin.
        let limit = RegionCut(point: frame.origin + axis * below, normal: -axis)
        var total = 0.0
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            guard tri < mesh.faceIDs.count, mesh.faceIDs[tri] == face else {
                t += 3; continue
            }
            var p = [SIMD3<Double>]()
            for k in 0..<3 {
                let vi = Int(mesh.indices[t + k]) * 3
                guard vi + 2 < mesh.positions.count else { break }
                p.append(SIMD3<Double>(SIMD3<Float>(mesh.positions[vi],
                                                    mesh.positions[vi + 1],
                                                    mesh.positions[vi + 2])))
            }
            t += 3
            guard p.count == 3 else { continue }
            let poly = clipPolygon(p, to: within + [limit])
            total += polygonArea(poly)
        }
        return total
    }

    /// The piece's reach along each axis, from the member vertices that lie inside
    /// its half-spaces. Falls back to the frame when the piece has no vertices of
    /// its own to measure.
    static func pieceExtent(face: FaceID, frame: FaceRegionGeometry.Frame,
                            in mesh: ViewerMesh,
                            within: [RegionCut]) -> (Double, Double, Double, Double) {
        var uLo = Double.greatestFiniteMagnitude, uHi = -Double.greatestFiniteMagnitude
        var vLo = Double.greatestFiniteMagnitude, vHi = -Double.greatestFiniteMagnitude
        var any = false
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            guard tri < mesh.faceIDs.count, mesh.faceIDs[tri] == face else {
                t += 3; continue
            }
            for k in 0..<3 {
                let vi = Int(mesh.indices[t + k]) * 3
                guard vi + 2 < mesh.positions.count else { continue }
                let p = SIMD3<Double>(SIMD3<Float>(mesh.positions[vi],
                                                   mesh.positions[vi + 1],
                                                   mesh.positions[vi + 2]))
                guard FaceRegionGeometry.inside(p, within) else { continue }
                let d = p - frame.origin
                let u = simd_dot(d, frame.u), v = simd_dot(d, frame.v)
                uLo = min(uLo, u); uHi = max(uHi, u)
                vLo = min(vLo, v); vHi = max(vHi, v)
                any = true
            }
            t += 3
        }
        // ★ AND THE CUT BOUNDARY ITSELF. A piece reaches all the way to the plane
        // that bounds it, but no VERTEX sits there — the half of a face bounded at
        // x = 20 may have vertices only at x = 0. Measured from vertices alone its
        // extent collapses and the grid refuses. The trace of each bounding plane
        // is exactly where the piece stops, so it belongs in the measurement.
        for cut in within {
            let seg = SurfaceCutLines.trace(plane: cut, faces: [face], in: mesh)
            var i = 0
            while i + 2 < seg.count {
                let p = SIMD3<Double>(Double(seg[i]), Double(seg[i + 1]),
                                      Double(seg[i + 2]))
                i += 3
                let d = p - frame.origin
                let u = simd_dot(d, frame.u), v = simd_dot(d, frame.v)
                uLo = min(uLo, u); uHi = max(uHi, u)
                vLo = min(vLo, v); vHi = max(vHi, v)
                any = true
            }
        }
        guard any, uHi > uLo, vHi > vLo else {
            return (frame.uLo, frame.uHi, frame.vLo, frame.vHi)
        }
        return (uLo, uHi, vLo, vHi)
    }

    /// One sample per triangle of the face: where it sits along each axis, and how
    /// much material it is.
    struct AreaSample { let u: Double; let v: Double; let area: Double }

    /// ★ CLIP THE TRIANGLE TO THE PIECE (Sutherland–Hodgman against each plane).
    ///
    /// Filtering whole triangles by whether a POINT of them is inside gets the
    /// piece's material badly wrong when a cut bounds it: the half of a face
    /// bounded at x = 20 may have vertices only at x = 0, so every surviving sample
    /// sits at one end and the quantiles collapse onto it. Clipping gives the
    /// piece's REAL polygon — the part of the triangle that is actually in it.
    static func clipPolygon(_ poly: [SIMD3<Double>],
                            to cuts: [RegionCut]) -> [SIMD3<Double>] {
        var current = poly
        for cut in cuts {
            guard simd_length(cut.normal) > 1e-12, current.count >= 3 else { return [] }
            let n = simd_normalize(cut.normal)
            func d(_ p: SIMD3<Double>) -> Double { simd_dot(p - cut.point, n) }
            var next: [SIMD3<Double>] = []
            for i in current.indices {
                let a = current[i], b = current[(i + 1) % current.count]
                let da = d(a), db = d(b)
                if da >= 0 { next.append(a) }
                if (da < 0) != (db < 0), abs(da - db) > 1e-15 {
                    next.append(a + (b - a) * (da / (da - db)))
                }
            }
            current = next
        }
        return current
    }

    /// The area of a planar polygon, by fanning from its first vertex.
    static func polygonArea(_ poly: [SIMD3<Double>]) -> Double {
        guard poly.count >= 3 else { return 0 }
        var acc = SIMD3<Double>.zero
        for i in 1..<(poly.count - 1) {
            acc += simd_cross(poly[i] - poly[0], poly[i + 1] - poly[0])
        }
        return simd_length(acc) / 2
    }

    static func areaSamples(face: FaceID, frame: FaceRegionGeometry.Frame,
                            in mesh: ViewerMesh,
                            within: [RegionCut] = []) -> [AreaSample] {
        var out: [AreaSample] = []
        var t = 0
        while t + 2 < mesh.indices.count {
            let tri = t / 3
            guard tri < mesh.faceIDs.count, mesh.faceIDs[tri] == face else {
                t += 3; continue
            }
            var p = [SIMD3<Double>]()
            for k in 0..<3 {
                let vi = Int(mesh.indices[t + k]) * 3
                guard vi + 2 < mesh.positions.count else { break }
                p.append(SIMD3<Double>(SIMD3<Float>(mesh.positions[vi],
                                                    mesh.positions[vi + 1],
                                                    mesh.positions[vi + 2])))
            }
            t += 3
            guard p.count == 3 else { continue }
            // ★ ONLY THE PART OF THIS TRIANGLE THAT IS IN THE PIECE.
            let poly = within.isEmpty ? p : clipPolygon(p, to: within)
            guard poly.count >= 3 else { continue }
            let area = polygonArea(poly)
            guard area > 0 else { continue }

            // ★ ONE SAMPLE PER VERTEX, EACH CARRYING A THIRD OF THE AREA — not one
            // lump at the centroid.
            //
            // A centroid puts a triangle's whole mass at a single position. On a
            // coarse piece — a handful of long triangles — the cumulative
            // distribution is then a staircase, and several quantiles fall inside
            // one step: the dividers bunch together instead of spreading across the
            // piece. That is a grid that "isn't going all the way across the face"
            // even when it is on the right one. Spreading the mass over the
            // triangle's own extent smooths it at no cost.
            for v in poly {
                let c = v - frame.origin
                out.append(AreaSample(u: simd_dot(c, frame.u),
                                      v: simd_dot(c, frame.v),
                                      area: area / Double(poly.count)))
            }
        }
        return out
    }

    /// The `parts - 1` positions that split the weighted samples into `parts` equal
    /// shares of total weight, INTERPOLATED and bounded by the face's own extent.
    ///
    /// ★ INTERPOLATED, NOT SNAPPED TO A SAMPLE. Snapping put every divider on a
    /// triangle centroid, and a coarse face has few of those: two quantile
    /// boundaries could land on the SAME centroid, giving two identical dividers.
    /// Identical dividers make coincident cells — no line is drawn between them and
    /// a tap lands in both. Six pieces asked for, three delivered, one selectable
    /// as two. Interpolating between the bracketing samples gives a distinct
    /// position for every quantile even on a two-triangle face.
    ///
    /// `lo`/`hi` are the face's extent along the axis, so the result is bounded by
    /// the face rather than by where its triangles happen to be centred.
    static func quantiles(_ samples: [(Double, Double)], parts: Int,
                          lo: Double, hi: Double) -> [Double] {
        guard parts >= 2, hi > lo else { return [] }
        let sorted = samples.sorted { $0.0 < $1.0 }
        let total = sorted.reduce(0.0) { $0 + $1.1 }
        guard total > 0 else { return [] }

        // The cumulative distribution as (position, weight-so-far), anchored at the
        // face's own edges so a quantile can fall outside the centroid range.
        var xs: [Double] = [lo]
        var ws: [Double] = [0]
        var acc = 0.0
        for (pos, w) in sorted {
            acc += w
            xs.append(min(max(pos, lo), hi))
            ws.append(acc)
        }
        xs.append(hi); ws.append(total)

        var out: [Double] = []
        for k in 1..<parts {
            let target = total * Double(k) / Double(parts)
            var pos = hi
            for i in 1..<ws.count where ws[i] >= target {
                let w0 = ws[i - 1], w1 = ws[i]
                let t = w1 > w0 ? (target - w0) / (w1 - w0) : 0
                pos = xs[i - 1] + (xs[i] - xs[i - 1]) * t
                break
            }
            out.append(pos)
        }

        // ★ STRICTLY INCREASING, WITH ROOM BETWEEN. A cell needs width; dividers
        // closer than this hold no surface between them.
        let minGap = (hi - lo) * 1e-3
        for i in out.indices {
            if i > 0, out[i] - out[i - 1] < minGap { return [] }
            if out[i] - lo < minGap || hi - out[i] < minGap { return [] }
        }
        return out
    }
}
