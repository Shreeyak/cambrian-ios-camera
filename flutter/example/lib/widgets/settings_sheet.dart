import 'package:flutter/material.dart';
import 'package:cambrian_ios_camera/cambrian_ios_camera.dart';

/// Modal bottom sheet with ISO / exposure / focus / EV sliders bounded by the
/// session's `SessionCapabilities`, applied via `engine.updateSettings`.
class SettingsSheet extends StatefulWidget {
  final CameraEngine engine;
  final SessionCapabilities caps;
  const SettingsSheet({super.key, required this.engine, required this.caps});

  static Future<void> show(
          BuildContext context, CameraEngine engine, SessionCapabilities caps) =>
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        builder: (_) => SettingsSheet(engine: engine, caps: caps),
      );

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  double? _iso;
  double? _expNs;
  double? _focus;
  double? _evComp;

  @override
  void initState() {
    super.initState();
    widget.engine.currentSettings().then((s) {
      if (!mounted) return;
      // s may be null (engine not reporting settings yet) — still seed every
      // control from capability defaults so the sheet renders instead of
      // hanging on the spinner.
      setState(() {
        _iso = s?.iso?.toDouble() ?? widget.caps.isoMin;
        _expNs = s?.exposureTimeNs?.toDouble() ??
            widget.caps.exposureDurationMinNs.toDouble();
        _focus = s?.focusDistance ?? widget.caps.focusMin;
        _evComp = s?.evCompensation?.toDouble() ?? 0;
      });
    });
  }

  Future<void> _apply() async {
    final s = CameraSettings(
      iso: _iso?.round(),
      exposureTimeNs: _expNs?.round(),
      focusDistance: _focus,
      evCompensation: _evComp?.round(),
    );
    await widget.engine.updateSettings(s);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    if (_iso == null) {
      return const SizedBox(
          height: 100, child: Center(child: CircularProgressIndicator()));
    }
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        _row('ISO', _iso!, widget.caps.isoMin, widget.caps.isoMax,
            (v) => setState(() => _iso = v)),
        _row(
            'Exposure (ns)',
            _expNs!,
            widget.caps.exposureDurationMinNs.toDouble(),
            widget.caps.exposureDurationMaxNs.toDouble(),
            (v) => setState(() => _expNs = v)),
        _row('Focus', _focus!, widget.caps.focusMin, widget.caps.focusMax,
            (v) => setState(() => _focus = v)),
        _row('EV', _evComp!, widget.caps.evMin, widget.caps.evMax,
            (v) => setState(() => _evComp = v)),
        Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel')),
          FilledButton(onPressed: _apply, child: const Text('Apply')),
        ]),
        const SizedBox(height: 16),
      ]),
    );
  }

  Widget _row(String label, double value, double min, double max,
          ValueChanged<double> onChanged) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(children: [
          SizedBox(width: 100, child: Text(label)),
          Expanded(
              child: Slider(
                  value: value.clamp(min, max),
                  min: min,
                  max: max,
                  onChanged: onChanged)),
          SizedBox(width: 80, child: Text(value.toStringAsFixed(1))),
        ]),
      );
}
