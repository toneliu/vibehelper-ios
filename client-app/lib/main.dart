import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_shell.dart';
import 'core/app_settings.dart';
import 'core/pinned_http_client.dart';
import 'core/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = PinnedHttpOverrides();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
  ]);
  runApp(const ProviderScope(child: VibeHelperApp()));
}

class VibeHelperApp extends ConsumerWidget {
  const VibeHelperApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = ref.watch(settingsProvider.select((s) => s.isDarkTheme));
    return MaterialApp(
      title: 'VibeHelper',
      debugShowCheckedModeBanner: false,
      theme: VibeTheme.light(),
      darkTheme: VibeTheme.dark(),
      themeMode: isDark ? ThemeMode.dark : ThemeMode.light,
      home: const VibeHelperShell(),
    );
  }
}
