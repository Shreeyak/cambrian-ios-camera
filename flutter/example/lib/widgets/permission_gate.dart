import 'package:flutter/material.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

/// Shows `granted` when camera permission is `.authorized`. Otherwise shows a
/// Grant button (on `.notDetermined`) that requests permission and re-renders,
/// or a Settings-required message (on `.denied` / `.restricted`).
class PermissionGate extends StatefulWidget {
  final Widget granted;
  const PermissionGate({super.key, required this.granted});
  @override
  State<PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<PermissionGate> {
  CameraPermissionStatus? _status;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final s = await Permissions.cameraPermissionStatus();
    if (mounted) setState(() => _status = s);
  }

  Future<void> _request() async {
    final s = await Permissions.requestCameraPermission();
    if (mounted) setState(() => _status = s);
  }

  @override
  Widget build(BuildContext context) {
    final s = _status;
    if (s == null) return const Center(child: CircularProgressIndicator());
    if (s == CameraPermissionStatus.authorized) return widget.granted;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(s == CameraPermissionStatus.denied ||
                  s == CameraPermissionStatus.restricted
              ? 'Camera permission denied. Enable in Settings.'
              : 'Camera permission required.'),
          const SizedBox(height: 16),
          if (s == CameraPermissionStatus.notDetermined)
            ElevatedButton(onPressed: _request, child: const Text('Grant')),
        ],
      ),
    );
  }
}
