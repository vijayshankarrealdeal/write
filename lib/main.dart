import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:writer/provider/auth_provider.dart';
import 'package:writer/provider/editor_provider.dart';
import 'package:writer/provider/nav_provider.dart';
import 'package:writer/provider/settings_provider.dart';
import 'package:writer/services/storage_service.dart';
import 'package:writer/ui/app/feed.dart';
import 'package:writer/ui/app/settings.dart';
import 'package:writer/ui/app/writing_page.dart';
import 'package:writer/ui/auth/auth_gate.dart';
import 'package:writer/ui/pages/new_book_addition.dart';
import 'package:writer/ui/theme/app_theme.dart';
import 'package:writer/ui/utilities/responsive_layout.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = StorageService();
  await storage.init();
  runApp(MyApp(storage: storage));
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
        ChangeNotifierProvider(create: (_) => EditorProvider(storage)),
        ChangeNotifierProvider(create: (_) => SettingsProvider(storage)),
      ],
      child: Consumer<SettingsProvider>(
        builder: (context, settingsProvider, child) {
          return MaterialApp(
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              FlutterQuillLocalizations.delegate,
            ],
            title: "Writer",
            debugShowCheckedModeBanner: false,
            themeMode: settingsProvider.themeMode,
            theme: MonochromeTheme.lightTheme,
            darkTheme: MonochromeTheme.darkTheme,
            home: const AuthGate(),
          );
        },
      ),
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
                icon: Icon(CupertinoIcons.settings),
                activeIcon: Icon(CupertinoIcons.settings_solid),
                label: "Settings",
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
    final navBg = isDark ? const Color(0xFF000000) : CupertinoColors.systemBackground.resolveFrom(context);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: navBg,
        border: null,
        middle: Text(
          "Stories",
          style: GoogleFonts.playfairDisplay(
            fontWeight: FontWeight.bold,
            color: CupertinoColors.label.resolveFrom(context),
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

class _MobileSettingsWrapper extends StatelessWidget {
  const _MobileSettingsWrapper();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final navBg = isDark ? const Color(0xFF000000) : CupertinoColors.systemBackground.resolveFrom(context);
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: navBg,
        middle: Text(
          "Settings",
          style: GoogleFonts.inter(
            fontWeight: FontWeight.w600,
            color: CupertinoColors.label.resolveFrom(context),
          ),
        ),
      ),
      child: const SafeArea(child: SettingsPage()),
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
    final subtleBorder = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.05);

    final pages = [const Feed(), const WritingPageUI(), const SettingsPage()];

    return Scaffold(
      backgroundColor: bgColor,
      body: Row(
        children: [
          NavigationRail(
            backgroundColor: bgColor,
            labelType: NavigationRailLabelType.none,
            minWidth: isTablet ? 72 : 80,
            trailingAtBottom: true,
            selectedIconTheme: IconThemeData(color: textColor, size: 24),
            unselectedIconTheme: IconThemeData(
              color: textColor.withValues(alpha: 0.4),
              size: 24,
            ),
            indicatorColor: isDark
                ? Colors.white.withValues(alpha: 0.1)
                : Colors.black.withValues(alpha: 0.05),
            trailing: Padding(
              padding: const EdgeInsets.symmetric(vertical: 24.0),
              child: IconButton(
                onPressed: () {
                  context.read<NavProvider>().setIndex(SelectedPage.settings);
                },
                icon: Icon(
                  CupertinoIcons.settings,
                  color:
                      context.watch<NavProvider>().selectedPage ==
                              SelectedPage.settings
                          ? textColor
                          : textColor.withValues(alpha: 0.4),
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
            ],
            selectedIndex:
                context.watch<NavProvider>().selectedPage == SelectedPage.settings
                    ? null
                    : context.watch<NavProvider>().selectedPage.index,
            onDestinationSelected: (index) {
              context.read<NavProvider>().setIndex(SelectedPage.values[index]);
            },
          ),
          Container(width: 1, color: subtleBorder),
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
                    context.watch<NavProvider>().selectedPage.toName(),
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
                  if (context.watch<NavProvider>().selectedPage ==
                      SelectedPage.story)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32.0),
                      child: Row(
                        children: [
                          IconButton(
                            icon: Icon(
                              CupertinoIcons.slider_horizontal_3,
                              color: textColor.withValues(alpha: 0.7),
                            ),
                            onPressed: () {},
                          ),
                          const SizedBox(width: 16),
                          CircleAvatar(
                            radius: 18,
                            backgroundColor:
                                isDark ? Colors.white12 : Colors.black12,
                            child: Icon(
                              CupertinoIcons.person,
                              size: 18,
                              color: textColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (context.watch<NavProvider>().selectedPage ==
                          SelectedPage.write &&
                      context.watch<EditorProvider>().allBooks.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32.0),
                      child: CupertinoButton(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        color: textColor,
                        borderRadius: BorderRadius.circular(20),
                        child: Row(
                          children: [
                            Icon(
                              CupertinoIcons.add,
                              size: 16,
                              color: bgColor,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              "New Project",
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: bgColor,
                              ),
                            ),
                          ],
                        ),
                        onPressed: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (ctx) => const NewBookAddition(),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
              body: pages[context.watch<NavProvider>().selectedPage.index],
            ),
          ),
        ],
      ),
    );
  }
}
