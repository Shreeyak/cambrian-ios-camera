import MetalKit
import SwiftUI

/// Public SwiftUI view that renders a split camera preview (left natural,
/// right processed) plus a color-calibration sidebar.
///
/// Hosts two MTKViewRepresentable instances (natural / processed) and reacts
/// to scene phase transitions via ViewModel.handleScenePhase(_:)
/// (08-ui.md §scenePhase wiring, ADR-09, D-06).
/// CameraEngine lifecycle is owned by ViewModel.
public struct CameraView: View {

    @State private var viewModel = ViewModel()
    @State private var sidebarVisible: Bool = false
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        ZStack {
            HStack(spacing: 0) {
                // Left half — natural preview.
                MTKViewRepresentable(textureAccessor: { viewModel.naturalTex })
                    .ignoresSafeArea()
                // Right half — processed preview.
                MTKViewRepresentable(textureAccessor: { viewModel.processedTex })
                    .ignoresSafeArea()
            }
            VStack {
                Spacer()
                bottomBar
                    .padding()
                    .background(.black.opacity(0.6))
            }
            if sidebarVisible {
                HStack {
                    Spacer()
                    calibrationSidebar
                        .frame(width: 280)
                        .background(.black.opacity(0.7))
                }
            }
            VStack {
                HStack {
                    Spacer()
                    Button(sidebarVisible ? "Hide Cal" : "Calibrate Color") {
                        sidebarVisible.toggle()
                    }
                    .padding(8)
                    .background(.black.opacity(0.6))
                    .foregroundStyle(.white)
                    .padding()
                }
                Spacer()
            }
        }
        .task {
            await viewModel.start()
        }
        .onChange(of: viewModel.sessionState) { _, _ in
            // Future: react to state changes (error overlay, recovery UI, etc.)
        }
        // 08-ui.md §scenePhase wiring: .task(id:) auto-cancels and re-runs on phase change.
        // handleScenePhase enforces D-06 strict gating on .inactive and drives
        // backgroundSuspend / backgroundResume for .background / .active.
        .task(id: scenePhase) {
            await viewModel.handleScenePhase(scenePhase)
        }
    }

    // MARK: - Sidebar (08-ui.md §Color calibration sidebar)

    private var calibrationSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Color Calibration").foregroundStyle(.white).font(.headline)

            sliderRow(
                label: "Brightness",
                value: Binding(
                    get: { viewModel.currentProcessing.brightness },
                    set: { v in mutateProcessing { $0.brightness = v } }),
                range: -1.0...1.0)
            sliderRow(
                label: "Contrast",
                value: Binding(
                    get: { viewModel.currentProcessing.contrast },
                    set: { v in mutateProcessing { $0.contrast = v } }),
                range: 0.0...2.0)
            sliderRow(
                label: "Saturation",
                value: Binding(
                    get: { viewModel.currentProcessing.saturation },
                    set: { v in mutateProcessing { $0.saturation = v } }),
                range: -1.0...1.0)
            sliderRow(
                label: "Gamma",
                value: Binding(
                    get: { viewModel.currentProcessing.gamma },
                    set: { v in mutateProcessing { $0.gamma = v } }),
                range: 0.1...4.0)
            Divider().background(.white.opacity(0.5))
            sliderRow(
                label: "Black R",
                value: Binding(
                    get: { viewModel.currentProcessing.blackR },
                    set: { v in mutateProcessing { $0.blackR = v } }),
                range: 0.0...0.5)
            sliderRow(
                label: "Black G",
                value: Binding(
                    get: { viewModel.currentProcessing.blackG },
                    set: { v in mutateProcessing { $0.blackG = v } }),
                range: 0.0...0.5)
            sliderRow(
                label: "Black B",
                value: Binding(
                    get: { viewModel.currentProcessing.blackB },
                    set: { v in mutateProcessing { $0.blackB = v } }),
                range: 0.0...0.5)
            Spacer()
            Button("Reset") {
                Task { await viewModel.resetProcessing() }
            }
            .foregroundStyle(.white)
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(.gray.opacity(0.5))
        }
        .padding()
    }

    private func sliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).foregroundStyle(.white).font(.caption)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .foregroundStyle(.white).font(.caption.monospacedDigit())
            }
            Slider(value: value, in: range)
        }
    }

    private func mutateProcessing(_ mutate: (inout ProcessingParameters) -> Void) {
        var next = viewModel.currentProcessing
        mutate(&next)
        Task { await viewModel.updateProcessing(next) }
    }

    // MARK: - Bottom bar — Stage-03 controls (kept verbatim from prior stage)

    private var bottomBar: some View {
        HStack(spacing: 16) {
            sliderCell(
                label: "ISO",
                value: Binding(
                    get: { Double(viewModel.currentSettings.iso ?? 100) },
                    set: { new in Task { await viewModel.updateISO(Int(new)) } }),
                range: viewModel.capabilities.map {
                    Double($0.isoRange.lowerBound)...Double($0.isoRange.upperBound)
                } ?? 30...3200,
                readback: viewModel.lastFrameResult?.iso.flatMap { Optional("\($0)") } ?? "—")
            sliderCell(
                label: "Shutter (ms)",
                value: Binding(
                    get: { Double(viewModel.currentSettings.exposureTimeNs ?? 33_000_000) / 1_000_000 },
                    set: { new in Task { await viewModel.updateShutterNs(Int64(new * 1_000_000)) } }),
                range: 1...100,
                readback: viewModel.lastFrameResult?.exposureTimeNs.flatMap {
                    Optional(String(format: "%.1f", Double($0) / 1_000_000))
                } ?? "—")
            sliderCell(
                label: "Focus",
                value: Binding(
                    get: { viewModel.currentSettings.focusDistance ?? 0.0 },
                    set: { new in Task { await viewModel.updateFocus(new) } }),
                range: 0...1,
                readback: viewModel.lastFrameResult?.focusDistance
                    .flatMap { Optional(String(format: "%.2f", $0)) } ?? "—")
            sliderCell(
                label: "Zoom",
                value: Binding(
                    get: { viewModel.currentSettings.zoomRatio ?? 1.0 },
                    set: { new in Task { await viewModel.updateZoom(new) } }),
                range: 1...5,
                readback: String(format: "%.2fx", viewModel.currentSettings.zoomRatio ?? 1.0))
        }
    }

    private func sliderCell(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        readback: String
    ) -> some View {
        VStack {
            Text(label).foregroundStyle(.white).font(.caption)
            Slider(value: value, in: range)
            Text(readback).foregroundStyle(.white).font(.caption2)
        }
    }
}

// MARK: - MTKViewRepresentable (parameterized by a texture closure)

/// Internal UIViewRepresentable that wraps MTKView for the SwiftUI hierarchy.
///
/// Parameterized by a texture accessor closure to support both natural and
/// processed preview panels.
struct MTKViewRepresentable: UIViewRepresentable {

    let textureAccessor: () -> MTLTexture?

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.framebufferOnly = false
        mtkView.colorPixelFormat = .rgba16Float
        // Tag the CAMetalLayer as sRGB so the system treats values as gamma-encoded, not linear.
        (mtkView.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        mtkView.preferredFramesPerSecond = 30
        mtkView.delegate = context.coordinator
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> MTKViewCoordinator {
        MTKViewCoordinator(textureAccessor: textureAccessor)
    }
}

// MARK: - MTKViewCoordinator (reads texture via closure)

/// Drives the MTKView draw loop and blits the texture returned by the accessor
/// closure into each drawable.
final class MTKViewCoordinator: NSObject, MTKViewDelegate {

    let textureAccessor: () -> MTLTexture?

    /// Cached command queue — created once to avoid per-frame allocation at 30 fps.
    let commandQueue: MTLCommandQueue?

    init(textureAccessor: @escaping () -> MTLTexture?) {
        self.textureAccessor = textureAccessor
        self.commandQueue = MTLCreateSystemDefaultDevice()?.makeCommandQueue()
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Stage 01: no-op. Resize handling arrives in a later stage.
    }

    func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let texture = textureAccessor(),
            let commandQueue,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        // Clear drawable to black first so uncovered regions (when texture is smaller
        // than the screen) don't show uninitialized GPU memory (green artifacts).
        let renderDesc = MTLRenderPassDescriptor()
        renderDesc.colorAttachments[0].texture = drawable.texture
        renderDesc.colorAttachments[0].loadAction = .clear
        renderDesc.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        renderDesc.colorAttachments[0].storeAction = .store
        let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderDesc)!
        renderEncoder.endEncoding()

        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else { return }

        // Blit the region that fits both source and destination (Stage 01: no scaling).
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

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
