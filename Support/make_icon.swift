// アプリアイコンの元画像(1024px)を描く。 使い方: swift Support/make_icon.swift 出力.png
import AppKit

let size = 1024
let outPath = CommandLine.arguments[1]
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// 背景（macOS のアイコングリッドに合わせて 824px の角丸四角、オレンジのグラデーション）
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = roundedRect(body, 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: rgb(0x000000, 0.3))
ctx.addPath(bodyPath)
ctx.setFillColor(rgb(0xFF8A00))
ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(bodyPath)
ctx.clip()
let background = CGGradient(colorsSpace: nil, colors: [rgb(0xFFB547), rgb(0xFF7A00)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()

// 白いクリップボード
let board = CGRect(x: 512 - 220, y: 230, width: 440, height: 530)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: rgb(0x8A3A00, 0.35))
ctx.addPath(roundedRect(board, 72))
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillPath()
ctx.restoreGState()

// 上のクリップ（オレンジの縁取りで切り抜いたように見せる）
let clip = CGRect(x: 512 - 115, y: board.maxY - 62, width: 230, height: 110)
ctx.addPath(roundedRect(clip.insetBy(dx: -22, dy: -22), 52))
ctx.setFillColor(rgb(0xFF9A1F))
ctx.fillPath()
ctx.addPath(roundedRect(clip, 34))
ctx.setFillColor(rgb(0xFFFFFF))
ctx.fillPath()

// 本文の行
ctx.setFillColor(rgb(0xFFD3A1))
let widths: [CGFloat] = [300, 240, 300, 180]
for (i, lineWidth) in widths.enumerated() {
    let y = board.maxY - 170 - CGFloat(i) * 76
    ctx.addPath(roundedRect(CGRect(x: board.minX + 70, y: y, width: lineWidth, height: 34), 17))
    ctx.fillPath()
}

let image = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: image)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
