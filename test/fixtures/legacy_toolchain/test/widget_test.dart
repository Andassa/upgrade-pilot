import 'package:flutter_test/flutter_test.dart';

import 'package:legacy_app/main.dart';

void main() {
  testWidgets('shows the greeting', (WidgetTester tester) async {
    await tester.pumpWidget(const MainApp());

    expect(find.text('Hello World!'), findsOneWidget);
  });
}
