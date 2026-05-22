import CameraKit
import Flutter
import Foundation

extension CambrianIosCameraPlugin: CameraEngineHostApi {

    // MARK: - Lifecycle

    func open(
        configuration: OpenConfiguration?,
        completion: @escaping (Result<SessionCapabilities, any Error>) -> Void
    ) {
        if engine != nil {
            // open() returns capabilities for a fresh session — a second open
            // without close is a programming error the Dart facade surfaces.
            completion(
                .failure(
                    PigeonError(
                        code: "\(CameraErrorCode.invalidState)",
                        message: "engine already open; call close() before reopening",
                        details: ["isFatal": false]
                    )))
            return
        }
        Task {
            let phase = await Self.currentScenePhase()
            let cfg = configuration?.toCameraKit() ?? CameraKit.OpenConfiguration()
            let engine = CameraKit.CameraEngine(initialPhase: phase)
            do {
                let caps = try await engine.open(configuration: cfg)
                // Texture registry access must happen on the platform/main
                // thread (doing it on this background Task aborts the Flutter
                // engine). EventChannel handlers were already registered at
                // register(with:); here we only spawn the engine-iterating
                // forwarder Tasks now that the engine exists.
                await MainActor.run {
                    self.engine = engine
                    self.startStreamForwarders()
                    self.armPendingTextures()  // Per spec §3: pre-open textures wire subscribers now.
                }
                completion(.success(caps.toPigeon()))
            } catch {
                completion(.failure(error.asPigeonError()))
            }
        }
    }

    func close(completion: @escaping (Result<Void, any Error>) -> Void) {
        let engine = self.engine
        let oldStreamTasks = self.streamTasks
        let oldTextures = self.textures
        self.engine = nil
        self.streamTasks = []
        self.textures = [:]
        Task {
            for t in oldStreamTasks { t.cancel() }
            // Texture-registry calls must run on the platform/main thread.
            await MainActor.run {
                for (id, entry) in oldTextures {
                    entry.1.cancel()
                    self.registrar.textures().unregisterTexture(id)
                }
            }
            await engine?.close()
            completion(.success(()))
        }
    }

    // MARK: - Snapshots

    func currentSettings(
        completion: @escaping (Result<CameraSettings?, any Error>) -> Void
    ) {
        let engine = self.engine
        Task {
            let snap = await engine?.currentSettingsSnapshot()
            completion(.success(snap?.toPigeon()))
        }
    }

    func currentProcessingParameters(
        completion: @escaping (Result<ProcessingParameters?, any Error>) -> Void
    ) {
        let engine = self.engine
        Task {
            let snap = await engine?.currentProcessingParametersSnapshot()
            completion(.success(snap?.toPigeon()))
        }
    }

    // MARK: - Control

    func updateSettings(
        settings: CameraSettings,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        guardOpen(completion) { engine in
            try await engine.updateSettings(settings.toCameraKit())
        }
    }

    func setResolution(
        size: PSize,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        guardOpen(completion) { engine in
            try await engine.setResolution(size: size.toCameraKit())
        }
    }

    func setProcessingParams(
        params: ProcessingParameters,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        guardOpen(completion) { engine in
            await engine.setProcessingParams(params.toCameraKit())
        }
    }

    func setCropRegion(
        rect: PRect,
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        guardOpen(completion) { engine in
            try await engine.setCropRegion(rect.toCameraKit())
        }
    }

    // MARK: - Capture

    func captureImage(
        outputPath: String?,
        photosDestination: PhotosDestination,
        completion: @escaping (Result<String, any Error>) -> Void
    ) {
        guardOpenReturning(completion) { engine in
            let url = outputPath.flatMap { URL(fileURLWithPath: $0) }
            let result = try await engine.captureImage(
                outputURL: url,
                photosDestination: photosDestination.toCameraKit()
            )
            return result.filePath
        }
    }

    func captureNaturalPicture(
        outputPath: String?,
        photosDestination: PhotosDestination,
        completion: @escaping (Result<String, any Error>) -> Void
    ) {
        guardOpenReturning(completion) { engine in
            let url = outputPath.flatMap { URL(fileURLWithPath: $0) }
            let result = try await engine.captureNaturalPicture(
                outputURL: url,
                photosDestination: photosDestination.toCameraKit()
            )
            return result.filePath
        }
    }

    // MARK: - Recording

    func startRecording(
        options: RecordingOptions,
        completion: @escaping (Result<RecordingStart, any Error>) -> Void
    ) {
        guardOpenReturning(completion) { engine in
            let s = try await engine.startRecording(options: options.toCameraKit())
            return s.toPigeon()
        }
    }

    func stopRecording(
        completion: @escaping (Result<String, any Error>) -> Void
    ) {
        guardOpenReturning(completion) { engine in
            try await engine.stopRecording()
        }
    }

    // MARK: - Calibration

    func calibrateWhiteBalance(
        completion: @escaping (Result<CalibrationResult, any Error>) -> Void
    ) {
        guardOpenReturning(completion) { engine in
            let r = try await engine.calibrateWhiteBalance()
            return r.toPigeon()
        }
    }

    func calibrateBlackBalance(
        completion: @escaping (Result<CalibrationResult, any Error>) -> Void
    ) {
        guardOpenReturning(completion) { engine in
            let r = try await engine.calibrateBlackBalance()
            return r.toPigeon()
        }
    }

    // MARK: - Texture bridge (implemented in TextureBridge.swift — Task 10)

    // public func createPreviewTexture(...) — in TextureBridge.swift
    // public func destroyPreviewTexture(...) — in TextureBridge.swift

    // MARK: - Private helpers

    /// Calls `body` on the singleton engine; if absent, fails with `.notOpen`.
    private func guardOpen(
        _ completion: @escaping (Result<Void, any Error>) -> Void,
        body: @escaping (any CameraEngineProtocol) async throws -> Void
    ) {
        guard let engine = self.engine else {
            completion(
                .failure(
                    PigeonError(
                        code: "\(CameraErrorCode.notOpen)",
                        message: "engine not open; call open() first",
                        details: ["isFatal": false]
                    )))
            return
        }
        Task {
            do {
                try await body(engine)
                completion(.success(()))
            } catch {
                completion(.failure(error.asPigeonError()))
            }
        }
    }

    /// Same as `guardOpen` but for methods that return a non-Void result.
    private func guardOpenReturning<T>(
        _ completion: @escaping (Result<T, any Error>) -> Void,
        body: @escaping (any CameraEngineProtocol) async throws -> T
    ) {
        guard let engine = self.engine else {
            completion(
                .failure(
                    PigeonError(
                        code: "\(CameraErrorCode.notOpen)",
                        message: "engine not open; call open() first",
                        details: ["isFatal": false]
                    )))
            return
        }
        Task {
            do {
                let result = try await body(engine)
                completion(.success(result))
            } catch {
                completion(.failure(error.asPigeonError()))
            }
        }
    }
}
