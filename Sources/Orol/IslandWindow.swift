import AppKit
import SwiftUI

final class IslandPanel: NSPanel {
    var allowKey = false
    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
    /// AppKit keeps ordinary windows below the menu bar; the island belongs on top of it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// One fixed, transparent window over the notch. The pill morphs inside it; outside
/// the pill every click goes through to whatever is below.
final class IslandWindowController {
    let panel: IslandPanel
    private let model: IslandModel
    private var monitors: [Any] = []
    private var hoverWork: DispatchWorkItem?
    private var pointerInside = false
    private(set) var lastInside = Date.distantPast
    static let windowSize = CGSize(width: 760, height: 660)

    init(model: IslandModel) {
        self.model = model
        panel = IslandPanel(contentRect: NSRect(origin: .zero, size: Self.windowSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        // after isFloatingPanel, which would reset it to .floating (under the menu bar)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let host = NSHostingView(rootView: IslandView(model: model))
        host.sizingOptions = []
        host.safeAreaRegions = []
        panel.contentView = host

        reposition()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.reposition() }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in self?.pointerMoved() }) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.pointerMoved(); return e }) {
            monitors.append(m)
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.clickedOutside()
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == 53, let self, self.model.phase != .idle {          // Esc
                self.model.onDismiss()
                return nil
            }
            return e
        }) { monitors.append(m) }
    }

    /// The screen with the notch if there is one, else the main screen.
    private func targetScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    func reposition() {
        guard let screen = targetScreen() else { return }
        let f = screen.frame
        if screen.safeAreaInsets.top > 0, let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            let w = f.width - l.width - r.width
            model.hasNotch = true
            model.notch = CGSize(width: max(120, w), height: screen.safeAreaInsets.top)
        } else {
            let menuBar = max(24, f.maxY - screen.visibleFrame.maxY)
            model.hasNotch = false
            model.notch = CGSize(width: 120, height: min(menuBar, 30))
        }
        let s = Self.windowSize
        panel.setFrame(NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height), display: true)
    }

    private func pillRect() -> NSRect {
        let s = model.pillSize
        let f = panel.frame
        let extra = model.bubbleWidth > 0 ? model.bubbleWidth + 6 : 0
        return NSRect(x: f.midX - s.width / 2 + model.pillOffset, y: f.maxY - s.height, width: s.width + extra, height: s.height)
    }

    var isPointerInside: Bool { pointerInside }

    private var suppressHoverUntil = Date.distantPast

    /// A panel just closed under the pointer: that is not a hover. Start over from the small pill.
    func resetHover() {
        hoverWork?.cancel()
        suppressHoverUntil = Date().addingTimeInterval(0.45)
        pointerInside = false
        panel.ignoresMouseEvents = true
        if model.hovering { model.hovering = false }
    }

    /// Re-evaluate without a mouse event (the pill may have changed size under a still pointer).
    func recheckPointer() { pointerMoved() }

    private func pointerMoved() {
        if Date() < suppressHoverUntil { return }
        // A little slack so the pointer doesn't fall out at the rounded corners; more at rest,
        // where the pill hides behind the notch and the target is the notch itself.
        let resting = !model.hovering && model.phase == .idle && model.approvals.isEmpty
        let inside = pillRect().insetBy(dx: resting ? -8 : -3, dy: -3).contains(NSEvent.mouseLocation)
        if inside { lastInside = Date() }
        guard inside != pointerInside else { return }
        pointerInside = inside
        panel.ignoresMouseEvents = !inside
        hoverWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.pointerInside == inside, self.model.hovering != inside else { return }
            self.model.hovering = inside
            if inside, self.model.phase == .idle, self.model.approvals.isEmpty {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
        hoverWork = w
        let delay = inside ? (model.layout == .compact ? 0.38 : 0.10) : 0.32
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func clickedOutside() {
        // Global monitor: the click went to another app, so it was outside the pill.
        // Only a panel opened from the keyboard (it holds focus) closes this way; one woken by voice
        // stays while you keep working in other apps.
        guard panel.isKeyWindow else { return }
        if model.phase == .input || model.phase == .done { model.onDismiss() }
    }

    /// Give the island keyboard focus for the talk-or-type field without activating the app.
    func takeKey() {
        panel.allowKey = true
        panel.makeKey()
    }

    func releaseKey() {
        guard panel.allowKey else { return }
        panel.allowKey = false
        if panel.isKeyWindow {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        panel.ignoresMouseEvents = !pointerInside
    }
}
