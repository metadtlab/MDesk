import 'common.dart';
import 'main_native.dart' if (dart.library.html) 'main_web.dart' as app;

int? get kWindowId => app.kWindowId;
dynamic get kWindowType => app.kWindowType;
List<String> get kBootArgs => app.kBootArgs;

bool hasAgentIdInFilename() => app.hasAgentIdInFilename();
Future<void> showCmWindow({bool isStartup = false}) =>
    app.showCmWindow(isStartup: isStartup);
Future<void> hideCmWindow({bool isStartup = false}) =>
    app.hideCmWindow(isStartup: isStartup);

Future<void> main(List<String> args) => app.main(args);
