import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:inkspacex/models/comment_model.dart';
import 'package:inkspacex/services/api/api_data_service.dart';

CommentModel _c(String id, String text) => CommentModel(
      id: id,
      feedItemId: 'feed-1',
      authorId: 'u1',
      authorName: 'Test',
      text: text,
      createdAt: DateTime.utc(2026, 4, 26),
    );

void main() {
  test('polling stream emits when comments change, suppresses duplicates',
      () async {
    final responses = <List<CommentModel>>[
      [_c('1', 'hello')],
      [_c('1', 'hello')], // identical: should NOT be re-emitted
      [_c('1', 'hello'), _c('2', 'new comment')],
      [_c('1', 'hello'), _c('2', 'new comment')], // duplicate again
      [_c('2', 'new comment')], // a removal
    ];
    var i = 0;
    Future<List<CommentModel>> fetch() async {
      final next = responses[i.clamp(0, responses.length - 1)];
      i++;
      return next;
    }

    final stream = ApiDataService.pollComments(
      interval: const Duration(milliseconds: 5),
      fetch: fetch,
    );

    final emissions = <List<CommentModel>>[];
    final sub = stream.listen(emissions.add);

    // Wait long enough for all five fetches plus their interval ticks.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    await sub.cancel();

    // Expect three distinct emissions: initial, +new comment, removal.
    expect(emissions.length, greaterThanOrEqualTo(3));
    expect(emissions.first.length, 1);
    expect(emissions[1].map((c) => c.id), containsAll(['1', '2']));
    expect(emissions[2].single.id, '2');
  });

  test('subscription cancellation stops further fetches', () async {
    var fetchCount = 0;
    Future<List<CommentModel>> fetch() async {
      fetchCount++;
      return [_c('$fetchCount', 'msg')];
    }

    final stream = ApiDataService.pollComments(
      interval: const Duration(milliseconds: 5),
      fetch: fetch,
    );
    final sub = stream.listen((_) {});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final beforeCancel = fetchCount;
    await sub.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    // Allow a small race window: at most one extra fetch may have been
    // in-flight when we cancelled.
    expect(fetchCount - beforeCancel, lessThanOrEqualTo(1));
  });
}
