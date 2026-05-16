// Firebase configuration for inkspacex.
//
// Hand-maintained replacement for the file `flutterfire configure` would
// generate. Values pulled from:
//   - Android: android/app/google-services.json (auto-read at build time
//     by the google-services Gradle plugin; we mirror them here for
//     Flutter's typed init API).
//   - Web: the firebaseConfig object Firebase Console showed when we
//     registered the web app (project = write-52320).
//   - iOS: not yet configured — currentPlatform throws on iOS so we know
//     to add it before shipping an iOS build.
//
// Bundle ID matching:
//   - Android applicationId  -> com.inkspacex.app
//   - Web measurementId      -> G-02S43VZPWB
//
// Update procedure if you ever rotate keys / add iOS:
//   1. Generate a new web app or APNs cert in Firebase Console.
//   2. Update the matching FirebaseOptions block below.
//   3. No code import changes — Flutter picks the right one via
//      DefaultFirebaseOptions.currentPlatform.

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        throw UnsupportedError(
          'FirebaseOptions for iOS not configured. Add an iOS app in '
          'Firebase Console, drop GoogleService-Info.plist into '
          'ios/Runner/, then fill in the `ios` const below.',
        );
      default:
        throw UnsupportedError(
          'FirebaseOptions not configured for $defaultTargetPlatform — '
          'Firebase is mobile + web only in this app.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyDDrfOv0UsR4EbT7bKu4r83UzZ-tAN-Gis',
    appId: '1:642359466910:web:ce0049c0906ea4eed8d48f',
    messagingSenderId: '642359466910',
    projectId: 'write-52320',
    authDomain: 'write-52320.firebaseapp.com',
    storageBucket: 'write-52320.firebasestorage.app',
    measurementId: 'G-02S43VZPWB',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyDG8rK9HjBiuVZBngiK1ksA6QDm39JGN80',
    appId: '1:642359466910:android:b3316a2728e44fe4d8d48f',
    messagingSenderId: '642359466910',
    projectId: 'write-52320',
    storageBucket: 'write-52320.firebasestorage.app',
  );
}
