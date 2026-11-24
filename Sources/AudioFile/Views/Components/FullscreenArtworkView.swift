import SwiftUI
import AppKit

// MARK: - Borderless Full-Screen Window & Controller

@MainActor
private final class FullscreenArtworkWindow: NSWindow {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}

@MainActor
public final class FullscreenArtworkWindowController: NSObject, NSWindowDelegate {
    public static let shared = FullscreenArtworkWindowController()

    private var window: FullscreenArtworkWindow?
    private weak var previousKeyWindow: NSWindow?
    private var usesNativeSpace = false
    private var isTransitioningFullscreen = false
    private var pendingDismissAfterEnter = false
    private var isDismissing = false
    private var observers: [NSObjectProtocol] = []

    private override init() {
        super.init()
    }

    public var isPresented: Bool {
        window != nil && !isDismissing
    }

    public func present(vm: PlayerViewModel) {
        if let existing = window, !isDismissing {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        if let old = window {
            finishDismiss(old, restoreFocus: false)
        }

        let parentWindow = NSApp.keyWindow ?? NSApp.mainWindow
        previousKeyWindow = parentWindow

        let targetScreen = parentWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = targetScreen?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1120, height: 740)
        let screenFrame = targetScreen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        usesNativeSpace = NSScreen.screensHaveSeparateSpaces
        isTransitioningFullscreen = false
        pendingDismissAfterEnter = false
        isDismissing = false

        let hostingView = NSHostingView(rootView: FullscreenArtworkView(vm: vm))
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]

        let win: FullscreenArtworkWindow
        if usesNativeSpace {
            let initialFrame: NSRect
            if let parentWindow, parentWindow.screen == targetScreen {
                initialFrame = parentWindow.frame
            } else {
                let width = min(visibleFrame.width * 0.78, 1120)
                let height = min(visibleFrame.height * 0.78, 740)
                initialFrame = NSRect(
                    x: visibleFrame.midX - width / 2,
                    y: visibleFrame.midY - height / 2,
                    width: width,
                    height: height
                )
            }

            win = FullscreenArtworkWindow(
                contentRect: initialFrame,
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.titleVisibility = .hidden
            win.titlebarAppearsTransparent = true
            win.titlebarSeparatorStyle = .none
            win.standardWindowButton(.closeButton)?.isHidden = true
            win.standardWindowButton(.miniaturizeButton)?.isHidden = true
            win.standardWindowButton(.zoomButton)?.isHidden = true
            win.collectionBehavior = [.fullScreenPrimary]
        } else {
            win = FullscreenArtworkWindow(
                contentRect: screenFrame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.level = .normal
            win.collectionBehavior = [.fullScreenAuxiliary]
        }

        win.appearance = NSAppearance(named: .darkAqua)
        win.isReleasedWhenClosed = false
        win.backgroundColor = .black
        win.isOpaque = true
        win.hasShadow = false
        win.ignoresMouseEvents = false
        win.acceptsMouseMovedEvents = true
        win.delegate = self
        win.onEscape = { [weak self] in
            self?.dismiss()
        }
        hostingView.frame = win.contentView?.bounds ?? win.frame
        win.contentView = hostingView

        self.window = win
        installObservers()

        if usesNativeSpace {
            win.makeKeyAndOrderFront(nil)
            isTransitioningFullscreen = true
            Task { @MainActor [weak self, weak win] in
                guard let self, let win, self.window === win, !self.isDismissing else { return }
                win.toggleFullScreen(nil)
            }
        } else {
            win.setFrame(screenFrame, display: true)
            win.alphaValue = 0
            win.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().alphaValue = 1.0
            }
        }
    }

    public func dismiss() {
        guard let win = window else {
            PlayerViewModel.shared.isFullscreenPresented = false
            return
        }

        if usesNativeSpace && isTransitioningFullscreen {
            if !isDismissing {
                pendingDismissAfterEnter = true
            }
            return
        }

        guard !isDismissing else { return }
        isDismissing = true
        PlayerViewModel.shared.isFullscreenPresented = false

        if usesNativeSpace && win.styleMask.contains(.fullScreen) {
            isTransitioningFullscreen = true
            win.toggleFullScreen(nil)
        } else if usesNativeSpace {
            finishDismiss(win, restoreFocus: true)
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                win.animator().alphaValue = 0.0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    self?.finishDismiss(win, restoreFocus: true)
                }
            })
        }
    }

    private func finishDismiss(_ win: FullscreenArtworkWindow, restoreFocus: Bool) {
        guard window === win else { return }
        removeObservers()
        win.delegate = nil
        win.orderOut(nil)
        win.contentView = nil
        win.close()
        window = nil
        isTransitioningFullscreen = false
        pendingDismissAfterEnter = false
        isDismissing = false
        PlayerViewModel.shared.isFullscreenPresented = false

        if restoreFocus {
            previousKeyWindow?.makeKeyAndOrderFront(nil)
        }
        previousKeyWindow = nil
    }

    // MARK: - NSWindowDelegate

    public func window(
        _ window: NSWindow,
        willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions
    ) -> NSApplication.PresentationOptions {
        [.fullScreen, .autoHideMenuBar, .autoHideDock]
    }

    public func windowDidEnterFullScreen(_ notification: Notification) {
        isTransitioningFullscreen = false
        if pendingDismissAfterEnter {
            pendingDismissAfterEnter = false
            dismiss()
        }
    }

    public func windowWillExitFullScreen(_ notification: Notification) {
        PlayerViewModel.shared.isFullscreenPresented = false
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        isTransitioningFullscreen = false
        pendingDismissAfterEnter = false
        if let win = window {
            finishDismiss(win, restoreFocus: true)
        }
    }

    public func windowDidFailToEnterFullScreen(_ window: NSWindow) {
        isTransitioningFullscreen = false
        pendingDismissAfterEnter = false
        if let win = self.window {
            finishDismiss(win, restoreFocus: true)
        }
    }

    public func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? FullscreenArtworkWindow, closed === window else { return }
        removeObservers()
        window = nil
        isTransitioningFullscreen = false
        pendingDismissAfterEnter = false
        isDismissing = false
        previousKeyWindow = nil
        PlayerViewModel.shared.isFullscreenPresented = false
    }

    // MARK: - Screen Parameter Observer

    private func installObservers() {
        removeObservers()
        let nc = NotificationCenter.default

        observers.append(nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let win = self.window, !self.isDismissing, !self.usesNativeSpace else { return }
                if let screenFrame = (win.screen ?? NSScreen.main ?? NSScreen.screens.first)?.frame {
                    win.setFrame(screenFrame, display: true)
                }
            }
        })
    }

    private func removeObservers() {
        let nc = NotificationCenter.default
        for observer in observers {
            nc.removeObserver(observer)
        }
        observers.removeAll()
    }
}

// MARK: - Dominant Color Extractor

private enum ArtworkColorExtractor {
    static func extractAccentColor(from image: NSImage) -> Color {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .accentColor
        }

        let size = 16
        let bytesPerPixel = 4
        let bytesPerRow = size * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: size * bytesPerRow)

        guard let ctx = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return .accentColor
        }

        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var bestR: Double = 0.45
        var bestG: Double = 0.55
        var bestB: Double = 0.85
        var bestScore: Double = 0

        var sumR: Double = 0
        var sumG: Double = 0
        var sumB: Double = 0
        var count: Double = 0

        for i in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let a = Double(pixels[i + 3]) / 255.0
            if a < 0.5 { continue }

            let r = Double(pixels[i]) / 255.0
            let g = Double(pixels[i + 1]) / 255.0
            let b = Double(pixels[i + 2]) / 255.0

            sumR += r
            sumG += g
            sumB += b
            count += 1

            let maxC = max(r, g, b)
            let minC = min(r, g, b)
            let delta = maxC - minC
            let saturation = maxC > 0 ? delta / maxC : 0
            let luminance = 0.2126 * r + 0.7152 * g + 0.0722 * b

            // Prefer vibrant mid-bright colors over clipped blacks or washed-out whites
            if luminance > 0.12 && luminance < 0.90 {
                let score = (saturation * 1.4 + 0.1) * (1.0 - abs(luminance - 0.52))
                if score > bestScore {
                    bestScore = score
                    bestR = r
                    bestG = g
                    bestB = b
                }
            }
        }

        if bestScore > 0.15 {
            return Color(red: bestR, green: bestG, blue: bestB)
        } else if count > 0 {
            return Color(
                red: min(1.0, (sumR / count) * 1.15 + 0.12),
                green: min(1.0, (sumG / count) * 1.15 + 0.12),
                blue: min(1.0, (sumB / count) * 1.15 + 0.12)
            )
        }
        return .accentColor
    }
}

// MARK: - Frame-Rate Independent Motion State

@MainActor
private final class ArtworkMotionState {
    struct Snapshot {
        let elapsed: Double
        let motionPhase: Double
        let vinylAngle: Double
        let bass: Double
        let mid: Double
        let treble: Double
        let mouseX: Double
        let mouseY: Double
    }

    private var lastTimestamp: TimeInterval?
    private var elapsed: Double = 0
    private var motionPhase: Double = 0
    private var vinylAngle: Double = 0
    private var vinylVelocity: Double = 0
    private var smoothedBass: Double = 0
    private var smoothedMid: Double = 0
    private var smoothedTreble: Double = 0
    private var smoothedMouseX: Double = 0
    private var smoothedMouseY: Double = 0
    private var lastVisualizerFrame: VisualizerFrame = VisualizerFrame()

    func nextVisualizerFrame(mode: VisualizerMode, isPlaying: Bool, isStopped: Bool) -> VisualizerFrame {
        if isPlaying {
            lastVisualizerFrame = VisualizerEngine.shared.getFrame(for: mode)
        } else if isStopped {
            lastVisualizerFrame = VisualizerFrame()
        }
        return lastVisualizerFrame
    }

    func step(
        now: TimeInterval,
        isPlaying: Bool,
        mouseNormalized: CGPoint,
        mouseActive: Bool,
        energy: AudioEnergy
    ) -> Snapshot {
        let dt: Double
        if let last = lastTimestamp {
            dt = min(max(now - last, 0), 0.05)
        } else {
            dt = 0
        }
        lastTimestamp = now

        elapsed += dt
        motionPhase += dt * (isPlaying ? 1.0 : 0.35)

        // Smooth vinyl platter spin/coast
        let targetVelocity = isPlaying ? 1.0 : 0.0
        let velocityRate = 1.0 - exp(-dt * (isPlaying ? 3.2 : 2.0))
        vinylVelocity += (targetVelocity - vinylVelocity) * velocityRate
        vinylAngle = (vinylAngle + vinylVelocity * dt * 42.0).truncatingRemainder(dividingBy: 360.0)

        // Smooth audio energy envelope
        let targetBass = isPlaying ? Double(energy.bass) : 0.0
        let targetMid = isPlaying ? Double(energy.mid) : 0.0
        let targetTreble = isPlaying ? Double(energy.treble) : 0.0
        let attackAlpha = 1.0 - exp(-dt * 18.0)
        let decayAlpha = 1.0 - exp(-dt * 7.5)

        smoothedBass += (targetBass - smoothedBass) * (targetBass > smoothedBass ? attackAlpha : decayAlpha)
        smoothedMid += (targetMid - smoothedMid) * (targetMid > smoothedMid ? attackAlpha : decayAlpha)
        smoothedTreble += (targetTreble - smoothedTreble) * (targetTreble > smoothedTreble ? attackAlpha : decayAlpha)

        // Damped mouse parallax
        let targetMX = mouseActive ? Double(mouseNormalized.x) : 0.0
        let targetMY = mouseActive ? Double(mouseNormalized.y) : 0.0
        let mouseAlpha = 1.0 - exp(-dt * 5.5)
        smoothedMouseX += (targetMX - smoothedMouseX) * mouseAlpha
        smoothedMouseY += (targetMY - smoothedMouseY) * mouseAlpha

        return Snapshot(
            elapsed: elapsed,
            motionPhase: motionPhase,
            vinylAngle: vinylAngle,
            bass: smoothedBass,
            mid: smoothedMid,
            treble: smoothedTreble,
            mouseX: smoothedMouseX,
            mouseY: smoothedMouseY
        )
    }
}

// MARK: - View State (ObservableObject to avoid @State macro under Swift 6 CLI)

@MainActor
private final class FullscreenArtworkViewState: ObservableObject {
    @Published var dominantColor: Color = .accentColor
    @Published var isHUDVisible = true

    let motionState = ArtworkMotionState()
    var mouseNormalized: CGPoint = .zero
    var isPointerActive = false
    var isHoveringHUD = false
    private var hudHideTask: Task<Void, Never>?

    func updateHUDHover(_ hovering: Bool) {
        isHoveringHUD = hovering
        if hovering {
            hudHideTask?.cancel()
            if !isHUDVisible {
                isHUDVisible = true
            }
        } else {
            scheduleHUDHide()
        }
    }

    func revealHUD() {
        if !isHUDVisible {
            isHUDVisible = true
        }
        if !isHoveringHUD {
            scheduleHUDHide()
        }
    }

    func scheduleHUDHide() {
        hudHideTask?.cancel()
        hudHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.8))
            guard !Task.isCancelled, let self, !self.isHoveringHUD else { return }
            self.isHUDVisible = false
        }
    }

    func cancelHUDTask() {
        hudHideTask?.cancel()
        hudHideTask = nil
    }
}

// MARK: - Full-Screen Artwork Presentation View

public struct FullscreenArtworkView: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject var audio = AudioEngine.shared

    @StateObject private var loader = ArtworkLoader()
    @StateObject private var viewState = FullscreenArtworkViewState()

    public init(vm: PlayerViewModel) {
        self.vm = vm
    }

    private var imageDimensionsString: String? {
        guard let img = loader.artwork else { return nil }
        if let rep = img.representations.first, rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
            return "\(rep.pixelsWide) × \(rep.pixelsHigh) px"
        } else if img.size.width > 0 && img.size.height > 0 {
            return "\(Int(img.size.width)) × \(Int(img.size.height)) px"
        }
        return nil
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let track = audio.currentTrack
            let stageMode = vm.fullscreenStageMode
            let effect = vm.fullscreenArtworkEffect
            let isPlaying = (audio.state == .playing)
            let isStopped = (audio.state == .stopped)
            let needsAudioEnergy = (stageMode == .artwork) && isPlaying && (effect == .audioAura || effect == .vinylSpin)

            ZStack {
                Color.black.ignoresSafeArea()

                // Layer 1: Living Backdrop + 60/120 FPS Animated Stages (Artwork & Visualizer)
                TimelineView(.animation(minimumInterval: nil, paused: false)) { timeline in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    let energy = needsAudioEnergy ? VisualizerEngine.shared.getAudioEnergy() : .zero
                    let snap = viewState.motionState.step(
                        now: now,
                        isPlaying: isPlaying,
                        mouseNormalized: viewState.mouseNormalized,
                        mouseActive: viewState.isPointerActive,
                        energy: energy
                    )

                    ZStack {
                        // 1. Living Ambient Blurred Backdrop
                        livingBackdrop(image: loader.artwork, snapshot: snap, size: geo.size)

                        // 2. Animated Centerpiece Stage (Artwork or Visualizer)
                        if let track {
                            if stageMode == .artwork {
                                let layout = FullscreenLayoutMetrics(viewport: geo.size)
                                VStack(spacing: layout.artToMetaSpacing) {
                                    Spacer(minLength: layout.topMargin)

                                    artworkStage(
                                        image: loader.artwork,
                                        effect: effect,
                                        snapshot: snap,
                                        layout: layout
                                    )

                                    metadataBlock(track: track, layout: layout, viewportWidth: w)
                                        .id(track.id)
                                        .transition(.opacity.combined(with: .scale(scale: 0.985)))

                                    Spacer(minLength: layout.bottomMargin)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .animation(.easeInOut(duration: 0.45), value: track.id)
                            } else if stageMode == .visualizer {
                                let visFrame = viewState.motionState.nextVisualizerFrame(
                                    mode: vm.visualizerMode,
                                    isPlaying: isPlaying,
                                    isStopped: isStopped
                                )
                                visualizerStage(
                                    track: track,
                                    image: loader.artwork,
                                    frame: visFrame,
                                    viewport: geo.size
                                )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        } else {
                            emptyPlaybackState
                        }
                    }
                }

                // Layer 2: Full-Screen Lyrics (outside TimelineView so scrolling stays silky smooth)
                if let track, stageMode == .lyrics {
                    FullscreenLyricsStageView(
                        vm: vm,
                        lyrics: vm.lyrics,
                        audio: audio,
                        track: track,
                        artwork: loader.artwork,
                        viewport: geo.size
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // 3. Auto-Hiding Liquid Glass HUD
                hudOverlay(track: track, stageMode: stageMode, viewport: geo.size)
                    .opacity(viewState.isHUDVisible ? 1 : 0)
                    .animation(.easeInOut(duration: 0.25), value: viewState.isHUDVisible)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    let nx = w > 0 ? ((location.x / w) - 0.5) * 2.0 : 0
                    let ny = h > 0 ? ((location.y / h) - 0.5) * 2.0 : 0
                    viewState.mouseNormalized = CGPoint(x: min(max(nx, -1), 1), y: min(max(ny, -1), 1))
                    viewState.isPointerActive = true
                    viewState.revealHUD()
                case .ended:
                    viewState.isPointerActive = false
                }
            }
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .task(id: audio.currentTrack?.id) {
            await loader.load(track: audio.currentTrack, maxPixelSize: nil)
            if let img = loader.artwork {
                viewState.dominantColor = ArtworkColorExtractor.extractAccentColor(from: img)
            } else {
                viewState.dominantColor = .accentColor
            }
        }
        .onAppear {
            viewState.revealHUD()
        }
        .onDisappear {
            viewState.cancelHUDTask()
        }
    }

    // MARK: - Living Ambient Backdrop

    @ViewBuilder
    private func livingBackdrop(
        image: NSImage?,
        snapshot snap: ArtworkMotionState.Snapshot,
        size: CGSize
    ) -> some View {
        let maxDim = max(size.width, size.height)
        let driftX1 = sin(snap.elapsed * 0.13) * size.width * 0.07
        let driftY1 = cos(snap.elapsed * 0.10) * size.height * 0.06
        let driftX2 = cos(snap.elapsed * 0.09 + 1.2) * size.width * 0.08
        let driftY2 = sin(snap.elapsed * 0.12 + 0.8) * size.height * 0.06
        let bassBoost = vm.fullscreenArtworkEffect == .audioAura ? snap.bass * 0.14 : snap.bass * 0.05

        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.low)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: maxDim * 1.28, height: maxDim * 1.28)
                    .offset(x: driftX1, y: driftY1)
                    .blur(radius: 105)
                    .saturation(1.25)
                    .opacity(0.38 + bassBoost)

                Image(nsImage: image)
                    .resizable()
                    .interpolation(.low)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: maxDim * 1.15, height: maxDim * 1.15)
                    .rotationEffect(.degrees(180))
                    .offset(x: driftX2, y: driftY2)
                    .blur(radius: 120)
                    .saturation(1.15)
                    .opacity(0.24)
                    .blendMode(.screen)
            } else {
                RadialGradient(
                    colors: [viewState.dominantColor.opacity(0.32), Color.black],
                    center: .center,
                    startRadius: 20,
                    endRadius: maxDim * 0.7
                )
            }

            // Soft vignette for contrast & gallery depth
            RadialGradient(
                colors: [
                    Color.black.opacity(0.14),
                    Color.black.opacity(0.55),
                    Color.black.opacity(0.84)
                ],
                center: .center,
                startRadius: maxDim * 0.12,
                endRadius: maxDim * 0.72
            )
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .ignoresSafeArea()
    }

    // MARK: - Dynamic Display & Aspect-Ratio Sizing

    private struct FullscreenLayoutMetrics {
        let topMargin: CGFloat
        let bottomMargin: CGFloat
        let artToMetaSpacing: CGFloat
        let titleSize: CGFloat
        let artistSize: CGFloat
        let albumSize: CGFloat
        let baseArtSize: CGFloat
        let vinylArtSize: CGFloat

        init(viewport: CGSize) {
            let w = max(viewport.width, 320)
            let h = max(viewport.height, 320)
            let minDim = min(w, h)
            let isPortrait = h > w * 1.05

            self.topMargin = max(32, h * 0.045)
            self.bottomMargin = max(36, h * 0.055)
            self.artToMetaSpacing = min(max(h * 0.032, 22), 42)

            self.titleSize = min(max(minDim * 0.038, 26), 46)
            self.artistSize = min(max(minDim * 0.023, 17), 28)
            self.albumSize = min(max(minDim * 0.017, 13.5), 21)

            let metadataHeight = titleSize * 2.1 + artistSize * 1.4 + albumSize * 1.4 + 18
            let maxHeightForArt = max(240, h - topMargin - bottomMargin - artToMetaSpacing - metadataHeight)
            let maxWidthForArt = isPortrait ? (w * 0.82) : (w * 0.78)

            self.baseArtSize = min(maxWidthForArt, maxHeightForArt)
            self.vinylArtSize = min(isPortrait ? (w * 0.84) : (w * 0.76), maxHeightForArt)
        }
    }

    // MARK: - Realtime Effect Stage

    @ViewBuilder
    private func artworkStage(
        image: NSImage?,
        effect: FullscreenArtworkEffect,
        snapshot snap: ArtworkMotionState.Snapshot,
        layout: FullscreenLayoutMetrics
    ) -> some View {
        switch effect {
        case .audioAura:
            audioAuraStage(image: image, size: layout.baseArtSize, snapshot: snap)
        case .vinylSpin:
            vinylTurntableStage(image: image, size: layout.vinylArtSize, snapshot: snap)
        case .minimal:
            minimalStage(image: image, size: layout.baseArtSize)
        }
    }

    @ViewBuilder
    private func audioAuraStage(
        image: NSImage?,
        size: CGFloat,
        snapshot snap: ArtworkMotionState.Snapshot
    ) -> some View {
        let t = snap.motionPhase
        // Dual-frequency organic Lissajous sway + damped mouse parallax
        let yaw = sin(t * 0.42) * 6.5 + cos(t * 0.19) * 1.4 + snap.mouseX * 4.8
        let pitch = cos(t * 0.33 + 0.7) * 4.4 + sin(t * 0.16) * 1.0 - snap.mouseY * 3.8
        let floatY = sin(t * 0.52) * 6.5
        let scale = 1.0 + snap.bass * 0.036
        let cornerRad: CGFloat = 0

        ZStack {
            // Outer bass-driven diffuse halo
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            viewState.dominantColor.opacity(0.42 + snap.bass * 0.35),
                            viewState.dominantColor.opacity(0.14 + snap.mid * 0.18),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: size * 0.18,
                        endRadius: size * (0.78 + snap.bass * 0.16)
                    )
                )
                .frame(width: size * 1.55, height: size * 1.55)
                .blur(radius: 32)

            // Reactive crisp aura rings driven by mid & treble energy
            Rectangle()
                .stroke(viewState.dominantColor.opacity(0.18 + snap.mid * 0.36), lineWidth: 1.5)
                .frame(width: size * (1.06 + snap.bass * 0.08), height: size * (1.06 + snap.bass * 0.08))
                .blur(radius: 4)
                .rotation3DEffect(.degrees(yaw * 0.7), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
                .rotation3DEffect(.degrees(pitch * 0.7), axis: (x: 1, y: 0, z: 0), perspective: 0.45)

            Rectangle()
                .stroke(Color.white.opacity(0.08 + snap.treble * 0.24), lineWidth: 1.0)
                .frame(width: size * (1.13 + snap.mid * 0.10), height: size * (1.13 + snap.mid * 0.10))
                .blur(radius: 6)

            artworkCard(
                image: image,
                size: size,
                cornerRadius: cornerRad,
                yaw: yaw,
                pitch: pitch,
                sheenStrength: 0.18 + snap.treble * 0.10
            )
            .scaleEffect(scale)
            .rotation3DEffect(.degrees(yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
            .rotation3DEffect(.degrees(pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.45)
            .offset(y: floatY)
            .shadow(
                color: viewState.dominantColor.opacity(0.32 + snap.bass * 0.25),
                radius: 34,
                x: 0,
                y: 12
            )
            .shadow(
                color: Color.black.opacity(0.55),
                radius: 28,
                x: -yaw * 1.2,
                y: 18 + pitch
            )
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func vinylTurntableStage(
        image: NSImage?,
        size: CGFloat,
        snapshot snap: ArtworkMotionState.Snapshot
    ) -> some View {
        let t = snap.motionPhase
        let yaw = sin(t * 0.34) * 5.0 + snap.mouseX * 4.0
        let pitch = cos(t * 0.27 + 0.3) * 3.5 - snap.mouseY * 3.0
        let floatY = sin(t * 0.50) * 5.0

        ZStack {
            // Subtle ambient color glow behind the spinning vinyl disc
            Circle()
                .fill(viewState.dominantColor.opacity(0.22 + snap.bass * 0.14))
                .frame(width: size * 1.12, height: size * 1.12)
                .blur(radius: 60)

            vinylRecordView(
                image: image,
                size: size,
                labelColor: viewState.dominantColor,
                rotationAngle: snap.vinylAngle,
                yaw: yaw
            )
            .rotation3DEffect(.degrees(yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
            .rotation3DEffect(.degrees(pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.45)
            .offset(y: floatY)
            .shadow(
                color: Color.black.opacity(0.68),
                radius: 34,
                x: -yaw * 1.4,
                y: 22 + pitch * 1.1
            )
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder
    private func minimalStage(image: NSImage?, size: CGFloat) -> some View {
        let cornerRad: CGFloat = 0
        artworkSurface(image: image, size: size, cornerRadius: cornerRad)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRad)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.6), radius: 34, x: 0, y: 18)
            .frame(width: size, height: size)
    }

    // MARK: - Artwork Surface Helpers

    @ViewBuilder
    private func artworkCard(
        image: NSImage?,
        size: CGFloat,
        cornerRadius: CGFloat,
        yaw: Double,
        pitch: Double,
        sheenStrength: Double
    ) -> some View {
        let sheenShift = CGFloat(yaw / 14.0)
        let rimStart = UnitPoint(x: 0.15 + yaw * 0.025, y: 0.10 - pitch * 0.025)
        let rimEnd = UnitPoint(x: 0.85 + yaw * 0.025, y: 0.90 - pitch * 0.025)

        artworkSurface(image: image, size: size, cornerRadius: cornerRadius)
            .overlay {
                // Angle-responsive specular gloss sheen
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: max(0.0, 0.22 + sheenShift)),
                        .init(color: .white.opacity(sheenStrength), location: min(max(0.46 + sheenShift, 0.05), 0.95)),
                        .init(color: .clear, location: min(1.0, 0.72 + sheenShift))
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .blendMode(.screen)
                .allowsHitTesting(false)
            }
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.32),
                                Color.white.opacity(0.08),
                                Color.white.opacity(0.18)
                            ],
                            startPoint: rimStart,
                            endPoint: rimEnd
                        ),
                        lineWidth: 1.1
                    )
            )
    }

    @ViewBuilder
    private func artworkSurface(image: NSImage?, size: CGFloat, cornerRadius: CGFloat) -> some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: size, maxHeight: size)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [viewState.dominantColor.opacity(0.45), Color.white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.22, weight: .light))
                        .foregroundColor(.white.opacity(0.65))
                }
                .frame(width: size, height: size)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    private func vinylRecordView(
        image: NSImage?,
        size: CGFloat,
        labelColor: Color,
        rotationAngle: Double,
        yaw: Double
    ) -> some View {
        let labelSize = size * 0.44

        ZStack {
            // Outer black vinyl body with subtle outer bevel
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(white: 0.14),
                            Color(white: 0.06),
                            Color(white: 0.095),
                            Color(white: 0.045),
                            Color(white: 0.07)
                        ],
                        center: .center,
                        startRadius: size * 0.20,
                        endRadius: size * 0.50
                    )
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 1.2)
                )

            // Fine concentric playing grooves
            ForEach([0.97, 0.92, 0.87, 0.82, 0.77, 0.72, 0.67, 0.62, 0.57, 0.52], id: \.self) { ratio in
                Circle()
                    .stroke(Color.white.opacity(ratio == 0.97 ? 0.12 : 0.055), lineWidth: 0.75)
                    .frame(width: size * ratio, height: size * ratio)
            }

            // Dead-wax / run-out ring separating grooves from the center label
            Circle()
                .stroke(Color.white.opacity(0.08), lineWidth: 1.0)
                .frame(width: size * 0.47, height: size * 0.47)

            // Stationary studio light reflections across the spinning grooves
            AngularGradient(
                stops: [
                    .init(color: .white.opacity(0.02), location: 0.00),
                    .init(color: .white.opacity(0.20), location: 0.11),
                    .init(color: .white.opacity(0.02), location: 0.23),
                    .init(color: .white.opacity(0.01), location: 0.50),
                    .init(color: .white.opacity(0.17), location: 0.62),
                    .init(color: .white.opacity(0.02), location: 0.75),
                    .init(color: .white.opacity(0.02), location: 1.00)
                ],
                center: .center,
                angle: .degrees(yaw * 1.4)
            )
            .clipShape(Circle())
            .blendMode(.screen)

            // Rotating center artwork label
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: labelSize, height: labelSize)
                } else {
                    ZStack {
                        RadialGradient(
                            colors: [labelColor.opacity(0.95), labelColor.opacity(0.55)],
                            center: .center,
                            startRadius: 2,
                            endRadius: labelSize * 0.5
                        )
                        Image(systemName: "music.note")
                            .font(.system(size: labelSize * 0.28, weight: .light))
                            .foregroundColor(.white.opacity(0.75))
                    }
                    .frame(width: labelSize, height: labelSize)
                }
            }
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(Color.black.opacity(0.55), lineWidth: 2)
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.24), lineWidth: 0.9)
            )
            .rotationEffect(.degrees(rotationAngle))

            // Inner label press ring & center spindle hole
            Circle()
                .stroke(Color.black.opacity(0.42), lineWidth: 1.2)
                .frame(width: size * 0.12, height: size * 0.12)

            Circle()
                .fill(Color(white: 0.08))
                .frame(width: size * 0.044, height: size * 0.044)
                .overlay(
                    Circle().stroke(Color.white.opacity(0.32), lineWidth: 0.9)
                )
        }
        .frame(width: size, height: size)
    }

    // MARK: - Full-Screen Visualizer Stage

    @ViewBuilder
    private func visualizerStage(
        track: Track,
        image: NSImage?,
        frame: VisualizerFrame,
        viewport: CGSize
    ) -> some View {
        let w = max(viewport.width, 320)
        let h = max(viewport.height, 320)
        let isPortrait = h > w * 1.05
        let horizontalPad = max(36, w * 0.055)
        let topPad = max(68, h * 0.075)
        let bottomPad = max(36, h * 0.055)
        let stageWidth = max(260, w - horizontalPad * 2)
        let stageHeight = max(220, h - topPad - bottomPad - 96)

        VStack(spacing: max(18, h * 0.025)) {
            compactTrackBanner(track: track, image: image, maxWidth: min(w * 0.84, 860))
                .padding(.top, topPad)
                .id(track.id)

            Group {
                switch vm.visualizerMode {
                case .bars:
                    SpectrumBarView(bands: frame.bands, peaks: frame.peaks)
                        .frame(width: stageWidth, height: stageHeight)
                case .vuMeter:
                    let vuWidth = isPortrait
                        ? min(stageWidth, stageHeight * 0.72)
                        : min(stageWidth, stageHeight * 2.55)
                    let vuHeight = isPortrait
                        ? min(stageHeight, vuWidth * 1.38)
                        : min(stageHeight, vuWidth * 0.44)
                    DualVUMeterView(
                        left: frame.vuLeft,
                        right: frame.vuRight,
                        leftPeak: frame.vuLeftPeak,
                        rightPeak: frame.vuRightPeak,
                        stacked: isPortrait
                    )
                    .frame(width: vuWidth, height: vuHeight)
                case .circular:
                    let dialSize = min(stageWidth, stageHeight * 0.96)
                    CircularSpectrumView(bands: frame.bands, peaks: frame.peaks)
                        .frame(width: dialSize, height: dialSize)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    vm.cycleVisualizerMode()
                }
                viewState.revealHUD()
            }
            .help("Click to cycle visualizer mode (E)")

            Spacer(minLength: bottomPad)
        }
        .padding(.horizontal, horizontalPad)
    }

    @ViewBuilder
    private func compactTrackBanner(track: Track, image: NSImage?, maxWidth: CGFloat) -> some View {
        let albumLine = track.displayAlbum

        HStack(spacing: 14) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    ZStack {
                        Color.white.opacity(0.08)
                        Image(systemName: "music.note")
                            .font(.system(size: 16, weight: .light))
                            .foregroundColor(.white.opacity(0.65))
                    }
                }
            }
            .frame(width: 46, height: 46)
            .shadow(color: Color.black.opacity(0.45), radius: 8, x: 0, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.displayTitle)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Text("\(track.displayArtist)  ·  \(albumLine)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.68))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: maxWidth)
        .shadow(color: Color.black.opacity(0.45), radius: 8, x: 0, y: 2)
    }

    // MARK: - Tasteful Always-Visible Metadata

    @ViewBuilder
    private func metadataBlock(track: Track, layout: FullscreenLayoutMetrics, viewportWidth: CGFloat) -> some View {
        let albumLine = track.displayAlbum

        VStack(spacing: 6) {
            Text(track.displayTitle)
                .font(.system(size: layout.titleSize, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .shadow(color: Color.black.opacity(0.55), radius: 10, x: 0, y: 3)

            Text(track.displayArtist)
                .font(.system(size: layout.artistSize, weight: .semibold))
                .foregroundColor(.white.opacity(0.80))
                .lineLimit(1)
                .shadow(color: Color.black.opacity(0.45), radius: 8, x: 0, y: 2)

            Text(albumLine)
                .font(.system(size: layout.albumSize, weight: .regular))
                .foregroundColor(.white.opacity(0.56))
                .lineLimit(1)
                .shadow(color: Color.black.opacity(0.45), radius: 6, x: 0, y: 1)
        }
        .padding(.horizontal, 48)
        .frame(maxWidth: min(viewportWidth * 0.84, 1080))
    }

    private var emptyPlaybackState: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.note")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(.white.opacity(0.55))
            Text("Nothing Playing")
                .font(.title2.weight(.semibold))
                .foregroundColor(.white.opacity(0.85))
            Text("Press Esc to return to AudioFile")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
        }
    }

    // MARK: - Auto-Hiding Liquid Glass HUD

    @ViewBuilder
    private func hudOverlay(track: Track?, stageMode: FullscreenStageMode, viewport: CGSize) -> some View {
        VStack {
            // Top HUD Bar
            HStack(alignment: .center, spacing: 12) {
                if let track {
                    GlassEffectContainer(spacing: 8) {
                        HStack(spacing: 8) {
                            HStack(spacing: 8) {
                                FormatBadgeView(format: track.format, isLossless: track.isLossless)

                                if !track.qualityDescription.isEmpty {
                                    Text(track.qualityDescription)
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.75))
                                }

                                if stageMode == .artwork, let dims = imageDimensionsString {
                                    Text("· \(dims)")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.58))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .glassEffect(.regular, in: .capsule)

                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([track.path])
                            } label: {
                                Image(systemName: "folder")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.88))
                                    .frame(width: 30, height: 30)
                                    .contentShape(.circle)
                                    .glassEffect(.regular.interactive(), in: .circle)
                            }
                            .buttonStyle(.plain)
                            .help("Show in Finder")
                        }
                    }
                }

                Spacer()

                // Center Stage Switcher Pills (each isolated so active accent tint never bleeds into neighbors)
                HStack(spacing: 8) {
                    ForEach(FullscreenStageMode.allCases) { mode in
                        let isSelected = (stageMode == mode)
                        Button {
                            withAnimation(.easeInOut(duration: 0.22)) {
                                vm.fullscreenStageMode = mode
                            }
                            viewState.revealHUD()
                        } label: {
                            Label(mode.rawValue, systemImage: mode.systemImage)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(isSelected ? Color.white : Color.white.opacity(0.78))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .contentShape(.capsule)
                                .glassEffect(
                                    isSelected
                                        ? .regular.tint(Color.accentColor).interactive()
                                        : .regular.interactive(),
                                    in: .capsule
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Switch to \(mode.rawValue)")
                    }
                }

                Spacer()

                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        if stageMode == .artwork {
                            Menu {
                                ForEach(FullscreenArtworkEffect.allCases) { item in
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.3)) {
                                            vm.fullscreenArtworkEffect = item
                                        }
                                        viewState.revealHUD()
                                    } label: {
                                        HStack {
                                            Label(item.rawValue, systemImage: item.systemImage)
                                            if vm.fullscreenArtworkEffect == item {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: vm.fullscreenArtworkEffect.systemImage)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                    Text(vm.fullscreenArtworkEffect.rawValue)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.92))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .contentShape(.capsule)
                                .glassEffect(.regular.interactive(), in: .capsule)
                            }
                            .buttonStyle(.plain)
                            .help("Artwork Effect (Press E to cycle)")
                        } else if stageMode == .visualizer {
                            Menu {
                                ForEach(VisualizerMode.allCases) { mode in
                                    Button {
                                        withAnimation(.easeInOut(duration: 0.2)) {
                                            vm.setVisualizerMode(mode)
                                        }
                                        viewState.revealHUD()
                                    } label: {
                                        HStack {
                                            Label(mode.rawValue, systemImage: mode.systemImage)
                                            if vm.visualizerMode == mode {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                    }
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: vm.visualizerMode.systemImage)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                    Text(vm.visualizerMode.rawValue)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.92))
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.55))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .contentShape(.capsule)
                                .glassEffect(.regular.interactive(), in: .capsule)
                            }
                            .buttonStyle(.plain)
                            .help("Visualizer Mode (Press E to cycle)")
                        } else {
                            LyricsCardView.scaleSlider(scale: $vm.lyricsScale)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .glassEffect(.regular, in: .capsule)
                        }

                        Button {
                            vm.dismissFullscreen()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white.opacity(0.92))
                                .frame(width: 32, height: 32)
                                .contentShape(.circle)
                                .glassEffect(.regular.interactive(), in: .circle)
                        }
                        .buttonStyle(.plain)
                        .help("Exit Full Screen (Esc)")
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .onHover { hovering in
                viewState.updateHUDHover(hovering)
            }

            Spacer()

            // Bottom Floating Transport & Scrub Bar
            if let track {
                VStack(spacing: 10) {
                    FullscreenScrubberView(audio: audio)
                        .frame(width: min(viewport.width * 0.46, 460))

                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            Button {
                                vm.previousTrack()
                                viewState.revealHUD()
                            } label: {
                                Image(systemName: "backward.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white)
                                    .frame(width: 34, height: 34)
                                    .contentShape(.circle)
                                    .glassEffect(.regular.interactive(), in: .circle)
                            }
                            .buttonStyle(.plain)
                            .help("Previous Track (←)")

                            Button {
                                audio.togglePlayPause()
                                viewState.revealHUD()
                            } label: {
                                Image(systemName: audio.state == .playing ? "pause.fill" : "play.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .offset(x: audio.state == .playing ? 0 : 1)
                                    .frame(width: 42, height: 42)
                                    .contentShape(.circle)
                                    .glassEffect(.regular.tint(Color.accentColor).interactive(), in: .circle)
                            }
                            .buttonStyle(.plain)
                            .help("Play / Pause (Space)")

                            Button {
                                vm.nextTrack()
                                viewState.revealHUD()
                            } label: {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white)
                                    .frame(width: 34, height: 34)
                                    .contentShape(.circle)
                                    .glassEffect(.regular.interactive(), in: .circle)
                            }
                            .buttonStyle(.plain)
                            .help("Next Track (→)")

                            Button {
                                vm.toggleFavorite(track: track)
                                viewState.revealHUD()
                            } label: {
                                Image(systemName: vm.isCurrentTrackFavorite ? "star.fill" : "star")
                                    .font(.system(size: 13))
                                    .foregroundStyle(vm.isCurrentTrackFavorite ? Color.accentColor : Color.white.opacity(0.88))
                                    .frame(width: 34, height: 34)
                                    .contentShape(.circle)
                                    .glassEffect(
                                        vm.isCurrentTrackFavorite
                                            ? .regular.tint(Color.accentColor.opacity(0.28)).interactive()
                                            : .regular.interactive(),
                                        in: .circle
                                    )
                            }
                            .buttonStyle(.plain)
                            .help(vm.isCurrentTrackFavorite ? "Remove from Favorites (F)" : "Add to Favorites (F)")
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .padding(.bottom, 26)
                .onHover { hovering in
                    viewState.updateHUDHover(hovering)
                }
            }
        }
    }
}

// MARK: - Slim Interactive Scrub Bar

private struct FullscreenScrubberView: View {
    @ObservedObject var audio: AudioEngine

    var body: some View {
        let duration = max(audio.duration, 0)
        let current = min(max(audio.currentTime, 0), duration)
        let progress = duration > 0 ? current / duration : 0

        HStack(spacing: 10) {
            Text(formatDuration(current))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.68))
                .frame(width: 40, alignment: .trailing)

            GeometryReader { geo in
                let barWidth = max(geo.size.width, 1)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.18))
                        .frame(height: 4)

                    Capsule()
                        .fill(Color.white.opacity(0.88))
                        .frame(width: barWidth * CGFloat(progress), height: 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard duration > 0 else { return }
                            let ratio = min(max(value.location.x / barWidth, 0), 1)
                            audio.seek(to: TimeInterval(ratio) * duration)
                        }
                )
            }
            .frame(height: 18)
            .help("Click or drag to seek")

            Text("-" + formatDuration(max(0, duration - current)))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.68))
                .frame(width: 44, alignment: .leading)
        }
    }

    private func formatDuration(_ time: TimeInterval) -> String {
        let total = Int(max(0, time))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Full-Screen Synchronized Lyrics Stage (Isolated from 60/120 FPS TimelineView)

private struct FullscreenLyricsStageView: View {
    @ObservedObject var vm: PlayerViewModel
    @ObservedObject var lyrics: LyricsManager
    @ObservedObject var audio: AudioEngine
    let track: Track
    let artwork: NSImage?
    let viewport: CGSize

    var body: some View {
        let w = max(viewport.width, 320)
        let h = max(viewport.height, 320)
        let minDim = min(w, h)
        let baseScale = CGFloat(min(max(vm.lyricsScale, 0.85), 2.8))
        let viewportBoost = min(max(minDim / 680.0, 1.0), 1.65)
        let s = baseScale * viewportBoost
        let horizontalPad = max(36, w * 0.08)
        let topPad = max(68, h * 0.075)
        let bottomPad = max(40, h * 0.05)

        VStack(spacing: max(18, h * 0.025)) {
            // Compact always-visible track banner clear of the top HUD
            HStack(spacing: 14) {
                Group {
                    if let artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                    } else {
                        ZStack {
                            Color.white.opacity(0.08)
                            Image(systemName: "music.note")
                                .font(.system(size: 16, weight: .light))
                                .foregroundColor(.white.opacity(0.65))
                        }
                    }
                }
                .frame(width: 46, height: 46)
                .shadow(color: Color.black.opacity(0.45), radius: 8, x: 0, y: 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.displayTitle)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    let albumLine = track.displayAlbum
                    Text("\(track.displayArtist)  ·  \(albumLine)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white.opacity(0.68))
                        .lineLimit(1)
                }
            }
            .padding(.top, topPad)
            .shadow(color: Color.black.opacity(0.45), radius: 8, x: 0, y: 2)
            .id(track.id)

            // Main Synchronized Lyrics Canvas
            ZStack {
                switch lyrics.status {
                case .idle:
                    Text("Ready")
                        .font(.system(size: 18 * s, weight: .medium))
                        .foregroundColor(.white.opacity(0.6))

                case .loading:
                    VStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Fetching lyrics from LRCLIB...")
                            .font(.system(size: 16 * s, weight: .medium))
                            .foregroundColor(.accentColor)
                    }

                case .instrumental:
                    VStack(spacing: 12) {
                        Image(systemName: "music.quarternote.3")
                            .font(.system(size: 40 * s))
                            .foregroundColor(.accentColor)
                        Text("Instrumental Track")
                            .font(.system(size: 20 * s, weight: .bold))
                            .foregroundColor(.white)
                        Text("No vocal lyrics present for this recording")
                            .font(.system(size: 14 * s))
                            .foregroundColor(.white.opacity(0.6))
                    }

                case .notFound:
                    VStack(spacing: 12) {
                        Image(systemName: "quote.bubble")
                            .font(.system(size: 36 * s))
                            .foregroundColor(.white.opacity(0.55))
                        Text("No Synchronized Lyrics Found")
                            .font(.system(size: 18 * s, weight: .semibold))
                            .foregroundColor(.white.opacity(0.75))
                    }

                case .found(let synced):
                    let lines = synced.lines
                    let currentTimestamp = lyrics.currentWindow.curr?.timestamp
                    let activeIndex = lines.firstIndex(where: { $0.timestamp == currentTimestamp }) ?? 0

                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(spacing: 16.0 * s) {
                                Spacer().frame(height: max(120, h * 0.28))

                                ForEach(Array(lines.enumerated()), id: \.element.timestamp) { index, line in
                                    let isActive = (line.timestamp == currentTimestamp)
                                    let distance = abs(index - activeIndex)

                                    FullscreenLyricRowView(
                                        line: line,
                                        isActive: isActive,
                                        distance: distance,
                                        scale: s
                                    ) {
                                        audio.seek(to: line.timestamp)
                                    }
                                    .id(line.timestamp)
                                }

                                Spacer().frame(height: max(120, h * 0.28))
                            }
                            .frame(maxWidth: min(w - horizontalPad * 2, 1080))
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, horizontalPad)
                        }
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0.0),
                                    .init(color: .black, location: 0.10),
                                    .init(color: .black, location: 0.90),
                                    .init(color: .clear, location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .onChange(of: currentTimestamp) { _, newTs in
                            if let newTs {
                                withAnimation(.easeInOut(duration: 0.35)) {
                                    proxy.scrollTo(newTs, anchor: .center)
                                }
                            }
                        }
                        .onAppear {
                            if let curr = currentTimestamp {
                                proxy.scrollTo(curr, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, bottomPad)
        }
    }
}

private struct FullscreenLyricRowView: View {
    let line: LRCLine
    let isActive: Bool
    let distance: Int
    let scale: CGFloat
    let onSeek: () -> Void

    var body: some View {
        Button(action: onSeek) {
            HStack(spacing: 10) {
                if isActive {
                    Image(systemName: "music.note")
                        .font(.system(size: 16 * scale, weight: .bold))
                        .foregroundColor(.accentColor)
                }

                Text(line.isInstrumental ? "♪   Instrumental Break   ♪" : line.text)
                    .font(.system(
                        size: fontSize,
                        weight: isActive ? .bold : (distance <= 1 ? .semibold : .medium)
                    ))
                    .foregroundColor(textColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.75)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, isActive ? 12 * min(scale, 1.5) : 5 * min(scale, 1.5))
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.accentColor.opacity(0.20))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.white.opacity(0.14), lineWidth: 1)
                        )
                }
            }
            .shadow(color: Color.black.opacity(isActive ? 0.55 : 0.35), radius: isActive ? 12 : 6, x: 0, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help("Click to jump playback to \(line.formattedTimestamp)")
    }

    private var fontSize: CGFloat {
        if isActive {
            return 22.0 * scale
        } else if distance <= 1 {
            return 17.5 * scale
        } else if distance <= 3 {
            return 15.0 * scale
        } else {
            return 13.5 * scale
        }
    }

    private var textColor: Color {
        if line.isInstrumental {
            return Color.accentColor.opacity(isActive ? 1.0 : 0.55)
        }
        if isActive {
            return .white
        }
        if distance <= 1 {
            return Color.white.opacity(0.72)
        } else if distance <= 3 {
            return Color.white.opacity(0.42)
        } else {
            return Color.white.opacity(0.22)
        }
    }
}
