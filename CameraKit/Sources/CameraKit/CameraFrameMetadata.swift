import FrameTransport

/// The camera's per-frame metadata, carried on every delivered ``Frame``.
///
/// Minimal in this change — it exists so a `Frame` can be constructed (its
/// `metadata` is a non-optional `any FrameMetadata`). The `frame-metadata-signals`
/// change EXTENDS this type with typed decision data (sensor read, settle state,
/// etc.); it does not recreate it. Consumers downcast `Frame.metadata` to this
/// type at the camera-source boundary.
public struct CameraFrameMetadata: FrameMetadata {
    public init() {}
}
