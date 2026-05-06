import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter_quill/quill_delta.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';

import 'package:inkspacex/provider/linguistic_focus_provider.dart';
import 'package:inkspacex/services/api/api_client.dart';
import 'package:inkspacex/services/linguistic_focus_decoration.dart';
import 'package:inkspacex/services/linguistic_focus_service.dart';
import 'package:inkspacex/services/storage_service.dart';

/// Records every call to [tag] and lets the test return a canned
/// result. The constructor still has to satisfy the parent's
/// `ApiClient` slot, but the override never invokes it.
class _RecordingService extends LinguisticFocusService {
  _RecordingService(super.api, this._returns);

  final LinguisticTagResult Function(String text, Iterable<String> classes)
      _returns;
  final List<({String text, List<String> classes})> calls = [];

  @override
  Future<LinguisticTagResult> tag(
    String text, {
    Iterable<String> classes = LinguisticClass.all,
  }) async {
    calls.add((text: text, classes: classes.toList()));
    return _returns(text, classes);
  }
}

QuillController _controllerFor(String text) {
  final doc = Document.fromDelta(Delta()..insert('$text\n'));
  return QuillController(
    document: doc,
    selection: const TextSelection.collapsed(offset: 0),
  );
}

void main() {
  late Directory tmp;
  late StorageService storage;

  // Stand-in for path_provider's app-docs lookup. `StorageService.init`
  // calls `Hive.initFlutter()` which under the hood asks path_provider
  // for the app-documents directory; without this mock the channel
  // throws MissingPluginException in unit tests.
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
    tmp = await Directory.systemTemp.createTemp('linguistic_focus_test_');
    Hive.init(tmp.path);
    storage = StorageService();
    await storage.init();
  });

  tearDown(() async {
    await Hive.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  test('attach + setActiveClass triggers an immediate scan', () async {
    final svc = _RecordingService(
      ApiClient(storage),
      (_, _) => const LinguisticTagResult(
        dialogue: [LinguisticSpan(start: 0, length: 5)],
        adverbs: [],
        adjectives: [],
        verbs: [],
        nouns: [],
        posAvailable: true,
      ),
    );
    final provider = LinguisticFocusProvider(storage, svc);
    final controller = _controllerFor('Hello world');
    provider.attach(controller);

    // Setting the active class should kick off an immediate (not
    // debounced) scan so the UI doesn't show 500ms of nothing.
    await provider.setActiveClass(LinguisticClass.dialogue);
    // Drain microtasks so the scan future settles.
    await Future<void>.delayed(Duration.zero);

    expect(svc.calls, isNotEmpty);
    expect(provider.activeClass, LinguisticClass.dialogue);
  });

  test('debounce: rapid doc changes coalesce into a single scan', () async {
    final svc = _RecordingService(
      ApiClient(storage),
      (_, _) => LinguisticTagResult.empty,
    );
    final provider = LinguisticFocusProvider(storage, svc);
    final controller = _controllerFor('Hello');
    provider.attach(controller);
    await provider.setActiveClass(LinguisticClass.dialogue);
    // Drain the immediate scan.
    await Future<void>.delayed(Duration.zero);
    final initialCalls = svc.calls.length;

    // Three rapid edits within the debounce window. Routing through
    // the controller (not the document) is what fires the
    // ChangeNotifier the provider listens on.
    controller.replaceText(
      controller.document.length - 1, 0, ' a', null,
    );
    controller.replaceText(
      controller.document.length - 1, 0, ' b', null,
    );
    controller.replaceText(
      controller.document.length - 1, 0, ' c', null,
    );

    // Mid-debounce: no extra scan yet.
    await Future<void>.delayed(LinguisticFocusProvider.debounce ~/ 2);
    expect(svc.calls.length, initialCalls,
        reason: 'mid-debounce: no scan should have fired yet');

    // Wait past the debounce window.
    await Future<void>.delayed(LinguisticFocusProvider.debounce);
    expect(svc.calls.length, initialCalls + 1,
        reason: 'one consolidated scan should land after debounce');
  });

  test('no-op edits (same text) do not schedule a scan', () async {
    final svc = _RecordingService(
      ApiClient(storage),
      (_, _) => LinguisticTagResult.empty,
    );
    final provider = LinguisticFocusProvider(storage, svc);
    final controller = _controllerFor('hello');
    provider.attach(controller);
    await provider.setActiveClass(LinguisticClass.adverbs);
    await Future<void>.delayed(Duration.zero);
    final initialCalls = svc.calls.length;

    // Decoration composes (silent change source) leave plain text
    // unchanged. The provider must skip these so it doesn't loop on
    // its own marks.
    applyLinguisticFocus(
      controller,
      activeClass: LinguisticClass.adverbs,
      highlightSpans: const [],
    );
    await Future<void>.delayed(LinguisticFocusProvider.debounce * 2);

    expect(svc.calls.length, initialCalls,
        reason: 'cosmetic-only changes must not schedule a scan');
  });

  test('switching class refreshes the highlight without re-fetching '
      'when results are already cached', () async {
    final svc = _RecordingService(
      ApiClient(storage),
      (_, _) => const LinguisticTagResult(
        dialogue: [LinguisticSpan(start: 0, length: 5)],
        adverbs: [LinguisticSpan(start: 6, length: 5)],
        adjectives: [],
        verbs: [],
        nouns: [],
        posAvailable: true,
      ),
    );
    final provider = LinguisticFocusProvider(storage, svc);
    final controller = _controllerFor('hello world');
    provider.attach(controller);

    await provider.setActiveClass(LinguisticClass.dialogue);
    await Future<void>.delayed(Duration.zero);
    expect(provider.matchCount, 1);

    // Switch to adverbs. Because we already have a cached result with
    // both buckets, the match count flips immediately.
    await provider.setActiveClass(LinguisticClass.adverbs);
    expect(provider.matchCount, 1);
  });

  test('setActiveClass(null) clears overlay and skips network', () async {
    final svc = _RecordingService(
      ApiClient(storage),
      (_, _) => LinguisticTagResult.empty,
    );
    final provider = LinguisticFocusProvider(storage, svc);
    final controller = _controllerFor('hello');
    provider.attach(controller);

    await provider.setActiveClass(LinguisticClass.adverbs);
    await Future<void>.delayed(Duration.zero);
    final initialCalls = svc.calls.length;

    await provider.setActiveClass(null);
    expect(provider.activeClass, isNull);
    // Drain any pending microtasks just in case.
    await Future<void>.delayed(LinguisticFocusProvider.debounce * 2);
    expect(svc.calls.length, initialCalls,
        reason: 'turning the overlay off must not fire a scan');
  });

  test('persisted active class survives provider re-creation', () async {
    final svc1 = _RecordingService(
      ApiClient(storage),
      (_, _) => LinguisticTagResult.empty,
    );
    final p1 = LinguisticFocusProvider(storage, svc1);
    await p1.setActiveClass(LinguisticClass.verbs);

    // Tear down and rebuild — the new provider should pick up the
    // previously selected class from storage.
    final svc2 = _RecordingService(
      ApiClient(storage),
      (_, _) => LinguisticTagResult.empty,
    );
    final p2 = LinguisticFocusProvider(storage, svc2);
    expect(p2.activeClass, LinguisticClass.verbs);
  });

  test('setActiveClass(null) wipes the persisted selection', () async {
    final svc = _RecordingService(
      ApiClient(storage),
      (_, _) => LinguisticTagResult.empty,
    );
    final p1 = LinguisticFocusProvider(storage, svc);
    await p1.setActiveClass(LinguisticClass.nouns);
    await p1.setActiveClass(null);

    final svc2 = _RecordingService(
      ApiClient(storage),
      (_, _) => LinguisticTagResult.empty,
    );
    final p2 = LinguisticFocusProvider(storage, svc2);
    expect(p2.activeClass, isNull);
  });

  test('posUnavailable mirrors backend pos_available=false', () async {
    final svc = _RecordingService(
      ApiClient(storage),
      (_, _) => const LinguisticTagResult(
        dialogue: [],
        adverbs: [],
        adjectives: [],
        verbs: [],
        nouns: [],
        posAvailable: false,
      ),
    );
    final provider = LinguisticFocusProvider(storage, svc);
    final controller = _controllerFor('hi');
    provider.attach(controller);
    await provider.setActiveClass(LinguisticClass.adverbs);
    await Future<void>.delayed(Duration.zero);
    expect(provider.posUnavailable, isTrue);
  });

  test('detach cancels pending scans and clears state', () async {
    final svc = _RecordingService(
      ApiClient(storage),
      (_, _) => LinguisticTagResult.empty,
    );
    final provider = LinguisticFocusProvider(storage, svc);
    final controller = _controllerFor('hello');
    provider.attach(controller);
    await provider.setActiveClass(LinguisticClass.adjectives);
    // Trigger one debounced scan.
    controller.replaceText(
      controller.document.length - 1, 0, ' world', null,
    );

    provider.detach();
    expect(provider.lastResult, LinguisticTagResult.empty);
    expect(provider.hasScanned, isFalse);
  });
}
