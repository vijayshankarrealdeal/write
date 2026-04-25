import 'dart:async';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:go_router/go_router.dart';

import 'package:inkspacex/provider/auth_provider.dart';
import 'package:inkspacex/provider/bookshelf_provider.dart';
import 'package:inkspacex/provider/editor_provider.dart';
import 'package:inkspacex/provider/feed_provider.dart';
import 'package:inkspacex/provider/nav_provider.dart';
import 'package:inkspacex/provider/settings_provider.dart';
import 'package:inkspacex/router.dart';
import 'package:inkspacex/services/app_log.dart';
import 'package:inkspacex/services/storage_service.dart';
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
    runApp(MyApp(storage: storage));
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

class MyApp extends StatelessWidget {
  final StorageService storage;
  const MyApp({super.key, required this.storage});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<StorageService>.value(value: storage),
        ChangeNotifierProvider(create: (_) => NavProvider()),
        ChangeNotifierProvider(create: (_) => AuthProvider(storage)),
        ChangeNotifierProxyProvider<AuthProvider, EditorProvider>(
          create: (context) =>
              EditorProvider(storage, context.read<AuthProvider>()),
          update: (context, auth, previous) {
            final provider = previous ?? EditorProvider(storage, auth);
            if (previous != null && auth.isAuthenticated) {
              provider.loadBooks();
            }
            return provider;
          },
        ),
        ChangeNotifierProvider(create: (_) => SettingsProvider(storage)),
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
        trailing: GestureDetector(
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

/// Desktop/tablet shell: NavigationRail + content.
class _DesktopHomePage extends StatelessWidget {
  final bool isTablet;

  const _DesktopHomePage({required this.isTablet});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF000000) : const Color(0xFFF9F9FB);
    final textColor = isDark ? Colors.white : Colors.black;
    final railBg = isDark ? const Color(0xFF0A0A0A) : const Color(0xFFF2F2F5);

    const pages = [Feed(), WritingPageUI(), MyBooksPage(), ProfileHubPage()];
    final selectedPage = context.watch<NavProvider>().selectedPage;

    return Scaffold(
      backgroundColor: bgColor,
      body: Row(
        children: [
          NavigationRail(
            backgroundColor: railBg,
            labelType: NavigationRailLabelType.selected,
            selectedLabelTextStyle: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: textColor,
            ),
            unselectedLabelTextStyle: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: textColor.withValues(alpha: 0.4),
            ),
            minWidth: isTablet ? 72 : 80,
            groupAlignment: 0,
            selectedIconTheme: IconThemeData(color: textColor, size: 22),
            unselectedIconTheme: IconThemeData(
              color: textColor.withValues(alpha: 0.35),
              size: 22,
            ),
            indicatorColor: isDark
                ? Colors.white.withValues(alpha: 0.12)
                : Colors.black.withValues(alpha: 0.07),
            indicatorShape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
            trailing: Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 24.0),
                  child: _RailProfileButton(
                    isSelected: selectedPage == SelectedPage.settings,
                    isDark: isDark,
                    textColor: textColor,
                    onTap: () {
                      context
                          .read<NavProvider>()
                          .setIndex(SelectedPage.settings);
                    },
                  ),
                ),
              ),
            ),
            destinations: const [
              NavigationRailDestination(
                icon: Icon(CupertinoIcons.home),
                selectedIcon: Icon(CupertinoIcons.house_fill),
                label: Text("Home"),
              ),
              NavigationRailDestination(
                icon: Icon(CupertinoIcons.pen),
                label: Text("Write"),
              ),
              NavigationRailDestination(
                icon: Icon(CupertinoIcons.heart),
                selectedIcon: Icon(CupertinoIcons.heart_fill),
                label: Text("Library"),
              ),
            ],
            selectedIndex: selectedPage == SelectedPage.settings
                ? null
                : selectedPage.index,
            onDestinationSelected: (index) {
              context.read<NavProvider>().setIndex(SelectedPage.values[index]);
            },
          ),
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
                  if (selectedPage == SelectedPage.story)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32.0),
                      child: Row(
                        children: [
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

class _RailProfileButton extends StatelessWidget {
  const _RailProfileButton({
    required this.isSelected,
    required this.isDark,
    required this.textColor,
    required this.onTap,
  });

  final bool isSelected;
  final bool isDark;
  final Color textColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        final user = auth.currentUser;
        final pillColor = isDark
            ? Colors.white.withValues(alpha: 0.12)
            : Colors.black.withValues(alpha: 0.07);
        return GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: isSelected ? pillColor : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: CircleAvatar(
              radius: 16,
              backgroundColor:
                  isDark ? Colors.white12 : Colors.black.withValues(alpha: 0.06),
              backgroundImage: user?.photoUrl != null
                  ? CachedNetworkImageProvider(user!.photoUrl!)
                  : null,
              child: user?.photoUrl == null
                  ? Icon(
                      CupertinoIcons.person_fill,
                      size: 16,
                      color: isSelected
                          ? textColor
                          : textColor.withValues(alpha: 0.35),
                    )
                  : null,
            ),
          ),
        );
      },
    );
  }
}
