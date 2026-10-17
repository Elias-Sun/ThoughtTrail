// 生成 1024×1024 应用图标：用法 swift Scripts/make_icon.swift <输出路径>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "App/Resources/Assets.xcassets/AppIcon.appiconset/icon-1024.png"
let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("无法创建画布") }

// 背景：深青到墨绿的竖向渐变
let colors = [CGColor(red: 0.07, green: 0.29, blue: 0.33, alpha: 1), CGColor(red: 0.03, green: 0.15, blue: 0.18, alpha: 1)] as CFArray
let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(size)), end: CGPoint(x: 0, y: 0), options: [])

// 翻开的书：两页
ctx.setFillColor(CGColor(red: 0.98, green: 0.95, blue: 0.88, alpha: 1))
let left = CGMutablePath()
left.move(to: CGPoint(x: 512, y: 300))
left.addCurve(to: CGPoint(x: 190, y: 340), control1: CGPoint(x: 420, y: 250), control2: CGPoint(x: 280, y: 270))
left.addLine(to: CGPoint(x: 190, y: 720))
left.addCurve(to: CGPoint(x: 512, y: 690), control1: CGPoint(x: 290, y: 660), control2: CGPoint(x: 420, y: 650))
left.closeSubpath()
ctx.addPath(left); ctx.fillPath()
let right = CGMutablePath()
right.move(to: CGPoint(x: 512, y: 300))
right.addCurve(to: CGPoint(x: 834, y: 340), control1: CGPoint(x: 604, y: 250), control2: CGPoint(x: 744, y: 270))
right.addLine(to: CGPoint(x: 834, y: 720))
right.addCurve(to: CGPoint(x: 512, y: 690), control1: CGPoint(x: 734, y: 660), control2: CGPoint(x: 604, y: 650))
right.closeSubpath()
ctx.addPath(right); ctx.fillPath()

// 思考的轨迹：从书页升起的三段弧线与节点
ctx.setStrokeColor(CGColor(red: 0.96, green: 0.67, blue: 0.27, alpha: 1))
ctx.setLineWidth(26)
ctx.setLineCap(.round)
let trail = CGMutablePath()
trail.move(to: CGPoint(x: 512, y: 560))
trail.addCurve(to: CGPoint(x: 640, y: 820), control1: CGPoint(x: 600, y: 640), control2: CGPoint(x: 560, y: 760))
trail.addCurve(to: CGPoint(x: 760, y: 900), control1: CGPoint(x: 690, y: 860), control2: CGPoint(x: 720, y: 890))
ctx.addPath(trail); ctx.strokePath()
ctx.setFillColor(CGColor(red: 0.96, green: 0.67, blue: 0.27, alpha: 1))
for p in [CGPoint(x: 512, y: 560), CGPoint(x: 640, y: 820), CGPoint(x: 760, y: 900)] {
    ctx.fillEllipse(in: CGRect(x: p.x - 34, y: p.y - 34, width: 68, height: 68))
}

let image = ctx.makeImage()!
let url = URL(fileURLWithPath: out)
try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
CGImageDestinationFinalize(dest)
print("已生成图标：\(out)")
