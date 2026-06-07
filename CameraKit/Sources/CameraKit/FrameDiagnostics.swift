// MARK: - FrameDiagnostics (frame-metadata-signals)
//
// Builds the debug-only JSON payload carried on `FrameResult.diagnosticsJSON`
// (the ~3 Hz `frameResultStream`). This is NOT a control surface — it forwards
// heavyweight AF/WB/AE detail plus the grade params (formerly `ProcessingMetadata`)
// so a developer can inspect them without a rebuild. Anything a consumer branches
// on must be a typed field on `CameraFrameMetadata`, never parsed out of here.

/// Pure builder for the `FrameResult.diagnosticsJSON` debug payload.
///
/// Deterministic, fixed-key-order JSON (hand-emitted, not `JSONSerialization`,
/// so the output is stable and test-assertable). All inputs optional — absent
/// inputs simply omit their keys.
enum FrameDiagnostics {

    /// Emits a compact JSON object.
    ///
    /// Key order is fixed (sensor state, then grade params, then crop, then WB
    /// gains) for stable assertions.
    static func json(
        snapshot: DeviceStateSnapshot?,
        processing: ProcessingParameters?,
        crop: Rect?
    ) -> String {
        var fields: [(String, String)] = []

        if let s = snapshot {
            fields.append(("afAdjusting", s.isAdjustingFocus ? "true" : "false"))
            fields.append(("wbAdjusting", s.isAdjustingWhiteBalance ? "true" : "false"))
            fields.append(("aeAdjusting", s.isAdjustingExposure ? "true" : "false"))
        }
        if let p = processing {
            fields.append(("brightness", num(p.brightness)))
            fields.append(("contrast", num(p.contrast)))
            fields.append(("saturation", num(p.saturation)))
            fields.append(("gamma", num(p.gamma)))
            fields.append(("blackR", num(p.blackR)))
            fields.append(("blackG", num(p.blackG)))
            fields.append(("blackB", num(p.blackB)))
        }
        if let c = crop {
            fields.append(("cropX", String(c.x)))
            fields.append(("cropY", String(c.y)))
            fields.append(("cropW", String(c.width)))
            fields.append(("cropH", String(c.height)))
        }
        if let s = snapshot {
            fields.append(("wbGainR", num(Double(s.whiteBalanceGains.red))))
            fields.append(("wbGainG", num(Double(s.whiteBalanceGains.green))))
            fields.append(("wbGainB", num(Double(s.whiteBalanceGains.blue))))
        }

        let body = fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
        return "{\(body)}"
    }

    /// Formats a Double with up to 4 decimal places, trimming trailing zeros, so
    /// the JSON stays compact and stable (no locale, no exponent).
    private static func num(_ value: Double) -> String {
        var s = String(format: "%.4f", value)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}
