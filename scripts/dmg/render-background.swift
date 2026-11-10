import AppKit

// Draws the background of the Dicavo CLI Bridge installer window: a title, a
// "drag to Applications" hint and an arrow between the two icons that
// scripts/make-dmg.sh places on top of it. The geometry below is shared with
// that script (window 660 x 400 points, icons centred at x 165 and 495,
// y 225 from the top); change both together.
//
// The picture is larger than the window. Finder draws it from the top-left
// corner without scaling or tiling, and when the image opens in a tab of a
// bigger window the rest would stay white; the margin is plain paper.
//
//   swift scripts/dmg/render-background.swift <output-dir>
//
// writes background.png (1x) and background@2x.png; make-dmg.sh combines them
// into one HiDPI TIFF with tiffutil.

let width: CGFloat = 660
let canvasWidth: CGFloat = 2560
let canvasHeight: CGFloat = 1600
let iconCentreY: CGFloat = 225
let leftIconX: CGFloat = 165
let rightIconX: CGFloat = 495

// Brand/06-Brand-Guide/tokens.json
let paper = NSColor(srgbRed: 0xF3 / 255.0, green: 0xF1 / 255.0, blue: 0xEC / 255.0, alpha: 1)
let indigo = NSColor(srgbRed: 0x22 / 255.0, green: 0x23 / 255.0, blue: 0x3F / 255.0, alpha: 1)
let muted = NSColor(srgbRed: 0x77 / 255.0, green: 0x77 / 255.0, blue: 0x81 / 255.0, alpha: 1)

func drawCentred(_ text: String, font: NSFont, color: NSColor, top: CGFloat) {
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
    let string = NSAttributedString(string: text, attributes: attributes)
    let size = string.size()
    // AppKit's origin is bottom-left; the layout above is measured from the top.
    string.draw(at: NSPoint(x: (width - size.width) / 2, y: canvasHeight - top - size.height))
}

func render(scale: CGFloat, to url: URL) throws {
    let pixelsWide = Int(canvasWidth * scale)
    let pixelsHigh = Int(canvasHeight * scale)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { fatalError("cannot allocate a \(pixelsWide) x \(pixelsHigh) bitmap") }
    // Points, so Finder shows the 2x image at the same size as the 1x one.
    bitmap.size = NSSize(width: canvasWidth, height: canvasHeight)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    paper.setFill()
    NSRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight).fill()

    drawCentred("Install Dicavo CLI Bridge",
                font: NSFont.systemFont(ofSize: 30, weight: .semibold),
                color: indigo, top: 48)
    drawCentred("Drag to Applications",
                font: NSFont.systemFont(ofSize: 15, weight: .regular),
                color: muted, top: 92)

    // The arrow sits between the icons, clear of both 128-point icons.
    let y = canvasHeight - iconCentreY
    let start = leftIconX + 92
    let end = rightIconX - 92
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: start, y: y))
    arrow.line(to: NSPoint(x: end, y: y))
    arrow.move(to: NSPoint(x: end - 11, y: y + 9))
    arrow.line(to: NSPoint(x: end, y: y))
    arrow.line(to: NSPoint(x: end - 11, y: y - 9))
    arrow.lineWidth = 2
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    muted.setStroke()
    arrow.stroke()

    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:])
    else { fatalError("cannot encode \(url.lastPathComponent)") }
    try png.write(to: url)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: swift render-background.swift <output-dir>\n".data(using: .utf8)!)
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
try render(scale: 1, to: output.appendingPathComponent("background.png"))
try render(scale: 2, to: output.appendingPathComponent("background@2x.png"))
print("Rendered the DMG background into \(output.path)")
