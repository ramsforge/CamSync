import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/main.dart';

void main() {
  testWidgets('CamSyncMobileApp basic smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const CamSyncMobileApp());
    expect(find.text('CamSync'), findsOneWidget);
  });
}
