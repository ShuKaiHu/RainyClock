#!/usr/bin/swift
import Foundation
import CoreGraphics
import ImageIO

let W = 1024, H = 1024
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(
    data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
    space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue).rawValue
)!

// Use screen coordinates (y increases downward)
ctx.translateBy(x: 0, y: CGFloat(H))
ctx.scaleBy(x: 1, y: -1)

// ── 1. Background: deep navy to medium blue
let gradColors = [
    CGColor(red: 0.09, green: 0.19, blue: 0.42, alpha: 1.0),  // top dark
    CGColor(red: 0.18, green: 0.40, blue: 0.76, alpha: 1.0)   // bottom lighter
] as CFArray
let grad = CGGradient(colorsSpace: cs, colors: gradColors, locations: [0, 1] as [CGFloat])!
ctx.drawLinearGradient(
    grad,
    start: CGPoint(x: 0, y: 0),
    end: CGPoint(x: 0, y: CGFloat(H)),
    options: []
)

// ── 2. Clock face (white circle)
let CX = CGFloat(W) / 2
let CY: CGFloat = 435
let CR: CGFloat = 294

ctx.setFillColor(CGColor(red: 0.97, green: 0.97, blue: 0.99, alpha: 1))
ctx.fillEllipse(in: CGRect(x: CX-CR, y: CY-CR, width: CR*2, height: CR*2))

// Clock face border
ctx.setStrokeColor(CGColor(red: 0.18, green: 0.36, blue: 0.70, alpha: 0.22))
ctx.setLineWidth(10)
ctx.strokeEllipse(in: CGRect(x: CX-CR+5, y: CY-CR+5, width: (CR-5)*2, height: (CR-5)*2))

// ── 3. Hour markers (12 positions)
// In screen coords (y-down): 12 o'clock = -π/2; clockwise = +angle
ctx.setLineCap(.round)
for i in 0..<12 {
    let angle = CGFloat(-Double.pi/2 + Double(i) * Double.pi/6)
    let isMajor = (i % 3 == 0)
    let inner = CR - (isMajor ? 52 : 34)
    let outer = CR - 13
    ctx.setStrokeColor(CGColor(red: 0.17, green: 0.33, blue: 0.64, alpha: 0.80))
    ctx.setLineWidth(isMajor ? 13 : 7)
    ctx.move(to: CGPoint(x: CX + cos(angle)*inner, y: CY + sin(angle)*inner))
    ctx.addLine(to: CGPoint(x: CX + cos(angle)*outer, y: CY + sin(angle)*outer))
    ctx.strokePath()
}

// ── 4. Clock hands (showing 7:00)
// Hour hand: 7 o'clock = -π/2 + 7*(π/6) = 2π/3
// In screen coords (y-down), this points left-and-down → correct for 7:00
let handColor = CGColor(red: 0.12, green: 0.26, blue: 0.55, alpha: 1)
ctx.setStrokeColor(handColor)
ctx.setLineCap(.round)

let hourA = CGFloat(-Double.pi/2 + 7.0 * Double.pi/6)
ctx.setLineWidth(26)
ctx.move(to: CGPoint(x: CX - cos(hourA)*52, y: CY - sin(hourA)*52))   // tail
ctx.addLine(to: CGPoint(x: CX + cos(hourA)*185, y: CY + sin(hourA)*185))
ctx.strokePath()

// Minute hand: 12:00 = straight up = angle -π/2
let minA = CGFloat(-Double.pi/2)
ctx.setLineWidth(17)
ctx.move(to: CGPoint(x: CX - cos(minA)*58, y: CY - sin(minA)*58))     // tail
ctx.addLine(to: CGPoint(x: CX + cos(minA)*245, y: CY + sin(minA)*245))
ctx.strokePath()

// Center hub
ctx.setFillColor(handColor)
ctx.fillEllipse(in: CGRect(x: CX-19, y: CY-19, width: 38, height: 38))
ctx.setFillColor(CGColor(red: 0.82, green: 0.90, blue: 0.98, alpha: 1))
ctx.fillEllipse(in: CGRect(x: CX-10, y: CY-10, width: 20, height: 20))

// ── 5. Rain drops (bottom portion, two staggered rows)
let dropColor = CGColor(red: 0.58, green: 0.82, blue: 1.0, alpha: 0.88)
ctx.setFillColor(dropColor)

// Each drop: narrow vertical ellipse with a pointed top via rotation
let dropPositions: [(x: CGFloat, y: CGFloat, scale: CGFloat)] = [
    (265, 775, 1.0),  (420, 820, 0.9),  (580, 780, 1.0),  (735, 822, 0.9),
    (345, 908, 0.85), (510, 878, 0.85), (670, 912, 0.85)
]
let baseW: CGFloat = 46
let baseH: CGFloat = 96
let tiltRad = CGFloat(0.20)  // slight rightward tilt

for drop in dropPositions {
    ctx.saveGState()
    ctx.translateBy(x: drop.x, y: drop.y + baseH * drop.scale / 2)
    ctx.rotate(by: tiltRad)
    let w = baseW * drop.scale
    let h = baseH * drop.scale
    // Main elongated body
    ctx.fillEllipse(in: CGRect(x: -w/2, y: -h/2, width: w, height: h))
    // Pointed top cap (triangle-ish)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 0, y: -h/2 - h*0.38))
    path.addLine(to: CGPoint(x: -w*0.42, y: -h/2 + h*0.05))
    path.addLine(to: CGPoint(x:  w*0.42, y: -h/2 + h*0.05))
    path.closeSubpath()
    ctx.addPath(path)
    ctx.fillPath()
    ctx.restoreGState()
}

// ── 6. Save PNG
guard let cgImage = ctx.makeImage() else {
    print("Error: could not create image")
    exit(1)
}

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon-1024.png"
let url = URL(fileURLWithPath: outPath)

guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
    print("Error: could not create image destination")
    exit(1)
}
CGImageDestinationAddImage(dest, cgImage, nil)
guard CGImageDestinationFinalize(dest) else {
    print("Error: could not write PNG")
    exit(1)
}
print("Saved: \(url.path)")
