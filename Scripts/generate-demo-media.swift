import AppKit
import AVFoundation
import CoreVideo
import Foundation

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let samples: [(String, String, NSColor)] = [
    ("blue-orbit", "Blue Orbit", NSColor(red: 0.1, green: 0.35, blue: 0.85, alpha: 1)),
    ("green-waves", "Green Waves", NSColor(red: 0.08, green: 0.55, blue: 0.25, alpha: 1)),
    ("orange-sunrise", "Orange Sunrise", NSColor(red: 0.9, green: 0.35, blue: 0.08, alpha: 1))
]
let width = 640, height = 360, fps: Int32 = 24, frames = 480
for (filename, title, color) in samples {
    let url = outputDirectory.appendingPathComponent(filename + ".mp4")
    if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 { continue }
    let temporaryURL = outputDirectory.appendingPathComponent(filename + ".pending.mp4")
    if FileManager.default.fileExists(atPath: temporaryURL.path) { try FileManager.default.removeItem(at: temporaryURL) }
    let writer = try AVAssetWriter(outputURL: temporaryURL, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 900_000,
                                          AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel]
    ])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                       sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ])
    writer.add(input)
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        var optionalBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &optionalBuffer)
        guard let buffer = optionalBuffer else { fatalError("Pixel buffer creation failed") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let angle = Double(frame) / 24 * 1.2
        context.setFillColor(NSColor.white.withAlphaComponent(0.4).cgColor)
        context.fillEllipse(in: CGRect(x: 240 + cos(angle) * 160, y: 150 + sin(angle) * 70, width: 90, height: 90))
        context.setFillColor(NSColor.black.withAlphaComponent(0.15).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: 110))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (title as NSString).draw(at: NSPoint(x: 24, y: 62), withAttributes: [
            .font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.white
        ])
        let caption = String(format: "Theatre local demo  ·  %.1f / 20.0 seconds", Double(frame) / 24)
        (caption as NSString).draw(at: NSPoint(x: 24, y: 30), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .regular), .foregroundColor: NSColor.white
        ])
        NSGraphicsContext.restoreGraphicsState()
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: fps)) else {
            throw writer.error ?? NSError(domain: "DemoMedia", code: 1)
        }
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { throw writer.error ?? NSError(domain: "DemoMedia", code: 2) }
    if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    try FileManager.default.moveItem(at: temporaryURL, to: url)
    print("Generated \(url.lastPathComponent)")
}
