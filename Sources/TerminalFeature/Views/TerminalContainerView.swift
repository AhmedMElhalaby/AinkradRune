import SwiftUI
import AppKit
import SwiftTerm

private struct PaneResizesImmediatelyKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by the layout on the pane that fills the Focus-Mode canvas; read by
    /// `TerminalContainerView` to make that pane's resize immediate (no debounce).
    var paneResizesImmediately: Bool {
        get { self[PaneResizesImmediatelyKey.self] }
        set { self[PaneResizesImmediatelyKey.self] = newValue }
    }
}

/// The terminal view. Resize behaves normally (live, fills the pane); the
/// output-duplication-on-resize fix lives in the SwiftTerm fork, which
/// disables SwiftTerm's line-reflow (the re-wrap that duplicated output). No
/// app-side resize hacks — those caused a residual artifact and, worse, an
/// empty gap while dragging.
final class AinkradTerminalView: LocalProcessTerminalView {
    /// Fired once, when the view is first laid out at a usable size. The shell
    /// is spawned here rather than at creation so it starts already matching the
    /// pane — avoiding a resize (SIGWINCH) mid-startup, which races the shell's
    /// first prompt and can leave a stray zsh `%` end-of-line mark (seen when
    /// opening several panes in quick succession).
    var onReady: (() -> Void)?
    private var didBecomeReady = false

    /// True when this pane owns the window's keyboard focus.
    ///
    /// Used to keep the agent's terminal context on the pane the user is
    /// actually in. The context source used to be set once, in `makeNSView` —
    /// making it whichever pane was created *last*, not the focused one. With
    /// two terminals open, asking the assistant about "the terminal" fed it the
    /// other pane's buffer, silently, with nothing to indicate which it read.
    ///
    /// Read rather than overriding `becomeFirstResponder`: SwiftTerm declares
    /// that method `public`, not `open`, so it cannot be overridden from here.
    /// (Having the *host* tell plugins which pane is active is the better fix
    /// and belongs to the SDK focus work batched into the next generation.)
    var ownsKeyboardFocus: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard !didBecomeReady, newSize.width > 8, newSize.height > 8 else { return }
        didBecomeReady = true
        onReady?()
        onReady = nil
    }

    /// Spawns the shell if the first layout never arrived (defensive; panes are
    /// always laid out, but never leave a session unstarted).
    func startIfNeeded() {
        guard !didBecomeReady else { return }
        didBecomeReady = true
        onReady?()
        onReady = nil
    }
}

/// Hosts the terminal (an AppKit `NSView`) inside SwiftUI. Spawns the session's
/// PTY-backed login shell on creation and terminates it deterministically when
/// this view leaves the hierarchy — see ADR-0002 and Terminal App
/// Architecture.md. The resolved `appearance` (colors + ANSI palette + font +
/// cursor + transparency) applies live; the scrollbar is hidden until the user
/// scrolls. When translucent, the blurred backdrop is provided by a SwiftUI
/// `Material` behind this view (see TerminalBlockRootView).
struct TerminalContainerView: NSViewRepresentable {
    let session: TerminalSession
    let appearance: TerminalRenderAppearance
    let contextBridge: TerminalContextBridge
    /// True for the single pane that fills the Focus-Mode canvas — its resize
    /// applies immediately (no debounce) so the zoom-in fills without a flash.
    @Environment(\.paneResizesImmediately) private var resizesImmediately

    func makeNSView(context: Context) -> AinkradTerminalView {
        let view = AinkradTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        view.applyResizeImmediately = resizesImmediately
        apply(appearance, to: view, coordinator: context.coordinator)
        context.coordinator.installScrollReveal(for: view)
        // Defer the spawn to the first real layout so the shell starts at the
        // pane's size (no startup-time SIGWINCH → no stray `%`). See `onReady`.
        view.onReady = { [weak view, session] in
            let executable = session.launchExecutable ?? session.shellPath
            let args = session.launchArgs ?? ["-l"]
            view?.startProcess(
                executable: executable,
                args: args,
                environment: nil,
                currentDirectory: session.workingDirectory.path
            )
        }
        // Safety net: if a valid layout never arrives, start anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak view] in
            view?.startIfNeeded()
        }
        // Seed the context source with this pane (it is the newest, and often
        // the only, one) — but from here on, FOCUS decides; see `updateNSView`.
        contextBridge.setActiveSource(view)
        return view
    }

    func updateNSView(_ nsView: AinkradTerminalView, context: Context) {
        // Set BEFORE applying appearance so a focus-driven resize in this same
        // update takes the immediate path (the setter also flushes any pending
        // debounced resize the instant this pane becomes the focused one).
        nsView.applyResizeImmediately = resizesImmediately
        // Keep the agent's terminal context on the FOCUSED pane, not the
        // last-created one. Focusing a pane changes host state (`focusedID`),
        // which re-renders every `BlockView` and lands here — so this runs on
        // exactly the transitions that matter.
        if nsView.ownsKeyboardFocus {
            contextBridge.setActiveSource(nsView)
        }
        apply(appearance, to: nsView, coordinator: context.coordinator)
    }

    /// Applies the resolved appearance. Skips entirely when nothing changed —
    /// crucially, a resize does NOT change the appearance, so we don't re-set
    /// the font mid-resize (that runs resetFont/selectNone).
    private func apply(_ appearance: TerminalRenderAppearance, to view: AinkradTerminalView, coordinator: Coordinator) {
        guard coordinator.appliedAppearance != appearance else { return }
        coordinator.appliedAppearance = appearance

        let palette = appearance.ansi.compactMap(Self.terminalColor(hex:))
        if palette.count == 16 {
            view.installColors(palette)
        }
        // Translucent background lets the SwiftUI Material behind this view
        // (the blurred island/sky) show through. The layer must be non-opaque.
        let isTranslucent = appearance.backgroundOpacity < 1
        view.nativeBackgroundColor = Self.nsColor(hex: appearance.background)
            .withAlphaComponent(CGFloat(appearance.backgroundOpacity))
        view.wantsLayer = true
        view.layer?.isOpaque = !isTranslucent
        view.layer?.backgroundColor = .clear
        view.nativeForegroundColor = Self.nsColor(hex: appearance.foreground)
        view.caretColor = Self.nsColor(hex: appearance.cursor)
        view.selectedTextBackgroundColor = Self.nsColor(hex: appearance.selection)
        view.font = Self.font(family: appearance.fontFamily, size: appearance.fontSize)
        view.optionAsMetaKey = appearance.optionAsMeta
        view.allowMouseReporting = appearance.sendMouseEventsToApps
        view.getTerminal().setCursorStyle(Self.cursorStyle(shape: appearance.cursorShape, blink: appearance.cursorBlink))

        // Rebuilding history is comparatively heavy — only when it changes.
        if coordinator.appliedScrollback != appearance.scrollback {
            view.changeScrollback(appearance.scrollback)
            coordinator.appliedScrollback = appearance.scrollback
        }
    }

    private static func cursorStyle(shape: TerminalCursorShape, blink: Bool) -> CursorStyle {
        switch (shape, blink) {
        case (.block, true): return .blinkBlock
        case (.block, false): return .steadyBlock
        case (.underline, true): return .blinkUnderline
        case (.underline, false): return .steadyUnderline
        case (.bar, true): return .blinkBar
        case (.bar, false): return .steadyBar
        }
    }

    // MARK: - Color / font conversion

    private static func rgb(hex: String) -> (r: UInt8, g: UInt8, b: UInt8)? {
        var value = hex
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let int = UInt32(value, radix: 16) else { return nil }
        return (UInt8((int >> 16) & 0xFF), UInt8((int >> 8) & 0xFF), UInt8(int & 0xFF))
    }

    private static func nsColor(hex: String) -> NSColor {
        guard let c = rgb(hex: hex) else { return .black }
        return NSColor(
            srgbRed: CGFloat(c.r) / 255,
            green: CGFloat(c.g) / 255,
            blue: CGFloat(c.b) / 255,
            alpha: 1
        )
    }

    private static func terminalColor(hex: String) -> SwiftTerm.Color? {
        guard let c = rgb(hex: hex) else { return nil }
        // SwiftTerm.Color components are 16-bit; scale 8-bit up by 257.
        return SwiftTerm.Color(red: UInt16(c.r) * 257, green: UInt16(c.g) * 257, blue: UInt16(c.b) * 257)
    }

    private static func font(family: String, size: Double) -> NSFont {
        NSFont(name: family, size: CGFloat(size))
            ?? NSFont.monospacedSystemFont(ofSize: CGFloat(size), weight: .regular)
    }

    static func dismantleNSView(_ nsView: AinkradTerminalView, coordinator: Coordinator) {
        coordinator.contextBridge.clearActiveSource(nsView)
        coordinator.teardown()
        let pid = nsView.process.shellPid
        nsView.terminate()
        PTYReaper.reapAfterTerminate(pid)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session, contextBridge: contextBridge)
    }

    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        private let session: TerminalSession
        let contextBridge: TerminalContextBridge
        var appliedAppearance: TerminalRenderAppearance?
        var appliedScrollback: Int?

        private weak var terminalView: NSView?
        private weak var scroller: NSScroller?
        private var scrollMonitor: Any?
        private var hideWork: DispatchWorkItem?

        init(session: TerminalSession, contextBridge: TerminalContextBridge) {
            self.session = session
            self.contextBridge = contextBridge
        }

        /// Hides SwiftTerm's always-on scrollbar and reveals it only while the
        /// pointer is scrolling over this terminal, hiding again shortly after.
        @MainActor
        func installScrollReveal(for view: NSView) {
            terminalView = view
            let scroller = view.subviews.compactMap { $0 as? NSScroller }.first
            self.scroller = scroller
            scroller?.scrollerStyle = .overlay
            scroller?.isHidden = true

            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScroll(event)
                return event
            }
        }

        @MainActor
        private func handleScroll(_ event: NSEvent) {
            guard let view = terminalView, let scroller, event.window === view.window else { return }
            let point = view.convert(event.locationInWindow, from: nil)
            guard view.bounds.contains(point) else { return }

            scroller.isHidden = false
            hideWork?.cancel()
            let work = DispatchWorkItem { [weak scroller] in scroller?.isHidden = true }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
        }

        func teardown() {
            hideWork?.cancel()
            if let scrollMonitor {
                NSEvent.removeMonitor(scrollMonitor)
                self.scrollMonitor = nil
            }
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            Task { @MainActor [session] in
                session.terminate()
            }
        }
    }
}
