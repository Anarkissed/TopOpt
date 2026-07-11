// PlaybackVideo.swift — export the optimization-history playback as a video.
//
// Renders the variant's keyframe meshes (solid → carved-out) offscreen through the
// SAME Metal renderer the viewer uses, holds each frame briefly, and encodes an
// H.264 .mp4 via AVAssetWriter. Because `renderOffscreen` + AVFoundation both work
// headlessly on macOS, the whole pipeline is unit-tested (a real .mp4 is produced
// and validated) — only the on-device share sheet + button feel are device QA.

import Foundation
import AVFoundation
import CoreVideo
import Metal
import TopOptDesign

public enum VideoExportError: Error, Equatable, CustomStringConvertible {
    case noFrames
    case noRenderer
    case writerSetup
    case encodeFailed
    case writerFailed(String)

    public var description: String {
        switch self {
        case .noFrames: return "Nothing to export yet."
        case .noRenderer: return "Couldn’t start the renderer."
        case .writerSetup: return "Couldn’t set up the video writer."
        case .encodeFailed: return "A frame failed to encode."
        case .writerFailed(let s): return "Video writing failed: \(s)"
        }
    }
}

/// Renders playback keyframes to an .mp4. Value type; `export` is blocking (call it
/// off the main thread).
public struct VideoExporter {
    /// Output square size in pixels.
    public var size: Int
    /// Playback frame rate.
    public var fps: Int
    /// How many video frames to hold each keyframe (the playback speed).
    public var framesPerKeyframe: Int

    public init(size: Int = 640, fps: Int = 30, framesPerKeyframe: Int = 6) {
        self.size = max(16, size)
        self.fps = max(1, fps)
        self.framesPerKeyframe = max(1, framesPerKeyframe)
    }

    /// The dark stage background (design `#060608`), as BGRA bytes + an MTL clear.
    private var clearColor: MTLClearColor {
        let c = DS.Color.background
        return MTLClearColor(red: c.r, green: c.g, blue: c.b, alpha: 1)
    }
    private var backgroundBGRA: [UInt8] {
        let c = DS.Color.background
        return [UInt8(c.b * 255), UInt8(c.g * 255), UInt8(c.r * 255), 255]
    }

    /// Render `keyframes` to an .mp4 at `url` (overwriting). Blocking.
    public func export(keyframes: [ViewerMesh], to url: URL) throws {
        guard !keyframes.isEmpty else { throw VideoExportError.noFrames }
        guard let device = MTLCreateSystemDefaultDevice(),
              let renderer = MeshRenderer(device: device) else { throw VideoExportError.noRenderer }

        // Fix the camera to the first non-empty (largest-extent) keyframe so the
        // part doesn't jump/zoom as material is carved away.
        if let reference = keyframes.first(where: { !$0.isEmpty }) {
            renderer.setMesh(reference)
        }
        let camera = renderer.camera

        try? FileManager.default.removeItem(at: url)
        let writer: AVAssetWriter
        do { writer = try AVAssetWriter(outputURL: url, fileType: .mp4) }
        catch { throw VideoExportError.writerFailed(error.localizedDescription) }

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: size, AVVideoHeightKey: size,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size,
                kCVPixelBufferHeightKey as String: size,
            ])
        guard writer.canAdd(input) else { throw VideoExportError.writerSetup }
        writer.add(input)
        guard writer.startWriting() else {
            throw VideoExportError.writerFailed(writer.error?.localizedDescription ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        let bg = backgroundBGRA
        var frameIndex: Int64 = 0
        for kf in keyframes {
            renderer.setMesh(kf)     // re-frames the camera…
            renderer.camera = camera // …restore the fixed framing
            let bytes = kf.isEmpty
                ? [UInt8](repeating: 0, count: 0)   // → filled with bg below
                : (renderer.renderOffscreen(size: size, clear: clearColor) ?? [])
            let pixels = bytes.isEmpty ? fillBackground(bg) : bytes
            guard let buffer = Self.pixelBuffer(from: pixels, size: size) else {
                throw VideoExportError.encodeFailed
            }
            for _ in 0..<framesPerKeyframe {
                while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
                let time = CMTime(value: frameIndex, timescale: Int32(fps))
                guard adaptor.append(buffer, withPresentationTime: time) else {
                    throw VideoExportError.encodeFailed
                }
                frameIndex += 1
            }
        }

        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw VideoExportError.writerFailed(writer.error?.localizedDescription ?? "not completed")
        }
    }

    private func fillBackground(_ bg: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: size * size * 4)
        var i = 0
        while i < out.count { out[i] = bg[0]; out[i + 1] = bg[1]; out[i + 2] = bg[2]; out[i + 3] = bg[3]; i += 4 }
        return out
    }

    /// BGRA bytes → a CVPixelBuffer (32BGRA), row-padding aware.
    static func pixelBuffer(from bgra: [UInt8], size: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [kCVPixelBufferCGImageCompatibilityKey as String: true,
                                    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, size, size, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let dstStride = CVPixelBufferGetBytesPerRow(buffer)
        let srcStride = size * 4
        bgra.withUnsafeBytes { src in
            for row in 0..<size {
                memcpy(base.advanced(by: row * dstStride),
                       src.baseAddress!.advanced(by: row * srcStride), srcStride)
            }
        }
        return buffer
    }
}

/// The download-video flow's state, driving the timeline's export button. The
/// encode is injected so the orchestration is testable without Metal/AVFoundation.
@MainActor
public final class VideoExportModel: ObservableObject {
    public enum State: Equatable {
        case idle
        case exporting
        case ready(URL)
        case failed(String)
    }

    @Published public private(set) var state: State = .idle

    /// The encode step. Default renders + writes an .mp4; tests inject a stub.
    var encode: (_ keyframes: [ViewerMesh], _ url: URL) throws -> Void
    /// Background-dispatch seam (synchronous in tests).
    var runInBackground: (@escaping () -> Void) -> Void
    var runOnMain: (@escaping () -> Void) -> Void

    public init(
        encode: @escaping (_ keyframes: [ViewerMesh], _ url: URL) throws -> Void =
            { try VideoExporter().export(keyframes: $0, to: $1) },
        runInBackground: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
        runOnMain: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    ) {
        self.encode = encode
        self.runInBackground = runInBackground
        self.runOnMain = runOnMain
    }

    public var isExporting: Bool { state == .exporting }

    /// Export `keyframes` to a temp .mp4 named after the project. No-op while a
    /// previous export is still running.
    public func export(keyframes: [ViewerMesh], name: String) {
        guard state != .exporting else { return }
        guard !keyframes.isEmpty else { state = .failed(VideoExportError.noFrames.description); return }
        state = .exporting
        let safe = name.isEmpty ? "optimization"
            : name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: " ", with: "_")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safe)-optimization.mp4")
        let encode = self.encode
        let runOnMain = self.runOnMain
        runInBackground { [weak self] in
            do {
                try encode(keyframes, url)
                runOnMain { self?.state = .ready(url) }
            } catch {
                runOnMain { self?.state = .failed((error as? VideoExportError)?.description ?? error.localizedDescription) }
            }
        }
    }

    /// Back to idle after the share sheet is dismissed / a failure is acknowledged.
    public func reset() { state = .idle }
}
