import CameraKit
import Flutter
import Foundation

extension CambrianIosCameraPlugin: CameraEngineHostApi {

    // MARK: - Lifecycle

    func open(
        configuration: OpenConfiguration?,
        completion: @escaping (Result<SessionCapabilities, any Error>) -> Void
    ) {
        if engine != nil || isClosing {
            // open() returns capabilities for a fresh session. A second open
            // without close — or an open while a previous close is still tearing
            // down — is a programming error the Dart facade surfaces.
            completion(
                .failure(
                    PigeonError(
                        code: "\(CameraErrorCode.invalidState)",
                        message: "engine already open or closing; await close() before reopening",
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
        guard !isClosing, let engine = self.engine else {
            // Already closed, or a close is already in flight — idempotent no-op.
            completion(.success(()))
            return
        }
        // Keep `engine` non-nil and mark `isClosing` until teardown finishes, so
        // a concurrent open() is rejected until the old session is fully closed.
        // This reorder (vs niling synchronously up front) is the #3 fix for the
        // close→open AVCaptureSession race.
        isClosing = true
        let oldStreamTasks = self.streamTasks
        let oldTextures = self.textures
        self.streamTasks = []
        self.textures = [:]
        Task {
            for t in oldStreamTasks { t.cancel() }
            // Texture-registry calls must run on the platform/main thread.
            await MainActor.run {
                for (id, entry) in oldTextures {
                    entry.0.setEngine(nil)
                    entry.1.cancel()
                    self.registrar.textures().unregisterTexture(id)
                }
            }
            await engine.close()
            await MainActor.run {
                self.engine = nil
                self.isClosing = false
            }
            completion(.success(()))
        }
    }

    // MARK: - Snapshots

    func currentState(
        completion: @escaping (Result<SessionState, any Error>) -> Void
    ) {
        let engine = self.engine
        Task {
            // Fresh read of the engine's actual current state — not a replay.
            // `.closed` when no engine exists yet (before open()).
            let snap = await engine?.currentStateSnapshot() ?? .closed
            completion(.success(snap.toPigeon()))
        }
    }

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
        whitePoint: Bool,
        completion: @escaping (Result<CalibrationResult, any Error>) -> Void
    ) {
        guardOpenReturning(completion) { engine in
            let r = try await engine.calibrateWhite(whitePoint: whitePoint)
            return r.toPigeon()
        }
    }

    func calibrateBlackPoint(
        completion: @escaping (Result<Void, any Error>) -> Void
    ) {
        guardOpen(completion) { engine in
            // Discard the per-channel diagnostics — the Dart surface only needs
            // success/failure. Failure throws EngineError.blackPointCalibrationFailed,
            // mapped to CameraErrorCode.calibrationFailed by `asPigeonError()`.
            _ = try await engine.calibrateBlack()
        }
    }

    // Calibration toggles (§8.2). enable* propagate EngineError.{whiteBalance,
    // blackPoint}NotCalibrated → CameraErrorCode.invalidState via asPigeonError();
    // disable*/clear* never throw.
    func enableWhiteBalance(completion: @escaping (Result<Void, any Error>) -> Void) {
        guardOpen(completion) { try await $0.enableWhiteBalance() }
    }
    func disableWhiteBalance(completion: @escaping (Result<Void, any Error>) -> Void) {
        guardOpen(completion) { await $0.disableWhiteBalance() }
    }
    func enableWhitePoint(completion: @escaping (Result<Void, any Error>) -> Void) {
        guardOpen(completion) { try await $0.enableWhitePoint() }
    }
    func disableWhitePoint(completion: @escaping (Result<Void, any Error>) -> Void) {
        guardOpen(completion) { await $0.disableWhitePoint() }
    }
    func clearWhiteBalance(completion: @escaping (Result<Void, any Error>) -> Void) {
        guardOpen(completion) { await $0.clearWhiteBalance() }
    }
    func enableBlackPoint(completion: @escaping (Result<Void, any Error>) -> Void) {
        guardOpen(completion) { try await $0.enableBlackPoint() }
    }
    func disableBlackPoint(completion: @escaping (Result<Void, any Error>) -> Void) {
        guardOpen(completion) { await $0.disableBlackPoint() }
    }
    func clearBlackPoint(completion: @escaping (Result<Void, any Error>) -> Void) {
        guardOpen(completion) { await $0.clearBlackPoint() }
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
