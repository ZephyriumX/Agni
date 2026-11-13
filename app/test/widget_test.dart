
import 'package:flutter_test/flutter_test.dart';
import 'package:agni_pulse/main.dart';

void main() {
  testWidgets('Agni-Pulse application launches', (WidgetTester tester) async {
    await tester.pumpWidget(const AgniPulseApp());

    expect(find.text('Agni-Pulse'), findsOneWidget);
    expect(
      find.text('Vascular & autonomic check using your phone camera.'),
      findsOneWidget,
    );
  });
}
