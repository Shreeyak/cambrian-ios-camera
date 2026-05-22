import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

void main() {
  group('CameraException', () {
    test('constructs with code, message, isFatal', () {
      final e = CameraException(
        code: CameraErrorCode.frameStall,
        message: 'no frame in 800ms',
        isFatal: false,
      );
      expect(e.code, CameraErrorCode.frameStall);
      expect(e.message, 'no frame in 800ms');
      expect(e.isFatal, false);
    });

    test('toString includes code name and message', () {
      final e = CameraException(
        code: CameraErrorCode.cameraInUse,
        message: 'busy',
        isFatal: false,
      );
      expect(e.toString(), contains('cameraInUse'));
      expect(e.toString(), contains('busy'));
    });

    test('toString flags fatal', () {
      final e = CameraException(
        code: CameraErrorCode.hardwareError,
        message: 'oops',
        isFatal: true,
      );
      expect(e.toString(), contains('FATAL'));
    });
  });

  group('CameraException.fromPlatformException', () {
    test('parses known code string', () {
      final pe = PlatformException(
        code: 'frameStall',
        message: 'watchdog fired',
        details: {'isFatal': false},
      );
      final ce = CameraException.fromPlatformException(pe);
      expect(ce.code, CameraErrorCode.frameStall);
      expect(ce.message, 'watchdog fired');
      expect(ce.isFatal, false);
    });

    test('unknown code maps to .unknownError, preserves original code in message',
        () {
      final pe = PlatformException(
        code: 'someNewCodeFromFutureVersion',
        message: 'thing happened',
      );
      final ce = CameraException.fromPlatformException(pe);
      expect(ce.code, CameraErrorCode.unknownError);
      expect(ce.message, contains('someNewCodeFromFutureVersion'));
      expect(ce.message, contains('thing happened'));
      expect(ce.isFatal, false);
    });

    test('missing details maps isFatal to false', () {
      final pe = PlatformException(code: 'frameStall', message: 'x');
      final ce = CameraException.fromPlatformException(pe);
      expect(ce.isFatal, false);
    });

    test('details with isFatal true', () {
      final pe = PlatformException(
        code: 'hardwareError',
        message: 'x',
        details: {'isFatal': true},
      );
      expect(CameraException.fromPlatformException(pe).isFatal, true);
    });
  });

  group('CameraErrorCode parsing', () {
    test('parses each known case via byName', () {
      for (final c in CameraErrorCode.values) {
        expect(parseCameraErrorCode(c.name), c);
      }
    });
    test('unknown string returns unknownError', () {
      expect(parseCameraErrorCode('garbage'), CameraErrorCode.unknownError);
    });
  });
}
