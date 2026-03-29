import 'package:bot_toast/bot_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/web/home_page.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

const Locale _forcedWebLocale = Locale('ko');

Future<void> _initWebEnv(String appType) async {
  await platformFFI.init(appType);
  await initGlobalFFI();
  updateSystemWindowTheme();
}

Future<void> main(List<String> args) async {
  earlyAssert();
  WidgetsFlutterBinding.ensureInitialized();

  await _initWebEnv(kAppTypeMain);
  checkUpdate();
  await Future.wait([gFFI.abModel.loadCache(), gFFI.groupModel.loadCache()]);
  gFFI.userModel.refreshCurrentUser();

  runApp(const WebApp());
  await initUniLinks();
}

int? get kWindowId => null;

dynamic get kWindowType => null;

List<String> get kBootArgs => const <String>[];

bool hasAgentIdInFilename() => false;

Future<void> showCmWindow({bool isStartup = false}) async {}

Future<void> hideCmWindow({bool isStartup = false}) async {}

class WebApp extends StatelessWidget {
  const WebApp({super.key});

  @override
  Widget build(BuildContext context) {
    final botToastBuilder = BotToastInit();
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: gFFI.ffiModel),
        ChangeNotifierProvider.value(value: gFFI.imageModel),
        ChangeNotifierProvider.value(value: gFFI.cursorModel),
        ChangeNotifierProvider.value(value: gFFI.canvasModel),
        ChangeNotifierProvider.value(value: gFFI.peerTabModel),
      ],
      child: GetMaterialApp(
        navigatorKey: globalKey,
        debugShowCheckedModeBanner: false,
        title: '${bind.mainGetAppNameSync()} Web Client V2 (Preview)',
        locale: _forcedWebLocale,
        theme: MyTheme.lightTheme,
        darkTheme: MyTheme.darkTheme,
        themeMode: MyTheme.currentThemeMode(),
        home: WebHomePage(),
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: const [_forcedWebLocale],
        navigatorObservers: [
          BotToastNavigatorObserver(),
        ],
        builder: (context, child) {
          child = MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(1.0),
            ),
            child: child ?? Container(),
          );
          return botToastBuilder(context, child);
        },
      ),
    );
  }
}
