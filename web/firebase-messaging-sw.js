// Firebase Cloud Messaging service worker for inkspacex.com.
//
// Browsers will only deliver web push notifications to a registered
// service worker that imports the Firebase messaging SDK. The browser
// loads this file from the site root (must be served from /); flutter
// build web copies it from web/ → build/web/.
//
// Keep this file small and dependency-free — the SW boots before the
// rest of the app and any error here kills push delivery silently.
//
// Versions must match firebase-js-sdk; the compat builds are used so
// the file works without a bundler. Pin to the same major across
// imports.
importScripts(
  'https://www.gstatic.com/firebasejs/10.13.2/firebase-app-compat.js',
);
importScripts(
  'https://www.gstatic.com/firebasejs/10.13.2/firebase-messaging-compat.js',
);

// Mirrors lib/firebase_options.dart::web. If you rotate keys, update
// both files together.
firebase.initializeApp({
  apiKey: 'AIzaSyDDrfOv0UsR4EbT7bKu4r83UzZ-tAN-Gis',
  authDomain: 'write-52320.firebaseapp.com',
  projectId: 'write-52320',
  storageBucket: 'write-52320.firebasestorage.app',
  messagingSenderId: '642359466910',
  appId: '1:642359466910:web:ce0049c0906ea4eed8d48f',
  measurementId: 'G-02S43VZPWB',
});

const messaging = firebase.messaging();

// Background message handler. Fires when a push arrives while the tab
// is closed / not focused. With a `notification` payload the browser
// shows the system notification automatically — this handler is
// invoked only for data-only payloads, which we use sparingly.
messaging.onBackgroundMessage((payload) => {
  const data = payload.data || {};
  const title = data.title || payload.notification?.title || 'InkSpaceX';
  const body = data.body || payload.notification?.body || '';
  self.registration.showNotification(title, {
    body,
    icon: '/icons/Icon-192.png',
    badge: '/icons/Icon-192.png',
    data: { deeplink: data.deeplink || '/' },
  });
});

// Route a notification click back into the app: focus an existing tab
// if one is open, otherwise open a new one at the deeplink.
self.addEventListener('notificationclick', (event) => {
  const target = event.notification.data?.deeplink || '/';
  event.notification.close();
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((wins) => {
      for (const w of wins) {
        if (w.url.includes(self.location.origin) && 'focus' in w) {
          w.focus();
          if (target && 'navigate' in w) w.navigate(target);
          return;
        }
      }
      return clients.openWindow(target);
    }),
  );
});
