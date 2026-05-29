import 'package:flutter/services.dart';

import 'pigeon/cambrian_ios_camera_api.g.dart' as g;

/// Mirror of the Pigeon-generated `CameraErrorCode` re-exported for ergonomic
/// imports.
///
/// The enum cases must match `flutter/pigeons/cambrian_ios_camera_api.dart`
/// 1:1; any addition there requires a matching addition in the DSL. (Exposed as
/// a typedef so consumers don't see the `g.` prefix.)
typedef CameraErrorCode = g.CameraErrorCode;

/// Typed exception thrown by every `CameraEngine` and `Permissions` method.
///
/// Caught from raw `PlatformException`s at the Dart facade boundary and
/// re-thrown so consumers never see an untyped exception. The `code` enum is
/// matched against the Swift adapter's error code (the case-name string).
class CameraException implements Exception {
  final CameraErrorCode code;
  final String message;
  final bool isFatal;

  const CameraException({
    required this.code,
    required this.message,
    required this.isFatal,
  });

  /// Wraps a raw `PlatformException` (the form Pigeon's `@async` methods throw
  /// on the Dart side).
  ///
  /// Unknown `code` strings map to `CameraErrorCode.unknownError` and the
  /// original string is preserved in `message` for forward-compat.
  factory CameraException.fromPlatformException(PlatformException e) {
    final parsed = parseCameraErrorCode(e.code);
    final message = parsed == CameraErrorCode.unknownError
        ? 'unknown adapter code "${e.code}": ${e.message ?? ""}'
        : (e.message ?? '');
    final details = e.details;
    final isFatal = details is Map && details['isFatal'] == true;
    return CameraException(code: parsed, message: message, isFatal: isFatal);
  }

  @override
  String toString() =>
      'CameraException(${code.name}): $message${isFatal ? " [FATAL]" : ""}';
}

/// Resolves a code-string to a `CameraErrorCode`, returning `.unknownError` if
/// no enum case matches (forward-compat with newer CameraKit versions adding
/// codes).
CameraErrorCode parseCameraErrorCode(String name) {
  for (final c in CameraErrorCode.values) {
    if (c.name == name) return c;
  }
  return CameraErrorCode.unknownError;
}
