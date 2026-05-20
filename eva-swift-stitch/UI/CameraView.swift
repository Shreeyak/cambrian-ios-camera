import CameraKit
import MetalKit
import SwiftUI

/// Public SwiftUI view that renders the camera preview, controls, and overlays.
///
/// Composes the parent `ViewModel` (engine lifecycle + session state) with six
/// `@Observable @MainActor` child VMs (display, recording, hardware, processing,
/// calibration, errors). Stage 11 surface per `domain-revised/09-ui-behaviors.md`:
/// 5-button bottom bar, expanded bar (ISO/Shutter/Focus/Zoom), color-calibration
/// sidebar with WB/BB Calibrate, recording indicator with `mm:ss` timer,
/// capture-success toast, non-fatal error toast (both top, auto-dismiss),
/// blocking fatal-error dialog,
/// state-driven enable/disable, scanning overlay bound to `SessionState`,
/// landscape-right orientation lock.
public struct CameraView: View {

    @State private var viewModel = ViewModel()
    @State private var sidebarVisible: Bool = false
    @State private var showExpandedBar: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    #if DEBUG
    /// Long-press toggles the D-11 frame-delivery-stats panel in `debugSurface`.
    @State private var showDeliveryStats: Bool = false
    #endif

    public init() {}

    public var body: some View {
        let enablement = viewModel.controlEnablement
        return ZStack {
            previewArea
            scanningOverlay(enablement: enablement)
            calibrationReticleLayer()
            #if DEBUG
            debugSurface
            #endif
        }
        // Sidebar lives as an overlay (not a ZStack child) so its
        // appearance can't nudge the body's content-layout pass — that
        // was visibly shifting the bottom safeAreaInset by a few pixels
        // when Calibrate toggled `sidebarVisible`.
        .overlay(alignment: .trailing) {
            calibrationSidebarLayer(enablement: enablement)
        }
        // Top-edge toast stack — error toast and capture-success toast are
        // structurally separate (own state, own styling) but share this anchor
        // so they stack instead of overlapping when both are visible.
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                if let toast = viewModel.errors.currentToast {
                    errorToast(toast)
                }
                if let output = viewModel.captureConfirmation {
                    captureToast(output)
                }
            }
            .padding(.top, 20)
        }
        .alert(
            "Camera Error",
            isPresented: Binding(
                get: { viewModel.errors.fatalDialog != nil },
                set: { if !$0 { viewModel.errors.dismissFatal() } }
            ),
            presenting: viewModel.errors.fatalDialog
        ) { _ in
            Button("Retry") { Task { await viewModel.retryFromFatal() } }
            Button("Dismiss", role: .cancel) { viewModel.errors.dismissFatal() }
        } message: { err in
            Text("\(err.code.rawValue)\n\n\(err.message)")
        }
        // Bottom-edge stack — two independent safeAreaInsets, applied
        // innermost-first (top-to-bottom on screen): expandedBar (conditional)
        // → bottomBar (always). Splitting the expanded bar into its own inset
        // stops it from pushing the bottomBar off-screen when the calibration
        // sidebar is also open (CLAUDE.md §8 — bottom-bar idiom:
        // independently-anchored insets).
        .safeAreaInset(edge: .bottom, spacing: 8) {
            if showExpandedBar {
                ExpandedSliderBar(viewModel: viewModel, enablement: enablement)
                    .padding(.horizontal, 12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar(enablement: enablement)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .animation(.easeInOut(duration: 0.3), value: viewModel.captureConfirmation != nil)
        .animation(.easeInOut(duration: 0.3), value: viewModel.errors.currentToast != nil)
        .animation(.easeInOut(duration: 0.2), value: showExpandedBar)
        .animation(.easeInOut(duration: 0.2), value: sidebarVisible)
        .task {
            await viewModel.start()
        }
        .task(id: scenePhase) {
            await viewModel.handleScenePhase(scenePhase)
        }
    }

    // MARK: - Preview area (split natural / processed)

    private var previewArea: some View {
        HStack(spacing: 0) {
            MTKViewRepresentable(
                textureAccessor: { viewModel.display.naturalTex },
                label: "natural"
            )
            MTKViewRepresentable(
                textureAccessor: { viewModel.display.processedTex },
                label: "processed"
            )
        }
        .background(Color.black)
        .ignoresSafeArea()
    }

    // MARK: - Scanning overlay (J4: bound to SessionState, not focusDistance)

    @ViewBuilder
    private func scanningOverlay(enablement: ControlEnablement) -> some View {
        if enablement.showScanningAnimation {
            VStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(1.4)
                Text(viewModel.sessionState == .recovering ? "Recovering camera…" : "Opening camera…")
                    .font(.caption)
                    .foregroundStyle(.white)
            }
            .padding(24)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 14))
        }
    }

    // MARK: - Bottom bar (5 buttons; expanded bar lives in its own safeAreaInset)

    private func bottomBar(enablement: ControlEnablement) -> some View {
        HStack(spacing: 18) {
            barButton(
                label: "Settings",
                systemImage: "slider.horizontal.3",
                enabled: enablement.isSettingsEnabled
            ) { showExpandedBar.toggle() }
            barButton(
                label: "Calibrate",
                systemImage: "paintpalette",
                enabled: enablement.isCalibrateEnabled
            ) { sidebarVisible.toggle() }
            captureButton(enabled: enablement.isCaptureEnabled)
            recordButton(
                isRecording: isRecordingActive,
                startEnabled: enablement.isRecordEnabled,
                stopEnabled: enablement.isStopEnabled
            )
            resolutionButton(enabled: enablement.isResolutionEnabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    @ViewBuilder
    private func barButton(
        label: String, systemImage: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage).font(.title3)
                Text(label).font(.caption2)
            }
            .frame(minWidth: 60)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.4)
        .accessibilityLabel(label)
    }

    @ViewBuilder
    private func captureButton(enabled: Bool) -> some View {
        Button {
            viewModel.captureImage()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 3)
                    .frame(width: 56, height: 56)
                Circle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 46, height: 46)
                Image(systemName: "camera.shutter.button")
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(.white)
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.4)
        .accessibilityLabel("Capture")
        .accessibilityHint("Takes a photo")
    }

    @ViewBuilder
    private func recordButton(isRecording: Bool, startEnabled: Bool, stopEnabled: Bool) -> some View {
        Button {
            viewModel.recording.toggleRecording()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isRecording ? Color.red : Color.white)
                    .frame(width: 18, height: 18)
                if isRecording {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(elapsedMMSS)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.white)
                    }
                } else {
                    Text("REC").font(.caption.bold()).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.6), in: Capsule())
        }
        .disabled(isRecording ? !stopEnabled : !startEnabled)
        .opacity((isRecording ? stopEnabled : startEnabled) ? 1.0 : 0.4)
        .accessibilityLabel(isRecording ? "Stop recording" : "Start recording")
    }

    @ViewBuilder
    private func resolutionButton(enabled: Bool) -> some View {
        ResolutionPickerButton(
            supportedSizes: viewModel.supportedSizesCache,
            active: viewModel.capabilities?.activeCaptureResolution,
            enabled: enabled,
            onPick: { viewModel.setResolution($0) }
        )
        .equatable()
    }

    private var isRecordingActive: Bool {
        if case .recording = viewModel.recording.recordingState { return true }
        return false
    }

    private var elapsedMMSS: String {
        let s = viewModel.recording.recordingElapsedSeconds
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    // (Expanded bar lives in `ExpandedSliderBar` at the bottom of this file —
    // extracted so its reads of `viewModel.lastFrameResult` /
    // `hardware.currentSettings` don't invalidate `CameraView.body` on every
    // slider-readback tick.)

    // MARK: - Calibration reticle (Bug 8 — sample-point indicator)

    /// Reticle pinned to the right (processed) preview lane's center while
    /// the calibration sidebar is open.
    ///
    /// Indicates the sample area for **both**
    /// WB Calibrate (samples naturalTex) and BB Calibrate (samples a scratch
    /// render of current BCSG with BB zeroed).
    ///
    /// The actual sample patch is `MetalPipeline.scaledCenterPatchSize` square
    /// — 96 px at the default 4160×3120 capture, scaling proportionally on
    /// smaller lanes with a 16-px floor. Patch fraction ≈ 96/3120 ≈ 3% of
    /// the shorter dimension at default; ratio-preserving on smaller lanes
    /// because both numerator and denominator scale together. The 80×80pt
    /// reticle is an approximate visual match — not pixel-perfect, but
    /// gives the user a clear "sample is here" hint.
    ///
    /// After the Bug-6/9 fix (`sessionPreset = .inputPriority`) the texture
    /// fills the lane proportionally, so center-of-lane ≈ center-of-texture.
    @ViewBuilder
    private func calibrationReticleLayer() -> some View {
        if sidebarVisible {
            HStack(spacing: 0) {
                Color.clear
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.yellow, lineWidth: 1.5)
                        .frame(width: 80, height: 80)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }

    // MARK: - Calibration sidebar

    @ViewBuilder
    private func calibrationSidebarLayer(enablement: ControlEnablement) -> some View {
        if sidebarVisible {
            calibrationSidebar(enablement: enablement)
                .frame(width: 300)
                .padding(.trailing, 12)
                .padding(.vertical, 12)
                .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    /// Calibrate-WB button with three states driven by `wbCalibrationStatus`:
    /// idle = "Calibrate", calibrating = small spinner + "Calibrating…",
    /// completed = checkmark + "Calibrated" (auto-reverts after
    /// `wbCompletedDisplayMs`).
    @ViewBuilder
    private var wbCalibrateButton: some View {
        let status = viewModel.calibration.wbCalibrationStatus
        switch status {
        case .idle:
            Button("Calibrate") { viewModel.calibration.calibrateWB() }
                .buttonStyle(.borderedProminent)
        case .calibrating:
            Button {
            } label: {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text("Calibrating…")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(true)
        case .completed:
            Button {
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                    Text("Calibrated")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(true)
        }
    }

    private func calibrationSidebar(enablement: ControlEnablement) -> some View {
        let processing = viewModel.processing.currentProcessing
        let wbMode = viewModel.calibration.wbMode
        // Lock active when the WB is in locked mode OR manual mode (Calibrate
        // writes `.manual` and the user perceives that as "locked"). Auto
        // active only when AVF is in continuous-AWB mode. Mutually exclusive
        // by construction of the wbMode enum.
        let lockActive = (wbMode == .locked || wbMode == .manual)
        let autoActive = (wbMode == .auto)
        return VStack(alignment: .leading, spacing: 12) {
            Text("Color Calibration").foregroundStyle(.white).font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text("White Balance").foregroundStyle(.white.opacity(0.7)).font(.caption)
                HStack(spacing: 8) {
                    wbCalibrateButton
                    if lockActive {
                        Button("Lock") { viewModel.calibration.lockCurrentWB() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Lock") { viewModel.calibration.lockCurrentWB() }
                            .buttonStyle(.bordered)
                    }
                    if autoActive {
                        Button("Auto") { viewModel.calibration.resetToAutoWB() }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Auto") { viewModel.calibration.resetToAutoWB() }
                            .buttonStyle(.bordered)
                    }
                }
            }

            // Black balance row — two actions.
            VStack(alignment: .leading, spacing: 6) {
                Text("Black Balance").foregroundStyle(.white.opacity(0.7)).font(.caption)
                HStack(spacing: 8) {
                    Button("Calibrate") { viewModel.calibration.calibrateBB() }
                        .buttonStyle(.borderedProminent)
                    Button("Reset") { viewModel.calibration.resetBlackBalance() }
                        .buttonStyle(.bordered)
                }
            }

            Divider().background(.white.opacity(0.5))

            sliderRow(
                label: "Brightness",
                current: processing.brightness,
                range: -1.0...1.0,
                push: viewModel.processing.pushBrightness
            )
            sliderRow(
                label: "Contrast",
                current: processing.contrast,
                range: 0.0...2.0,
                push: viewModel.processing.pushContrast
            )
            sliderRow(
                label: "Saturation",
                current: processing.saturation,
                range: -1.0...1.0,
                push: viewModel.processing.pushSaturation
            )
            sliderRow(
                label: "Gamma",
                current: processing.gamma,
                range: 0.1...4.0,
                push: viewModel.processing.pushGamma
            )
            Divider().background(.white.opacity(0.5))
            sliderRow(
                label: "Black R", current: processing.blackR, range: 0.0...0.5,
                push: viewModel.processing.pushBlackR)
            sliderRow(
                label: "Black G", current: processing.blackG, range: 0.0...0.5,
                push: viewModel.processing.pushBlackG)
            sliderRow(
                label: "Black B", current: processing.blackB, range: 0.0...0.5,
                push: viewModel.processing.pushBlackB)
            Spacer()
            Button("Reset All Sliders") {
                Task { await viewModel.processing.resetProcessing() }
            }
            .foregroundStyle(.white)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(.gray.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .disabled(!enablement.isCalibrateEnabled)
        .opacity(enablement.isCalibrateEnabled ? 1.0 : 0.4)
    }

    private func sliderRow(
        label: String,
        current: Double,
        range: ClosedRange<Double>,
        push: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).foregroundStyle(.white).font(.caption)
                Spacer()
                Text(String(format: "%.2f", current))
                    .foregroundStyle(.white).font(.caption.monospacedDigit())
            }
            SliderRebinding(initial: current, range: range, onChange: push)
        }
    }

    // MARK: - Capture-success toast (top, auto-dismiss)

    /// Success-only capture confirmation — a top toast.
    ///
    /// Structurally separate from `errorToast`: its own view-model state
    /// (`captureConfirmation`) and its own green-checkmark styling. Capture
    /// *failures* go through `viewModel.errors` (the error toast) instead.
    private func captureToast(_ output: StillCaptureOutput) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("Image saved: \(URL(fileURLWithPath: output.filePath).lastPathComponent)")
                .font(.caption)
                .lineLimit(1)
            Spacer()
        }
        .padding(10)
        .foregroundStyle(.white)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 400)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - Error toast (top, auto-dismiss after ≥3s)

    @ViewBuilder
    private func errorToast(_ err: CameraError) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(err.code.rawValue).font(.caption.bold())
                Text(err.message).font(.caption2).lineLimit(2)
            }
            Spacer()
        }
        .padding(10)
        .foregroundStyle(.white)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: 400)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    // MARK: - DEBUG surface (overlays + tracker thumbnail)

    #if DEBUG
    @ViewBuilder
    private var debugSurface: some View {
        // Long-press anywhere over the preview toggles the D-11 delivery-stats
        // panel. Sits below the interactive debug controls (added later in this
        // ViewBuilder) so the tracker toggle stays tappable.
        Color.clear
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 0.6) {
                showDeliveryStats.toggle()
            }
        // Frame number overlay (top-left).
        if let overlay = viewModel.display.debugOverlay {
            VStack {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("#\(overlay.frameNumber)  t=\(overlay.captureTimeMs)ms")
                        if let edges = overlay.edgeCount {
                            Text("edges=\(edges)")
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.yellow)
                    .padding(6)
                    .background(.black.opacity(0.6))
                    .padding([.top, .leading], 8)
                    Spacer()
                }
                Spacer()
            }
        }
        // Tracker thumbnail (bottom-left) when subscribed.
        if viewModel.display.debugTrackerSubscribed {
            VStack {
                Spacer()
                HStack {
                    MTKViewRepresentable(
                        textureAccessor: { viewModel.display.trackerTex.latest },
                        label: "tracker"
                    )
                    .frame(width: 160, height: 120)
                    .border(.yellow, width: 1)
                    .padding([.bottom, .leading], 80)
                    Spacer()
                }
            }
        }
        // Show/hide tracker toggle (top-right).
        VStack {
            HStack {
                Spacer()
                Button(viewModel.display.debugTrackerSubscribed ? "Hide Tracker" : "Show Tracker") {
                    Task { await viewModel.display.toggleDebugTrackerSubscription() }
                }
                .padding(8)
                .background(.black.opacity(0.6), in: Capsule())
                .foregroundStyle(.yellow)
                .padding(.top, 12)
                .padding(.trailing, 12)
            }
            Spacer()
        }
        // D-11 frame-delivery-stats panel (bottom-right), long-press toggled.
        if showDeliveryStats, let stats = viewModel.frameDeliveryStats {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    deliveryStatsPanel(stats)
                }
            }
        }
    }

    /// Live per-lane delivery counters from both the Swift facade
    /// (`droppedByLane`) and the C++ pool (`cppOverwriteByLane`), per-window
    /// deltas (D-11).
    private func deliveryStatsPanel(_ stats: FrameDeliveryStats) -> some View {
        let lanes: [StreamId] = [.natural, .processed, .tracker]
        return VStack(alignment: .leading, spacing: 2) {
            Text("FrameDeliveryStats (Δ/window)")
                .font(.caption2.bold())
            ForEach(lanes, id: \.self) { lane in
                Text(
                    "\(lane.rawValue): swiftDrop=\(stats.droppedByLane[lane] ?? 0)"
                        + "  cppOverwrite=\(stats.cppOverwriteByLane[lane] ?? 0)")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.cyan)
        .padding(8)
        .background(.black.opacity(0.7))
        .padding([.bottom, .trailing], 16)
    }
    #endif
}

// MARK: - SliderRebinding (avoid mid-drag write-back oscillation)

/// A slider whose `value` is owned by local `@State` and whose updates are forwarded
/// through `onChange` instead of a two-way `Binding`.
///
/// The two-way `Binding(get:set:)` pattern oscillates mid-drag when the upstream
/// (debouncer-driven) view-model writes a slightly different committed value back
/// — SwiftUI re-renders the parent and the slider snaps. Keeping the slider's
/// state local and forwarding only the user input via `onChange` gives the
/// debouncer authority over the dispatch.
struct SliderRebinding: View {

    let initial: Double
    let range: ClosedRange<Double>
    let onChange: (Double) -> Void
    @State private var local: Double

    init(initial: Double, range: ClosedRange<Double>, onChange: @escaping (Double) -> Void) {
        self.initial = initial
        self.range = range
        self.onChange = onChange
        _local = State(initialValue: initial)
    }

    var body: some View {
        Slider(value: $local, in: range)
            .onChange(of: local) { _, new in onChange(new) }
    }
}

// MARK: - MTKViewRepresentable + Coordinator (preview rendering — unchanged from Stage 10)

/// Internal `UIViewRepresentable` wrapping `MTKView` for the SwiftUI hierarchy.
///
/// Parameterized by a texture accessor closure to support both natural and
/// processed preview panels.
struct MTKViewRepresentable: UIViewRepresentable {

    let textureAccessor: () -> MTLTexture?
    // bug6: identifies which preview lane this view renders, for log correlation.
    var label: String = "preview"

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.framebufferOnly = false
        // All lane textures are now BGRA8 (8-bit end-to-end delivery). The blit
        // in `draw(in:)` requires the drawable and source to share a pixel
        // format, so the drawable matches the `.bgra8Unorm` lane textures.
        mtkView.colorPixelFormat = .bgra8Unorm
        (mtkView.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        mtkView.preferredFramesPerSecond = 30
        mtkView.backgroundColor = .black
        mtkView.delegate = context.coordinator
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> MTKViewCoordinator {
        MTKViewCoordinator(textureAccessor: textureAccessor, label: label)
    }
}

/// Drives the `MTKView` draw loop and blits the texture returned by the accessor.
///
/// Acquire drawable → unconditional clear-pass → conditional blit → always present
/// (CLAUDE.md §8 invariant — never return between drawable acquire and present).
final class MTKViewCoordinator: NSObject, MTKViewDelegate {

    let textureAccessor: () -> MTLTexture?
    let label: String

    /// Cached command queue — created once to avoid per-frame allocation at 30 fps.
    let commandQueue: MTLCommandQueue?

    init(textureAccessor: @escaping () -> MTLTexture?, label: String = "preview") {
        self.textureAccessor = textureAccessor
        self.label = label
        self.commandQueue = MTLCreateSystemDefaultDevice()?.makeCommandQueue()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Stage 01: no-op. Resize handling arrives in a later stage.
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable else { return }
        guard let commandBuffer = commandQueue?.makeCommandBuffer() else { return }

        let renderDesc = MTLRenderPassDescriptor()
        renderDesc.colorAttachments[0].texture = drawable.texture
        renderDesc.colorAttachments[0].loadAction = .clear
        renderDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        renderDesc.colorAttachments[0].storeAction = .store
        if let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderDesc) {
            renderEncoder.endEncoding()
        }

        if let texture = textureAccessor(),
            let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        {
            let srcWidth = min(texture.width, drawable.texture.width)
            let srcHeight = min(texture.height, drawable.texture.height)
            blitEncoder.copy(
                from: texture,
                sourceSlice: 0,
                sourceLevel: 0,
                sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                sourceSize: MTLSize(width: srcWidth, height: srcHeight, depth: 1),
                to: drawable.texture,
                destinationSlice: 0,
                destinationLevel: 0,
                destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
            )
            blitEncoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - Resolution picker

/// Standalone bottom-bar button for the resolution picker.
///
/// Inputs are plain value types (no `@Observable` references), so SwiftUI only
/// re-evaluates this view when one of its props changes — not on every
/// `CameraView.body` re-render driven by 30 Hz `lastFrameResult` updates.
/// Stable identity keeps the Menu's gesture recognition responsive.
///
/// `Equatable` conformance compares only the equatable inputs (sizes, active,
/// enabled) — the `onPick` closure is intentionally ignored. Without this,
/// SwiftUI treats every parent re-render as "props changed" because closures
/// have no value equality, defeating the view-extraction isolation.
private struct ResolutionPickerButton: View, Equatable {
    let supportedSizes: [Size]
    let active: Size?
    let enabled: Bool
    let onPick: (Size) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.supportedSizes == rhs.supportedSizes
            && lhs.active == rhs.active
            && lhs.enabled == rhs.enabled
    }

    var body: some View {
        Menu {
            ForEach(supportedSizes, id: \.self) { size in
                Button {
                    onPick(size)
                } label: {
                    if size == active {
                        Label("\(size.width)×\(size.height)", systemImage: "checkmark")
                    } else {
                        Text("\(size.width)×\(size.height)")
                    }
                }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: "aspectratio").font(.title3)
                Text(label).font(.caption2.monospaced())
            }
            .frame(minWidth: 60)
            .foregroundStyle(.white)
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .disabled(!enabled)
        .opacity(enabled ? 1.0 : 0.4)
        .accessibilityLabel("Resolution")
        .accessibilityHint("Choose capture resolution")
    }

    private var label: String {
        guard let active else { return "—" }
        return "\(active.width)×\(active.height)"
    }
}

// MARK: - Expanded slider bar (ISO / Shutter / Focus / Zoom)

/// Standalone sub-view for the four-slider expanded bar.
///
/// All reads of `viewModel.lastFrameResult` and
/// `viewModel.hardware.currentSettings` happen inside *this* body, so when
/// those change SwiftUI only invalidates `ExpandedSliderBar` — not the
/// parent `CameraView`. Paired with the 10 Hz throttle in
/// `ViewModel.makeFrameResultTask`, this is what keeps the picker, toolbar,
/// and sidebar from re-rendering on every camera frame.
private struct ExpandedSliderBar: View {
    let viewModel: ViewModel
    let enablement: ControlEnablement

    var body: some View {
        let settings = viewModel.hardware.currentSettings
        let frame = viewModel.lastFrameResult
        let caps = viewModel.capabilities

        VStack(alignment: .leading, spacing: 10) {
            row(
                label: "ISO",
                readback: frame?.iso.map { "\($0)" } ?? "AUTO",
                initial: Double(settings.iso ?? Int(frame?.iso ?? 400)),
                range: caps.map {
                    Double($0.isoRange.lowerBound)...Double($0.isoRange.upperBound)
                } ?? 30...3200,
                push: viewModel.hardware.pushISO
            )
            row(
                label: "Shutter (ms)",
                readback: frame?.exposureTimeNs.map {
                    String(format: "%.1f", Double($0) / 1_000_000)
                } ?? "AUTO",
                initial: Double(settings.exposureTimeNs ?? frame?.exposureTimeNs ?? 16_666_667)
                    / 1_000_000.0,
                range: 1.0...100.0,
                push: { ms in viewModel.hardware.pushShutter(ms * 1_000_000) }
            )
            row(
                label: "Focus",
                readback: frame?.focusDistance.map { String(format: "%.2f", $0) } ?? "AUTO",
                initial: settings.focusDistance ?? frame?.focusDistance ?? 0.5,
                range: 0.0...1.0,
                push: viewModel.hardware.pushFocus
            )
            row(
                label: "Zoom",
                readback: String(format: "%.1fx", settings.zoomRatio ?? 1.0),
                initial: settings.zoomRatio ?? 1.0,
                range: 1.0...4.0,
                push: viewModel.hardware.pushZoom
            )
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .opacity(enablement.isSettingsEnabled ? 1.0 : 0.4)
        .disabled(!enablement.isSettingsEnabled)
    }

    @ViewBuilder
    private func row(
        label: String,
        readback: String,
        initial: Double,
        range: ClosedRange<Double>,
        push: @escaping (Double) -> Void
    ) -> some View {
        HStack {
            Text(label).foregroundStyle(.white).frame(width: 100, alignment: .leading)
            Text(readback)
                .font(.caption.monospaced())
                .foregroundStyle(.white)
                .frame(width: 80, alignment: .trailing)
            SliderRebinding(initial: initial, range: range, onChange: push)
                .frame(maxWidth: .infinity)
        }
    }
}
