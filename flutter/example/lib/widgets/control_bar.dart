import 'package:flutter/material.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';
import 'settings_sheet.dart';
import 'calibration_dialog.dart';

/// Bottom toolbar: capture, record/stop, settings, calibrate.
class ControlBar extends StatelessWidget {
  final CameraEngine engine;
  final SessionCapabilities caps;
  final bool isRecording;
  final VoidCallback onToggleRecording;
  final VoidCallback onCaptureImage;
  const ControlBar({
    super.key,
    required this.engine,
    required this.caps,
    required this.isRecording,
    required this.onToggleRecording,
    required this.onCaptureImage,
  });

  @override
  Widget build(BuildContext context) => Container(
        height: 80,
        color: Colors.black87,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            IconButton(
              icon: const Icon(Icons.camera, color: Colors.white, size: 32),
              tooltip: 'Capture',
              onPressed: onCaptureImage,
            ),
            IconButton(
              icon: Icon(
                  isRecording ? Icons.stop : Icons.fiber_manual_record,
                  color: isRecording ? Colors.white : Colors.red,
                  size: 36),
              tooltip: isRecording ? 'Stop recording' : 'Record',
              onPressed: onToggleRecording,
            ),
            IconButton(
              icon: const Icon(Icons.settings, color: Colors.white, size: 28),
              tooltip: 'Settings',
              onPressed: () => SettingsSheet.show(context, engine, caps),
            ),
            IconButton(
              icon: const Icon(Icons.build, color: Colors.white, size: 28),
              tooltip: 'Calibrate',
              onPressed: () => CalibrationDialog.show(context, engine),
            ),
          ],
        ),
      );
}
