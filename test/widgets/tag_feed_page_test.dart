import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/services/api/api_data_service.dart';
import 'package:inkspacex/ui/pages/tag_feed_page.dart';

FeedItemModel _item(String id, String title) {
  final now = DateTime.now();
  return FeedItemModel(
    id: id,
    title: title,
    author: 'Author $id',
    authorId: 'a$id',
    description: 'Body of $title',
    imageUrl: '',
    createdAt: now,
    updatedAt: now,
  );
}

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  testWidgets('renders the empty-state when the loader returns no items',
      (tester) async {
    await tester.pumpWidget(_wrap(TagFeedPage(
      kind: TagFeedKind.tag,
      value: 'mystery',
      loader: ({required sort, cursor}) async =>
          const ApiFeedPage(items: <FeedItemModel>[]),
    )));
    await tester.pumpAndSettle();

    expect(find.text('Nothing here yet'), findsOneWidget);
    expect(find.textContaining('mystery'), findsWidgets);
  });

  testWidgets('renders one card per item the loader returns', (tester) async {
    await tester.pumpWidget(_wrap(TagFeedPage(
      kind: TagFeedKind.genre,
      value: 'Fiction',
      loader: ({required sort, cursor}) async => ApiFeedPage(
        items: [_item('1', 'First'), _item('2', 'Second')],
        nextCursor: '2',
      ),
    )));
    await tester.pumpAndSettle();

    expect(find.text('First'), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
    // Genre header (kind label) is shown alongside the value.
    expect(find.text('Genre'), findsOneWidget);
    expect(find.text('Fiction'), findsOneWidget);
  });

  testWidgets('switching sort triggers a reload through the loader',
      (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(_wrap(TagFeedPage(
      kind: TagFeedKind.tag,
      value: 'poetry',
      loader: ({required sort, cursor}) async {
        calls.add(sort);
        // Empty page keeps the body in the empty-state branch — no
        // RefreshIndicator viewport for the test framework to visit
        // mid-rebuild, which keeps `find.text` stable across the tap.
        return const ApiFeedPage(items: <FeedItemModel>[]);
      },
    )));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(calls, ['recent']);

    await tester.tap(find.text('Trending'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(calls, ['recent', 'trending']);
  });
}
