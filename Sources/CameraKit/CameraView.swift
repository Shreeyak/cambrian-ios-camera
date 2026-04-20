import SwiftUI
import MetalKit

/// Public SwiftUI view that renders a live camera preview via an MTKView.
///
/// Hosts MTKViewRepresentable and reacts to scene phase transitions.
/// CameraEngine lifecycle is owned by ViewModel; this view calls start() once on
/// appear and naiveBackgroundStop() on background (scaffolding:01:naive-scenephase-stop).
public struct CameraView: View {

    @State private var viewModel = ViewModel()
    @Environment(\.scenePhase) private var scenePhase

    public init() {}

    public var body: some View {
        ZStack {
            MTKViewRepresentable(viewModel: viewModel)
                .ignoresSafeArea()
        }
        .task {
            await viewModel.start()
        }
        .onChange(of: viewModel.sessionState) { _, _ in
            // Future: react to state changes (error overlay, recovery UI, etc.)
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                // Call naiveBackgroundStop on background transition.
                // The scaffold slug lives in CameraEngine.naiveBackgroundStop().
                Task { await viewModel.engine.naiveBackgroundStop() }
            }
        }
    }
}

// MARK: - MTKViewRepresentable

/// Internal UIViewRepresentable that wraps MTKView for the SwiftUI hierarchy.
struct MTKViewRepresentable: UIViewRepresentable {

    let viewModel: ViewModel

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.framebufferOnly = false
        mtkView.colorPixelFormat = .rgba16Float  // must match naturalTex workingPixelFormat
        // Tag the CAMetalLayer as sRGB so the system treats values as gamma-encoded, not linear.
        (mtkView.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        mtkView.preferredFramesPerSecond = 30
        mtkView.delegate = context.coordinator
        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> MTKViewCoordinator {
        MTKViewCoordinator(viewModel: viewModel)
    }
}

// MARK: - MTKViewCoordinator

/// Drives the MTKView draw loop and blits naturalTex into each drawable.
final class MTKViewCoordinator: NSObject, MTKViewDelegate {

    let viewModel: ViewModel

    /// Cached command queue — created once to avoid per-frame allocation at 30 fps.
    let commandQueue: MTLCommandQueue?

    init(viewModel: ViewModel) {
        self.viewModel = viewModel
        self.commandQueue = MTLCreateSystemDefaultDevice()?.makeCommandQueue()
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Stage 01: no-op. Resize handling arrives in a later stage.
    }

    func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let texture = viewModel.naturalTex,
            let commandQueue,
            let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        // Clear drawable to black first so uncovered regions (when naturalTex is smaller
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
        let srcWidth  = min(texture.width,  drawable.texture.width)
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
