import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/theme.dart';
import 'features/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: MeetingRecorderApp()));
}

class MeetingRecorderApp extends StatelessWidget {
  const MeetingRecorderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '회의 녹음',
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      home: const HomeScreen(),
    );
  }
}
