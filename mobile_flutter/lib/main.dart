import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'settings.dart';
import 'ui/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 行车视角：锁定横屏，使相机传感器方向与界面方向一致，
  // 从而避免检测框与预览画面之间的 90° 旋转错位。
  await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  final settings = await AppSettings.load();
  runApp(FastGuardApp(settings: settings));
}

class FastGuardApp extends StatelessWidget {
  const FastGuardApp({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FastGuard 移动端',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF09090B),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1),
          secondary: Color(0xFF818CF8),
          surface: Color(0xFF18181B),
        ),
        fontFamily: 'Microsoft YaHei',
      ),
      home: HomeScreen(settings: settings),
    );
  }
}
