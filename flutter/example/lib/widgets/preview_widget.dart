import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

/// Renders the processed-lane preview texture once it is created, swapping to a
/// "No signal" placeholder whenever the session isn't actively producing frames.
class PreviewWidget extends StatefulWidget {
  final CameraEngine engine;
  const PreviewWidget({super.key, required this.engine});
  @override
  State<PreviewWidget> createState() => _PreviewWidgetState();
}

class _PreviewWidgetState extends State<PreviewWidget> {
  int? _textureId;
  StreamSubscription<SessionState>? _stateSub;
  SessionState _lastState = SessionState.closed;

  @override
  void initState() {
    super.initState();
    _stateSub = widget.engine.stateStream().listen((s) {
      if (mounted) setState(() => _lastState = s);
    });
    widget.engine.createPreviewTexture(stream: StreamId.processed).then((id) {
      if (mounted) setState(() => _textureId = id);
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
    if (id == null) return const Center(child: CircularProgressIndicator());
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
