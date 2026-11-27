// UnreadableProjectEvidenceGen — the "Can’t open" card for round 3 ruling (c), rendered offscreen
// from the app's own view (`UnreadableProjectCard`). Opt-in: TOPOPT_UNREADABLE_EVIDENCE=1 writes
// evidence/2026-10-01-cant-open/; without it the test SKIPS.

#if canImport(SwiftUI) && os(macOS)
import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import TopOptDesign
@testable import TopOptFlows

@MainActor
final class UnreadableProjectEvidenceGen: XCTestCase {
    func testWriteTheCantOpenCards() throws {
        guard ProcessInfo.processInfo.environment["TOPOPT_UNREADABLE_EVIDENCE"] == "1" else {
            throw XCTSkip("set TOPOPT_UNREADABLE_EVIDENCE=1")
        }
        var dir = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { dir.deleteLastPathComponent() }
        dir.appendPathComponent("evidence/2026-10-01-cant-open", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID(uuidString: "102117B9-DDD2-4597-9BDE-49DD47EBF393")!
        let cards: [UnreadableProject] = [
            // what his 102117B9 said before fix 1, in the store's words
            UnreadableProject(id: id, name: "M2 verticalStand",
                              reason: "“startMM” is missing in lattice › wallThickness › faces › f:820422E9-A2C0-4546-95C2-B1AD18E207DC:2",
                              modifiedAt: nil),
            UnreadableProject(id: UUID(uuidString: "0000BEEF-0000-0000-0000-000000000000")!, name: "Bracket",
                              reason: "it was saved by a newer version of TopOpt", modifiedAt: nil),
            UnreadableProject(id: UUID(uuidString: "0000CAFE-0000-0000-0000-000000000000")!, name: nil,
                              reason: "project.json is missing", modifiedAt: nil),
        ]
        let view = HStack(alignment: .top, spacing: DS.Space.xl3) {
            ForEach(cards) { UnreadableProjectCard(entry: $0).frame(width: 300) }
        }
        .padding(DS.Space.xl6)
        .background(DS.Color.background.color)
        .environment(\.colorScheme, .dark)
        let r = ImageRenderer(content: view)
        r.scale = 2
        let image = try XCTUnwrap(r.cgImage)
        let url = dir.appendingPathComponent("cant_open_cards.png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        print("UNREADABLE-EVIDENCE wrote \(url.path)")
    }
}
#endif
