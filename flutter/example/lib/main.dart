import 'package:flutter/material.dart';
import 'camera_screen.dart';

void main() => runApp(const _App());

class _App extends StatelessWidget {
  const _App();
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'cambrian_ios_camera example',
        theme: ThemeData.dark(),
        home: const CameraScreen(),
      );
}
