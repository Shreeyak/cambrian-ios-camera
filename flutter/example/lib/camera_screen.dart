import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';
import 'widgets/control_bar.dart';
import 'widgets/permission_gate.dart';
import 'widgets/preview_widget.dart';
import 'widgets/status_bar.dart';

/// Single-screen demo: PermissionGate over a PreviewWidget, with a StatusBar
/// (top) and ControlBar (bottom). Owns one CameraEngine for its lifetime.
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  final CameraEngine _engine = CameraEngine();
  SessionCapabilities? _caps;
  SessionState _state = SessionState.closed;
  bool _isRecording = false;
  DateTime? _recordingStartedAt;
  Timer? _ticker;
  int? _isoCurrent;
  StreamSubscription<SessionState>? _stateSub;
  StreamSubscription<FrameResult>? _frameSub;
  StreamSubscription<RecordingStateValue>? _recSub;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final caps = await _engine.open();
      if (!mounted) return;
      setState(() => _caps = caps);
      _stateSub = _engine.stateStream().listen((s) {
        if (mounted) setState(() => _state = s);
      });
      // Seed the status from the camera's actual current state (fresh read, not
      // a replay) — covers the case where open() already reached `streaming`
      // before this subscription. Live transitions then update it.
      _engine.currentState().then((s) {
        if (mounted) setState(() => _state = s);
      }).catchError((_) {});
      _frameSub = _engine.frameResultStream().listen((f) {
        if (mounted) setState(() => _isoCurrent = f.iso);
      });
      _recSub = _engine.recordingStateStream().listen((r) {
        if (!mounted) return;
        setState(() => _isRecording = r.kind == RecordingStateKind.recording);
      });
      _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
        if (mounted) setState(() {});
      });
    } on CameraException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('open failed: $e')));
    }
  }

  Future<void> _capture() async {
    try {
      final path =
          await _engine.captureImage(photosDestination: PhotosDestination.copy);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Saved: $path')));
    } on CameraException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Capture failed: $e')));
    }
  }

  Future<void> _toggleRecording() async {
    try {
      if (_isRecording) {
        await _engine.stopRecording();
      } else {
        final s = await _engine.startRecording(RecordingOptions(
          fps: 30,
          photosDestination: PhotosDestination.copy,
        ));
        _recordingStartedAt = DateTime.now();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Recording → ${s.displayName}')));
      }
    } on CameraException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Recording failed: $e')));
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _stateSub?.cancel();
    _frameSub?.cancel();
    _recSub?.cancel();
    _engine.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final caps = _caps;
    return Scaffold(
      body: PermissionGate(
        granted: caps == null
            ? const Center(child: CircularProgressIndicator())
            : Stack(children: [
                Positioned.fill(child: PreviewWidget(engine: _engine)),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: SafeArea(
                    child: StatusBar(
                      state: _state,
                      isRecording: _isRecording,
                      recordingDuration:
                          _isRecording && _recordingStartedAt != null
                              ? DateTime.now().difference(_recordingStartedAt!)
                              : Duration.zero,
                      frameIsoCurrent: _isoCurrent,
                    ),
                  ),
                ),
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: SafeArea(
                    child: ControlBar(
                      engine: _engine,
                      caps: caps,
                      isRecording: _isRecording,
                      onCaptureImage: _capture,
                      onToggleRecording: _toggleRecording,
                    ),
                  ),
                ),
              ]),
      ),
    );
  }
}
