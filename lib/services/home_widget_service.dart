import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:home_widget/home_widget.dart';

import 'package:inkspacex/models/writing_model.dart';
import 'package:inkspacex/services/app_log.dart';

/// Pushes a small payload — most-recent draft + author name + feed
/// teaser — into the OS-level shared container (`UserDefaults` on
/// iOS/macOS, `SharedPreferences` on Android) so the native home-screen
/// widgets can read it and paint themselves.
///
/// Web/desktop platforms that don't ship a widget surface just no-op.
class HomeWidgetService {
  HomeWidgetService._();
  static final HomeWidgetService instance = HomeWidgetService._();

  static const _appGroupId = 'group.com.inkspacex.app.widget';
  static const _iosWidgetName = 'InkSpaceXWidget';
  static const _androidWidgetProvider = 'InkSpaceXWidgetProvider';

  bool _initialized = false;

  bool get _isSupported {
    if (kIsWeb) return false;
    return Platform.isIOS || Platform.isAndroid;
  }

  Future<void> init() async {
    if (_initialized || !_isSupported) return;
    _initialized = true;
    try {
      await HomeWidget.setAppGroupId(_appGroupId);
      HomeWidget.registerInteractivityCallback(_backgroundCallback);
      log.i('[home_widget] initialized');
    } catch (e) {
      log.w('[home_widget] init failed: $e');
    }
  }

  /// Push the latest draft + author + feed teaser to the widget.
  /// Safe to call from anywhere — non-supported platforms no-op.
  Future<void> updateWritingWidget({
    required String? authorName,
    required List<WritingModel> books,
    String? feedTeaserTitle,
    String? feedTeaserAuthor,
  }) async {
    if (!_isSupported) return;
    try {
      WritingModel? mostRecent;
      if (books.isNotEmpty) {
        final sorted = [...books]
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
        mostRecent = sorted.first;
      }

      await HomeWidget.saveWidgetData<String>(
        'author',
        authorName ?? 'Writer',
      );
      await HomeWidget.saveWidgetData<String>(
        'recent_title',
        mostRecent?.title.isNotEmpty == true
            ? mostRecent!.title
            : 'Start a new story',
      );
      await HomeWidget.saveWidgetData<String>(
        'recent_id',
        mostRecent?.id ?? '',
      );
      await HomeWidget.saveWidgetData<String>(
        'recent_subtitle',
        mostRecent?.description.isNotEmpty == true
            ? mostRecent!.description
            : 'Tap to start writing',
      );
      await HomeWidget.saveWidgetData<int>(
        'book_count',
        books.length,
      );
      await HomeWidget.saveWidgetData<String>(
        'feed_teaser_title',
        feedTeaserTitle ?? '',
      );
      await HomeWidget.saveWidgetData<String>(
        'feed_teaser_author',
        feedTeaserAuthor ?? '',
      );
      await HomeWidget.saveWidgetData<String>(
        'updated_at',
        DateTime.now().toIso8601String(),
      );

      await HomeWidget.updateWidget(
        name: _androidWidgetProvider,
        iOSName: _iosWidgetName,
        androidName: _androidWidgetProvider,
        qualifiedAndroidName: 'com.inkspacex.app.$_androidWidgetProvider',
      );
    } catch (e) {
      log.w('[home_widget] updateWritingWidget failed: $e');
    }
  }

  /// Wipes the widget back to the signed-out CTA state.
  Future<void> clear() async {
    if (!_isSupported) return;
    try {
      await HomeWidget.saveWidgetData<String>('author', 'Writer');
      await HomeWidget.saveWidgetData<String>(
        'recent_title',
        'Sign in to InkSpaceX',
      );
      await HomeWidget.saveWidgetData<String>('recent_id', '');
      await HomeWidget.saveWidgetData<String>(
        'recent_subtitle',
        'Tap to open the app',
      );
      await HomeWidget.saveWidgetData<int>('book_count', 0);
      await HomeWidget.saveWidgetData<String>('feed_teaser_title', '');
      await HomeWidget.saveWidgetData<String>('feed_teaser_author', '');
      await HomeWidget.updateWidget(
        name: _androidWidgetProvider,
        iOSName: _iosWidgetName,
        androidName: _androidWidgetProvider,
        qualifiedAndroidName: 'com.inkspacex.app.$_androidWidgetProvider',
      );
    } catch (e) {
      log.w('[home_widget] clear failed: $e');
    }
  }

  /// Returns the deep-link URI the user tapped (when opening from a
  /// widget tap). Null on first launch / non-widget launches.
  Future<Uri?> initialLaunchUri() async {
    if (!_isSupported) return null;
    try {
      return await HomeWidget.initiallyLaunchedFromHomeWidget();
    } catch (_) {
      return null;
    }
  }

  /// Stream of widget tap events while the app is running.
  ///
  /// Tolerates a missing native implementation (e.g. the plugin's pod/aar
  /// hasn't been synced into the host project yet) by quietly degrading
  /// to an empty stream instead of letting the exception escape into the
  /// app's zone error handler.
  Stream<Uri?> get launchStream {
    if (!_isSupported) return const Stream<Uri?>.empty();
    try {
      return HomeWidget.widgetClicked.handleError((Object error) {
        if (error is MissingPluginException) {
          log.w('[home_widget] launchStream unavailable: $error');
          return;
        }
        log.w('[home_widget] launchStream error: $error');
      });
    } on MissingPluginException catch (e) {
      log.w('[home_widget] launchStream unavailable: $e');
      return const Stream<Uri?>.empty();
    }
  }
}

/// Handler for Android background `RemoteViews` taps. Stays a top-level
/// function because it's invoked in an isolate that doesn't share state.
@pragma('vm:entry-point')
Future<void> _backgroundCallback(Uri? uri) async {
  // No-op: taps are handled in the foreground via [launchStream].
  // The handler is registered so home_widget keeps a valid callback
  // registered even when the app is killed.
}
