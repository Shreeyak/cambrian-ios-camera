/// Marker protocol for producer-specific frame metadata.
///
/// Each producer defines its own concrete conforming type (e.g. the camera's
/// `CameraFrameMetadata`); the universal ``Frame`` envelope stays
/// producer-agnostic. Any datum a consumer makes a control decision on MUST be
/// a typed member of a concrete `FrameMetadata` type, never an untyped payload.
/// Consumers downcast to the concrete type at a source-specific boundary.
public protocol FrameMetadata: Sendable {}
