import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:desktop/main.dart';

void main() {
  testWidgets('CamSyncDesktopApp basic smoke test', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(const CamSyncDesktopApp(autoStartUsb: false));
    expect(find.text('CamSync Studio'), findsOneWidget);
    expect(find.text('STUDIO CAMERA CONTROLS'), findsOneWidget);
  });
}
