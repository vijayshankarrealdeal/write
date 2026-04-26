import 'package:flutter_test/flutter_test.dart';

import 'package:inkspacex/provider/feed_provider.dart';

void main() {
  test('toggleFilter switches a value on then off without a data service',
      () {
    final feed = FeedProvider();
    expect(feed.hasActiveFilters, isFalse);

    feed.toggleFilter('genre', 'Fiction');
    expect(feed.filterGenres, contains('Fiction'));
    expect(feed.hasActiveFilters, isTrue);

    feed.toggleFilter('genre', 'Fiction');
    expect(feed.filterGenres, isEmpty);
    expect(feed.hasActiveFilters, isFalse);
  });

  test('filters across all three columns coexist', () {
    final feed = FeedProvider();
    feed.toggleFilter('genre', 'Fiction');
    feed.toggleFilter('tag', 'noir');
    feed.toggleFilter('type', 'Story');

    expect(feed.filterGenres, {'Fiction'});
    expect(feed.filterTags, {'noir'});
    expect(feed.filterWritingTypes, {'Story'});
    expect(feed.hasActiveFilters, isTrue);
  });

  test('clearFilters wipes every column at once', () {
    final feed = FeedProvider();
    feed.toggleFilter('genre', 'Fiction');
    feed.toggleFilter('tag', 'noir');
    expect(feed.hasActiveFilters, isTrue);

    feed.clearFilters();

    expect(feed.filterGenres, isEmpty);
    expect(feed.filterTags, isEmpty);
    expect(feed.filterWritingTypes, isEmpty);
    expect(feed.hasActiveFilters, isFalse);
  });

  test('toggleFilter ignores unknown kinds (defensive)', () {
    final feed = FeedProvider();
    feed.toggleFilter('writing_type', 'ignored');
    feed.toggleFilter('', '');
    expect(feed.hasActiveFilters, isFalse);
  });

  test('removing the last filter resets the filtered list state', () {
    final feed = FeedProvider();
    feed.toggleFilter('genre', 'Fiction');
    feed.toggleFilter('tag', 'noir');
    feed.toggleFilter('genre', 'Fiction'); // back to one
    feed.toggleFilter('tag', 'noir'); // back to none

    expect(feed.filteredItems, isEmpty);
    expect(feed.isLoadingFiltered, isFalse);
    expect(feed.hasMoreFiltered, isTrue);
    expect(feed.filteredError, isNull);
  });

  test('exposed filter sets are unmodifiable views', () {
    final feed = FeedProvider();
    feed.toggleFilter('genre', 'Fiction');
    expect(
      () => feed.filterGenres.add('Drama'),
      throwsA(isA<UnsupportedError>()),
    );
  });
}
