// ShotShot — нативний (arm64) аналог LightShot: виділення області + анотації.
// Знімок екрана: ScreenCaptureKit. Хоткей: ⌘⇧7 (Carbon). Без Rosetta.
import Cocoa
import Carbon
import ScreenCaptureKit

// MARK: - Модель анотацій

enum Tool { case arrow, rect, line, text, marker }

final class Annotation {
    let tool: Tool
    var color: NSColor
    var width: CGFloat
    var start: CGPoint = .zero
    var end: CGPoint = .zero
    var points: [CGPoint] = []   // для marker (freehand)
    var text: String = ""
    var fontSize: CGFloat = 18
    init(tool: Tool, color: NSColor, width: CGFloat) {
        self.tool = tool; self.color = color; self.width = width
    }
}

// MARK: - Вікно оверлея (borderless, може стати key)

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - В'юха оверлея

final class OverlayView: NSView {
    var background: NSImage!          // заморожений екран
    var backingScale: CGFloat = 2

    private enum Phase { case selecting, annotating }
    private var phase: Phase = .selecting

    private enum HandleKind { case tl, t, tr, r, br, b, bl, l }
    private enum Mode { case none, newSel, move, resize(HandleKind), annotate }
    private var mode: Mode = .none
    private let handleSize: CGFloat = 10

    private var selection: CGRect? = nil
    private var dragStart: CGPoint = .zero
    private var dragging = false
    private var moveAnchor: CGPoint = .zero
    private var selAtDragStart: CGRect = .zero

    private var annotations: [Annotation] = []
    private var current: Annotation? = nil

    var tool: Tool = .arrow
    var color: NSColor = .systemRed
    var lineWidth: CGFloat = 3

    private var toolbar: NSView? = nil
    private var textEditor: NSTextField? = nil
    private var exporting = false

    var onFinish: (() -> Void)?       // закрити оверлей

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }   // bottom-left, як NSBezierPath

    // MARK: Малювання

    override func draw(_ dirty: NSRect) {
        // 1) фон — заморожений екран
        background.draw(in: bounds)

        // 2) затемнення поза виділенням (не для експорту)
        if !exporting {
            NSColor.black.withAlphaComponent(0.35).setFill()
            if let sel = selection {
                let p = NSBezierPath(rect: bounds)
                p.append(NSBezierPath(rect: sel).reversed)
                p.fill()
                // рамка виділення
                NSColor.white.setStroke()
                let b = NSBezierPath(rect: sel); b.lineWidth = 1; b.stroke()
                drawDimensionLabel(sel)
                // ручки для зміни розміру (лише в режимі анотацій)
                if phase == .annotating {
                    for (_, c) in handleCenters(sel) {
                        let r = handleRect(c)
                        NSColor.white.setFill(); NSBezierPath(rect: r).fill()
                        NSColor.black.withAlphaComponent(0.5).setStroke()
                        let hp = NSBezierPath(rect: r); hp.lineWidth = 1; hp.stroke()
                    }
                }
            } else {
                bounds.fill()
            }
        }

        // 3) анотації (і в експорт теж)
        for a in annotations { drawAnnotation(a) }
        if let c = current { drawAnnotation(c) }
    }

    private func drawDimensionLabel(_ sel: CGRect) {
        let txt = "\(Int(sel.width)) × \(Int(sel.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let s = NSAttributedString(string: txt, attributes: attrs)
        let size = s.size()
        var o = CGPoint(x: sel.minX, y: sel.maxY + 4)
        if o.y + size.height > bounds.maxY { o.y = sel.maxY - size.height - 4 }
        let bg = CGRect(x: o.x - 4, y: o.y - 2, width: size.width + 8, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: bg, xRadius: 3, yRadius: 3).fill()
        s.draw(at: o)
    }

    private func drawAnnotation(_ a: Annotation) {
        a.color.setStroke()
        a.color.setFill()
        switch a.tool {
        case .rect:
            let r = CGRect(x: min(a.start.x, a.end.x), y: min(a.start.y, a.end.y),
                           width: abs(a.end.x - a.start.x), height: abs(a.end.y - a.start.y))
            let p = NSBezierPath(rect: r); p.lineWidth = a.width; p.stroke()
        case .line:
            let p = NSBezierPath(); p.lineWidth = a.width; p.lineCapStyle = .round
            p.move(to: a.start); p.line(to: a.end); p.stroke()
        case .arrow:
            drawArrow(from: a.start, to: a.end, width: a.width)
        case .marker:
            guard a.points.count > 1 else { break }
            let p = NSBezierPath(); p.lineWidth = a.width
            p.lineCapStyle = .round; p.lineJoinStyle = .round
            p.move(to: a.points[0])
            for pt in a.points.dropFirst() { p.line(to: pt) }
            a.color.withAlphaComponent(0.4).setStroke()
            p.stroke()
        case .text:
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: a.fontSize, weight: .semibold),
                .foregroundColor: a.color
            ]
            NSAttributedString(string: a.text, attributes: attrs).draw(at: a.start)
        }
    }

    private func drawArrow(from s: CGPoint, to e: CGPoint, width: CGFloat) {
        let path = NSBezierPath(); path.lineWidth = width
        path.lineCapStyle = .round; path.lineJoinStyle = .round
        path.move(to: s); path.line(to: e)
        let angle = atan2(e.y - s.y, e.x - s.x)
        let len = max(14, width * 4), spread = CGFloat.pi / 7
        let p1 = CGPoint(x: e.x - len * cos(angle - spread), y: e.y - len * sin(angle - spread))
        let p2 = CGPoint(x: e.x - len * cos(angle + spread), y: e.y - len * sin(angle + spread))
        path.move(to: e); path.line(to: p1)
        path.move(to: e); path.line(to: p2)
        path.stroke()
    }

    // MARK: Миша

    override func resetCursorRects() {
        if phase == .selecting {
            addCursorRect(bounds, cursor: .crosshair)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if phase == .selecting {
            dragStart = p; dragging = true; selection = .zero; mode = .newSel
            return
        }
        // phase == .annotating
        commitTextEditorIfAny()
        if let s = selection {
            if let h = hitHandle(p, s) { mode = .resize(h); selAtDragStart = s; return }
            if nearBorder(p, s)        { mode = .move; moveAnchor = p; selAtDragStart = s; return }
        }
        if tool == .text { beginTextInput(at: p); mode = .none; return }
        let a = Annotation(tool: tool, color: color, width: tool == .marker ? 14 : lineWidth)
        a.start = p; a.end = p
        if tool == .marker { a.points = [p] }
        current = a; mode = .annotate
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .newSel:
            selection = CGRect(x: min(dragStart.x, p.x), y: min(dragStart.y, p.y),
                               width: abs(p.x - dragStart.x), height: abs(p.y - dragStart.y))
        case .resize(let h):
            selection = resized(selAtDragStart, h, p)
        case .move:
            selection = moved(selAtDragStart, byX: p.x - moveAnchor.x, byY: p.y - moveAnchor.y)
        case .annotate:
            if let a = current { a.end = p; if a.tool == .marker { a.points.append(p) } }
        case .none:
            break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .newSel:
            dragging = false
            if let sel = selection, sel.width > 5, sel.height > 5 {
                phase = .annotating
                NSCursor.arrow.set()
                showToolbar(for: sel)
            } else {
                selection = nil
            }
        case .resize, .move:
            positionToolbar()
        case .annotate:
            if let a = current { annotations.append(a); current = nil }
        case .none:
            break
        }
        mode = .none
        needsDisplay = true
    }

    // MARK: Геометрія ручок / переміщення / розміру

    private func handleCenters(_ s: CGRect) -> [(HandleKind, CGPoint)] {
        [(.tl, CGPoint(x: s.minX, y: s.maxY)), (.t, CGPoint(x: s.midX, y: s.maxY)),
         (.tr, CGPoint(x: s.maxX, y: s.maxY)), (.r, CGPoint(x: s.maxX, y: s.midY)),
         (.br, CGPoint(x: s.maxX, y: s.minY)), (.b, CGPoint(x: s.midX, y: s.minY)),
         (.bl, CGPoint(x: s.minX, y: s.minY)), (.l, CGPoint(x: s.minX, y: s.midY))]
    }
    private func handleRect(_ c: CGPoint) -> CGRect {
        CGRect(x: c.x - handleSize/2, y: c.y - handleSize/2, width: handleSize, height: handleSize)
    }
    private func hitHandle(_ p: CGPoint, _ s: CGRect) -> HandleKind? {
        for (k, c) in handleCenters(s) where handleRect(c).insetBy(dx: -3, dy: -3).contains(p) { return k }
        return nil
    }
    private func nearBorder(_ p: CGPoint, _ s: CGRect) -> Bool {
        s.insetBy(dx: -6, dy: -6).contains(p) && !s.insetBy(dx: 6, dy: 6).contains(p)
    }
    private func resized(_ s: CGRect, _ h: HandleKind, _ p: CGPoint) -> CGRect {
        var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
        switch h {
        case .tl: minX = p.x; maxY = p.y
        case .t:  maxY = p.y
        case .tr: maxX = p.x; maxY = p.y
        case .r:  maxX = p.x
        case .br: maxX = p.x; minY = p.y
        case .b:  minY = p.y
        case .bl: minX = p.x; minY = p.y
        case .l:  minX = p.x
        }
        minX = max(0, minX); minY = max(0, minY)
        maxX = min(bounds.width, maxX); maxY = min(bounds.height, maxY)
        let x = min(minX, maxX), y = min(minY, maxY)
        let w = max(abs(maxX - minX), 10), hgt = max(abs(maxY - minY), 10)
        return CGRect(x: x, y: y, width: w, height: hgt)
    }
    private func moved(_ s: CGRect, byX dx: CGFloat, byY dy: CGFloat) -> CGRect {
        var o = CGPoint(x: s.minX + dx, y: s.minY + dy)
        o.x = max(0, min(o.x, bounds.width - s.width))
        o.y = max(0, min(o.y, bounds.height - s.height))
        return CGRect(origin: o, size: s.size)
    }

    // MARK: Клавіатура

    override func keyDown(with event: NSEvent) {
        if Int(event.keyCode) == 53 { onFinish?(); return }   // Esc
        // ⌘C — копіювати виділений скрін (коли вже є зона)
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "c",
           phase == .annotating, selection != nil {
            copyShot(); return
        }
        super.keyDown(with: event)
    }

    // MARK: Текстовий інструмент

    private func beginTextInput(at p: CGPoint) {
        let tf = NSTextField(frame: CGRect(x: p.x, y: p.y - 6, width: 200, height: 24))
        tf.font = NSFont.systemFont(ofSize: 18, weight: .semibold)
        tf.textColor = color
        tf.backgroundColor = .clear
        tf.isBordered = false
        tf.focusRingType = .none
        tf.target = self; tf.action = #selector(textCommitted)
        addSubview(tf)
        window?.makeFirstResponder(tf)
        textEditor = tf
    }

    @objc private func textCommitted() { commitTextEditorIfAny() }

    private func commitTextEditorIfAny() {
        guard let tf = textEditor else { return }
        let str = tf.stringValue
        let origin = CGPoint(x: tf.frame.minX, y: tf.frame.minY + 6)
        tf.removeFromSuperview(); textEditor = nil
        if !str.isEmpty {
            let a = Annotation(tool: .text, color: color, width: lineWidth)
            a.start = origin; a.text = str; a.fontSize = 18
            annotations.append(a)
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: Тулбар

    private func showToolbar(for sel: CGRect) {
        let bar = NSView(frame: .zero)
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.12, alpha: 0.95).cgColor
        bar.layer?.cornerRadius = 8

        var x: CGFloat = 8
        func addButton(_ title: String, _ sel: Selector, width: CGFloat = 30) {
            let b = NSButton(frame: CGRect(x: x, y: 6, width: width, height: 26))
            b.title = title; b.bezelStyle = .regularSquare; b.isBordered = false
            b.font = .systemFont(ofSize: 15)
            b.contentTintColor = .white
            b.target = self; b.action = sel
            bar.addSubview(b); x += width + 2
        }
        func addColor(_ c: NSColor) {
            let b = NSButton(frame: CGRect(x: x, y: 9, width: 20, height: 20))
            b.title = ""; b.isBordered = false; b.wantsLayer = true
            b.layer?.backgroundColor = c.cgColor
            b.layer?.cornerRadius = 10
            b.target = self; b.action = #selector(pickColor(_:))
            objc_setAssociatedObject(b, &colorKey, c, .OBJC_ASSOCIATION_RETAIN)
            bar.addSubview(b); x += 24
        }
        func sep() { x += 8 }

        addButton("↗", #selector(selArrow))
        addButton("▭", #selector(selRect))
        addButton("—", #selector(selLine))
        addButton("T", #selector(selText))
        addButton("🖍", #selector(selMarker))
        sep()
        for c in [NSColor.systemRed, .systemYellow, .systemGreen, .systemBlue, .black, .white] { addColor(c) }
        sep()
        addButton("↶", #selector(undo))
        sep()
        addButton("📋", #selector(copyShot))
        addButton("💾", #selector(saveShot))
        addButton("✕", #selector(cancelShot))

        bar.frame = CGRect(x: 0, y: 0, width: x + 6, height: 38)
        addSubview(bar)
        toolbar = bar
        positionToolbar()
    }

    private func positionToolbar() {
        guard let bar = toolbar, let sel = selection else { return }
        let barW = bar.frame.width, barH = bar.frame.height
        let margin: CGFloat = 8
        // спершу — під виділенням
        var by = sel.minY - barH - margin
        if by < margin {
            // не влазить знизу — пробуємо над виділенням
            let above = sel.maxY + margin
            if above + barH <= bounds.maxY - margin {
                by = above
            } else {
                // не влазить ні знизу, ні зверху (виділено весь екран) —
                // кладемо тулбар усередину виділення, біля нижнього краю
                by = sel.minY + margin
            }
        }
        // фінальне обмеження у межах видимої області
        by = max(margin, min(by, bounds.maxY - barH - margin))
        var bx = sel.minX
        if bx + barW > bounds.maxX { bx = bounds.maxX - barW - margin }
        if bx < margin { bx = margin }
        bar.frame = CGRect(x: bx, y: by, width: barW, height: barH)
    }

    // MARK: Курсори

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard phase == .annotating, let s = selection else { NSCursor.crosshair.set(); return }
        if let h = hitHandle(p, s) { cursor(for: h).set() }
        else if nearBorder(p, s)   { NSCursor.openHand.set() }
        else                       { NSCursor.arrow.set() }
    }

    private func cursor(for h: HandleKind) -> NSCursor {
        switch h {
        case .l, .r: return .resizeLeftRight
        case .t, .b: return .resizeUpDown
        default:     return .crosshair   // кути (діагональних курсорів немає в публічному API)
        }
    }

    // MARK: Дії тулбара

    @objc private func selArrow()  { commitTextEditorIfAny(); tool = .arrow }
    @objc private func selRect()   { commitTextEditorIfAny(); tool = .rect }
    @objc private func selLine()   { commitTextEditorIfAny(); tool = .line }
    @objc private func selText()   { commitTextEditorIfAny(); tool = .text }
    @objc private func selMarker() { commitTextEditorIfAny(); tool = .marker }
    @objc private func undo()      { if !annotations.isEmpty { annotations.removeLast(); needsDisplay = true } }
    @objc private func pickColor(_ sender: NSButton) {
        if let c = objc_getAssociatedObject(sender, &colorKey) as? NSColor { color = c }
    }
    @objc private func cancelShot() { onFinish?() }

    @objc private func copyShot() {
        guard let img = exportImage() else { return }
        let pb = NSPasteboard.general
        pb.clearContents(); pb.writeObjects([img])
        onFinish?()
    }

    @objc private func saveShot() {
        guard let img = exportImage(), let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let name = "Screenshot \(fmt.string(from: Date())).png"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop").appendingPathComponent(name)
        try? png.write(to: url)
        onFinish?()
    }

    // MARK: Експорт виділеної області з анотаціями

    private func exportImage() -> NSImage? {
        commitTextEditorIfAny()
        guard let sel = selection else { return nil }
        exporting = true
        toolbar?.isHidden = true
        guard let rep = bitmapImageRepForCachingDisplay(in: sel) else {
            exporting = false; toolbar?.isHidden = false; return nil
        }
        cacheDisplay(in: sel, to: rep)
        exporting = false
        toolbar?.isHidden = false
        let img = NSImage(size: sel.size)
        img.addRepresentation(rep)
        return img
    }
}

private var colorKey: UInt8 = 0

// MARK: - Контролер захоплення

@MainActor
final class CaptureController {
    static let shared = CaptureController()
    private var window: OverlayWindow?

    func begin() {
        if window != nil { return }   // вже відкрито
        Task { await self.capture() }
    }

    private func capture() async {
        // екран під курсором
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen else { return }
        let scale = screen.backingScaleFactor
        guard let screenNumber = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            guard let display = content.displays.first(where: { $0.displayID == screenNumber })
                    ?? content.displays.first else { showPermissionHelp(); return }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
            config.showsCursor = false
            config.captureResolution = .best

            let cg = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
            present(cgImage: cg, on: screen, scale: scale)
        } catch {
            showPermissionHelp()
        }
    }

    private func present(cgImage: CGImage, on screen: NSScreen, scale: CGFloat) {
        let win = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless],
                                backing: .buffered, defer: false)
        win.level = .screenSaver
        win.backgroundColor = .clear
        win.isOpaque = false
        win.ignoresMouseEvents = false
        win.acceptsMouseMovedEvents = true
        win.setFrame(screen.frame, display: true)

        let view = OverlayView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.background = NSImage(cgImage: cgImage, size: screen.frame.size)
        view.backingScale = scale
        view.onFinish = { [weak self] in
            self?.window?.orderOut(nil); self?.window = nil
        }
        win.contentView = view

        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(view)
        window = win
    }

    private func showPermissionHelp() {
        let a = NSAlert()
        a.messageText = "Потрібен доступ «Запис екрана»"
        a.informativeText = "Увімкни ShotShot у Системні налаштування → Приватність і безпека → Запис екрана, потім перезапусти застосунок."
        a.addButton(withTitle: "Відкрити налаштування")
        a.addButton(withTitle: "Скасувати")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - Хоткей ⌘⇧7

final class HotKey {
    var ref: EventHotKeyRef?
    func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { CaptureController.shared.begin() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x53485453), id: 1)
        RegisterEventHotKey(UInt32(kVK_ANSI_7), UInt32(cmdKey | shiftKey),
                            id, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let hotKey = HotKey()
    var statusItem: NSStatusItem!
    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        hotKey.install()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "✂︎"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Знімок: ⌘⇧7", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Вийти", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
