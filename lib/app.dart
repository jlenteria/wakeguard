import 'dart:async';

import 'package:flutter/material.dart';

import 'core/alarm.dart';
import 'core/alarm_controller.dart';
import 'core/alarm_repository.dart';
import 'core/settings.dart';
import 'core/wake_up_qr.dart';
import 'platform/alarm_engine.dart';
import 'ui/alarm_editor.dart';
import 'ui/health_page.dart';
import 'ui/history_page.dart';
import 'ui/onboarding_page.dart';
import 'ui/settings_page.dart';

class WakeGuardApp extends StatefulWidget {
  const WakeGuardApp({
    super.key,
    required this.engine,
    required this.repository,
    this.pendingChallenge,
  });

  final AlarmEngine engine;
  final AlarmRepository repository;

  /// Non-null when the app was cold-launched straight into a live alarm.
  final Map<String, Object?>? pendingChallenge;

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
        home: RootShell(
          engine: widget.engine,
          controller: _alarms,
          settings: _settings,
          pendingChallenge: widget.pendingChallenge,
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

class RootShell extends StatefulWidget {
  const RootShell({
    super.key,
    required this.engine,
    required this.controller,
    required this.settings,
    this.pendingChallenge,
  });

  final AlarmEngine engine;
  final AlarmController controller;
  final SettingsController settings;

  /// Non-null when the app was cold-launched straight into a live alarm.
  final Map<String, Object?>? pendingChallenge;

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> with WidgetsBindingObserver {
  int _tab = 0;
  Timer? _clock;
  bool _foreground = true;
  Alarm? _pendingCameraDraft;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _clock = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && _foreground && _tab == 0) setState(() {});
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock?.cancel();
    super.dispose();
  }

  /// The user usually fixes a health item in system settings and then comes
  /// back, so re-check as soon as the app is foregrounded again. This is also
  /// when an alarm that fired while the app was closed gets reconciled into
  /// the list.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (state == AppLifecycleState.resumed) {
      unawaited(widget.controller.refreshHealth());
      unawaited(widget.controller.reload());
    } else {
      // A preview or sound test must not keep playing once the app is not in
      // front of the user.
      unawaited(widget.controller.stopAudibilitySample());
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (!widget.settings.loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (!widget.settings.settings.onboardingDone) {
      return OnboardingPage(
        controller: controller,
        onDone: () async {
          // "Get started"/"Skip" enters the home shell: silence the sound test
          // that the onboarding step may have left running.
          await controller.stopAudibilitySample();
          await widget.settings.update((s) => s.copyWith(onboardingDone: true));
        },
      );
    }
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Scaffold(
          body: controller.fatalError != null
              ? _FatalErrorView(
                  message: controller.fatalError!,
                  onRetry: controller.retry,
                )
              : IndexedStack(
                  index: _tab,
                  children: [
                    AlarmListView(
                      controller: controller,
                      onOpenHealth: () => setState(() => _tab = 1),
                      onOpen: (alarm) => _openEditor(context, existing: alarm),
                    ),
                     HealthPage(
                       controller: controller,
                       onReturnToAlarm: _pendingCameraDraft == null ? null
                           : () => _openEditor(context, existing: _pendingCameraDraft),
                     ),
                    HistoryPage(controller: controller),
                    SettingsPage(
                      controller: controller,
                      settings: widget.settings.settings,
                      onSettingsChanged: (next) =>
                          unawaited(widget.settings.update((_) => next)),
                    ),
                  ],
                ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (index) {
              // Switching tabs leaves the screen the sound was started from, so
              // a running audibility sample would otherwise keep ringing.
              if (index != _tab) unawaited(controller.stopAudibilitySample());
              setState(() => _tab = index);
            },
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.alarm_outlined),
                selectedIcon: Icon(Icons.alarm),
                label: 'Alarms',
              ),
              NavigationDestination(
                icon: Icon(Icons.health_and_safety_outlined),
                selectedIcon: Icon(Icons.health_and_safety),
                label: 'Health',
              ),
              NavigationDestination(
                icon: Icon(Icons.insights_outlined),
                selectedIcon: Icon(Icons.insights),
                label: 'History',
              ),
              NavigationDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: 'Settings',
              ),
            ],
          ),
          floatingActionButton: _tab == 0
              ? FloatingActionButton.extended(
                  onPressed: () => _openEditor(context),
                  icon: const Icon(Icons.alarm_add),
                  label: const Text('Add alarm'),
                )
              : null,
        );
      },
    );
  }

  Future<void> _openEditor(BuildContext context, {Alarm? existing}) async {
    String sharedQr;
    try {
      final codes = widget.controller.alarms.map((a) => a.qrValue.trim()).where((code) => code.isNotEmpty);
      sharedQr = await WakeUpQrRepository().getOrCreate(
          preferredValue: codes.isEmpty ? null : codes.first);
    } catch (error) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load wake-up QR: $error')));
      return;
    }
    if (!context.mounted) return;
    final draft = await showModalBottomSheet<Alarm>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => AlarmEditor(
        engine: widget.engine,
        sharedQrValue: sharedQr,
        existing: existing,
        defaultSnoozeMinutes: widget.settings.settings.defaultSnoozeMinutes,
        canCheckIn: widget.controller.capabilities?.canCheckIn ?? false,
        canPractice: widget.controller.capabilities?.canPractice ?? false,
      ),
    );
    if (draft == null || !mounted) return;

    // Re-check right now: the user may have just fixed (or revoked) something.
    await widget.controller.refreshHealth();
    if (!mounted) return;
    if (widget.controller.cameraPermissionMissingFor(draft)) {
      setState(() { _pendingCameraDraft = draft; _tab = 1; });
      ScaffoldMessenger.of(this.context).showSnackBar(const SnackBar(
        content: Text('Alarm not saved. Enable Camera in Health, then tap Return to alarm to save your draft.'),
      ));
      return;
    }
    final unresolved = widget.controller.unresolvedChecks;
    if (unresolved.isNotEmpty) {
      // Keep the alarm rather than throwing the draft away. It cannot ring
      // until the checks pass, so it is stored switched off and the user is
      // told exactly that — losing the whole alarm to a settings problem was
      // the worst outcome of the old behaviour.
      await widget.controller.upsert(draft.copyWith(enabled: false));
      if (!mounted) return;
      setState(() => _tab = 1);
      final messenger = ScaffoldMessenger.of(this.context);
      messenger.clearSnackBars();
      messenger.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: Theme.of(this.context).colorScheme.error,
          duration: const Duration(seconds: 8),
          content: Text(
            'Saved, but switched off: ${unresolved.map((c) => c.label).join(', ')}'
            ' must be fixed first. Turn the alarm on once the Health tab is '
            'clear.',
          ),
        ),
      );
      return;
    }
    await widget.controller.upsert(draft);
    if (!mounted) return;
    final error = widget.controller.lastError;
    if (error == null) setState(() => _pendingCameraDraft = null);
    final at = widget.controller.nextFireTime(draft.id);
    final message = error ?? (!draft.enabled ? 'Saved, switched off.' : at == null
        ? 'Saved. Check alarm readiness.'
        : 'Next alarm: ${MaterialLocalizations.of(this.context).formatMediumDate(at)} at ${TimeOfDay.fromDateTime(at).format(this.context)}');
    ScaffoldMessenger.of(this.context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class AlarmListView extends StatelessWidget {
  const AlarmListView({
    super.key,
    required this.controller,
    required this.onOpen,
    this.onOpenHealth,
  });

  final AlarmController controller;
  final VoidCallback? onOpenHealth;

  /// Opens the editor for an existing alarm; tapping a row used to only
  /// toggle the switch, which left no way to change a saved alarm at all.
  final Future<void> Function(Alarm alarm) onOpen;

  @override
  Widget build(BuildContext context) {
    if (controller.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final dropped = controller.droppedAlarms;
    return Scaffold(
      appBar: AppBar(title: const Text('WakeGuard')),
      body: Column(
        children: [
          if (controller.lastError != null)
            _ErrorBar(
              message: controller.lastError!,
              onDismiss: controller.clearError,
            ),
          Expanded(
            child: controller.alarms.isEmpty
                 ? Column(children: [_ReadinessCard(controller: controller), const Expanded(child: _EmptyState())])
                 : ListView.builder(
                     itemCount: controller.alarms.length + 2,
                     itemBuilder: (context, index) {
                       if (index == 0) return Column(children: [
                       _ReadinessCard(controller: controller),
                       if (dropped.isNotEmpty)
                         _SlotWarning(count: dropped.length),
                       for (final banner in _nextAlarm(controller)) banner,
                       ]);
                       if (index == controller.alarms.length + 1) return const SizedBox(height: 96);
                       final alarm = controller.alarms[index - 1];
                       return _AlarmTile(
                          alarm: alarm,
                          plannedAt: controller.nextFireTime(alarm.id),
                          onOpen: onOpen,
                           onToggle: (value) async {
                             try {
                               await controller.setEnabled(alarm, value);
                             } finally {
                               if (value && controller.cameraPermissionMissingFor(alarm)) onOpenHealth?.call();
                             }
                           },
                          onDelete: () => controller.delete(alarm),
                           onRestore: () => controller.upsert(alarm),
                           onDuplicate: () => controller.duplicate(alarm),
                           onSkip: () => alarm.skipUntilMillis > DateTime.now().millisecondsSinceEpoch
                               ? controller.restoreNext(alarm) : controller.skipNext(alarm),
                         );
                     },
                  ),
          ),
        ],
      ),
    );
  }

  /// The soonest armed trigger, as a one-line banner.
  ///
  /// "Rings in 7h 32m" is the answer to the only question the list itself
  /// cannot answer: whether what is armed is the alarm you think it is.
  static List<Widget> _nextAlarm(AlarmController controller) {
    if (controller.alarms.isEmpty) return const [];
    DateTime? soonest;
    for (final planned in controller.planned) {
      final at = controller.nextFireTime(planned.alarm.id) ?? planned.triggerAt;
      if (soonest == null ||
          at.isBefore(soonest)) {
        soonest = at;
      }
    }
    if (soonest == null) return const [];
    return [_NextAlarmBanner(triggerAt: soonest)];
  }
}

class _ReadinessCard extends StatelessWidget {
  const _ReadinessCard({required this.controller});
  final AlarmController controller;
  @override
  Widget build(BuildContext context) {
    final blocking = controller.unresolvedChecks;
    return Card(margin: const EdgeInsets.fromLTRB(16, 12, 16, 8), child: ListTile(
      leading: Icon(blocking.isEmpty ? Icons.check_circle_outline : Icons.error_outline),
      title: Text(controller.checks.isEmpty ? 'Checking readiness…' : blocking.isEmpty ? 'Alarm settings ready' : 'Your alarm needs attention'),
      subtitle: Text(blocking.isEmpty ? 'Practise your challenge and test the sound before your first morning.' : blocking.map((c) => c.label).join(', ')),
      onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => HealthPage(controller: controller))),
    ));
  }
}

class _NextAlarmBanner extends StatelessWidget {
  const _NextAlarmBanner({required this.triggerAt});

  final DateTime triggerAt;

  @override
  Widget build(BuildContext context) {
    final delta = triggerAt.difference(DateTime.now());
    final label = delta.isNegative || delta.inMinutes < 1
        ? 'rings now'
        : delta.inHours >= 24
            ? 'rings in ${delta.inDays}d ${delta.inHours % 24}h'
            : 'rings in ${delta.inHours}h ${delta.inMinutes % 60}m';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Row(
        children: [
          const Icon(Icons.schedule, size: 16),
          const SizedBox(width: 8),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _ErrorBar extends StatelessWidget {
  const _ErrorBar({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.errorContainer,
      child: ListTile(
        leading: const Icon(Icons.error_outline),
        title: Text(message, style: const TextStyle(fontSize: 13)),
        trailing: IconButton(
          icon: const Icon(Icons.close),
          onPressed: onDismiss,
        ),
      ),
    );
  }
}

class _SlotWarning extends StatelessWidget {
  const _SlotWarning({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.warning_amber),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '$count alarm(s) exceed this platform\'s pending notification '
                'budget and will NOT ring. Disable or delete some alarms '
                '(swipe left to delete).',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AlarmTile extends StatelessWidget {
  const _AlarmTile({
    required this.alarm,
    required this.onOpen,
    required this.onToggle,
    required this.onDelete,
    required this.onRestore,
    required this.onDuplicate,
    required this.onSkip,
    this.plannedAt,
  });

  final Alarm alarm;
  final Future<void> Function(Alarm alarm) onOpen;
  final Future<void> Function(bool) onToggle;
  final Future<bool> Function() onDelete;
  final Future<void> Function() onRestore;
  final Future<void> Function() onDuplicate;
  final Future<void> Function() onSkip;
  final DateTime? plannedAt;

  @override
  Widget build(BuildContext context) {
    final time = TimeOfDay(hour: alarm.hour, minute: alarm.minute);
    final timeLabel = time.format(context);
    final messenger = ScaffoldMessenger.of(context);
    return Dismissible(
      key: ValueKey(alarm.id),
      direction: DismissDirection.endToStart,
      confirmDismiss: (_) async {
        final deleted = await onDelete();
        if (!deleted) return false;
        // Captured before the await: the tile itself is unmounted by the time
        // the delete lands, and looking the messenger up through it would
        // throw exactly when the user most needs the Undo button.
        messenger.clearSnackBars();
        messenger.showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
            // Action snackbars persist by default; Undo has a five-second window.
            persist: false,
            content: Text('Deleted the $timeLabel alarm'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () => unawaited(onRestore().catchError((Object error) {
                messenger.showSnackBar(SnackBar(content: Text('Could not restore alarm: $error')));
              })),
            ),
          ),
        );
        return true;
      },
      background: Container(
        color: Theme.of(context).colorScheme.error,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete_outline),
      ),
      // A plain ListTile rather than SwitchListTile: the latter wires every
      // row tap to the switch, which made a saved alarm impossible to edit.
      child: Opacity(
        opacity: alarm.enabled ? 1 : 0.55,
        child: ListTile(
          onTap: () => onOpen(alarm),
          title: Text(time.format(context), style: const TextStyle(fontSize: 32)),
          subtitle: Text([
            '${alarm.label} · ${_repeatSummary(alarm)}',
            if (plannedAt != null) 'rings ${_relative(plannedAt!)}',
            '${alarm.difficulty.label} challenge · ${_escapeSummary(alarm)}'
                '${alarm.snoozeMinutes == 0 ? ' · no snooze' : ''}',
            if (alarm.checkInMinutes > 0) 'Stay Awake check-in · ${alarm.checkInMinutes} min',
            if (alarm.skipUntilMillis > DateTime.now().millisecondsSinceEpoch) 'Next occurrence skipped',
          ].join('\n')),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Switch(value: alarm.enabled, onChanged: (value) async {
              try { await onToggle(value); }
              catch (error) { messenger.showSnackBar(SnackBar(content: Text('Could not update alarm: $error'))); }
            }),
            PopupMenuButton<String>(tooltip: 'Alarm actions',
              onSelected: (action) async {
                try {
                  if (action == 'duplicate') await onDuplicate();
                  if (action == 'skip') await onSkip();
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(
                    action == 'duplicate' ? 'Alarm duplicated, switched off. Edit it to choose a time.' : 'Schedule updated.')));
                } catch (error) {
                  if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not update alarm: $error')));
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'duplicate', child: Text('Duplicate')),
                if (alarm.enabled && alarm.isRepeating) PopupMenuItem(value: 'skip', child: Text(
                  alarm.skipUntilMillis > DateTime.now().millisecondsSinceEpoch ? 'Restore skipped occurrence' : 'Skip next occurrence')),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  /// "Face, Pattern" — what the alarm will actually ask for, so a restricted
  /// escape set is visible without opening the editor.
  static String _escapeSummary(Alarm alarm) => EscapeKind.values
      .where(alarm.escapes.contains)
      .map((escape) => escape.label)
      .join(', ');

  /// "Every day", "Mon, Wed, Fri" or "Once" — the shape of the alarm at a
  /// glance, which the time alone never tells you.
  static String _repeatSummary(Alarm alarm) {
    if (!alarm.isRepeating) return 'Once';
    if (alarm.weekdays.isEmpty) return 'Every day';
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final ordered = alarm.weekdays.toList()..sort();
    return ordered.map((day) => names[day - 1]).join(', ');
  }

  static String _relative(DateTime when) {
    final delta = when.difference(DateTime.now());
    if (delta.isNegative || delta.inMinutes < 1) return 'now';
    if (delta.inMinutes < 60) return 'in ${delta.inMinutes}m';
    if (delta.inHours < 24) {
      return 'in ${delta.inHours}h ${delta.inMinutes % 60}m';
    }
    return 'in ${delta.inDays}d';
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.alarm_off_outlined, size: 56),
            SizedBox(height: 16),
            Text(
              'Make tomorrow morning easier.\nAdd an alarm, choose a preset, '
              'and practise your challenge.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _FatalErrorView extends StatelessWidget {
  const _FatalErrorView({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 56),
              const SizedBox(height: 16),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
                onPressed: () => unawaited(onRetry()),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
