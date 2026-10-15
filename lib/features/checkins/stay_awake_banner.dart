import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../platform/alarm_engine.dart';
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
        final colors = Theme.of(context).colorScheme;
        return SafeArea(
          bottom: false,
          child: SingleChildScrollView(
            primary: false,
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: colors.primary),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    header: true,
                    liveRegion: true,
                    child: Text(
                      'Still up?',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${checkIn.label} · Confirm within ${vm.remainingSeconds} seconds '
                    'to prevent a follow-up alarm.',
                  ),
                  if (vm.error != null) ...[
                    const SizedBox(height: 8),
                    Text(vm.error!),
                  ],
                  const SizedBox(height: 12),
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
