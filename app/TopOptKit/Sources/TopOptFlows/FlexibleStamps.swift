// FlexibleStamps — the stamp library (docs/design/flexibles/data/stamps.json, bundled
// as-is), and the APP's half of M14: turning a shape into core's pressure grid.
//
// ★ M14: "the app turns a shape into a pressure grid; core never reads an SVG or image."
// This file is that turn and nothing more. It does not press the grid on a lattice
// (core's check_stamp) and it does not decide what a column feels (core's stamp_on_columns).
//
// ★ C1 problem #6 / #16: rasterise at NO MORE THAN HALF the column pitch, so a column the
// stamp's edge crosses sees a fair average. `cellMM = pitch / 2`.
//
// ★ FORCE: the values are scaled so Σ value × cell² = the stated weight exactly; core
// refuses a grid off by more than 0.5 % (stamp_grid_error), and the app checks it with
// that same function before it sends one.

import CoreGraphics
import Foundation
import ImageIO
import TopOptKit

/// One built-in stamp, as stamps.json states it.
public struct FlexibleStampShape: Decodable, Equatable, Sendable, Identifiable {
    public struct Member: Decodable, Equatable, Sendable {
        public let shape: String
        public let widthMM: Double?
        public let lengthMM: Double?
        public let offsetMM: [Double]?
        enum CodingKeys: String, CodingKey {
            case shape, widthMM = "width_mm", lengthMM = "length_mm", offsetMM = "offset_mm"
        }
    }
    public let id: String
    public let name: String
    /// ellipse | circle | rounded_rect | group | whole_face
    public let shape: String
    public let widthMM: Double?
    public let lengthMM: Double?
    public let cornerMM: Double?
    public let diameterMM: Double?
    public let members: [Member]?
    /// soft | rigid
    public let press: String
    public let note: String?
    enum CodingKeys: String, CodingKey {
        case id, name, shape, press, note, members
        case widthMM = "width_mm", lengthMM = "length_mm", cornerMM = "corner_mm"
        case diameterMM = "diameter_mm"
    }

    /// The stamp's natural size (mm): its width and length at the stated adult size.
    public var naturalSizeMM: (width: Double, length: Double) {
        switch shape {
        case "circle": return (diameterMM ?? 0, diameterMM ?? 0)
        case "group":
            var xl = Double.infinity, xh = -Double.infinity, yl = Double.infinity, yh = -Double.infinity
            for m in members ?? [] {
                let o = m.offsetMM ?? [0, 0], w = (m.widthMM ?? 0) / 2, l = (m.lengthMM ?? 0) / 2
                xl = min(xl, o[0] - w); xh = max(xh, o[0] + w)
                yl = min(yl, o[1] - l); yh = max(yh, o[1] + l)
            }
            return xl.isFinite ? (xh - xl, yh - yl) : (0, 0)
        default: return (widthMM ?? 0, lengthMM ?? 0)
        }
    }
}

public struct FlexibleStampLibrary: Decodable, Equatable, Sendable {
    public let status: String
    public let stamps: [FlexibleStampShape]
    public func shape(_ id: String) -> FlexibleStampShape? { stamps.first { $0.id == id } }

    public static func load(path: String) throws -> FlexibleStampLibrary {
        try JSONDecoder().decode(FlexibleStampLibrary.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }
}

/// Where the bundled Flexible data lives: the app bundle (Xcode Resources phase, core's
/// own files — never a second copy), or a path the caller states (tests, tools).
public enum FlexibleResources {
    public static var materialsPath: String? {
        Bundle.main.path(forResource: "flexible_materials", ofType: "json")
    }
    public static var stampsPath: String? {
        Bundle.main.path(forResource: "stamps", ofType: "json")
    }
}

public enum FlexibleStamps {

    /// The rasterisation cell for a face whose columns are `pitchMM` apart (C1 #6).
    public static func cellMM(pitchMM: Double) -> Double { pitchMM / 2 }

    /// A new placement of a library stamp at the face centre, at its adult size.
    public static func place(_ shape: FlexibleStampShape, uExtentMM: Double, vExtentMM: Double,
                             weightKg: Double) -> FlexibleStampPlacement {
        let size = shape.naturalSizeMM
        return FlexibleStampPlacement(source: .library(shape.id), widthMM: size.width,
                                      lengthMM: size.length, centreU: uExtentMM / 2,
                                      centreV: vExtentMM / 2, weightKg: weightKg,
                                      rigid: shape.press == "rigid")
    }

    /// The pressure grid core reads. `onFace(u, v)` says whether a point is on the face
    /// (a column exists there); `whole_face` stamps cover exactly those points.
    public static func grid(_ p: FlexibleStampPlacement, library: FlexibleStampLibrary?,
                            uExtentMM: Double, vExtentMM: Double, pitchMM: Double,
                            onFace: (Double, Double) -> Bool) -> FlexStamp? {
        let cell = cellMM(pitchMM: pitchMM)
        guard cell > 0 else { return nil }
        let force = FlexibleUnits.newtons(kg: p.weightKg)
        let name: String
        let value: (Double, Double) -> Double       // local (x along width, y along length)
        var wholeFace = false
        switch p.source {
        case .library(let id):
            guard let s = library?.shape(id) else { return nil }
            name = s.name
            if s.shape == "whole_face" { wholeFace = true; value = { _, _ in 1 } }
            else { value = shapeValue(s, widthMM: p.widthMM, lengthMM: p.lengthMM) }
        case .imported(let n, let side, let mask, _):
            name = n
            value = maskValue(side: side, mask: mask, widthMM: p.widthMM, lengthMM: p.lengthMM)
        }
        // the grid's extent: the whole face, or the rotated stamp's bounding box
        var u0: Double, v0: Double, u1: Double, v1: Double
        if wholeFace {
            (u0, v0, u1, v1) = (0, 0, uExtentMM, vExtentMM)
        } else {
            let th = p.rotationDeg * .pi / 180, c = abs(cos(th)), s = abs(sin(th))
            let hw = (p.widthMM * c + p.lengthMM * s) / 2, hl = (p.widthMM * s + p.lengthMM * c) / 2
            (u0, v0, u1, v1) = (p.centreU - hw, p.centreV - hl, p.centreU + hw, p.centreV + hl)
        }
        let nu = max(1, Int(((u1 - u0) / cell).rounded(.up)))
        let nv = max(1, Int(((v1 - v0) / cell).rounded(.up)))
        let th = -p.rotationDeg * .pi / 180, ct = cos(th), st = sin(th)
        let sub = 3
        var raw = [Double](repeating: 0, count: nu * nv)
        for iv in 0..<nv {
            for iu in 0..<nu {
                var acc = 0.0
                for sv in 0..<sub {
                    for su in 0..<sub {
                        let u = u0 + (Double(iu) + (Double(su) + 0.5) / Double(sub)) * cell
                        let v = v0 + (Double(iv) + (Double(sv) + 0.5) / Double(sub)) * cell
                        if wholeFace {
                            acc += onFace(u, v) ? 1 : 0
                        } else {
                            let du = u - p.centreU, dv = v - p.centreV
                            acc += value(du * ct - dv * st, du * st + dv * ct)
                        }
                    }
                }
                raw[iv * nu + iu] = acc / Double(sub * sub)
            }
        }
        let total = raw.reduce(0, +) * cell * cell
        guard total > 0, force > 0 else { return nil }
        let scale = force / total
        return FlexStamp(name: name, originU: u0, originV: v0, cellMM: cell, nu: nu, nv: nv,
                         valuesMPa: raw.map { $0 * scale }, forceN: force, rigid: p.rigid)
    }

    /// 1 inside the built-in shape at this size, else 0 (local coordinates, centred).
    static func shapeValue(_ s: FlexibleStampShape, widthMM: Double,
                           lengthMM: Double) -> (Double, Double) -> Double {
        let nat = s.naturalSizeMM
        let kx = nat.width > 0 ? widthMM / nat.width : 1
        let ky = nat.length > 0 ? lengthMM / nat.length : 1
        func ellipse(_ x: Double, _ y: Double, _ w: Double, _ l: Double) -> Bool {
            guard w > 0, l > 0 else { return false }
            let a = x / (w / 2), b = y / (l / 2)
            return a * a + b * b <= 1
        }
        switch s.shape {
        case "ellipse": return { x, y in ellipse(x, y, widthMM, lengthMM) ? 1 : 0 }
        case "circle": return { x, y in ellipse(x, y, widthMM, lengthMM) ? 1 : 0 }
        case "rounded_rect":
            let r = (s.cornerMM ?? 0) * min(kx, ky)
            return { x, y in
                let hx = widthMM / 2, hy = lengthMM / 2
                guard abs(x) <= hx, abs(y) <= hy else { return 0 }
                let dx = max(0, abs(x) - (hx - r)), dy = max(0, abs(y) - (hy - r))
                return dx * dx + dy * dy <= r * r ? 1 : 0
            }
        case "group":
            // the members at their offsets, relative to the group's own centre, scaled
            var xl = Double.infinity, xh = -Double.infinity, yl = Double.infinity, yh = -Double.infinity
            for m in s.members ?? [] {
                let o = m.offsetMM ?? [0, 0], w = (m.widthMM ?? 0) / 2, l = (m.lengthMM ?? 0) / 2
                xl = min(xl, o[0] - w); xh = max(xh, o[0] + w); yl = min(yl, o[1] - l); yh = max(yh, o[1] + l)
            }
            let cx = (xl + xh) / 2, cy = (yl + yh) / 2
            let members = s.members ?? []
            return { x, y in
                for m in members {
                    let o = m.offsetMM ?? [0, 0]
                    if ellipse(x - (o[0] - cx) * kx, y - (o[1] - cy) * ky,
                               (m.widthMM ?? 0) * kx, (m.lengthMM ?? 0) * ky) { return 1 }
                }
                return 0
            }
        default: return { _, _ in 0 }
        }
    }

    /// An imported mask stretched over widthMM × lengthMM (nearest sample).
    static func maskValue(side: Int, mask: [Double], widthMM: Double,
                          lengthMM: Double) -> (Double, Double) -> Double {
        { x, y in
            guard side > 0, widthMM > 0, lengthMM > 0 else { return 0 }
            let fx = x / widthMM + 0.5, fy = 0.5 - y / lengthMM   // image rows run downwards
            guard fx >= 0, fx < 1, fy >= 0, fy < 1 else { return 0 }
            let i = min(side - 1, Int(fx * Double(side))), j = min(side - 1, Int(fy * Double(side)))
            return mask[j * side + i]
        }
    }
}

// MARK: - import (M14: SVG outline, or an image where greyscale = pressure)

public enum FlexibleStampImport {
    public static let side = 128

    public enum ImportError: Error, Equatable, CustomStringConvertible {
        case unreadable
        case empty
        public var description: String {
            switch self {
            case .unreadable: return "That file could not be read as an SVG or an image."
            case .empty: return "Nothing in that file presses: no filled shape, or an all-white image."
            }
        }
    }

    /// An image: alpha or dark pixels = contact; darker presses harder (stamps.json "import").
    public static func image(data: Data, name: String) throws -> FlexibleStampSource {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw ImportError.unreadable }
        let aspect = Double(img.height) > 0 ? Double(img.width) / Double(img.height) : 1
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &rgba, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw ImportError.unreadable }
        ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: side, height: side))
        var mask = [Double](repeating: 0, count: side * side)
        for k in 0..<(side * side) {
            let a = Double(rgba[4 * k + 3]) / 255
            guard a > 0 else { continue }
            // un-premultiply, then darkness = 1 − luminance
            let r = Double(rgba[4 * k]) / 255 / a, g = Double(rgba[4 * k + 1]) / 255 / a
            let b = Double(rgba[4 * k + 2]) / 255 / a
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            mask[k] = max(0, min(1, (1 - lum))) * a
        }
        guard mask.contains(where: { $0 > 0.01 }) else { throw ImportError.empty }
        return .imported(name: name, side: side, mask: mask, aspect: aspect)
    }

    /// An SVG: closed paths (and rect/circle/ellipse/polygon) filled, even pressure.
    public static func svg(text: String, name: String) throws -> FlexibleStampSource {
        let path = SVGOutline.path(from: text)
        let box = path.boundingBoxOfPath
        guard !path.isEmpty, box.width > 0, box.height > 0 else { throw ImportError.empty }
        var grey = [UInt8](repeating: 0, count: side * side)
        guard let ctx = CGContext(data: &grey, width: side, height: side, bitsPerComponent: 8,
                                  bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { throw ImportError.unreadable }
        // fit the outline's box to the square; the true aspect is kept separately.
        // SVG y runs down, the bitmap's up: flip so the stamp is not mirrored.
        ctx.translateBy(x: 0, y: CGFloat(side))
        ctx.scaleBy(x: CGFloat(side) / box.width, y: -CGFloat(side) / box.height)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        ctx.addPath(path)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fillPath(using: .evenOdd)
        // CGContext's row 0 is the TOP row of the flipped drawing, matching maskValue.
        let mask = grey.map { Double($0) / 255 }
        guard mask.contains(where: { $0 > 0.01 }) else { throw ImportError.empty }
        return .imported(name: name, side: side, mask: mask, aspect: Double(box.width / box.height))
    }
}

/// The small SVG subset an outline stamp needs: <path d>, <rect>, <circle>, <ellipse>,
/// <polygon>, <polyline>. Transforms and styles are ignored (an outline is a shape).
enum SVGOutline {
    static func path(from svg: String) -> CGPath {
        let p = CGMutablePath()
        for el in elements(svg) {
            let a = el.attrs
            func n(_ k: String) -> CGFloat { CGFloat(Double(a[k] ?? "") ?? 0) }
            switch el.name {
            case "path": if let d = a["d"] { addPathData(d, to: p) }
            case "rect":
                p.addRect(CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height")))
            case "circle":
                let r = n("r")
                p.addEllipse(in: CGRect(x: n("cx") - r, y: n("cy") - r, width: 2 * r, height: 2 * r))
            case "ellipse":
                let rx = n("rx"), ry = n("ry")
                p.addEllipse(in: CGRect(x: n("cx") - rx, y: n("cy") - ry, width: 2 * rx, height: 2 * ry))
            case "polygon", "polyline":
                let v = numbers(a["points"] ?? "")
                guard v.count >= 4 else { continue }
                p.move(to: CGPoint(x: v[0], y: v[1]))
                var i = 2
                while i + 1 < v.count { p.addLine(to: CGPoint(x: v[i], y: v[i + 1])); i += 2 }
                p.closeSubpath()
            default: break
            }
        }
        return p
    }

    struct Element { let name: String; let attrs: [String: String] }

    static func elements(_ s: String) -> [Element] {
        var out: [Element] = []
        let scanner = s as NSString
        let re = try? NSRegularExpression(pattern: "<\\s*([a-zA-Z]+)([^>]*)>", options: [])
        let attrRe = try? NSRegularExpression(pattern: "([a-zA-Z:-]+)\\s*=\\s*[\"']([^\"']*)[\"']", options: [])
        for m in re?.matches(in: s, range: NSRange(location: 0, length: scanner.length)) ?? [] {
            let name = scanner.substring(with: m.range(at: 1)).lowercased()
            let body = scanner.substring(with: m.range(at: 2)) as NSString
            var attrs: [String: String] = [:]
            for am in attrRe?.matches(in: body as String, range: NSRange(location: 0, length: body.length)) ?? [] {
                attrs[body.substring(with: am.range(at: 1))] = body.substring(with: am.range(at: 2))
            }
            out.append(Element(name: name, attrs: attrs))
        }
        return out
    }

    static func numbers(_ s: String) -> [CGFloat] {
        var out: [CGFloat] = []
        let re = try? NSRegularExpression(pattern: "[-+]?(?:\\d+\\.?\\d*|\\.\\d+)(?:[eE][-+]?\\d+)?")
        let ns = s as NSString
        for m in re?.matches(in: s, range: NSRange(location: 0, length: ns.length)) ?? [] {
            if let v = Double(ns.substring(with: m.range)) { out.append(CGFloat(v)) }
        }
        return out
    }

    /// Path data: M L H V C S Q T Z (absolute and relative); A is taken as a line to its
    /// end point (an outline stamp's area barely changes).
    static func addPathData(_ d: String, to p: CGMutablePath) {
        let re = try? NSRegularExpression(pattern: "([MmLlHhVvCcSsQqTtAaZz])([^MmLlHhVvCcSsQqTtAaZz]*)")
        let ns = d as NSString
        var cur = CGPoint.zero, start = CGPoint.zero, lastCtrl: CGPoint? = nil
        for m in re?.matches(in: d, range: NSRange(location: 0, length: ns.length)) ?? [] {
            let cmd = Character(ns.substring(with: m.range(at: 1)))
            let v = numbers(ns.substring(with: m.range(at: 2)))
            let rel = cmd.isLowercase
            func pt(_ i: Int) -> CGPoint {
                let q = CGPoint(x: v[i], y: v[i + 1])
                return rel ? CGPoint(x: cur.x + q.x, y: cur.y + q.y) : q
            }
            switch cmd.uppercased() {
            case "M":
                var i = 0
                while i + 1 < v.count {
                    let q = pt(i)
                    if i == 0 { p.move(to: q); start = q } else { p.addLine(to: q) }
                    cur = q; i += 2
                }
                lastCtrl = nil
            case "L":
                var i = 0
                while i + 1 < v.count { cur = pt(i); p.addLine(to: cur); i += 2 }
                lastCtrl = nil
            case "H":
                for x in v { cur = CGPoint(x: rel ? cur.x + x : x, y: cur.y); p.addLine(to: cur) }
                lastCtrl = nil
            case "V":
                for y in v { cur = CGPoint(x: cur.x, y: rel ? cur.y + y : y); p.addLine(to: cur) }
                lastCtrl = nil
            case "C":
                var i = 0
                while i + 5 < v.count {
                    let c1 = pt(i), c2 = pt(i + 2), e = pt(i + 4)
                    p.addCurve(to: e, control1: c1, control2: c2); cur = e; lastCtrl = c2; i += 6
                }
            case "S":
                var i = 0
                while i + 3 < v.count {
                    let c1 = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                    let c2 = pt(i), e = pt(i + 2)
                    p.addCurve(to: e, control1: c1, control2: c2); cur = e; lastCtrl = c2; i += 4
                }
            case "Q":
                var i = 0
                while i + 3 < v.count {
                    let c = pt(i), e = pt(i + 2)
                    p.addQuadCurve(to: e, control: c); cur = e; lastCtrl = c; i += 4
                }
            case "T":
                var i = 0
                while i + 1 < v.count {
                    let c = lastCtrl.map { CGPoint(x: 2 * cur.x - $0.x, y: 2 * cur.y - $0.y) } ?? cur
                    let e = pt(i)
                    p.addQuadCurve(to: e, control: c); cur = e; lastCtrl = c; i += 2
                }
            case "A":
                var i = 0
                while i + 6 < v.count { cur = pt(i + 5); p.addLine(to: cur); i += 7 }
                lastCtrl = nil
            case "Z":
                p.closeSubpath(); cur = start; lastCtrl = nil
            default: break
            }
        }
    }
}
