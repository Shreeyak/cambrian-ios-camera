import Flutter
import XCTest

@testable import cambrian_ios_camera

/// `StreamId` here is the Pigeon enum (the `createPreviewTexture` parameter
/// type) — CameraKit is deliberately not imported so the name is unambiguous.
final class TextureMapTests: XCTestCase {

    func test_createPreviewTexture_registers_and_stores() async throws {
        let registry = RecordingTextureRegistry()
        let plugin = CambrianIosCameraPlugin(
            registrar: StubRegistrar(textures: registry), engine: MockCameraEngine())
        let exp = expectation(description: "create completes")
        var id: Int64 = -1
        plugin.createPreviewTexture(stream: .processed) { result in
            if case .success(let value) = result { id = value }
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 1.0)
        XCTAssertGreaterThan(id, 0)
        XCTAssertNotNil(registry.registered[id])
        XCTAssertNotNil(plugin.textures[id])
    }

    /// Per Phase B spec §3 "Open-state coupling": createPreviewTexture before
    /// open() returns a texture id without error; copyPixelBuffer returns nil
    /// until the engine is wired.
    func test_createPreviewTexture_before_open_succeeds() async throws {
        let registry = RecordingTextureRegistry()
        let plugin = CambrianIosCameraPlugin(
            registrar: StubRegistrar(textures: registry), engine: nil)
        let exp = expectation(description: "create completes")
        var id: Int64 = -1
        var failure: Error?
        plugin.createPreviewTexture(stream: .processed) { result in
            switch result {
            case .success(let value): id = value
            case .failure(let e): failure = e
            }
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: 1.0)
        XCTAssertNil(failure, "expected success; got \(String(describing: failure))")
        XCTAssertGreaterThan(id, 0)
        let tex = registry.registered[id]
        XCTAssertNotNil(tex)
        XCTAssertNil(tex?.copyPixelBuffer())
    }

    func test_destroyPreviewTexture_unregisters_and_clears_map() async throws {
        let registry = RecordingTextureRegistry()
        let plugin = CambrianIosCameraPlugin(
            registrar: StubRegistrar(textures: registry), engine: MockCameraEngine())
        let createExp = expectation(description: "create")
        var id: Int64 = -1
        plugin.createPreviewTexture(stream: .processed) { r in
            if case .success(let v) = r { id = v }
            createExp.fulfill()
        }
        await fulfillment(of: [createExp], timeout: 1.0)
        let destroyExp = expectation(description: "destroy")
        plugin.destroyPreviewTexture(textureId: id) { _ in destroyExp.fulfill() }
        await fulfillment(of: [destroyExp], timeout: 1.0)
        XCTAssertNil(plugin.textures[id])
        XCTAssertTrue(registry.unregistered.contains(id))
    }

    func test_destroyTwice_is_idempotent() async throws {
        let registry = RecordingTextureRegistry()
        let plugin = CambrianIosCameraPlugin(
            registrar: StubRegistrar(textures: registry), engine: MockCameraEngine())
        let exp1 = expectation(description: "create")
        var id: Int64 = -1
        plugin.createPreviewTexture(stream: .processed) { r in
            if case .success(let v) = r { id = v }
            exp1.fulfill()
        }
        await fulfillment(of: [exp1], timeout: 1.0)
        let exp2 = expectation(description: "destroy 1")
        plugin.destroyPreviewTexture(textureId: id) { _ in exp2.fulfill() }
        await fulfillment(of: [exp2], timeout: 1.0)
        let exp3 = expectation(description: "destroy 2")
        plugin.destroyPreviewTexture(textureId: id) { result in
            XCTAssertNotNil(try? result.get())
            exp3.fulfill()
        }
        await fulfillment(of: [exp3], timeout: 1.0)
    }
}
