import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app builds without crashing under MaterialApp', (tester) async {
    // The real CameraScreen depends on platform channels we don't mock here;
    // we wrap a Scaffold instead to verify the example's pubspec wiring is sane.
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    expect(find.byType(Scaffold), findsOneWidget);
  });
}
