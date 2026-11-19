import AppKit
import AVFoundation
import MetalKit

/// The opening light and Warm analog, once in the life of a Mac:
/// at its first launch, before the welcome, the disk image's included, and
/// again when the welcome is asked for again (`replay`).
/// The existing browser window is the destination. A transparent, mouse-pass
/// carrier keeps its light continuous while the real window is revealed.
@MainActor
final class LaunchArrival: NSObject, AVAudioPlayerDelegate {
    static let shared = LaunchArrival()

    private var offered = false
    private var ticket = UUID()
    private weak var window: NSWindow?
    private var originalAlpha: CGFloat = 1
    private var originalMouse = false
    private var carrier: NSWindow?
    private var dimmer: NSWindow?
    private var light: LaunchLightView?
    private var renderer: LaunchLightRenderer?
    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var watchdog: DispatchWorkItem?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var escape: Any?
    private var startedAt: TimeInterval?
    private var progress = LaunchArrivalProgress()
    private var revealed = false
    private var screens: [CGRect] = []
    private weak var preparedWindow: NSWindow?
    private var preparedAlpha: CGFloat = 1

    /// Reserve the first window synchronously, before SwiftUI orders its
    /// still-empty surface. Dressing and Metal preparation follow later.
    func prepare(_ window: NSWindow, primary: Bool) {
        guard primary, !offered, preparedWindow == nil,
              eligibility(seen: Store.settings.bool(forKey: "launchArrivalSeen") || Arrival.welcomed).plays,
              MTLCreateSystemDefaultDevice() != nil else { return }
        preparedWindow = window
        preparedAlpha = window.alphaValue
        window.alphaValue = 0
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self, weak window] in
            guard let self, let window, self.preparedWindow === window else { return }
            self.restorePrepared(window)
        }
    }

    private func restorePrepared(_ window: NSWindow) {
        guard preparedWindow === window else { return }
        window.alphaValue = preparedAlpha
        preparedWindow = nil
    }

    /// The first window, as it is dressed. True when the light plays, so
    /// the disk image's arrival leaves the window where it is.
    @discardableResult
    func offer(_ window: NSWindow) -> Bool {
        guard let browser = BrowserWindows.shared.browser(for: window), browser.windowID == nil, !offered else { return false }
        let eligibility = eligibility(seen: Store.settings.bool(forKey: "launchArrivalSeen") || Arrival.welcomed)
        offered = true
        return play(window, eligibility)
    }

    /// Show Again: the welcome comes back over the window, and the light
    /// before it, as at the first launch.
    func replay(_ browser: Browser) {
        guard self.window == nil, let window = BrowserWindows.shared.window(for: browser) else { return }
        play(window, eligibility(seen: false))
    }

    private func eligibility(seen: Bool) -> LaunchArrivalEligibility {
        let environment = ProcessInfo.processInfo.environment
        return LaunchArrivalEligibility(
            headless: Headless.on || Headless.atLogin || OpenAtLogin.launchedAsLoginItem()
                || environment["YAB_LOGIN_START"] == "1",
            hidden: NSApp.isHidden || Headless.hidden,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            testing: Store.testing,
            seen: seen,
            overrideValue: environment["YAB_LAUNCH_ARRIVAL"]
        )
    }

    @discardableResult
    private func play(_ window: NSWindow, _ eligibility: LaunchArrivalEligibility) -> Bool {
        guard eligibility.plays, let device = MTLCreateSystemDefaultDevice() else {
            restorePrepared(window)
            return false
        }
        Store.settings.set(true, forKey: "launchArrivalSeen")
        // A replay during the last one's sound tail starts clean.
        player?.stop()
        player = nil
        removeObservers()
        ticket = UUID()
        self.window = window
        // Each Show Again has its own reveal boundary, after completion or cancellation.
        revealed = false
        screens = NSScreen.screens.map(\.frame)
        originalAlpha = preparedWindow === window ? preparedAlpha : window.alphaValue
        if preparedWindow === window { preparedWindow = nil }
        originalMouse = window.ignoresMouseEvents
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        let generation = ticket
        observe(window)
        armWatchdog(after: 3, generation: generation)

        // Resolve the dynamic accent in the window's appearance before leaving
        // the main thread. Runtime Metal compilation cannot stall browser setup.
        var palette = LaunchLightPalette.resolve(accent: .controlAccentColor)
        var surface = SIMD4<Float>(0.93, 0.93, 0.93, 0.20)
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            palette = LaunchLightPalette.resolve(accent: .controlAccentColor)
            let dark = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            surface = LaunchLightPalette.windowSurface(dark: dark)
        }
        let resolvedPalette = palette
        let resolvedSurface = surface
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let prepared = Result { try LaunchLightRenderer(device: device, palette: resolvedPalette, surface: resolvedSurface) }
            DispatchQueue.main.async {
                guard let self, self.ticket == generation, self.window != nil else { return }
                switch prepared {
                case let .success(renderer): self.present(renderer, device: device, generation: generation)
                case .failure: self.cancel()
                }
            }
        }
        return true
    }

    private func present(_ renderer: LaunchLightRenderer, device: MTLDevice, generation: UUID) {
        guard let window, window.isVisible, NSApp.isActive, !NSApp.isHidden,
              !Headless.hidden, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { cancel(); return }
        LaunchArrivalPreview.place(window)
        let margin: CGFloat = 76
        let frame = window.frame.insetBy(dx: -margin, dy: -margin)
        let carrier = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        carrier.title = "\(Brand.name) Launch Light"
        carrier.backgroundColor = .clear
        carrier.isOpaque = false
        carrier.hasShadow = false
        carrier.ignoresMouseEvents = true
        carrier.isReleasedWhenClosed = false
        carrier.isExcludedFromWindowsMenu = true
        carrier.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
        carrier.level = window.level
        let view = LaunchLightView(frame: CGRect(origin: .zero, size: frame.size), device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.autoresizingMask = [.width, .height]
        view.delegate = renderer
        renderer.state.targetSize = window.frame.size
        renderer.state.variant = Int.random(in: 3 ... 60000)
        renderer.onFailure = { [weak self] message in self?.cancel("renderer: " + message) }
        renderer.onPresented = { [weak self] _ in
            guard let self, self.ticket == generation, self.startedAt == nil else { return }
            self.start(generation: generation)
        }
        carrier.contentView = view
        self.carrier = carrier
        self.renderer = renderer
        light = view

        if let screen = window.screen {
            let dimmer = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            dimmer.title = "\(Brand.name) Launch Dimmer"
            dimmer.backgroundColor = .black
            dimmer.isOpaque = false
            dimmer.alphaValue = 0
            dimmer.hasShadow = false
            dimmer.ignoresMouseEvents = true
            dimmer.isReleasedWhenClosed = false
            dimmer.isExcludedFromWindowsMenu = true
            dimmer.collectionBehavior = [.transient, .fullScreenAuxiliary, .ignoresCycle]
            dimmer.level = window.level
            dimmer.order(.above, relativeTo: window.windowNumber)
            self.dimmer = dimmer
        }
        carrier.order(.above, relativeTo: dimmer?.windowNumber ?? window.windowNumber)
        // AppKit can constrain a borderless carrier near a display edge.
        // Use its real origin rather than assuming it stayed symmetric.
        renderer.state.targetOffset = CGPoint(x: window.frame.midX - carrier.frame.midX,
                                             y: carrier.frame.midY - window.frame.midY)
        view.draw()
    }

    private func start(generation: UUID) {
        watchdog?.cancel()
        guard ticket == generation, let window, window.isVisible, NSApp.isActive, !NSApp.isHidden else { cancel(); return }
        progress = LaunchArrivalProgress()
        startedAt = ProcessInfo.processInfo.systemUptime
        LaunchArrivalPreview.record("started", window: window)
        if let url = Bundle.main.url(forResource: "arrival-02", withExtension: "m4a", subdirectory: "LaunchArrival"),
           let player = try? AVAudioPlayer(contentsOf: url), player.prepareToPlay() {
            self.player = player
            player.delegate = self
            if !player.play() { self.player = nil }
        }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        armWatchdog(after: 10, generation: generation)
    }

    private func tick() {
        guard let startedAt, let window, window.isVisible else { cancel(); return }
        progress.advance(wallTime: ProcessInfo.processInfo.systemUptime - startedAt,
                         audioTime: player?.isPlaying == true ? player?.currentTime : nil)
        renderer?.state.elapsed = Float(progress.shaderTime)
        renderer?.state.rayOpacityOverride = Float(progress.lightOpacity)
        dimmer?.alphaValue = LaunchArrivalTiming.dimming(audioTime: progress.audioTime)
        if progress.revealsWindow, !revealed {
            revealed = true
            dimmer?.close()
            dimmer = nil
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            LaunchArrivalPreview.record("revealed", window: window)
            // The carrier never takes focus. Only keep the browser key when
            // Yab is still active; cancelling elsewhere never activates Yab.
            if NSApp.isActive { window.makeKeyAndOrderFront(nil) }
            carrier?.order(.above, relativeTo: window.windowNumber)
            window.invalidateShadow()
        }
        if revealed { window.alphaValue = originalAlpha * CGFloat(progress.windowOpacity) }
        light?.draw()
        if progress.finished { finishVisuals() }
    }

    private func armWatchdog(after seconds: Double, generation: UUID) {
        watchdog?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.ticket == generation else { return }
                self.cancel()
            }
        }
        watchdog = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func observe(_ window: NSWindow) {
        let center = NotificationCenter.default
        func watch(_ name: Notification.Name, object: AnyObject? = nil, center: NotificationCenter = .default) {
            let observer = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancel(name.rawValue) }
            }
            observers.append((center, observer))
        }
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.willEnterFullScreenNotification] {
            watch(name, object: window)
        }
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            let observer = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    // AppKit may still place its initial window while the
                    // pipelines prepare. Once drawn, moving it ends the light.
                    guard let self, self.carrier != nil else { return }
                    if let window = self.window { LaunchArrivalPreview.record("geometryChanged", window: window) }
                    self.cancel()
                }
            }
            observers.append((center, observer))
        }
        let focus = center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, self.window != nil, let other = note.object as? NSWindow,
                      other !== self.window, other !== self.carrier, other !== self.dimmer,
                      other.isVisible else { return }
                // Restored windows and a window somebody opens during launch
                // retain their focus. Never raise the first window over them.
                self.cancel("key window: " + String(describing: type(of: other)))
            }
        }
        observers.append((center, focus))
        for name in [NSApplication.didHideNotification, NSApplication.didResignActiveNotification,
                     NSApplication.willTerminateNotification] {
            watch(name)
        }
        let display = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSScreen.screens.map(\.frame) != self.screens else { return }
                self.cancel("display geometry changed")
            }
        }
        observers.append((center, display))
        let workspace = NSWorkspace.shared.notificationCenter
        let accessibility = workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { self?.cancel("reduce motion enabled") }
            }
        }
        observers.append((workspace, accessibility))
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated {
                guard event.keyCode == 53 else { return event }
                self?.cancel("escape")
                return nil
            }
        }
    }

    private func finishVisuals() {
        ticket = UUID()
        timer?.invalidate()
        timer = nil
        watchdog?.cancel()
        watchdog = nil
        if let window {
            window.alphaValue = originalAlpha
            window.ignoresMouseEvents = originalMouse
            LaunchArrivalPreview.record("finished", window: window)
        }
        window = nil
        carrier?.orderOut(nil)
        carrier?.contentView = nil
        carrier?.close()
        carrier = nil
        dimmer?.close()
        dimmer = nil
        light?.delegate = nil
        light = nil
        renderer?.onFailure = nil
        renderer?.onPresented = nil
        renderer = nil
        startedAt = nil
        if let escape { NSEvent.removeMonitor(escape); self.escape = nil }
        // Keep the original soundtrack's natural tail after the light leaves.
        if player == nil { removeObservers() }
    }

    private func cancel(_ reason: String = #function) {
        if let window { LaunchArrivalPreview.record("cancelled: " + reason, window: window) }
        player?.stop()
        player = nil
        finishVisuals()
        removeObservers()
    }

    private func removeObservers() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === player else { return }
            self.player = nil
            if self.window == nil { self.removeObservers() }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === player else { return }
            self.cancel("audio decode: " + (error?.localizedDescription ?? "unknown"))
        }
    }
}
