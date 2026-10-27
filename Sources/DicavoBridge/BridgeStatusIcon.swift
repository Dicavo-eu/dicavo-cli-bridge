import AppKit

/// The bridge's menu bar glyph: a terminal prompt `›_` inside a rounded
/// frame, like the input-source indicator (`Brand/08-Bridge/BridgeStatusTemplate.svg`),
/// so it does not read as a second Dicavo icon.
///
/// Unlike Dicavo's own item this one stays a template image. The bridge
/// has nothing that deserves colour in the menu bar, and a template follows
/// the menu bar's appearance for free, so every state is told apart by shape:
/// dimmed while starting, a dot when no tool is usable, struck through when
/// it does not listen.
enum BridgeStatusIcon {
    enum State: Equatable {
        case starting
        case ready
        case noUsableTool
        case failed
    }

    /// The glyph is drawn on the brand kit's 28 x 20 grid, at the height
    /// Dicavo's own item uses so the two sit level next to each other.
    static let symbolHeight: CGFloat = 16
    private static let units = NSSize(width: 28, height: 20)

    static var size: NSSize {
        NSSize(width: units.width * symbolHeight / units.height, height: symbolHeight)
    }

    static func image(for state: State) -> NSImage {
        // Flipped, so the drawing below reads in the SVG's own coordinates.
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current else { return false }
            context.shouldAntialias = true
            let transform = NSAffineTransform()
            transform.scale(by: rect.height / units.height)
            transform.concat()
            draw(state, in: context)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityLabel(for: state)
        return image
    }

    static func accessibilityLabel(for state: State) -> String {
        switch state {
        case .starting: return InterfaceLanguage.text("Dicavo CLI Bridge is starting")
        case .ready: return InterfaceLanguage.text("Dicavo CLI Bridge is ready")
        case .noUsableTool: return InterfaceLanguage.text("Dicavo CLI Bridge found no usable tool")
        case .failed: return InterfaceLanguage.text("Dicavo CLI Bridge is not listening")
        }
    }

    private static func draw(_ state: State, in context: NSGraphicsContext) {
        switch state {
        case .ready:
            drawGlyph(alpha: 1)
        case .starting:
            drawGlyph(alpha: 0.4)
        case .noUsableTool:
            drawGlyph(alpha: 1)
            // Cut a ring out of the frame's corner first, so the dot reads
            // as a mark on the glyph and not as part of it.
            let center = NSPoint(x: 24.5, y: 4.5)
            knockOut(NSBezierPath(ovalIn: circle(center, radius: 4)), in: context)
            NSColor.black.setFill()
            NSBezierPath(ovalIn: circle(center, radius: 2.6)).fill()
        case .failed:
            drawGlyph(alpha: 0.45)
            let slash = NSBezierPath()
            slash.move(to: NSPoint(x: 3, y: 18))
            slash.line(to: NSPoint(x: 25, y: 1))
            slash.lineCapStyle = .round
            slash.lineWidth = 4
            context.saveGraphicsState()
            context.compositingOperation = .clear
            slash.stroke()
            context.restoreGraphicsState()
            slash.lineWidth = 1.8
            NSColor.black.setStroke()
            slash.stroke()
        }
    }

    private static func drawGlyph(alpha: CGFloat) {
        let color = NSColor.black.withAlphaComponent(alpha)

        let frame = NSBezierPath(roundedRect: NSRect(x: 3, y: 3, width: 22, height: 14), xRadius: 3.5, yRadius: 3.5)
        frame.lineWidth = 1.5
        color.setStroke()
        frame.stroke()

        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: 8, y: 7))
        chevron.line(to: NSPoint(x: 11, y: 10))
        chevron.line(to: NSPoint(x: 8, y: 13))
        chevron.lineWidth = 1.8
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        color.setStroke()
        chevron.stroke()

        let underscore = NSBezierPath()
        underscore.move(to: NSPoint(x: 13.5, y: 13))
        underscore.line(to: NSPoint(x: 19, y: 13))
        underscore.lineWidth = 1.8
        underscore.lineCapStyle = .round
        color.setStroke()
        underscore.stroke()
    }

    private static func knockOut(_ path: NSBezierPath, in context: NSGraphicsContext) {
        context.saveGraphicsState()
        context.compositingOperation = .clear
        path.fill()
        context.restoreGraphicsState()
    }

    private static func circle(_ center: NSPoint, radius: CGFloat) -> NSRect {
        NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}
