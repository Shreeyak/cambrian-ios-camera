import CameraKit
import CoreVideo
import Flutter
import Foundation

/// One FlutterTexture instance per active preview stream.
///
/// `copyPixelBuffer` is called on Flutter's raster thread; it looks up the
/// current pixel buffer for this stream from the plugin's engine
/// (mailbox lookup — cheap, no copy) and returns it +1 retained. Flutter
/// releases after rendering. Per Phase B spec §3 "Open-state coupling":
/// pre-open this returns `nil` and the texture shows black until the first
/// frame after `open()`.
final class EnginePixelBufferTexture: NSObject, FlutterTexture {
    weak var plugin: CambrianIosCameraPlugin?
    let stream: StreamId

    init(plugin: CambrianIosCameraPlugin, stream: StreamId) {
        self.plugin = plugin
        self.stream = stream
        super.init()
    }

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        guard let engine = plugin?.engine else { return nil }
        guard let buf = engine.currentPixelBuffer(stream: stream.toCameraKit()) else {
            return nil
        }
        return Unmanaged.passRetained(buf)
    }
}

extension CambrianIosCameraPlugin {

    /// Per Phase B spec §3 "Open-state coupling": calling before `open()`
    /// returns a valid texture id; `copyPixelBuffer` returns `nil` until the
    /// engine is open and the first frame lands.
    ///
    /// Subscriber tasks spawned here exit immediately when the engine is
    /// absent; `armPendingTextures()` re-spawns them after `open()` sets
    /// `self.engine`.
    public func createPreviewTexture(
        stream: StreamId,
        completion: @escaping (Result<Int64, any Error>) -> Void
    ) {
        let texture = EnginePixelBufferTexture(plugin: self, stream: stream)
        let textureId = registrar.textures().register(texture)
        let task = makeTextureSubscriberTask(textureId: textureId, stream: stream)
        textures[textureId] = (texture, task)
        completion(.success(textureId))
    }

    public func destroyPreviewTexture(
        textureId: Int64,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        guard let entry = textures.removeValue(forKey: textureId) else {
            // Idempotent: destroy on an unknown ID is a no-op (covered by
            // RunnerTests/TextureMapTests/destroy-twice — Task 26).
            completion(.success(()))
            return
        }
        entry.1.cancel()
        registrar.textures().unregisterTexture(textureId)
        completion(.success(()))
    }

    /// Spawns subscriber tasks for any textures that were registered before
    /// the engine existed.
    ///
    /// Called from `open()` after `self.engine` is set.
    func armPendingTextures() {
        for (textureId, entry) in textures {
            entry.1.cancel()  // belt-and-braces; pending task is no-op
            let stream = entry.0.stream
            let newTask = makeTextureSubscriberTask(textureId: textureId, stream: stream)
            textures[textureId] = (entry.0, newTask)
        }
    }

    /// Builds the subscriber task that fires `textureFrameAvailable` per
    /// delivered frame.
    ///
    /// If `self.engine` is nil at call time, the task exits immediately;
    /// `armPendingTextures()` re-spawns it later. On Task cancellation, the
    /// `for-await` loop exits and the `AsyncStream`'s `onTermination`
    /// callback removes the subscriber from `ConsumerRegistry`'s internal
    /// table — no explicit unsubscribe call needed (see PixelSink.swift).
    private func makeTextureSubscriberTask(
        textureId: Int64, stream: StreamId
    ) -> Task<Void, Never> {
        let registry = registrar.textures()
        let kitStream = stream.toCameraKit()
        return Task { [weak self] in
            guard let self, let engine = self.engine else { return }
            let frames = await engine.consumers.subscribe(stream: kitStream)
            for await _ in frames {
                if Task.isCancelled { break }
                registry.textureFrameAvailable(textureId)
            }
        }
    }
}
