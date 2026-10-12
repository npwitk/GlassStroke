import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A write-on animation: the pen writes the drawing over `duration` seconds
/// (after `delay`), then the finished glass stays for `hold` seconds while
/// the light keeps moving.
public struct GlassAnimation {
    public var segments: [GlassSegment]
    /// A filled shape instead of strokes (no write-on; the light still moves).
    public var shape: GlassShape?
    public var backdrop: CGImage
    public var width: Int
    public var height: Int
    public var placement: Placement
    public var style = GlassStyle()
    public var duration: Double
    public var delay: Double = 0
    public var hold: Double = 1.5
    public var fps: Double = 60
    /// Pen progress (0...1) at time fraction (0...1).
    public var timing: @Sendable (Double) -> Double = HelloHandwriting.progress(at:)
    /// Draw the backdrop behind the glass; otherwise transparent around it.
    public var opaque = true

    public init(segments: [GlassSegment], backdrop: CGImage, width: Int, height: Int, placement: Placement, duration: Double) {
        self.segments = segments
        self.backdrop = backdrop
        self.width = width
        self.height = height
        self.placement = placement
        self.duration = duration
    }

    public var totalDuration: Double { delay + duration + hold }
    public var frameCount: Int { Int((totalDuration * fps - 1e-9).rounded(.up)) + 1 }

    public func progress(at t: Double) -> Float {
        guard duration > 0 else { return t >= delay ? 1 : 0 }
        return Float(timing(min(max((t - delay) / duration, 0), 1)))
    }

    /// The frame at `t` seconds.
    public func frame(at t: Double, renderer: GlassRenderer) throws -> CGImage {
        if let shape {
            return try renderer.render(shape: shape.revealed(at: progress(at: t)), backdrop: backdrop, width: width, height: height,
                                       placement: placement, style: style, time: t, opaque: opaque)
        }
        return try renderer.render(segments: segments, backdrop: backdrop, width: width, height: height, placement: placement,
                            style: style, progress: progress(at: t), time: t, opaque: opaque)
    }

    private func eachFrame(_ renderer: GlassRenderer, _ body: (Int, CGImage) throws -> Void) throws {
        for i in 0..<frameCount {
            try body(i, frame(at: min(Double(i) / fps, totalDuration), renderer: renderer))
        }
    }

    /// A QuickTime movie (ProRes 4444, keeping transparency) or, for .mp4,
    /// H.264.
    public func writeMovie(to url: URL, renderer: GlassRenderer) throws {
        try? FileManager.default.removeItem(at: url)
        let mp4 = url.pathExtension.lowercased() == "mp4"
        let writer = try AVAssetWriter(outputURL: url, fileType: mp4 ? .mp4 : .mov)
        let w = width + width % 2, h = height + height % 2
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: mp4 || opaque ? AVVideoCodecType.h264 : AVVideoCodecType.proRes4444,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw GlassError.texture("can't write \(url.path): \(writer.error?.localizedDescription ?? "")") }
        writer.startSession(atSourceTime: .zero)
        let timescale = Int32((fps * 1000).rounded())
        try eachFrame(renderer) { i, img in
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            guard let buf = pb else { throw GlassError.texture("out of memory") }
            CVPixelBufferLockBaseAddress(buf, [])
            let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buf), width: w, height: h, bitsPerComponent: 8,
                                bytesPerRow: CVPixelBufferGetBytesPerRow(buf), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.draw(img, in: CGRect(x: 0, y: h - height, width: width, height: height))
            CVPixelBufferUnlockBaseAddress(buf, [])
            while !input.isReadyForMoreMediaData { usleep(1000) }
            adaptor.append(buf, withPresentationTime: CMTime(value: Int64(i) * 1000, timescale: timescale))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw GlassError.texture("couldn't finish \(url.path): \(writer.error?.localizedDescription ?? "")") }
    }

    /// An animated GIF that loops.
    public func writeGIF(to url: URL, renderer: GlassRenderer, loop: Bool = true) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw GlassError.texture("can't write \(url.path)")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop ? 0 : 1]] as CFDictionary)
        let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps, kCGImagePropertyGIFUnclampedDelayTime: 1 / fps]] as CFDictionary
        try eachFrame(renderer) { _, img in CGImageDestinationAddImage(dest, img, delay) }
        guard CGImageDestinationFinalize(dest) else { throw GlassError.texture("couldn't write \(url.path)") }
    }

    /// An animated PNG: full transparency (unlike GIF), shown by browsers
    /// and GitHub. Loops.
    public func writeAPNG(to url: URL, renderer: GlassRenderer, loop: Bool = true) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, frameCount, nil) else {
            throw GlassError.texture("can't write \(url.path)")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: loop ? 0 : 1]] as CFDictionary)
        let delay = [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: 1 / fps, kCGImagePropertyAPNGUnclampedDelayTime: 1 / fps]] as CFDictionary
        try eachFrame(renderer) { _, img in CGImageDestinationAddImage(dest, img, delay) }
        guard CGImageDestinationFinalize(dest) else { throw GlassError.texture("couldn't write \(url.path)") }
    }

    /// Every frame as a numbered PNG in `folder`.
    public func writeFrames(to folder: URL, renderer: GlassRenderer) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try eachFrame(renderer) { i, img in
            try writePNG(img, to: folder.appendingPathComponent(String(format: "frame_%04d.png", i + 1)))
        }
    }
}

public func writePNG(_ img: CGImage, to url: URL) throws {
    guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw GlassError.texture("can't write \(url.path)")
    }
    CGImageDestinationAddImage(d, img, nil)
    guard CGImageDestinationFinalize(d) else { throw GlassError.texture("couldn't write \(url.path)") }
}

public func loadImage(_ url: URL) throws -> CGImage {
    guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(s, 0, nil) else {
        throw GlassError.texture("can't read the image \(url.path)")
    }
    return img
}
