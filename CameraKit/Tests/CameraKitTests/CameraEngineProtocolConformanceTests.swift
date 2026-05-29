import Testing

@testable import CameraKit

/// Proves `CameraEngine` satisfies `CameraEngineProtocol` for every public
/// method the Flutter adapter calls.
///
/// If a new method is added to the protocol, this fails to compile until the
/// engine implements it. Conversely, if the engine's public signature drifts
/// from a protocol requirement, the `extension CameraEngine: CameraEngineProtocol {}`
/// in `CameraEngineProtocol.swift` fails to compile — this test exists to
/// document the contract and provide a single grep target for "protocol
/// conformance".
@Suite("CameraEngineProtocol conformance")
struct CameraEngineProtocolConformanceTests {
    @Test("CameraEngine conforms to CameraEngineProtocol")
    func conformance() {
        // Compile-time check: assigning a concrete instance to the protocol
        // existential fails to build if any required member is missing.
        let _: any CameraEngineProtocol = CameraEngine(initialPhase: .background)
    }
}
