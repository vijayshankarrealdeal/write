import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:writer/provider/editor_provider.dart';
import 'package:writer/provider/nav_provider.dart';
import 'package:writer/provider/settings_provider.dart'; // Add this import
import 'package:writer/ui/app/feed.dart';
import 'package:writer/ui/app/settings.dart';
import 'package:writer/ui/app/writing_page.dart';
import 'package:writer/ui/pages/new_book_addition.dart';
import 'package:writer/ui/theme/app_theme.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => NavProvider()),
        ChangeNotifierProvider(lazy: false, create: (_) => EditorProvider()),
        ChangeNotifierProvider(
          create: (_) => SettingsProvider(),
        ), // Register SettingsProvider
      ],
      // Consume SettingsProvider here to listen to Theme changes dynamically
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
            // Bind themeMode to our new provider
            themeMode: settingsProvider.themeMode,
            theme: MonochromeTheme.lightTheme,
            darkTheme: MonochromeTheme.darkTheme,
            home: const HomePage(),
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
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF0E0E10) : const Color(0xFFF9F9FB);
    final textColor = isDark ? Colors.white : Colors.black;
    final subtleBorder = isDark
        ? Colors.white.withValues(alpha: 0.05)
        : Colors.black.withValues(alpha: 0.05);

    final pages = [const Feed(), const WritingPageUI(), const SettingsPage()];

    if (kIsWeb) {
      return Scaffold(
        backgroundColor: bgColor,
        body: Row(
          children: [
            // Refined Navigation Rail
            NavigationRail(
              backgroundColor: bgColor,
              labelType: NavigationRailLabelType.none,
              minWidth: 80,
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
                  context.watch<NavProvider>().selectedPage ==
                      SelectedPage.settings
                  ? null
                  : context.watch<NavProvider>().selectedPage.index,
              onDestinationSelected: (index) {
                context.read<NavProvider>().setIndex(
                  SelectedPage.values[index],
                );
              },
            ),

            // Ultra-subtle divider
            Container(width: 1, color: subtleBorder),

            // Main Content Area
            Expanded(
              child: Scaffold(
                backgroundColor: Colors.transparent,
                appBar: AppBar(
                  backgroundColor: Colors.transparent,
                  elevation: 0,
                  scrolledUnderElevation: 0,
                  toolbarHeight: 80, // Taller app bar for premium feel
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
                    // Feed (Stories) Actions
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
                              backgroundColor: isDark
                                  ? Colors.white12
                                  : Colors.black12,
                              child: Icon(
                                CupertinoIcons.person,
                                size: 18,
                                color: textColor,
                              ),
                            ),
                          ],
                        ),
                      ),

                    // Write Actions
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
    return Container(); // Mobile logic remains untouched
  }
}
