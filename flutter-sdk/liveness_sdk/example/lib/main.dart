import 'package:flutter/material.dart';
import 'package:flutter_face_auth_sdk/liveness_sdk.dart';
import 'home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Real APIs would normally be fetched securely, this is just demonstrating SDK initialization
  final sdk = await LiveFaceAuth.initialize(
    apiKey: "xXWn9_HSIKBCDf-nDeRn7DKYZwD8FrRdPFUnfFJOOD8",
  );

  runApp(MyApp(sdk: sdk));
}

class MyApp extends StatelessWidget {
  final LiveFaceAuth sdk;

  const MyApp({super.key, required this.sdk});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Liveness SDK Example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: Colors.white,
        fontFamily: 'Roboto',
      ),
      home: HomeScreen(sdk: sdk),
    );
  }
}
