// Draws the Always On Top app icon: a floating window pinned above another,
// on a blue rounded square. Run: swift Tools/MakeIcon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "icon.png"

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8,
                          bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
// Top-left origin, so the drawing below reads like screen coordinates.
ctx.translateBy(x: 0, y: size)
ctx.scaleBy(x: 1, y: -1)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func fillGradient(_ path: CGPath, _ colors: [CGColor], from start: CGPoint, to end: CGPoint) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
    ctx.restoreGState()
}

// Background: the macOS icon grid's rounded square, with a soft drop shadow.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = rounded(tile, 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x3554E0))
ctx.fillPath()
ctx.restoreGState()
fillGradient(tilePath, [rgb(0x5B8CFF), rgb(0x3047D6), rgb(0x2433A8)],
             from: CGPoint(x: 0, y: 100), to: CGPoint(x: 0, y: 924))
// A faint sheen across the top.
fillGradient(tilePath, [rgb(0xFFFFFF, 0.18), rgb(0xFFFFFF, 0)],
             from: CGPoint(x: 0, y: 100), to: CGPoint(x: 0, y: 480))

// The window behind: translucent, so it reads as covered.
let back = CGRect(x: 205, y: 335, width: 430, height: 330)
ctx.addPath(rounded(back, 34))
ctx.setFillColor(rgb(0xFFFFFF, 0.26))
ctx.fillPath()
ctx.addPath(rounded(CGRect(x: back.minX, y: back.minY, width: back.width, height: 54), 34))
ctx.setFillColor(rgb(0xFFFFFF, 0.14))
ctx.fillPath()
for (index, x) in [back.minX + 38, back.minX + 70, back.minX + 102].enumerated() {
    _ = index
    ctx.addEllipse(in: CGRect(x: x - 10, y: back.minY + 17, width: 20, height: 20))
}
ctx.setFillColor(rgb(0xFFFFFF, 0.45))
ctx.fillPath()

// The pinned window in front, lifted by a deeper shadow.
let front = CGRect(x: 325, y: 440, width: 480, height: 360)
let frontPath = rounded(front, 38)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 48, color: rgb(0x0B1450, 0.45))
ctx.addPath(frontPath)
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(frontPath)
ctx.clip()
ctx.setFillColor(rgb(0xEEF1F8))
ctx.fill(CGRect(x: front.minX, y: front.minY, width: front.width, height: 66))
ctx.setFillColor(rgb(0xDCE1EC))
ctx.fill(CGRect(x: front.minX, y: front.minY + 66, width: front.width, height: 2))
ctx.restoreGState()
for (x, color) in [(front.minX + 42, 0xFF5F57), (front.minX + 80, 0xFEBC2E), (front.minX + 118, 0x28C840)] {
    ctx.addEllipse(in: CGRect(x: x - 13, y: front.minY + 20, width: 26, height: 26))
    ctx.setFillColor(rgb(UInt32(color)))
    ctx.fillPath()
}
// Content: an accent block and a few lines of text.
ctx.addPath(rounded(CGRect(x: front.minX + 44, y: front.minY + 108, width: 150, height: 110), 18))
ctx.setFillColor(rgb(0x5B8CFF, 0.9))
ctx.fillPath()
for (y, width) in [(CGFloat(116), CGFloat(210)), (156, 170), (196, 196)] {
    ctx.addPath(rounded(CGRect(x: front.minX + 222, y: front.minY + y, width: width, height: 20), 10))
}
for (y, width) in [(CGFloat(250), CGFloat(392)), (290, 340)] {
    ctx.addPath(rounded(CGRect(x: front.minX + 44, y: front.minY + y, width: width, height: 20), 10))
}
ctx.setFillColor(rgb(0xD5DBE7))
ctx.fillPath()

// The pushpin, its needle in the front window's top-right corner, leaning right.
ctx.saveGState()
ctx.translateBy(x: 712, y: 478)
ctx.rotate(by: 0.5)
ctx.scaleBy(x: 0.8, y: 0.8)
ctx.setShadow(offset: CGSize(width: -8, height: -16), blur: 22, color: rgb(0x0B1450, 0.45))
ctx.beginTransparencyLayer(auxiliaryInfo: nil)
// Needle.
ctx.setLineCap(.round)
ctx.setLineWidth(16)
ctx.setStrokeColor(rgb(0xAEB6C4))
ctx.move(to: CGPoint(x: 0, y: -4))
ctx.addLine(to: CGPoint(x: 0, y: -140))
ctx.strokePath()
// Flared base.
let base = CGMutablePath()
base.move(to: CGPoint(x: -96, y: -138))
base.addLine(to: CGPoint(x: 96, y: -138))
base.addLine(to: CGPoint(x: 46, y: -186))
base.addLine(to: CGPoint(x: -46, y: -186))
base.closeSubpath()
base.addEllipse(in: CGRect(x: -96, y: -156, width: 192, height: 36))
fillGradient(base, [rgb(0xF0465A), rgb(0xB81B2C)], from: CGPoint(x: -96, y: 0), to: CGPoint(x: 96, y: 0))
// Waist.
let waist = CGPath(rect: CGRect(x: -44, y: -268, width: 88, height: 90), transform: nil)
fillGradient(waist, [rgb(0xFF5B6C), rgb(0xD02536), rgb(0xA81726)],
             from: CGPoint(x: -44, y: 0), to: CGPoint(x: 44, y: 0))
// Head: a disc with a lit top.
let headSide = CGMutablePath()
headSide.addRect(CGRect(x: -104, y: -306, width: 208, height: 30))
headSide.addEllipse(in: CGRect(x: -104, y: -290, width: 208, height: 40))
fillGradient(headSide, [rgb(0xF24A5C), rgb(0xB01A2A)], from: CGPoint(x: -104, y: 0), to: CGPoint(x: 104, y: 0))
let headTop = CGPath(ellipseIn: CGRect(x: -104, y: -328, width: 208, height: 44), transform: nil)
fillGradient(headTop, [rgb(0xFF8A95), rgb(0xFF4F61)], from: CGPoint(x: -60, y: -328), to: CGPoint(x: 60, y: -284))
ctx.addEllipse(in: CGRect(x: -58, y: -320, width: 70, height: 16))
ctx.setFillColor(rgb(0xFFFFFF, 0.45))
ctx.fillPath()
ctx.endTransparencyLayer()
ctx.restoreGState()

guard let image = ctx.makeImage() else { exit(1) }
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
