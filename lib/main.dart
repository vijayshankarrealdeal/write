import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:iconify_flutter/iconify_flutter.dart';
import 'package:iconify_flutter/icons/carbon.dart';
import 'package:provider/provider.dart';
import 'package:writer/provider/editor_provider.dart';
import 'package:writer/provider/nav_provider.dart';
import 'package:writer/ui/app/feed.dart';
import 'package:writer/ui/app/search_page.dart';
import 'package:writer/ui/app/settings.dart';
import 'package:writer/ui/app/writing_page.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:iconify_flutter/iconify_flutter.dart';
import 'package:writer/ui/pages/new_book_addition.dart';
import 'package:writer/ui/theme/app_theme.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => NavProvider()),
        ChangeNotifierProvider(lazy: false, create: (_) => EditorProvider()),
      ],
      child: MaterialApp(
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          FlutterQuillLocalizations.delegate,
        ],
        title: "Writer",
        debugShowCheckedModeBanner: false,
        themeMode: ThemeMode.system, // Switches based on device settings
        theme: MonochromeTheme.lightTheme,
        darkTheme: MonochromeTheme.darkTheme,
        home: const HomePage(),
      ),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    bool isDark = Theme.of(context).brightness == Brightness.dark;
    final hintColor = isDark ? Colors.grey[400] : Colors.black87;

    final pages = [
      const Feed(),
      // const SearchPage(),
      const WritingPageUI(),
      const SettingsPage(),
    ];
    if (kIsWeb) {
      return Row(
        children: [
          NavigationRail(
            labelType: NavigationRailLabelType.none,
            minWidth: 80,
            trailingAtBottom: true,
            trailing: Padding(
              padding: const EdgeInsets.symmetric(vertical: 18.0),
              child: IconButton(
                onPressed: () {
                  context.read<NavProvider>().setIndex(SelectedPage.settings);
                },
                icon: Icon(CupertinoIcons.settings),
              ),
            ),
            destinations: [
              const NavigationRailDestination(
                icon: Icon(CupertinoIcons.home),
                label: Text("Home"),
              ),
              // const NavigationRailDestination(
              //   icon: Icon(CupertinoIcons.search),
              //   label: Text("Search"),
              // ),
              const NavigationRailDestination(
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
              context.read<NavProvider>().setIndex(SelectedPage.values[index]);
            },
          ),
          VerticalDivider(width: 0.2, thickness: 0.2),
          Expanded(
            child: Scaffold(
              appBar: AppBar(
                title: Text(context.watch<NavProvider>().selectedPage.toName()),
                centerTitle: false,
                actions: [
                  context.watch<NavProvider>().selectedPage ==
                          SelectedPage.story
                      ? Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 18.0,
                            vertical: 5,
                          ),
                          child: Row(
                            children: [
                              Icon(
                                CupertinoIcons.slider_horizontal_3,
                                color: hintColor,
                              ),
                              const SizedBox(width: 10),
                              CircleAvatar(),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(),

                  context.watch<NavProvider>().selectedPage ==
                          SelectedPage.write
                      ? TextButton.icon(
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (ctx) => NewBookAddition(),
                              ),
                            );
                          },
                          icon: const Icon(CupertinoIcons.plus),
                          label: const Text("Writing"),
                        )
                      : Container(),
                ],
              ),
              body: pages[context.watch<NavProvider>().selectedPage.index],
            ),
          ),
        ],
      );
    }
    return Container();
  }
}
