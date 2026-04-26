import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/provider/feed_provider.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/ui/widgets/feed_filter_chip_row.dart';

Widget _wrap(FeedProvider feed, Widget child) {
  return ChangeNotifierProvider<FeedProvider>.value(
    value: feed,
    child: MaterialApp(
      home: Scaffold(body: child),
    ),
  );
}

const _facets = FeedFacets(
  genres: [
    FacetEntry(value: 'Fiction', count: 12),
    FacetEntry(value: 'Essay', count: 4),
  ],
  tags: [FacetEntry(value: 'noir', count: 3)],
  writingTypes: [FacetEntry(value: 'Story', count: 7)],
);

void main() {
  testWidgets('renders nothing when no facets and no active filters',
      (tester) async {
    final feed = FeedProvider();
    await tester.pumpWidget(_wrap(
      feed,
      FeedFilterChipRow(
        loader: () async => const FeedFacets(
          genres: [],
          tags: [],
          writingTypes: [],
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Bar collapses entirely so it doesn't take vertical space when
    // there's nothing to show.
    expect(find.text('Filters'), findsNothing);
    expect(find.text('Clear all'), findsNothing);
  });

  testWidgets('renders a Filters affordance and a chip per facet',
      (tester) async {
    final feed = FeedProvider();
    await tester.pumpWidget(_wrap(
      feed,
      FeedFilterChipRow(loader: () async => _facets),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Filters'), findsOneWidget);
    expect(find.text('Fiction'), findsOneWidget);
    expect(find.text('#noir'), findsOneWidget);
    expect(find.text('Story'), findsOneWidget);
    // No active filters → no Clear all chip yet.
    expect(find.text('Clear all'), findsNothing);
  });

  testWidgets('tapping a chip toggles the corresponding filter on the provider',
      (tester) async {
    final feed = FeedProvider();
    await tester.pumpWidget(_wrap(
      feed,
      FeedFilterChipRow(loader: () async => _facets),
    ));
    await tester.pumpAndSettle();

    expect(feed.hasActiveFilters, isFalse);

    await tester.tap(find.text('Fiction'));
    await tester.pump();

    expect(feed.filterGenres.contains('Fiction'), isTrue);
    expect(feed.hasActiveFilters, isTrue);
    // Active filters surface the Clear-all affordance.
    expect(find.text('Clear all'), findsOneWidget);
    // Filters chip shows count when filters are active.
    expect(find.text('Filters · 1'), findsOneWidget);

    await tester.tap(find.text('Fiction'));
    await tester.pump();

    expect(feed.filterGenres.contains('Fiction'), isFalse);
    expect(feed.hasActiveFilters, isFalse);
  });

  testWidgets('Clear all wipes every active filter at once', (tester) async {
    final feed = FeedProvider();
    feed.toggleFilter('genre', 'Fiction');
    feed.toggleFilter('tag', 'noir');

    await tester.pumpWidget(_wrap(
      feed,
      FeedFilterChipRow(loader: () async => _facets),
    ));
    await tester.pumpAndSettle();

    expect(feed.hasActiveFilters, isTrue);

    await tester.tap(find.text('Clear all'));
    await tester.pump();

    expect(feed.hasActiveFilters, isFalse);
    expect(feed.filterGenres, isEmpty);
    expect(feed.filterTags, isEmpty);
  });
}
