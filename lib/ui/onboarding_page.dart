import 'package:flutter/material.dart';

import '../core/alarm_controller.dart';

/// First-run screen: three things that decide whether an alarm actually rings.
///
/// An alarm app that opens straight into an empty list gives the user nothing
/// to do about the permissions and volume settings that cause the failures
/// this app exists to prevent. This is the one screen that asks for them
/// before the first alarm is saved.
class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key, required this.controller, required this.onDone});

  final AlarmController controller;

  /// Marks the screen complete and enters the app.
  final Future<void> Function() onDone;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  bool _requestingNotifications = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(listenable: widget.controller, builder: (context, _) => Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('WakeGuard', style: theme.textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                'Wake up, complete a challenge, and check you’re still up. '
                'Private, offline and free. Let’s get your first alarm ready.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              Expanded(
                child: ListView(
                  children: [
                    _Step(
                      icon: Icons.notifications_outlined,
                      title: 'Allow notifications',
                      body: 'Without them the alarm rings with nothing on '
                          'screen and the wake challenge cannot appear over '
                          'the lock screen.',
                      button: FilledButton.tonal(
                        onPressed: _requestingNotifications
                            ? null
                            : _requestNotifications,
                        child: Text(
                          _requestingNotifications ? 'Opening…' : 'Allow',
                        ),
                      ),
                    ),
                    if (widget.controller.checks.isNotEmpty) Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(widget.controller.unresolvedChecks.isEmpty ? 'Alarm settings are ready.'
                          : 'Still needed: ${widget.controller.unresolvedChecks.map((c) => c.label).join(', ')}'),
                    ),
                    if (widget.controller.lastError != null) Text(widget.controller.lastError!),
                    _Step(
                      icon: Icons.volume_up_outlined,
                      title: 'Check the alarm volume',
                      body: 'A muted alarm stream is silent no matter how '
                          'reliable the scheduling is. This plays the real '
                          'tone for ten seconds.',
                      button: FilledButton.tonal(
                        onPressed: widget.controller.runPreflight,
                        child: const Text('Test the sound'),
                      ),
                    ),
                    _Step(
                      icon: Icons.health_and_safety_outlined,
                      title: 'Exact alarms',
                      body: 'Android may delay an alarm by minutes unless it '
                          'is allowed to fire exactly. The Health tab shows '
                          'this and the rest.',
                      button: FilledButton.tonal(
                        onPressed: () => widget.controller.openFix('exact_alarm'),
                        child: const Text('Allow exact alarms'),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => widget.onDone(),
                child: const Text('Get started'),
              ),
              TextButton(
                onPressed: () => widget.onDone(),
                child: const Text('Skip for now'),
              ),
            ],
          ),
        ),
      ),
    ));
  }

  Future<void> _requestNotifications() async {
    setState(() => _requestingNotifications = true);
    try {
      await widget.controller.engine.requestPermissions();
      await widget.controller.refreshHealth();
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not request notifications: $error')));
    } finally {
      if (mounted) setState(() => _requestingNotifications = false);
    }
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.icon,
    required this.title,
    required this.body,
    this.button,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? button;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 28),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(body, style: theme.textTheme.bodySmall),
                if (button != null) ...[
                  const SizedBox(height: 8),
                  button!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
