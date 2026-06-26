import 'package:flutter/material.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

/// Modal dialog with white-balance + black-point buttons. White balance shows
/// the most-recent `CalibrationResult`; black point shows a success/failure
/// message (it returns nothing, throwing on failure).
class CalibrationDialog extends StatefulWidget {
  final CameraEngine engine;
  const CalibrationDialog({super.key, required this.engine});

  static Future<void> show(BuildContext context, CameraEngine engine) =>
      showDialog(
          context: context, builder: (_) => CalibrationDialog(engine: engine));

  @override
  State<CalibrationDialog> createState() => _CalibrationDialogState();
}

class _CalibrationDialogState extends State<CalibrationDialog> {
  CalibrationResult? _last;
  String? _lastKind;
  String? _message;
  bool _busy = false;

  Future<void> _doWB() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final r = await widget.engine.calibrateWhiteBalance();
      if (mounted) {
        setState(() {
          _last = r;
          _lastKind = 'White balance';
        });
      }
    } finally {
      // Always clear _busy, even if calibration threw — otherwise the spinner
      // hangs and both buttons stay disabled forever.
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _doBlack() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await widget.engine.calibrateBlackPoint();
      if (mounted) {
        setState(() {
          _last = null;
          _lastKind = null;
          _message = 'Black point calibrated.';
        });
      }
    } on CameraException catch (e) {
      if (mounted) {
        setState(() => _message = 'Black point failed: ${e.message}');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Calibration'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          if (_busy) const CircularProgressIndicator(),
          if (!_busy && _last != null)
            _ResultView(kind: _lastKind!, r: _last!),
          if (!_busy && _message != null) Text(_message!),
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            FilledButton(
                onPressed: _busy ? null : _doWB,
                child: const Text('White balance')),
            FilledButton(
                onPressed: _busy ? null : _doBlack,
                child: const Text('Black point')),
          ]),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'))
        ],
      );
}

class _ResultView extends StatelessWidget {
  final String kind;
  final CalibrationResult r;
  const _ResultView({required this.kind, required this.r});
  @override
  Widget build(BuildContext context) =>
      Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
            '$kind — ${r.converged ? "converged" : "did not converge"} in ${r.iterations} iter'),
        Text(
            'Before: R=${r.before.r.toStringAsFixed(3)} G=${r.before.g.toStringAsFixed(3)} B=${r.before.b.toStringAsFixed(3)}'),
        Text(
            'After:  R=${r.after.r.toStringAsFixed(3)} G=${r.after.g.toStringAsFixed(3)} B=${r.after.b.toStringAsFixed(3)}'),
      ]);
}
