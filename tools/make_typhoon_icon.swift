// Generates the Typhoonminigen app icon: dark rounded square (B·Telemetry palette) with an
// amber typhoon swirl — three spiral arms around the eye of the storm.
// Usage: swift tools/make_typhoon_icon.swift <output.png>
import AppKit
import CoreGraphics

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Apple icon grid: ~824x824 rounded square centered on a transparent 1024 canvas.
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let squircle = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let grad = CGGradient(colorsSpace: space,
                      colors: [color(0x1C1E26), color(0x101117)] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

ctx.addPath(squircle)
ctx.setStrokeColor(color(0xD8A06E, 0.30))
ctx.setLineWidth(6)
ctx.strokePath()

// Three spiral arms, thick near the eye and tapering outward, slightly fading.
let cx = 512.0, cy = 512.0
let amber: UInt32 = 0xD8A06E
ctx.setLineCap(.round)
for arm in 0 ..< 3 {
    let phase = Double(arm) * 2.0 * .pi / 3.0
    var prev: CGPoint? = nil
    let steps = 240
    for i in 0 ... steps {
        let t = Double(i) / Double(steps)
        let theta = t * 2.45 * .pi + phase
        let r = 58.0 + pow(t, 1.22) * 252.0
        let p = CGPoint(x: cx + r * cos(theta), y: cy + r * sin(theta))
        if let q = prev {
            ctx.setStrokeColor(color(amber, 1.0 - 0.30 * t))
            ctx.setLineWidth(CGFloat(36.0 - 24.0 * t))
            ctx.move(to: q)
            ctx.addLine(to: p)
            ctx.strokePath()
        }
        prev = p
    }
}

// Eye of the storm.
ctx.setStrokeColor(color(amber))
ctx.setLineWidth(18)
ctx.strokeEllipse(in: CGRect(x: cx - 34, y: cy - 34, width: 68, height: 68))

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("written \(CommandLine.arguments[1])")
