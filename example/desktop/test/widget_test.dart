import 'package:desktop_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('app renders with bottom navigation and Examples tab',
      (tester) async {
    await tester.pumpWidget(const MontyDesktopApp());

    expect(find.text('Monty Desktop Example'), findsOneWidget);
    expect(find.byType(BottomNavigationBar), findsOneWidget);
    expect(find.text('Examples'), findsOneWidget);
    expect(find.text('Sorting'), findsOneWidget);
    expect(find.text('TSP'), findsOneWidget);
    expect(find.text('Ladder'), findsOneWidget);

    // Examples tab is shown by default
    expect(find.text('Run'), findsOneWidget);
    expect(find.byType(DropdownButton<String>), findsOneWidget);
    expect(find.text('1. Expressions'), findsOneWidget);
  });

  testWidgets('Sorting tab renders with expected controls', (tester) async {
    await tester.pumpWidget(const MontyDesktopApp());

    // Tap the Sorting tab
    await tester.tap(find.text('Sorting'));
    await tester.pumpAndSettle();

    // Algorithm selector segments
    expect(find.text('Bubble'), findsOneWidget);
    expect(find.text('Selection'), findsOneWidget);
    expect(find.text('Insertion'), findsOneWidget);
    expect(find.text('Quick'), findsOneWidget);
    expect(find.text('Tim'), findsOneWidget);
    expect(find.text('Shell'), findsOneWidget);
    expect(find.text('Cocktail'), findsOneWidget);
    expect(find.text('Sleep'), findsOneWidget);

    // Size and Speed labels
    expect(find.text('Size:'), findsOneWidget);
    expect(find.text('Speed:'), findsOneWidget);

    // Start button (not sorting yet)
    expect(find.text('Start'), findsOneWidget);

    // Stats row
    expect(find.text('Comparisons: 0'), findsOneWidget);
    expect(find.text('Swaps: 0'), findsOneWidget);
    expect(find.text('Steps: 0'), findsOneWidget);

    // Status
    expect(find.text('Ready'), findsOneWidget);

    // Code preview
    expect(find.text('Python code'), findsOneWidget);
  });

  testWidgets('TSP tab renders with expected controls', (tester) async {
    await tester.pumpWidget(const MontyDesktopApp());

    // Tap the TSP tab
    await tester.tap(find.text('TSP'));
    await tester.pumpAndSettle();

    // Algorithm selector segments
    expect(find.text('Nearest Neighbor'), findsOneWidget);
    expect(find.text('2-opt'), findsOneWidget);

    // Cities and Speed labels
    expect(find.text('Cities:'), findsOneWidget);
    expect(find.text('Speed:'), findsOneWidget);

    // Start button
    expect(find.text('Start'), findsOneWidget);

    // Stats row
    expect(find.text('Distance: 0.0'), findsOneWidget);
    expect(find.text('Iterations: 0'), findsOneWidget);

    // Status
    expect(find.text('Ready'), findsOneWidget);

    // Code preview
    expect(find.text('Python code'), findsOneWidget);
  });

  testWidgets('Ladder tab renders with Run All button', (tester) async {
    await tester.pumpWidget(const MontyDesktopApp());

    // Tap the Ladder tab
    await tester.tap(find.text('Ladder'));
    await tester.pumpAndSettle();

    expect(find.text('Run All'), findsOneWidget);
  });
}
