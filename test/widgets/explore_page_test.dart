import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/ui/pages/explore_page.dart';

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('shows the empty card when facets are empty', (tester) async {
    await tester.pumpWidget(_wrap(ExplorePage(
      loader: () async => const FeedFacets(
        genres: [],
        tags: [],
        writingTypes: [],
      ),
    )));
    await tester.pumpAndSettle();

    expect(find.text('Nothing to explore yet'), findsOneWidget);
  });

  testWidgets('renders one chip per facet entry, grouped by section',
      (tester) async {
    await tester.pumpWidget(_wrap(ExplorePage(
      loader: () async => const FeedFacets(
        genres: [
          FacetEntry(value: 'Fiction', count: 12),
          FacetEntry(value: 'Essay', count: 4),
        ],
        tags: [FacetEntry(value: 'noir', count: 3)],
        writingTypes: [FacetEntry(value: 'Story', count: 7)],
      ),
    )));
    await tester.pumpAndSettle();

    expect(find.text('Genres'), findsOneWidget);
    expect(find.text('Tags'), findsOneWidget);
    expect(find.text('Writing types'), findsOneWidget);
    expect(find.text('Fiction'), findsOneWidget);
    expect(find.text('Essay'), findsOneWidget);
    expect(find.text('#noir'), findsOneWidget);
    expect(find.text('Story'), findsOneWidget);
  });

  testWidgets('search filters chips client-side and surfaces "no matches"',
      (tester) async {
    await tester.pumpWidget(_wrap(ExplorePage(
      loader: () async => const FeedFacets(
        genres: [FacetEntry(value: 'Fiction', count: 1)],
        tags: [FacetEntry(value: 'noir', count: 1)],
        writingTypes: [],
      ),
    )));
    await tester.pumpAndSettle();

    // Both chips visible up front.
    expect(find.text('Fiction'), findsOneWidget);
    expect(find.text('#noir'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'fic');
    await tester.pump();

    expect(find.text('Fiction'), findsOneWidget);
    expect(find.text('#noir'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump();

    expect(find.text('No matches'), findsOneWidget);
  });
}
