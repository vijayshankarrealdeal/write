import 'package:flutter/material.dart';

enum SelectedPage { home, search, write, settings }

extension SelectedPageTitle on SelectedPage {
  String toName() {
    switch (this) {
      case SelectedPage.home:
        return "Home";
      case SelectedPage.search:
        return "Search";
      case SelectedPage.write:
        return "Write";
      case SelectedPage.settings:
        return "Settings";
    }
  }
}

class NavProvider extends ChangeNotifier {
  SelectedPage selectedPage = SelectedPage.home;
  void setIndex(SelectedPage i) {
    selectedPage = i;
    notifyListeners();
  }
}
