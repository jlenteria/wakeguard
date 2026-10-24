import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../platform/alarm_engine.dart';
import '../../shared/brand.dart';
import '../../shared/theme.dart';
import '../alarms/alarm_controller.dart';
import 'stay_awake_view_model.dart';

/// Visible on every shell tab during the native one-minute response window.
class StayAwakeBanner extends StatelessWidget {
  const StayAwakeBanner({
    super.key,
    required this.engine,
    required this.controller,
  });

  final AlarmEngine engine;
  final AlarmController controller;

  @override
  Widget build(
    BuildContext context,
  ) => ChangeNotifierProvider<StayAwakeViewModel>(
    create: (_) => StayAwakeViewModel(engine, controller),
    child: Consumer<StayAwakeViewModel>(
      builder: (context, vm, _) {
        final checkIn = vm.current;
        if (checkIn == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        final tokens = WakeTokens.of(context);
        return SafeArea(
          bottom: false,
          child: SingleChildScrollView(
            primary: false,
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.brightness == Brightness.light
                    ? colors.surfaceContainerLowest
                    : colors.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(28),
                border: Border.all(color: tokens.amber.withValues(alpha: 0.45)),
                boxShadow: [
                  BoxShadow(
                    color: tokens.amber.withValues(alpha: 0.18),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      IconWell(
                        icon: Icons.bedtime_outlined,
                        color: tokens.amber,
                        background: tokens.amber.withValues(alpha: 0.14),
                        size: 40,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Semantics(
                          header: true,
                          liveRegion: true,
                          child: Text(
                            'Still up?',
                            style: theme.textTheme.titleLarge,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ExcludeSemantics(
                        child: Text(
                          '${vm.remainingSeconds}s',
                          style: theme.textTheme.headlineMedium?.copyWith(
                            color: tokens.amber,
                            fontFeatures: WakeTheme.tabular,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '${checkIn.label} · Confirm within ${vm.remainingSeconds} seconds '
                    'to prevent a follow-up alarm.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (vm.error != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      vm.error!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: vm.confirming ? null : vm.confirm,
                    icon: const Icon(Icons.check),
                    label: Text(vm.confirming ? 'Confirming…' : "I'm up"),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}
