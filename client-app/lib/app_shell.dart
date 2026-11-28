import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/connection/connection_controller.dart';
import 'features/mobile/mobile_vibe_page.dart';

class VibeHelperShell extends ConsumerStatefulWidget {
  const VibeHelperShell({super.key});

  @override
  ConsumerState<VibeHelperShell> createState() => _VibeHelperShellState();
}

class _VibeHelperShellState extends ConsumerState<VibeHelperShell>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(ref.read(hostActionProvider).autoConnectOnStartup());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(ref.read(hostActionProvider).reconnectOnResume());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const MobileVibePage();
  }
}
