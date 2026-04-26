import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inkspacex/models/feed_item_model.dart';
import 'package:inkspacex/ui/widgets/more_like_this_carousel.dart';

FeedItemModel _item(String id, String title) {
  final now = DateTime.now();
  return FeedItemModel(
    id: id,
    title: title,
    author: 'Author $id',
    authorId: 'a$id',
    description: '',
    imageUrl: '',
    createdAt: now,
    updatedAt: now,
  );
}

Widget _wrap(Widget child) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: child),
      ),
    );

void main() {
  testWidgets('hides itself when the loader returns an empty list',
      (tester) async {
    await tester.pumpWidget(_wrap(MoreLikeThisCarousel(
      feedItemId: 'seed-1',
      isDark: false,
      textColor: Colors.black,
      subtleColor: Colors.black54,
      loader: (_) async => const <FeedItemModel>[],
    )));
    // Drain the future + post-frame callbacks.
    await tester.pumpAndSettle();

    // No header, no card — the carousel collapses to SizedBox.shrink.
    expect(find.text('More like this'), findsNothing);
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('renders the header and a card per result when populated',
      (tester) async {
    await tester.pumpWidget(_wrap(MoreLikeThisCarousel(
      feedItemId: 'seed-1',
      isDark: false,
      textColor: Colors.black,
      subtleColor: Colors.black54,
      loader: (_) async => [
        _item('a', 'First Match'),
        _item('b', 'Second Match'),
      ],
    )));
    await tester.pumpAndSettle();

    expect(find.text('More like this'), findsOneWidget);
    expect(find.text('First Match'), findsOneWidget);
    expect(find.text('Second Match'), findsOneWidget);
  });

  testWidgets('shows nothing while the loader is still pending',
      (tester) async {
    final completer = Completer<List<FeedItemModel>>();
    await tester.pumpWidget(_wrap(MoreLikeThisCarousel(
      feedItemId: 'seed-1',
      isDark: false,
      textColor: Colors.black,
      subtleColor: Colors.black54,
      loader: (_) => completer.future,
    )));
    // Loader is unresolved — no header, no skeleton.
    expect(find.text('More like this'), findsNothing);
    completer.complete(const <FeedItemModel>[]);
    await tester.pumpAndSettle();
  });
}
