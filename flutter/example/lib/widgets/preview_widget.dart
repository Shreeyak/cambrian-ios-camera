import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

/// Renders the primary-lane preview texture once it is created, swapping to a
/// "No signal" placeholder whenever the session isn't actively producing frames.
class PreviewWidget extends StatefulWidget {
  final CameraEngine engine;
  const PreviewWidget({super.key, required this.engine});
  @override
  State<PreviewWidget> createState() => _PreviewWidgetState();
}

class _PreviewWidgetState extends State<PreviewWidget> {
  int? _textureId;
  bool _textureCreateFailed = false;
  StreamSubscription<SessionState>? _stateSub;
  SessionState _lastState = SessionState.closed;

  @override
  void initState() {
    super.initState();
    // Observe live transitions...
    _stateSub = widget.engine.stateStream().listen((s) {
      if (mounted) setState(() => _lastState = s);
    });
    // ...and read the camera's ACTUAL current state once, now, so a preview
    // built after the engine already reached `streaming` renders immediately
    // instead of waiting for the next transition. A fresh read, not a replay —
    // a live transition arriving first simply supersedes it.
    widget.engine.currentState().then((s) {
      if (mounted) setState(() => _lastState = s);
    }).catchError((_) {});
    widget.engine.createPreviewTexture(stream: StreamId.primary).then((id) {
      if (mounted) setState(() => _textureId = id);
    }).catchError((Object _) {
      // createPreviewTexture shouldn't fail on iOS, but if it does, drop the
      // spinner and show the placeholder rather than hang on it forever.
      if (mounted) setState(() => _textureCreateFailed = true);
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    final id = _textureId;
    if (id != null) widget.engine.destroyPreviewTexture(id);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final id = _textureId;
    if (id == null) {
      return _textureCreateFailed
          ? const _NoSignal()
          : const Center(child: CircularProgressIndicator());
    }
    final isRendering = _lastState == SessionState.streaming ||
        _lastState == SessionState.paused;
    return isRendering ? Texture(textureId: id) : const _NoSignal();
  }
}

class _NoSignal extends StatelessWidget {
  const _NoSignal();
  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Text('No signal',
              style: TextStyle(color: Colors.white60, fontSize: 16)),
        ),
      );
}
