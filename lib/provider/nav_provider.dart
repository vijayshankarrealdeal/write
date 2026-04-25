import 'package:flutter/material.dart';

enum SelectedPage { story, write, library, settings }

extension SelectedPageTitle on SelectedPage {
  String toName() {
    switch (this) {
      case SelectedPage.story:
        return "Discover";
      case SelectedPage.write:
        return "Write";
      case SelectedPage.library:
        return "My Books";
      case SelectedPage.settings:
        return "Profile";
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
