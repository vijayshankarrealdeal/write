// Integration test for the per-project page-layout setting added
// in P2 #8.
//
// Two round-trips:
//   (1) PageLayoutSettings.toJson → fromJson preserves every
//       configurable field, including the named PageSize / PageFont
//       enums.
//   (2) WritingModel.toJson → fromJson preserves nested page
//       layout, mirroring how the local Hive cache stores it.
//   (3) An updateWritingProject outbox op carrying `page_layout`
//       drains through to the SyncDispatcher with the snake-case
//       payload the backend expects.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:inkspacex/models/page_layout_settings.dart';
import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/services/connectivity_service.dart';
import 'package:inkspacex/services/sync/outbox.dart';
import 'package:inkspacex/services/sync/outbox_drainer.dart';
import 'package:inkspacex/services/sync/pending_op.dart';

import '_helpers.dart';

void main() {
  group('PageLayoutSettings JSON round-trip', () {
    test('default preserves every configurable field', () {
      final original = PageLayoutSettings.standard;
      final round = PageLayoutSettings.fromJson(original.toJson());
      expect(round.size, original.size);
      expect(round.widthIn, original.widthIn);
      expect(round.heightIn, original.heightIn);
      expect(round.marginTopIn, original.marginTopIn);
      expect(round.marginBottomIn, original.marginBottomIn);
      expect(round.marginLeftIn, original.marginLeftIn);
      expect(round.marginRightIn, original.marginRightIn);
      expect(round.font, original.font);
      expect(round.fontSizePt, original.fontSizePt);
      expect(round.lineHeight, original.lineHeight);
    });

    test('A4 + custom font + tight margins survive toJson/fromJson', () {
      final original = PageLayoutSettings.standard.copyWith(
        size: PageSize.a4,
        widthIn: 210 / 25.4,
        heightIn: 297 / 25.4,
        marginTopIn: 0.5,
        marginBottomIn: 0.6,
        marginLeftIn: 0.75,
        marginRightIn: 0.85,
        font: PageFont.lora,
        fontSizePt: 11,
        lineHeight: 1.7,
      );
      final round = PageLayoutSettings.fromJson(original.toJson());
      expect(round.size, PageSize.a4);
      expect(round.font, PageFont.lora);
      expect(round.fontSizePt, 11);
      expect(round.lineHeight, 1.7);
      expect(round.marginLeftIn, 0.75);
    });

    test('unknown enum names fall back to defaults', () {
      final round = PageLayoutSettings.fromJson({
        'size': 'tabloid',
        'font': 'comic_sans',
        'fontSizePt': 12,
      });
      expect(round.size, PageLayoutSettings.standard.size);
      expect(round.font, PageLayoutSettings.standard.font);
      expect(round.fontSizePt, 12);
    });
  });

  group('WritingModel JSON nests pageLayout end-to-end', () {
    test('book without pageLayout serializes pageLayout as null', () {
      final book = WritingModel(
        id: 'w1',
        title: 'Untitled',
        author: 'Test',
        description: '',
        coverImagePath: '',
        writingType: WritingType.creative,
        subtype: 'shortStory',
        sections: const [],
      );
      final json = book.toJson();
      expect(json.containsKey('pageLayout'), isTrue);
      expect(json['pageLayout'], isNull);
      final restored = WritingModel.fromJson(json);
      expect(restored.pageLayout, isNull);
    });

    test('book with pageLayout round-trips through Hive-shaped JSON', () {
      final settings = PageLayoutSettings.standard.copyWith(
        size: PageSize.a4,
        font: PageFont.sourceSerif,
        fontSizePt: 13,
      );
      final book = WritingModel(
        id: 'w2',
        title: 'A4 manuscript',
        author: 'Test',
        description: '',
        coverImagePath: '',
        writingType: WritingType.creative,
        subtype: 'shortStory',
        sections: const [],
        pageLayout: settings,
      );
      final round = WritingModel.fromJson(book.toJson());
      expect(round.pageLayout, isNotNull);
      expect(round.pageLayout!.size, PageSize.a4);
      expect(round.pageLayout!.font, PageFont.sourceSerif);
      expect(round.pageLayout!.fontSizePt, 13);
    });

    test('snake_case backend response decodes into pageLayout', () {
      final book = WritingModel(
        id: 'w3',
        title: 'From server',
        author: 'Test',
        description: '',
        coverImagePath: '',
        writingType: WritingType.creative,
        subtype: 'shortStory',
        sections: const [],
      );
      final hybrid = book.toJson()
        ..remove('pageLayout')
        // The api decoder rebuilds WritingModel via its own
        // factory, but the local cache may persist a snake-case
        // copy after a manual "Reload from server" — make sure
        // both shapes decode.
        ..['page_layout'] =
            PageLayoutSettings.standard.copyWith(size: PageSize.a4).toJson();
      final round = WritingModel.fromJson(hybrid);
      expect(round.pageLayout, isNotNull);
      expect(round.pageLayout!.size, PageSize.a4);
    });
  });

  group('Outbox drain — updateWritingProject with page_layout', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('page_layout_test_');
      Hive.init(tmp.path);
    });

    tearDown(() async {
      await Hive.close();
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });

    test('queued op carrying page_layout drains to updateWritingProjectFields',
        () async {
      final outbox = Outbox(boxName: 'page_layout_drain');
      await outbox.init();
      final connectivity = ConnectivityService()..debugSet(true);
      final dispatcher = RecordingDispatcher();
      final drainer = OutboxDrainer(
        outbox: outbox,
        dataService: dispatcher,
        connectivity: connectivity,
      );

      final settings = PageLayoutSettings.standard.copyWith(
        size: PageSize.a4,
        font: PageFont.lora,
      );
      await outbox.enqueue(PendingOp(
        kind: PendingOpKind.updateWritingProject,
        payload: {
          'writingId': 'w-page-layout',
          'fields': {'page_layout': settings.toJson()},
        },
      ));

      await drainer.drain();

      expect(dispatcher.calls,
          contains('updateWritingProjectFields:w-page-layout'));
      expect(outbox.isEmpty, isTrue);

      await drainer.dispose();
      await outbox.dispose();
      await connectivity.dispose();
    });
  });
}
