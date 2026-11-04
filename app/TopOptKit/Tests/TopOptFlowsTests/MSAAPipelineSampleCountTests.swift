// MSAAPipelineSampleCountTests — his iPad crash 2026-11-04 18:40 (and the same one 2026-11-03 15:03): Outlines on aborted the
// app in MeshRenderer.encode at MetalMeshView.swift:3712, `setRenderPipelineState(wideLinePipeline)`. The wide-line pipeline
// was built without `rasterSampleCount`, so it was 1× while the colour pass it draws into is the 4× MSAA one (§3b), and the
// iPad's Metal validation aborts on the mismatch. (The macOS test hosts run without Metal validation, so no hosted test saw it.)
//
// Every pipeline that draws into the MSAA colour pass, i.e. its colour attachment 0 is `Self.colorFormat`, must set
// `rasterSampleCount = raster`. The G-buffer, id, shadow and AO pipelines draw into their own 1× targets and are left alone.
// RED CONTROL: the descriptor block as it shipped in release 0c4d5c9c (no rasterSampleCount) is caught.
import XCTest

final class MSAAPipelineSampleCountTests: XCTestCase {

    /// Each `let X = MTLRenderPipelineDescriptor()` … `makeRenderPipelineState(descriptor: X)` block of a source.
    static func blocks(_ code: String) -> [(name: String, body: String)] {
        let start = try! NSRegularExpression(pattern: #"let (\w+) = MTLRenderPipelineDescriptor\(\)"#)
        let ns = code as NSString
        return start.matches(in: code, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let name = ns.substring(with: m.range(at: 1))
            let rest = ns.substring(from: m.range.location)
            guard let end = rest.range(of: "makeRenderPipelineState(descriptor: \(name))") else { return nil }
            return (name, String(rest[rest.startIndex..<end.upperBound]))
        }
    }

    /// The MSAA-pass pipelines that do not take the pass's sample count.
    static func offenders(_ code: String) -> [String] {
        blocks(code).filter { b in
            b.body.contains("\(b.name).colorAttachments[0].pixelFormat = Self.colorFormat")
                && !b.body.contains("\(b.name).rasterSampleCount = raster")
        }.map(\.name)
    }

    func testEveryPipelineInTheMSAAPassTakesItsSampleCount() throws {
        let code = try FlexibleSource.code("MetalMeshView.swift")
        let all = Self.blocks(code)
        XCTAssertGreaterThanOrEqual(all.count, 15, "the pipeline blocks are found (\(all.map(\.name)))")
        XCTAssertTrue(all.contains { $0.name == "wd" }, "the wide-line (Outlines) pipeline is one of them")
        XCTAssertEqual(Self.offenders(code), [], "★ a pipeline drawn into the 4× MSAA colour pass is built 1×: the iPad aborts")
        // RED CONTROL: the wide-line block as released in 0c4d5c9c
        let released = """
            let wd = MTLRenderPipelineDescriptor()
            wd.colorAttachments[0].pixelFormat = Self.colorFormat
            wd.depthAttachmentPixelFormat = Self.depthFormat
            wideLinePipeline = try? device.makeRenderPipelineState(descriptor: wd)
            """
        XCTAssertEqual(Self.offenders(released), ["wd"], "★ RED CONTROL: the released Outlines pipeline is caught")
    }
}
