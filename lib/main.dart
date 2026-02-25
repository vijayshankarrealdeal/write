import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:provider/provider.dart';
import 'package:writer/provider/editor_provider.dart';
import 'package:writer/provider/nav_provider.dart';
import 'package:writer/ui/feed.dart';
import 'package:writer/ui/search_page.dart';
import 'package:writer/ui/settings.dart';
import 'package:writer/ui/writing_page.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

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
        ChangeNotifierProvider(create: (_) => EditorProvider()),
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
        theme: ThemeData(
          popupMenuTheme: PopupMenuThemeData(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          brightness: Brightness.light,
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.blue,
            brightness: Brightness.light,
          ),
        ),
        home: const HomePage(),
      ),
    );
  }
}

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    final pages = [
      const Feed(),
      const SearchPage(),
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
                onPressed: () {},
                icon: Icon(CupertinoIcons.settings),
              ),
            ),
            destinations: [
              const NavigationRailDestination(
                icon: Icon(CupertinoIcons.home),
                label: Text("Home"),
              ),
              const NavigationRailDestination(
                icon: Icon(CupertinoIcons.search),
                label: Text("Search"),
              ),
              const NavigationRailDestination(
                icon: Icon(CupertinoIcons.pen),
                label: Text("Write"),
              ),
            ],
            selectedIndex: context.watch<NavProvider>().selectedPage.index,
            onDestinationSelected: (index) {
              print(index);
              context.read<NavProvider>().setIndex(SelectedPage.values[index]);
            },
          ),

          // SizedBox(
          //   width: 60,
          //   height: double.infinity,
          //   child: Consumer<NavProvider>(
          //     builder: (context, navProvider, child) {
          //       return Column(
          //         children: [
          //           const SizedBox(height: 10),
          //           Column(
          //             children: [
          //               IconButton(
          //                 onPressed: () {
          //                   navProvider.setIndex(SelectedPage.home);
          //                 },
          //                 icon: Icon(
          //                   CupertinoIcons.home,
          //                   color: navProvider.selectedPage == SelectedPage.home
          //                       ? CupertinoColors.activeBlue
          //                       : CupertinoColors.inactiveGray,
          //                 ),
          //               ),
          //               // const SizedBox(height: 8),
          //               // IconButton(
          //               //   onPressed: () {
          //               //     navProvider.setIndex(SelectedPage.search);
          //               //   },
          //               //   icon: Icon(
          //               //     CupertinoIcons.search,

          //               //     color:
          //               //         navProvider.selectedPage == SelectedPage.search
          //               //         ? CupertinoColors.activeBlue
          //               //         : CupertinoColors.inactiveGray,
          //               //   ),
          //               // ),
          //               const SizedBox(height: 8),
          //               IconButton(
          //                 onPressed: () {
          //                   navProvider.setIndex(SelectedPage.write);
          //                 },
          //                 icon: Icon(
          //                   CupertinoIcons.pen,

          //                   color:
          //                       navProvider.selectedPage == SelectedPage.write
          //                       ? CupertinoColors.activeBlue
          //                       : CupertinoColors.inactiveGray,
          //                 ),
          //               ),
          //             ],
          //           ),
          //           const Spacer(),
          //           IconButton(
          //             onPressed: () {
          //               navProvider.setIndex(SelectedPage.settings);
          //             },
          //             icon: Icon(
          //               CupertinoIcons.settings,

          //               color: navProvider.selectedPage == SelectedPage.settings
          //                   ? CupertinoColors.activeBlue
          //                   : CupertinoColors.inactiveGray,
          //             ),
          //           ),
          //           const SizedBox(height: 20),
          //         ],
          //       );
          //     },
          //   ),
          // ),
          VerticalDivider(width: 1, thickness: 1, color: Colors.grey[300]),
          Expanded(
            child: Scaffold(
              appBar: AppBar(
                title: Text(context.watch<NavProvider>().selectedPage.toName()),
                centerTitle: false,
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
