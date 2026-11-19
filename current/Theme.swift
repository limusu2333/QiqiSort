import AppKit
import QuartzCore

enum Memphis {
    static let ink = NSColor(hex: 0x171717)
    static let paper = NSColor(hex: 0xF8F7F3)
    static let pink = NSColor(hex: 0xFF4E8E)
    static let mint = NSColor(hex: 0x7ED9C3)
    static let yellow = NSColor(hex: 0xFFCE3A)
    static let lavender = NSColor(hex: 0xB9A7F0)
    static let blue = NSColor(hex: 0x2F55E8)
    static let muted = NSColor(hex: 0x656561)
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                  green: CGFloat((hex >> 8) & 255) / 255,
                  blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}
let ink = Memphis.ink
let mutedInk = Memphis.muted
func label(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular,
           _ color: NSColor = ink) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size, weight: weight); field.textColor = color
    field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return field
}
func pin(_ view: NSView, to parent: NSView, inset: CGFloat = 0) {
    view.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
        view.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        view.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        view.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        view.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
    ])
}
func column(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing; stack.distribution = .fill
    return stack
}
func row(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal; stack.alignment = .centerY; stack.spacing = spacing; stack.distribution = .fill
    return stack
}
func spacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.init(1), for: .horizontal)
    view.setContentHuggingPriority(.init(1), for: .vertical)
    return view
}
func fullWidth(_ views: [NSView], in stack: NSView) {
    for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
}
func symbol(_ name: String, size: CGFloat = 18, color: NSColor = ink) -> NSImageView {
    let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage())
    view.symbolConfiguration = .init(pointSize: size, weight: .semibold); view.contentTintColor = color
    view.widthAnchor.constraint(equalToConstant: size + 4).isActive = true
    view.heightAnchor.constraint(equalToConstant: size + 4).isActive = true
    return view
}
func rule(_ color: NSColor = ink.withAlphaComponent(0.16)) -> NSView {
    let view = NSView(); view.wantsLayer = true; view.layer?.backgroundColor = color.cgColor
    view.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return view
}
final class WorkspaceBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Memphis.paper.setFill(); bounds.fill()
        Memphis.mint.setFill()
        NSBezierPath(rect: NSRect(x: bounds.maxX - 130, y: bounds.maxY - 12, width: 108, height: 5)).fill()
        Memphis.pink.setFill(); NSBezierPath(rect: NSRect(x: 24, y: 18, width: 26, height: 5)).fill()
        ink.withAlphaComponent(0.10).setFill()
        for x in stride(from: CGFloat(30), to: bounds.width - 24, by: 18) {
            NSBezierPath(ovalIn: NSRect(x: x, y: 29, width: 1.5, height: 1.5)).fill()
        }
    }
}
final class PaperSurface: NSView {
    var fill: NSColor = .white { didSet { needsDisplay = true } }
    var accent: NSColor? { didSet { needsDisplay = true } }
    var highlighted = false { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 4, dy: 5).offsetBy(dx: -2, dy: 2)
        ink.setFill(); NSBezierPath(roundedRect: rect.offsetBy(dx: 5, dy: -5), xRadius: 4, yRadius: 4).fill()
        (highlighted ? NSColor(hex: 0xE3F5EE) : fill).setFill()
        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        path.fill(); (highlighted ? Memphis.blue : ink).setStroke(); path.lineWidth = highlighted ? 3 : 2; path.stroke()
        if let accent {
            accent.setFill(); NSBezierPath(rect: NSRect(x: rect.midX - 36, y: rect.maxY - 6, width: 72, height: 10)).fill()
        }
    }
    func install(_ content: NSView, padding: CGFloat = 24) { addSubview(content); pin(content, to: self, inset: padding) }
}
final class MemphisButton: NSButton {
    var fill: NSColor = .white { didSet { needsDisplay = true } }
    var foreground: NSColor = ink { didSet { needsDisplay = true } }
    var symbolName: String?
    var compact = false
    private var hovered = false
    private var feedbackUntil = Date.distantPast
    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        guard isEnabled else { return false }
        feedbackUntil = Date().addingTimeInterval(0.18); needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.needsDisplay = true }
        return super.sendAction(action, to: target)
    }
    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]).width
        return NSSize(width: compact ? 42 : ceil(width) + (symbolName == nil ? 30 : 54), height: 42)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        let pressed = isEnabled && (cell?.isHighlighted == true || Date() < feedbackUntil)
        let offset: CGFloat = pressed ? 0 : (hovered && isEnabled ? 4 : 3)
        let face = bounds.insetBy(dx: 2, dy: 3).offsetBy(dx: -1 + (pressed ? 2 : 0), dy: 1 - (pressed ? 2 : 0))
        ink.withAlphaComponent(isEnabled ? 1 : 0.16).setFill()
        NSBezierPath(roundedRect: face.offsetBy(dx: offset, dy: -offset), xRadius: 3, yRadius: 3).fill()
        (isEnabled ? fill : NSColor(hex: 0xECECE8)).setFill()
        let path = NSBezierPath(roundedRect: face, xRadius: 3, yRadius: 3)
        path.fill(); ink.withAlphaComponent(isEnabled ? 1 : 0.2).setStroke(); path.lineWidth = 1.6; path.stroke()
        let color = isEnabled ? foreground : Memphis.muted.withAlphaComponent(0.48)
        let attrs: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: color]
        let textSize = (title as NSString).size(withAttributes: attrs)
        let total = compact ? CGFloat(18) : textSize.width + (symbolName == nil ? 0 : 26)
        let left = face.midX - total / 2
        if let symbolName, let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 15, weight: .semibold)) {
            image.lockFocus(); color.set(); NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop); image.unlockFocus()
            image.draw(in: NSRect(x: left, y: face.midY - 9, width: 18, height: 18))
        }
        if !compact {
            (title as NSString).draw(at: NSPoint(x: left + (symbolName == nil ? 0 : 26), y: face.midY - textSize.height / 2), withAttributes: attrs)
        }
        if window?.firstResponder === self {
            Memphis.blue.setStroke(); let focus = NSBezierPath(roundedRect: face.insetBy(dx: 3, dy: 3), xRadius: 2, yRadius: 2)
            focus.lineWidth = 2; focus.stroke()
        }
    }
}
func styleButton(_ button: NSButton, primary: Bool = false, symbol: String? = nil, compact: Bool = false) {
    button.isBordered = false; button.bezelStyle = .regularSquare
    button.font = .systemFont(ofSize: 13, weight: .semibold)
    button.focusRingType = .none; button.translatesAutoresizingMaskIntoConstraints = false
    button.heightAnchor.constraint(equalToConstant: 42).isActive = true
    if let button = button as? MemphisButton {
        button.fill = primary ? Memphis.yellow : .white; button.symbolName = symbol; button.compact = compact
        button.invalidateIntrinsicContentSize()
    }
    if compact { button.widthAnchor.constraint(equalToConstant: 42).isActive = true }
    button.toolTip = button.title; button.setAccessibilityLabel(button.title)
}
final class StatusBadge: NSView {
    let text: NSTextField
    var color: NSColor { didSet { needsDisplay = true } }
    init(_ value: String, color: NSColor) {
        text = label(value, 11, .semibold); self.color = color; super.init(frame: .zero); addSubview(text)
        text.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor), heightAnchor.constraint(equalToConstant: 28)])
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        color.setFill(); let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        path.fill(); ink.setStroke(); path.lineWidth = 1.3; path.stroke()
    }
}
final class PrintProgress: NSView {
    var fraction: Double = 0 {
        didSet {
            if fraction != oldValue && !Memphis.reduceMotion {
                wantsLayer = true
                let transition = CATransition(); transition.type = .fade; transition.duration = 0.16
                layer?.add(transition, forKey: "progress-change")
            }
            needsDisplay = true
        }
    }
    override var intrinsicContentSize: NSSize { NSSize(width: 200, height: 16) }
    override func draw(_ dirtyRect: NSRect) {
        let count = max(1, Int(bounds.width / 16)), gap: CGFloat = 3
        let width = (bounds.width - CGFloat(count - 1) * gap) / CGFloat(count)
        for index in 0..<count {
            (Double(index) < min(1, max(0, fraction)) * Double(count) ? Memphis.yellow : NSColor(hex: 0x444442)).setFill()
            NSBezierPath(rect: NSRect(x: CGFloat(index) * (width + gap), y: 1, width: width, height: bounds.height - 2)).fill()
        }
    }
}
func metric(_ title: String, number: NSTextField, symbol name: String, color: NSColor) -> NSView {
    number.font = .monospacedDigitSystemFont(ofSize: 28, weight: .bold); number.textColor = ink
    let tile = NSView(); tile.wantsLayer = true; tile.layer?.backgroundColor = color.cgColor
    tile.layer?.borderWidth = 1.5; tile.layer?.borderColor = ink.cgColor; tile.layer?.cornerRadius = 3
    let icon = symbol(name, size: 18); tile.addSubview(icon); icon.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([tile.widthAnchor.constraint(equalToConstant: 42), tile.heightAnchor.constraint(equalToConstant: 42), icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor), icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor)])
    let content = row([tile, label(title, 13, .semibold), spacer(), number])
    let surface = PaperSurface(); surface.install(content, padding: 16)
    surface.heightAnchor.constraint(equalToConstant: 64).isActive = true; return surface
}
final class ImportArtwork: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 100) }
    override func draw(_ dirtyRect: NSRect) {
        let x = bounds.midX, y = bounds.midY
        for (dx, dy, color) in [(-20.0, 6.0, Memphis.mint), (12.0, -2.0, Memphis.yellow)] {
            color.setFill(); let p = NSBezierPath(roundedRect: NSRect(x: x - 43 + dx, y: y - 31 + dy, width: 84, height: 66), xRadius: 3, yRadius: 3)
            p.fill(); ink.setStroke(); p.lineWidth = 2; p.stroke()
        }
        let front = NSRect(x: x - 37, y: y - 35, width: 84, height: 66)
        ink.setFill(); NSBezierPath(rect: front.offsetBy(dx: 4, dy: -4)).fill()
        NSColor.white.setFill(); NSBezierPath(rect: front).fill(); ink.setStroke(); NSBezierPath(rect: front).stroke()
        NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: nil)?.draw(in: NSRect(x: x - 16, y: y - 19, width: 40, height: 34))
        Memphis.pink.setFill(); NSBezierPath(rect: NSRect(x: x - 51, y: y + 36, width: 14, height: 7)).fill()
    }
}
