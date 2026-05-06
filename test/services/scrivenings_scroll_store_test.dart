import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:inkspacex/services/scrivenings_scroll_store.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ScrivenningsScrollStore.debugUseMemoryStore(null);
  });

  group('ScrivenningsScrollStore (SharedPreferences-backed)', () {
    test('round-trips a write through to a read', () async {
      const store = ScrivenningsScrollStore();
      expect(await store.read('book-1'), isNull);
      await store.write('book-1', 1234.5);
      expect(await store.read('book-1'), 1234.5);
    });

    test('clear removes the entry', () async {
      const store = ScrivenningsScrollStore();
      await store.write('book-1', 100);
      await store.clear('book-1');
      expect(await store.read('book-1'), isNull);
    });

    test('keys are scoped per book id', () async {
      const store = ScrivenningsScrollStore();
      await store.write('book-1', 10);
      await store.write('book-2', 20);
      expect(await store.read('book-1'), 10);
      expect(await store.read('book-2'), 20);
    });

    test('empty book id is a no-op for write/read/clear', () async {
      const store = ScrivenningsScrollStore();
      await store.write('', 99);
      expect(await store.read(''), isNull);
      // No throw on clear of an empty id.
      await store.clear('');
    });
  });

  group('ScrivenningsScrollStore (in-memory test backend)', () {
    test('debugUseMemoryStore replaces the prefs backend', () async {
      final mem = <String, double>{};
      ScrivenningsScrollStore.debugUseMemoryStore(mem);
      addTearDown(() => ScrivenningsScrollStore.debugUseMemoryStore(null));

      const store = ScrivenningsScrollStore();
      await store.write('b', 42);
      expect(mem.length, 1);
      expect(await store.read('b'), 42);
      await store.clear('b');
      expect(mem, isEmpty);
    });
  });
}
