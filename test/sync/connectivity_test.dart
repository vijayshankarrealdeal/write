import 'package:flutter_test/flutter_test.dart';
import 'package:inkspacex/services/connectivity_service.dart';

void main() {
  group('ConnectivityService', () {
    test('starts online by default', () {
      final svc = ConnectivityService();
      expect(svc.isOnlineNow, isTrue);
    });

    test('debugSet flips state and emits on the stream', () async {
      final svc = ConnectivityService();
      final events = <bool>[];
      final sub = svc.onChange.listen(events.add);

      svc.debugSet(false);
      svc.debugSet(true);
      svc.debugSet(true); // duplicate, must not re-emit
      svc.debugSet(false);

      // Let the stream pump.
      await Future<void>.delayed(Duration.zero);

      expect(events, [false, true, false]);
      expect(svc.isOnlineNow, isFalse);

      await sub.cancel();
    });

    test('isOnline ValueListenable mirrors state', () {
      final svc = ConnectivityService();
      final notifications = <bool>[];
      void listener() => notifications.add(svc.isOnline.value);
      svc.isOnline.addListener(listener);

      svc.debugSet(false);
      svc.debugSet(true);

      expect(notifications, [false, true]);
      svc.isOnline.removeListener(listener);
    });
  });
}
