import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:provider/provider.dart';

import 'package:inkspacex/provider/linguistic_focus_provider.dart';
import 'package:inkspacex/services/api/api_client.dart';
import 'package:inkspacex/services/linguistic_focus_service.dart';
import 'package:inkspacex/services/storage_service.dart';
import 'package:inkspacex/ui/pages/editor_page_entry/writing_page/linguistic_focus_chip.dart';

class _FakeService extends LinguisticFocusService {
  _FakeService(super.api);

  @override
  Future<LinguisticTagResult> tag(
    String text, {
    Iterable<String> classes = LinguisticClass.all,
  }) async {
    // Pretend the doc has 4 adverbs and 2 dialogue spans.
    return const LinguisticTagResult(
      dialogue: [
        LinguisticSpan(start: 0, length: 5),
        LinguisticSpan(start: 10, length: 5),
      ],
      adverbs: [
        LinguisticSpan(start: 0, length: 6),
        LinguisticSpan(start: 7, length: 6),
        LinguisticSpan(start: 14, length: 6),
        LinguisticSpan(start: 21, length: 6),
      ],
      adjectives: [],
      verbs: [],
      nouns: [],
      posAvailable: true,
    );
  }
}

Widget _wrap(LinguisticFocusProvider provider) {
  return ChangeNotifierProvider<LinguisticFocusProvider>.value(
    value: provider,
    child: const MaterialApp(
      home: Scaffold(body: LinguisticFocusChip()),
    ),
  );
}

void main() {
  late Directory tmp;
  late StorageService storage;

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getApplicationSupportDirectory') {
        return Directory.systemTemp.createTempSync('lf_pp_').path;
      }
      return null;
    });
  });

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('linguistic_chip_test_');
    Hive.init(tmp.path);
    storage = StorageService();
    await storage.init();
  });

  tearDown(() async {
    await Hive.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  testWidgets('chip shows "Focus" label when no class is active',
      (tester) async {
    final provider =
        LinguisticFocusProvider(storage, _FakeService(ApiClient(storage)));
    await tester.pumpWidget(_wrap(provider));
    await tester.pumpAndSettle();
    expect(find.text('Focus'), findsOneWidget);
  });

  testWidgets('chip label tracks the active class via provider', (tester) async {
    final provider =
        LinguisticFocusProvider(storage, _FakeService(ApiClient(storage)));
    await tester.pumpWidget(_wrap(provider));
    await tester.pump();

    // Idle — no class selected.
    expect(find.text('Focus'), findsOneWidget);

    // Hive.put runs on a real Future (not the fake-async clock the
    // test framework otherwise drives), so we have to escape the
    // fake zone via [runAsync] for the storage write to complete.
    await tester.runAsync(() async {
      await provider.setActiveClass(LinguisticClass.dialogue);
    });
    await tester.pump();
    expect(find.textContaining('Dialogue'), findsOneWidget);
    expect(find.text('Focus'), findsNothing);
  });

  testWidgets('chip label flips back to "Focus" when selection cleared',
      (tester) async {
    final provider =
        LinguisticFocusProvider(storage, _FakeService(ApiClient(storage)));
    await tester.runAsync(() async {
      await provider.setActiveClass(LinguisticClass.adverbs);
    });

    await tester.pumpWidget(_wrap(provider));
    await tester.pump();

    // While a class is active the chip reads "Adverbs · …".
    expect(find.textContaining('Adverbs'), findsOneWidget);
    expect(find.text('Focus'), findsNothing);

    // Clearing the class via the provider (the same path the Off row
    // takes) should put the chip back to its idle "Focus" label.
    await tester.runAsync(() async {
      await provider.setActiveClass(null);
    });
    await tester.pump();

    expect(find.text('Focus'), findsOneWidget);
    expect(provider.activeClass, isNull);
  });

  testWidgets('sheet renders all six rows (5 classes + Off)', (tester) async {
    final provider =
        LinguisticFocusProvider(storage, _FakeService(ApiClient(storage)));

    // Build the sheet in isolation — no modal animation, no overlay,
    // no async scrim. We're verifying *layout*, not navigation.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChangeNotifierProvider<LinguisticFocusProvider>.value(
          value: provider,
          child: LinguisticFocusSheet(provider: provider),
        ),
      ),
    ));
    await tester.pump();

    expect(find.text('Linguistic Focus'), findsOneWidget);
    expect(find.text('Off'), findsOneWidget);
    for (final c in LinguisticClass.all) {
      expect(find.text(LinguisticClass.label(c)), findsOneWidget,
          reason: 'class ${LinguisticClass.label(c)} missing from sheet');
    }
  });
}
