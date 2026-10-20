// frames.swift: a video → one contact-sheet PNG of frames with timestamps, so
// motion can be reviewed as a filmstrip (no ffmpeg needed).
//
//   swift tools/frames.swift <video.mp4> <out.png> [fps=8] [columns=8] [width=180] [from=0] [to=end]
//
// fps is frames per second sampled; width is each frame's width in points.

import AVFoundation
import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: swift frames.swift <video> <out.png> [fps=8] [columns=8] [width=180] [from=0] [to=end]")
    exit(1)
}
let videoURL = URL(fileURLWithPath: args[1])
let outURL = URL(fileURLWithPath: args[2])
let fps = args.count > 3 ? Double(args[3]) ?? 8 : 8
let columns = args.count > 4 ? Int(args[4]) ?? 8 : 8
let frameWidth = args.count > 5 ? CGFloat(Double(args[5]) ?? 180) : 180

let asset = AVURLAsset(url: videoURL)
let semaphore = DispatchSemaphore(value: 0)
var duration = 0.0
Task {
    duration = (try? await asset.load(.duration).seconds) ?? 0
    semaphore.signal()
}
semaphore.wait()
guard duration > 0 else { print("could not read \(videoURL.path)"); exit(1) }
let from = args.count > 6 ? Double(args[6]) ?? 0 : 0
let to = min(duration, args.count > 7 ? Double(args[7]) ?? duration : duration)

let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero

var times: [Double] = []
var t = from
while t <= to { times.append(t); t += 1 / fps }

var images: [(Double, CGImage)] = []
for time in times {
    if let image = try? generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil) {
        images.append((time, image))
    }
}
guard let first = images.first?.1 else { print("no frames"); exit(1) }

let scale = frameWidth / CGFloat(first.width)
let frameHeight = CGFloat(first.height) * scale
let label: CGFloat = 18, gap: CGFloat = 8
let rows = Int((Double(images.count) / Double(columns)).rounded(.up))
let sheetW = CGFloat(columns) * (frameWidth + gap) + gap
let sheetH = CGFloat(rows) * (frameHeight + label + gap) + gap

let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(sheetW), height: Int(sheetH), bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))

let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = ns
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
                                            .foregroundColor: NSColor.white]
for (i, (time, image)) in images.enumerated() {
    let col = i % columns, row = i / columns
    let x = gap + CGFloat(col) * (frameWidth + gap)
    // CoreGraphics' origin is bottom-left: row 0 at the top.
    let yTop = sheetH - gap - CGFloat(row) * (frameHeight + label + gap)
    ctx.draw(image, in: CGRect(x: x, y: yTop - label - frameHeight, width: frameWidth, height: frameHeight))
    NSAttributedString(string: String(format: "%.2fs", time), attributes: attrs).draw(at: CGPoint(x: x, y: yTop - label + 3))
}

guard let sheet = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(outURL as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, sheet, nil)
CGImageDestinationFinalize(dest)
print("\(images.count) frames, \(String(format: "%.1f", from))–\(String(format: "%.1f", to))s → \(outURL.path)")
