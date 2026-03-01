import 'package:flutter/material.dart';

enum SelectedPage { story, write, settings }

extension SelectedPageTitle on SelectedPage {
  String toName() {
    switch (this) {
      case SelectedPage.story:
        return "Stories";
      // case SelectedPage.search:
      //   return "Search";
      case SelectedPage.write:
        return "Write";
      case SelectedPage.settings:
        return "Settings";
    }
  }
}

class NavProvider extends ChangeNotifier {
  SelectedPage selectedPage = SelectedPage.story;
  void setIndex(SelectedPage i) {
    selectedPage = i;
    notifyListeners();
  }
}
