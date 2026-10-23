import 'package:flutter/material.dart';
import 'presentation/screens/desktop_main_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CamSyncDesktopApp());
}

class CamSyncDesktopApp extends StatelessWidget {
  final bool autoStartUsb;
  const CamSyncDesktopApp({super.key, this.autoStartUsb = true});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CamSync Virtual Camera Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.blueAccent,
        useMaterial3: true,
      ),
      home: DesktopMainScreen(autoStartUsb: autoStartUsb),
    );
  }
}
