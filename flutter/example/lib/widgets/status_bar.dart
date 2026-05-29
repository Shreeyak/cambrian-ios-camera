import 'package:flutter/material.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

/// Top overlay: a colored SessionState dot + name, REC + mm:ss while recording,
/// and the current ISO from the latest FrameResult.
class StatusBar extends StatelessWidget {
  final SessionState state;
  final bool isRecording;
  final Duration recordingDuration;
  final int? frameIsoCurrent;
  const StatusBar({
    super.key,
    required this.state,
    required this.isRecording,
    required this.recordingDuration,
    required this.frameIsoCurrent,
  });

  Color _stateColor() => switch (state) {
        SessionState.streaming => Colors.green,
        SessionState.paused => Colors.yellow,
        SessionState.interrupted => Colors.orange,
        SessionState.recovering => Colors.orange,
        SessionState.error => Colors.red,
        SessionState.opening => Colors.blue,
        SessionState.closed => Colors.grey,
      };

  String _fmtDur() {
    final s = recordingDuration.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => Container(
        height: 36,
        color: Colors.black54,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          Container(
            width: 10,
            height: 10,
            decoration:
                BoxDecoration(color: _stateColor(), shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(state.name, style: const TextStyle(color: Colors.white)),
          const Spacer(),
          if (isRecording) ...[
            const Icon(Icons.fiber_manual_record, color: Colors.red, size: 14),
            const SizedBox(width: 4),
            Text(_fmtDur(), style: const TextStyle(color: Colors.white)),
            const SizedBox(width: 16),
          ],
          if (frameIsoCurrent != null)
            Text('ISO $frameIsoCurrent',
                style: const TextStyle(color: Colors.white70)),
        ]),
      );
}
