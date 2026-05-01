import 'dart:async';
import 'dart:ui';

import 'package:inkspacex/ui/widgets/app_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:go_router/go_router.dart';

import 'package:inkspacex/provider/annotation_provider.dart';
import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/bookmark_provider.dart';
import 'package:inkspacex/provider/bookshelf_provider.dart';
import 'package:inkspacex/provider/editor_provider.dart';
import 'package:inkspacex/provider/feed_provider.dart';
import 'package:inkspacex/provider/nav_provider.dart';
import 'package:inkspacex/provider/notification_provider.dart';
import 'package:inkspacex/provider/offline_provider.dart';
import 'package:inkspacex/provider/settings_provider.dart';
import 'package:inkspacex/router.dart';
import 'package:inkspacex/services/analytics_service.dart';
import 'package:inkspacex/services/api/api_client.dart';
import 'package:inkspacex/services/app_log.dart';
import 'package:inkspacex/services/connectivity_service.dart';
import 'package:inkspacex/services/local_notification_service.dart';
import 'package:inkspacex/services/storage_service.dart';
import 'package:inkspacex/services/sync/merge_log.dart';
import 'package:inkspacex/services/sync/outbox.dart';
import 'package:inkspacex/services/sync/outbox_drainer.dart';
import 'package:inkspacex/ui/widgets/notification_badge.dart';
import 'package:inkspacex/ui/widgets/offline_banner.dart';
import 'package:inkspacex/ui/widgets/sync_conflict_banner.dart';
import 'package:inkspacex/ui/app/feed.dart';
import 'package:inkspacex/ui/app/writing_page.dart';
import 'package:inkspacex/ui/pages/profile_hub_page.dart';
import 'package:inkspacex/ui/pages/my_books_page.dart';
import 'package:inkspacex/ui/pages/new_book_addition.dart';
import 'package:inkspacex/ui/theme/app_theme.dart';
import 'package:inkspacex/ui/utilities/responsive_layout.dart';
import 'package:flutter/foundation.dart';
import 'package:inkspacex/web_utils_stub.dart'
    if (dart.library.html) 'package:inkspacex/web_utils.dart' as web_utils;

// Messages we don't want in the log stream (noisy lib internals).
const _debugPrintBlocklist = <String>[
  'Got object store box',
];

bool _shouldSuppress(String msg) =>
    _debugPrintBlocklist.any(msg.contains);

void main() {
  runZonedGuarded(() async {
    if (kIsWeb) {
      web_utils.useWebPathUrlStrategy();
      web_utils.listenForUpdates();
    }
    WidgetsFlutterBinding.ensureInitialized();

    // Flutter framework errors (widget build, layout, etc.)
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      log.e(
        '[flutter] ${details.exception}',
        error: details.exception,
        stackTrace: details.stack,
      );
    };

    // Uncaught async errors outside the framework
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      log.e('[dispatcher] $error', error: error, stackTrace: stack);
      return true;
    };

    log.i('[lifecycle] App starting');

    final storage = StorageService();
    await storage.init();

    // Web-only: if we just came back from the backend's Google OAuth callback,
    // the tokens ride in the URL fragment. Persist them before AuthProvider
    // boots so its restoreSession picks them up like any other resume.
    if (kIsWeb) {
      final tokens = web_utils.consumeOAuthTokensFromUrl();
      if (tokens != null) {
        await storage.saveAuthToken(tokens.access);
        await storage.saveRefreshToken(tokens.refresh);
        log.i('[auth] Imported Google OAuth tokens from URL fragment');
      }
    }

    final connectivity = ConnectivityService();
    await connectivity.init();
    // The outbox stays closed until AuthProvider opens the per-user sandbox
    // after auth resolves — this is what guarantees one user's queued ops
    // can never be drained under another user's auth token.
    final outbox = Outbox();
    await outbox.init();
    final mergeLog = MergeLog();
    await mergeLog.init();
    // Local notifications: best-effort init — on platforms where the
    // package isn't supported (web, desktop) this is a no-op and the
    // service simply never publishes anything.
    final localNotifications = LocalNotificationService();
    await localNotifications.init();

    // Analytics: spins up its own ApiClient (stateless aside from the
    // shared storage handle for auth tokens) so behaviour events flow
    // even before AuthProvider — pre-login screens are first-class
    // entries in the funnel. Disabled by default in debug builds; flip
    // with --dart-define=ANALYTICS_ENABLED=true.
    await AnalyticsService.init(api: ApiClient(storage));
    AnalyticsService.instance.track('app_started', action: 'lifecycle');

    runApp(MyApp(
      storage: storage,
      connectivity: connectivity,
      outbox: outbox,
      mergeLog: mergeLog,
      localNotifications: localNotifications,
    ));
  }, (error, stack) {
    // Top-level zone fallback — anything uncaught (including bare `print` errors).
    log.e('[zone] uncaught: $error', error: error, stackTrace: stack);
  }, zoneSpecification: ZoneSpecification(
    // Capture every print() call anywhere in the app.
    print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
      if (!_shouldSuppress(line)) {
        log.d('[print] $line');
      }
      parent.print(zone, line);
    },
  ));
}

class MyApp extends StatefulWidget {
  final StorageService storage;
  final ConnectivityService connectivity;
  final Outbox outbox;
  final MergeLog mergeLog;
  final LocalNotificationService localNotifications;
  const MyApp({
    super.key,
    required this.storage,
    required this.connectivity,
    required this.outbox,
    required this.mergeLog,
    required this.localNotifications,
  });

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Analytics session boundaries — fg/bg tracking, plus a final flush
    // on background so events written right before the OS may evict us
    // don't get lost.
    switch (state) {
      case AppLifecycleState.resumed:
        AnalyticsService.instance.onAppForegrounded();
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        AnalyticsService.instance.onAppBackgrounded();
        break;
      case AppLifecycleState.hidden:
        // Flutter web fires `hidden` on tab visibility loss (user
        // switched tabs / minimised the window) — the user's still
        // around, so don't roll the session, just flush so events
        // written right before the tab was hidden don't sit in memory
        // until the OS evicts us. On native this state is rare and
        // already covered by paused/detached above.
        unawaited(AnalyticsService.instance.flush());
        break;
      case AppLifecycleState.inactive:
        break;
    }
  }

  StorageService get storage => widget.storage;
  ConnectivityService get connectivity => widget.connectivity;
  Outbox get outbox => widget.outbox;
  MergeLog get mergeLog => widget.mergeLog;
  LocalNotificationService get localNotifications => widget.localNotifications;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<StorageService>.value(value: storage),
        Provider<ConnectivityService>.value(value: connectivity),
        Provider<Outbox>.value(value: outbox),
        Provider<MergeLog>.value(value: mergeLog),
        ChangeNotifierProvider(create: (_) => NavProvider()),
        ChangeNotifierProvider(create: (_) => AuthProvider(storage, outbox)),
        // The drainer needs AuthProvider's dataService — it's created
        // alongside AuthProvider in the constructor (eagerly), so it's safe
        // to read here. We hand the drainer back to AuthProvider so logout
        // can do a final best-effort drain before tokens get cleared.
        ProxyProvider<AuthProvider, OutboxDrainer>(
          create: (context) {
            final auth = context.read<AuthProvider>();
            final drainer = OutboxDrainer(
              outbox: outbox,
              dataService: auth.dataService,
              connectivity: connectivity,
            );
            auth.attachDrainer(drainer);
            return drainer;
          },
          update: (context, auth, previous) {
            if (previous != null) return previous;
            final drainer = OutboxDrainer(
              outbox: outbox,
              dataService: auth.dataService,
              connectivity: connectivity,
            );
            auth.attachDrainer(drainer);
            return drainer;
          },
          dispose: (_, drainer) => drainer.dispose(),
        ),
        ChangeNotifierProxyProvider<AuthProvider, EditorProvider>(
          create: (context) => EditorProvider(
            storage,
            context.read<AuthProvider>(),
            connectivity,
            outbox,
            context.read<OutboxDrainer>(),
            mergeLog,
          ),
          update: (context, auth, previous) {
            final provider = previous ??
                EditorProvider(
                  storage,
                  auth,
                  connectivity,
                  outbox,
                  context.read<OutboxDrainer>(),
                  mergeLog,
                );
            if (previous != null && auth.isAuthenticated) {
              provider.loadBooks();
            }
            return provider;
          },
        ),
        ChangeNotifierProvider(create: (_) => SettingsProvider(storage)),
        ChangeNotifierProvider(create: (_) => AnnotationProvider(storage)),
        ChangeNotifierProxyProvider<AuthProvider, FeedProvider>(
          create: (_) => FeedProvider(),
          update: (context, auth, previous) {
            final provider = previous ?? FeedProvider();
            provider.setDataService(auth.dataService);
            return provider;
          },
        ),
        ChangeNotifierProxyProvider<AuthProvider, BookshelfProvider>(
          create: (context) =>
              BookshelfProvider(context.read<AuthProvider>()),
          update: (context, auth, previous) =>
              previous ?? BookshelfProvider(auth),
        ),
        // Phase 4 (offline `.inkx`): lazy-init store + downloader. The
        // provider lives at the app shell so any read/library page can
        // consult the local cache without a fresh init pass.
        ChangeNotifierProxyProvider<AuthProvider, OfflineProvider>(
          create: (context) => OfflineProvider(
            storage: storage,
            apiClient: context.read<AuthProvider>().apiClient,
          ),
          update: (context, auth, previous) =>
              previous ??
              OfflineProvider(
                storage: storage,
                apiClient: auth.apiClient,
              ),
        ),
        ChangeNotifierProxyProvider<AuthProvider, BookmarkProvider>(
          create: (context) => BookmarkProvider(
            auth: context.read<AuthProvider>(),
            outbox: outbox,
            drainer: context.read<OutboxDrainer>(),
          ),
          update: (context, auth, previous) =>
              previous ??
              BookmarkProvider(
                auth: auth,
                outbox: outbox,
                drainer: context.read<OutboxDrainer>(),
              ),
        ),
        Provider<LocalNotificationService>.value(value: localNotifications),
        // Notifications: rebuilt when the user logs out (which swaps
        // the realtime service) so the new session starts clean.
        ChangeNotifierProxyProvider<AuthProvider, NotificationProvider>(
          create: (context) => buildNotificationProvider(
            context.read<AuthProvider>(),
          ),
          update: (context, auth, previous) {
            // When the user becomes authenticated, ensureStarted() pulls
            // history + opens the SSE channel. Safe to call repeatedly.
            if (auth.isAuthenticated && previous != null) {
              previous.ensureStarted();
              // Mirror SSE notifications to the OS tray as well.
              localNotifications.attachToSse(auth.realtimeService);
              return previous;
            }
            return previous ?? buildNotificationProvider(auth);
          },
        ),
      ],
      child: _AppWithRouter(),
    );
  }
}

class _AppWithRouter extends StatefulWidget {
  @override
  State<_AppWithRouter> createState() => _AppWithRouterState();
}

class _AppWithRouterState extends State<_AppWithRouter> {
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    _router = createRouter(context.read<AuthProvider>());
  }

  @override
  void dispose() {
    _router.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SettingsProvider>(
      builder: (context, settingsProvider, child) {
        return MaterialApp.router(
          routerConfig: _router,
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            FlutterQuillLocalizations.delegate,
          ],
          title: "Inkspacex",
          debugShowCheckedModeBanner: false,
          themeMode: settingsProvider.themeMode,
          theme: MonochromeTheme.lightTheme,
          darkTheme: MonochromeTheme.darkTheme,
          builder: (context, child) => OfflineBanner(
            child: SyncConflictBanner(
              child: child ?? const SizedBox.shrink(),
            ),
          ),
        );
      },
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;

    if (Breakpoints.isMobile(width)) {
      return const _MobileHomePage();
    }
    return _DesktopHomePage(isTablet: Breakpoints.isTablet(width));
  }
}

/// iOS-style mobile shell: CupertinoTabScaffold with bottom tab bar.
class _MobileHomePage extends StatelessWidget {
  const _MobileHomePage();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Consumer<NavProvider>(
      builder: (context, nav, _) {
        return CupertinoTabScaffold(
          tabBar: CupertinoTabBar(
            activeColor: isDark ? Colors.white : Colors.black,
            items: const [
              BottomNavigationBarItem(
                icon: Icon(CupertinoIcons.house),
                activeIcon: Icon(CupertinoIcons.house_fill),
                label: "Home",
              ),
              BottomNavigationBarItem(
                icon: Icon(CupertinoIcons.pen),
                activeIcon: Icon(CupertinoIcons.pen),
                label: "Write",
              ),
              BottomNavigationBarItem(
                icon: Icon(CupertinoIcons.heart),
                activeIcon: Icon(CupertinoIcons.heart_fill),
                label: "My Books",
              ),
              BottomNavigationBarItem(
                icon: Icon(CupertinoIcons.person),
                activeIcon: Icon(CupertinoIcons.person_fill),
                label: "Profile",
              ),
            ],
            currentIndex: nav.selectedPage.index,
            onTap: (i) => nav.setIndex(SelectedPage.values[i]),
          ),
          tabBuilder: (context, index) {
            return CupertinoTabView(
              builder: (context) {
                switch (SelectedPage.values[index]) {
                  case SelectedPage.story:
                    return const _MobileFeedWrapper();
                  case SelectedPage.write:
                    return const _MobileWriteWrapper();
                  case SelectedPage.library:
                    return const _MobileLibraryWrapper();
                  case SelectedPage.settings:
                    return const _MobileSettingsWrapper();
                }
              },
            );
          },
        );
      },
    );
  }
}

class _MobileFeedWrapper extends StatelessWidget {
  const _MobileFeedWrapper();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final navBg = isDark
        ? const Color(0xFF000000)
        : CupertinoColors.systemBackground.resolveFrom(context);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: navBg,
        border: null,
        middle: Text(
          "Discover",
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w700,
            color: CupertinoColors.label.resolveFrom(context),
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            NotificationBellButton(
              onTap: () => context.push('/notifications'),
              size: 20,
            ),
            const SizedBox(width: 4),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => context.push('/search'),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  CupertinoIcons.search,
                  color: CupertinoColors.label.resolveFrom(context),
                  size: 22,
                ),
              ),
            ),
          ],
        ),
      ),
      child: const SafeArea(child: Feed()),
    );
  }
}

class _MobileWriteWrapper extends StatelessWidget {
  const _MobileWriteWrapper();

  @override
  Widget build(BuildContext context) {
    return const WritingPageUI();
  }
}

class _MobileLibraryWrapper extends StatelessWidget {
  const _MobileLibraryWrapper();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final navBg = isDark
        ? const Color(0xFF000000)
        : CupertinoColors.systemBackground.resolveFrom(context);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: navBg,
        border: null,
        middle: Text(
          "My Books",
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w700,
            color: CupertinoColors.label.resolveFrom(context),
          ),
        ),
      ),
      child: const SafeArea(child: MyBooksPage()),
    );
  }
}

class _MobileSettingsWrapper extends StatelessWidget {
  const _MobileSettingsWrapper();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final navBg = isDark
        ? const Color(0xFF000000)
        : CupertinoColors.systemBackground.resolveFrom(context);
    return CupertinoPageScaffold(
      backgroundColor: navBg,
      navigationBar: CupertinoNavigationBar(
        backgroundColor: navBg,
        border: null,
        middle: Text(
          "Profile",
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w700,
            color: CupertinoColors.label.resolveFrom(context),
          ),
        ),
      ),
      child: const SafeArea(child: ProfileHubPage()),
    );
  }
}

/// Desktop/tablet shell: custom sidebar + content.
class _DesktopHomePage extends StatelessWidget {
  final bool isTablet;

  const _DesktopHomePage({required this.isTablet});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFF9F9FB);
    final textColor = isDark ? Colors.white : Colors.black;

    const pages = [Feed(), WritingPageUI(), MyBooksPage(), ProfileHubPage()];
    final selectedPage = context.watch<NavProvider>().selectedPage;

    return Scaffold(
      backgroundColor: bgColor,
      body: Row(
        children: [
          _AppSidebar(isDark: isDark, isTablet: isTablet),
          Expanded(
            child: Scaffold(
              backgroundColor: Colors.transparent,
              appBar: AppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                scrolledUnderElevation: 0,
                toolbarHeight: 80,
                title: Padding(
                  padding: const EdgeInsets.only(left: 16.0),
                  child: Text(
                    selectedPage.toName(),
                    style: GoogleFonts.playfairDisplay(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                centerTitle: false,
                actions: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24.0),
                    child: Row(
                      children: [
                        if (selectedPage == SelectedPage.story) ...[
                          IconButton(
                            icon: Icon(
                              CupertinoIcons.search,
                              color: textColor.withValues(alpha: 0.7),
                            ),
                            tooltip: "Search",
                            onPressed: () => context.push('/search'),
                          ),
                          IconButton(
                            icon: Icon(
                              CupertinoIcons.slider_horizontal_3,
                              color: textColor.withValues(alpha: 0.7),
                            ),
                            tooltip: "Feed preferences",
                            onPressed: () =>
                                context.push('/feed-preferences'),
                          ),
                        ],
                        NotificationBellButton(
                          onTap: () => context.push('/notifications'),
                          color: textColor.withValues(alpha: 0.7),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              body: IndexedStack(index: selectedPage.index, children: pages),
            ),
          ),
        ],
      ),
    );
  }
}

class _AppSidebar extends StatelessWidget {
  const _AppSidebar({required this.isDark, required this.isTablet});

  final bool isDark;
  final bool isTablet;

  static const double _expandedWidth = 232;
  static const double _collapsedWidth = 72;

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavProvider>();
    // Tablet width forces collapsed; otherwise honor the user's toggle.
    final expanded = !isTablet && !nav.sidebarCollapsed;
    final selectedPage = nav.selectedPage;
    final textColor = isDark ? Colors.white : const Color(0xFF0F172A);
    final railBg = isDark ? const Color(0xFF0A0A0A) : Colors.white;
    final borderColor = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);

    final destinations = <_NavItem>[
      _NavItem(
        icon: CupertinoIcons.home,
        activeIcon: CupertinoIcons.house_fill,
        label: 'Discover',
        page: SelectedPage.story,
      ),
      _NavItem(
        icon: CupertinoIcons.pencil_outline,
        activeIcon: CupertinoIcons.pencil,
        label: 'Write',
        page: SelectedPage.write,
      ),
      _NavItem(
        icon: CupertinoIcons.book,
        activeIcon: CupertinoIcons.book_fill,
        label: 'Library',
        page: SelectedPage.library,
      ),
    ];

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      width: expanded ? _expandedWidth : _collapsedWidth,
      decoration: BoxDecoration(
        color: railBg,
        border: Border(right: BorderSide(color: borderColor)),
      ),
      child: ClipRect(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SidebarBrand(
                expanded: expanded,
                isDark: isDark,
                onToggle: isTablet ? null : nav.toggleSidebar,
              ),
              const SizedBox(height: 12),
              _SidebarSectionLabel(
                  text: 'NAVIGATE', expanded: expanded, isDark: isDark),
              ...destinations.map(
                (d) => _SidebarItem(
                  icon: d.icon,
                  activeIcon: d.activeIcon,
                  label: d.label,
                  expanded: expanded,
                  isDark: isDark,
                  isSelected: selectedPage == d.page,
                  onTap: () => context.read<NavProvider>().setIndex(d.page),
                ),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Divider(color: borderColor, height: 1),
              ),
              const SizedBox(height: 12),
              _SidebarProfileTile(
                expanded: expanded,
                isDark: isDark,
                textColor: textColor,
                isSelected: selectedPage == SelectedPage.settings,
                onTap: () => context
                    .read<NavProvider>()
                    .setIndex(SelectedPage.settings),
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavItem {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final SelectedPage page;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.page,
  });
}

class _SidebarBrand extends StatelessWidget {
  const _SidebarBrand({
    required this.expanded,
    required this.isDark,
    required this.onToggle,
  });

  final bool expanded;
  final bool isDark;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final fg = isDark ? Colors.white : const Color(0xFF0F172A);
    final mark = Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: fg,
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Text(
        'I',
        style: GoogleFonts.playfairDisplay(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          color: isDark ? Colors.black : Colors.white,
          height: 1,
        ),
      ),
    );

    if (!expanded) {
      // Collapsed: brand mark doubles as the expand button.
      return Padding(
        padding: const EdgeInsets.fromLTRB(0, 18, 0, 8),
        child: Center(
          child: onToggle == null
              ? mark
              : Tooltip(
                  message: 'Expand sidebar',
                  preferBelow: false,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: onToggle,
                      behavior: HitTestBehavior.opaque,
                      child: mark,
                    ),
                  ),
                ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 8, 8),
      child: Row(
        children: [
          mark,
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'InkSpaceX',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.playfairDisplay(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: fg,
                letterSpacing: -0.4,
              ),
            ),
          ),
          if (onToggle != null)
            Tooltip(
              message: 'Collapse sidebar',
              preferBelow: false,
              child: IconButton(
                onPressed: onToggle,
                splashRadius: 16,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints.tightFor(width: 28, height: 28),
                icon: Icon(
                  CupertinoIcons.sidebar_left,
                  size: 16,
                  color: fg.withValues(alpha: 0.55),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SidebarSectionLabel extends StatelessWidget {
  const _SidebarSectionLabel({
    required this.text,
    required this.expanded,
    required this.isDark,
  });

  final String text;
  final bool expanded;
  final bool isDark;

  @override
  Widget build(BuildContext context) {
    if (!expanded) return const SizedBox(height: 4);
    final color = (isDark ? Colors.white : Colors.black).withValues(alpha: 0.35);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
      child: Text(
        text,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  const _SidebarItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.expanded,
    required this.isDark,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool expanded;
  final bool isDark;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final fg = widget.isDark ? Colors.white : const Color(0xFF0F172A);
    final selectedBg = widget.isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.06);
    final hoverBg = widget.isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.035);
    final iconColor = widget.isSelected
        ? fg
        : fg.withValues(alpha: _hover ? 0.75 : 0.55);
    final labelColor = widget.isSelected
        ? fg
        : fg.withValues(alpha: _hover ? 0.85 : 0.65);

    final tile = AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      height: 38,
      padding: EdgeInsets.symmetric(horizontal: widget.expanded ? 12 : 0),
      decoration: BoxDecoration(
        color: widget.isSelected
            ? selectedBg
            : (_hover ? hoverBg : Colors.transparent),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisAlignment: widget.expanded
            ? MainAxisAlignment.start
            : MainAxisAlignment.center,
        children: [
          Icon(
            widget.isSelected ? widget.activeIcon : widget.icon,
            size: 18,
            color: iconColor,
          ),
          if (widget.expanded) ...[
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                widget.label,
                style: GoogleFonts.inter(
                  fontSize: 13.5,
                  fontWeight:
                      widget.isSelected ? FontWeight.w600 : FontWeight.w500,
                  color: labelColor,
                ),
              ),
            ),
          ],
        ],
      ),
    );

    return Padding(
      padding: EdgeInsets.fromLTRB(
        widget.expanded ? 12 : 14,
        2,
        widget.expanded ? 12 : 14,
        2,
      ),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: widget.expanded
              ? tile
              : Tooltip(
                  message: widget.label,
                  preferBelow: false,
                  child: tile,
                ),
        ),
      ),
    );
  }
}

class _SidebarProfileTile extends StatefulWidget {
  const _SidebarProfileTile({
    required this.expanded,
    required this.isDark,
    required this.textColor,
    required this.isSelected,
    required this.onTap,
  });

  final bool expanded;
  final bool isDark;
  final Color textColor;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  State<_SidebarProfileTile> createState() => _SidebarProfileTileState();
}

class _SidebarProfileTileState extends State<_SidebarProfileTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selectedBg = widget.isDark
        ? Colors.white.withValues(alpha: 0.10)
        : Colors.black.withValues(alpha: 0.06);
    final hoverBg = widget.isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.035);
    final subtle = widget.textColor.withValues(alpha: 0.55);

    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        final user = auth.currentUser;
        final name = user?.name ?? '';
        final email = user?.email ?? '';
        final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
        final avatar = ClipOval(
          child: SizedBox(
            width: 28,
            height: 28,
            child: user?.photoUrl != null
                ? AppNetworkImage(
                    url: user!.photoUrl,
                    meta: user.photoMeta,
                    width: 28,
                    height: 28,
                    fit: BoxFit.cover,
                  )
                : Container(
                    color: widget.isDark
                        ? Colors.white.withValues(alpha: 0.12)
                        : Colors.black.withValues(alpha: 0.08),
                    alignment: Alignment.center,
                    child: Text(
                      initial,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: widget.textColor,
                      ),
                    ),
                  ),
          ),
        );

        final tile = AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: EdgeInsets.symmetric(
            horizontal: widget.expanded ? 8 : 0,
            vertical: 6,
          ),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? selectedBg
                : (_hover ? hoverBg : Colors.transparent),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisAlignment: widget.expanded
                ? MainAxisAlignment.start
                : MainAxisAlignment.center,
            children: [
              avatar,
              if (widget.expanded) ...[
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isNotEmpty ? name : 'Sign in',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: widget.textColor,
                        ),
                      ),
                      Text(
                        email.isNotEmpty ? email : 'Profile & settings',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: subtle,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  CupertinoIcons.chevron_up_chevron_down,
                  size: 14,
                  color: subtle,
                ),
              ],
            ],
          ),
        );

        return Padding(
          padding: EdgeInsets.symmetric(horizontal: widget.expanded ? 12 : 14),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              onTap: widget.onTap,
              behavior: HitTestBehavior.opaque,
              child: widget.expanded
                  ? tile
                  : Tooltip(
                      message: name.isNotEmpty ? name : 'Profile',
                      preferBelow: false,
                      child: tile,
                    ),
            ),
          ),
        );
      },
    );
  }
}

