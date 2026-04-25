import 'package:web/web.dart' as web;
import 'dart:js_interop';

void listenForUpdates() {
  web.window.navigator.serviceWorker.addEventListener(
    'controllerchange',
    (web.Event event) {
      web.window.location.reload();
    }.toJS,
  );
}
