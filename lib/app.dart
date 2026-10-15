import 'dart:async';

import 'package:flutter/material.dart';

import 'features/alarms/alarm_controller.dart';
import 'features/alarms/alarm_repository.dart';
import 'features/settings/settings_controller.dart';
import 'models/app_settings.dart';
import 'platform/alarm_engine.dart';
import 'features/shell/shell_screen.dart';
import 'features/shell/shell_screen_view_model.dart';
import 'package:provider/provider.dart';

class WakeGuardApp extends StatefulWidget {
  const WakeGuardApp({
    super.key,
    required this.engine,
    required this.repository,
  });

  final AlarmEngine engine;
  final AlarmRepository repository;

  @override
  State<WakeGuardApp> createState() => _WakeGuardAppState();
}

class _WakeGuardAppState extends State<WakeGuardApp> {
  late final SettingsController _settings;
  late final AlarmController _alarms;

  @override
  void initState() {
    super.initState();
    _settings = SettingsController();
    _alarms = AlarmController(
      engine: widget.engine,
      repository: widget.repository,
    );
    unawaited(_settings.load());
    unawaited(_alarms.attach());
  }

  @override
  void dispose() {
    _settings.dispose();
    _alarms.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'WakeGuard',
        theme: _theme(Brightness.light),
        darkTheme: _theme(Brightness.dark),
        themeMode: switch (_settings.settings.themeMode) {
          ThemeModeSetting.system => ThemeMode.system,
          ThemeModeSetting.light => ThemeMode.light,
          ThemeModeSetting.dark => ThemeMode.dark,
        },
        home: ChangeNotifierProvider<ShellScreenViewModel>(
          create: (_) => ShellScreenViewModel(
            engine: widget.engine,
            controller: _alarms,
            settings: _settings,
          ),
          child: Consumer<ShellScreenViewModel>(
            builder: (_, viewModel, _) => ShellScreen(viewModel: viewModel),
          ),
        ),
      ),
    );
  }

  static ThemeData _theme(Brightness brightness) => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xffef5b2a),
      brightness: brightness,
    ),
    useMaterial3: true,
  );
}
