import 'package:flutter/material.dart';

abstract class PageShape extends Widget {
  String get title;
  Widget get icon;
  List<Widget> get appBarActions;
}

class HomePage extends StatefulWidget {
  static final homeKey = GlobalKey<HomePageState>();

  HomePage() : super(key: homeKey);

  @override
  HomePageState createState() => HomePageState();
}

class HomePageState extends State<HomePage> {
  bool get isChatPageCurrentTab => false;

  void refreshPages() {}

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
