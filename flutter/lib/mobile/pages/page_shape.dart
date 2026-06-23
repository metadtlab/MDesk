import 'package:flutter/material.dart';

abstract class PageShape extends Widget {
  String get title;
  Widget get icon;
  List<Widget> get appBarActions;
}
