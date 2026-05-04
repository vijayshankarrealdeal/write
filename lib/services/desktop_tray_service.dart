import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:tray_manager/tray_manager.dart';

import 'package:inkspacex/services/app_log.dart';

/// Windows / Linux / macOS system-tray surface — the practical
/// "home-screen widget" equivalent on platforms where the OS doesn't
/// expose a real widget API. Right-clicking the tray icon opens a menu
/// with the same quick actions the iOS / Android widget exposes:
/// "Continue last draft", "New writing", "Open InkSpaceX".
///
/// On platforms where we already have a real WidgetKit / AppWidget
/// surface (iOS, Android), this service is a no-op so we don't end up
/// with two competing entry points.
class DesktopTrayService with TrayListener {
  DesktopTrayService._();
  static final DesktopTrayService instance = DesktopTrayService._();

  bool _initialized = false;
  String _recentTitle = 'Start a new story';
  String _recentId = '';
  int _bookCount = 0;

  final StreamController<Uri> _launchController =
      StreamController<Uri>.broadcast();

  /// Tap events from the tray menu — same shape as the home_widget
  /// `widgetClicked` stream so the rest of the app can listen uniformly.
  Stream<Uri> get launchStream => _launchController.stream;

  bool get _isSupported {
    if (kIsWeb) return false;
    return Platform.isWindows || Platform.isLinux;
  }

  Future<void> init() async {
    if (_initialized || !_isSupported) return;
    _initialized = true;
    try {
      trayManager.addListener(this);
      await _setIcon();
      await trayManager.setToolTip('InkSpaceX');
      await _rebuildMenu();
      log.i('[tray] initialized');
    } catch (e) {
      log.w('[tray] init failed: $e');
    }
  }

  Future<void> dispose() async {
    if (!_isSupported) return;
    trayManager.removeListener(this);
    await trayManager.destroy();
    await _launchController.close();
  }

  /// Push the latest draft snapshot. Mirrors HomeWidgetService.update so
  /// callers can fan out to both without juggling per-platform branches.
  Future<void> update({
    required String? authorName,
    required String recentTitle,
    required String recentId,
    required int bookCount,
  }) async {
    _recentTitle = recentTitle;
    _recentId = recentId;
    _bookCount = bookCount;
    if (!_initialized) return;
    await _rebuildMenu();
  }

  Future<void> _setIcon() async {
    // Use the bundled launcher icon for the tray. On Windows the .ico
    // ships in `windows/runner/resources/app_icon.ico`; tray_manager's
    // setIcon also accepts a path or a buffer from rootBundle — using
    // the asset keeps us cross-platform.
    try {
      final iconBytes = await rootBundle.load('assets/icon/icon.png');
      await trayManager.setIcon(
        Platform.isWindows
            ? 'windows/runner/resources/app_icon.ico'
            : 'assets/icon/icon.png',
        isTemplate: false,
      );
      // Touch iconBytes to suppress the unused warning on platforms
      // where tray_manager loads from path.
      iconBytes.lengthInBytes;
    } catch (e) {
      log.w('[tray] setIcon failed: $e');
    }
  }

  Future<void> _rebuildMenu() async {
    final items = <MenuItem>[
      MenuItem(
        key: 'open',
        label: 'Open InkSpaceX',
      ),
      MenuItem.separator(),
      MenuItem(
        key: 'continue',
        label: _recentId.isEmpty
            ? 'Start a new story'
            : 'Continue: ${_truncate(_recentTitle, 36)}',
        disabled: false,
      ),
      MenuItem(
        key: 'new',
        label: '+ New writing',
      ),
      MenuItem.separator(),
      MenuItem(
        key: 'count',
        label: _bookCount == 1
            ? '1 draft saved'
            : '$_bookCount drafts saved',
        disabled: true,
      ),
      MenuItem.separator(),
      MenuItem(
        key: 'quit',
        label: 'Quit',
      ),
    ];
    await trayManager.setContextMenu(Menu(items: items));
  }

  String _truncate(String s, int max) {
    if (s.length <= max) return s;
    return '${s.substring(0, max - 1)}…';
  }

  // MARK: - TrayListener

  @override
  void onTrayIconMouseDown() {
    _launchController.add(Uri.parse('inkspacex://home'));
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        _launchController.add(Uri.parse('inkspacex://home'));
        break;
      case 'continue':
        if (_recentId.isEmpty) {
          _launchController.add(Uri.parse('inkspacex://editor?new=1'));
        } else {
          _launchController
              .add(Uri.parse('inkspacex://editor?id=$_recentId'));
        }
        break;
      case 'new':
        _launchController.add(Uri.parse('inkspacex://editor?new=1'));
        break;
      case 'quit':
        _launchController.add(Uri.parse('inkspacex://quit'));
        break;
    }
  }
}
