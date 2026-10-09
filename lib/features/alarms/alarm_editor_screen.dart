import 'package:flutter/material.dart';

import '../../models/alarm.dart';
import '../../platform/alarm_engine.dart';
import 'alarm_editor_screen_view_model.dart';
import '../challenges/qr_sheet.dart';
import '../../shared/toast.dart';
import '../../shared/view_model.dart';

/// Public entry for creating or editing an alarm. Stateless: it only wires the
/// view model lifecycle to [AlarmEditorScreen].
class AlarmEditor extends StatelessWidget {
  const AlarmEditor({
    super.key,
    this.existing,
    this.engine,
    this.defaultSnoozeMinutes,
    this.canCheckIn = true,
    this.canPractice = true,
    this.sharedQrValue,
  });

  final Alarm? existing;

  /// Enables tone preview only; null disables it, keeping the editor usable in tests.
  final AlarmEngine? engine;
  final int? defaultSnoozeMinutes;
  final bool canCheckIn;
  final bool canPractice;
  final String? sharedQrValue;

  @override
  Widget build(BuildContext context) {
    return ViewModelProvider<AlarmEditorScreenViewModel>(
      create: (_) => AlarmEditorScreenViewModel(
        engine: engine,
        existing: existing,
        defaultSnoozeMinutes: defaultSnoozeMinutes,
        canCheckIn: canCheckIn,
        canPractice: canPractice,
        sharedQrValue: sharedQrValue,
      ),
      builder: (context, viewModel) => AlarmEditorScreen(viewModel: viewModel),
    );
  }
}

class AlarmEditorScreen extends StatelessWidget {
  const AlarmEditorScreen({super.key, required this.viewModel});

  final AlarmEditorScreenViewModel viewModel;

  static const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  /// Snooze lengths offered; zero means no snooze, the point of a strict alarm.
  static const _snoozeChoices = [0, 5, 9, 15];

  @override
  Widget build(BuildContext context) {
    // Use both insets; handling only the keyboard hides Save behind the nav bar.
    final media = MediaQuery.of(context);
    final bottomInset = media.viewPadding.bottom + media.viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 8, 24, bottomInset + 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(viewModel.isExisting ? 'Edit alarm' : 'Make tomorrow morning easier',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (index, name) in [
                (0, 'Simple'),
                (1, 'Challenge'),
                (2, 'Get out of bed')
              ])
                ChoiceChip(
                  label: Text(name),
                  selected: viewModel.preset == index,
                  onSelected: (_) => viewModel.applyPreset(index),
                ),
            ]),
            const SizedBox(height: 8),
            Text('Presets set the challenge, snooze and check-in. You can customise everything below.',
                style: Theme.of(context).textTheme.bodySmall),
            TextButton(
              onPressed: () async {
                final picked =
                    await showTimePicker(context: context, initialTime: viewModel.time);
                if (picked != null) viewModel.setTime(picked);
              },
              child: Text(viewModel.time.format(context), style: const TextStyle(fontSize: 52)),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: viewModel.labelController,
              decoration: const InputDecoration(labelText: 'Label'),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 16),
            Text('Wake escapes', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'Which ways out this alarm offers when it rings. The one-minute '
              'hold is always available, so no combination can leave you '
              'stuck.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final escape in EscapeKind.values)
                  FilterChip(
                    label: Text(escape.label),
                    selected: viewModel.escapes.contains(escape),
                    onSelected: (selected) => viewModel.toggleEscape(escape, selected),
                  ),
              ],
            ),
            if (viewModel.validationError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  viewModel.validationError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 13),
                ),
              ),
            // Only when QR is on: an unused code field is one more thing to misread at 05:00.
            if (viewModel.showQrField) ...[
              const SizedBox(height: 16),
              TextField(
                controller: viewModel.qrController,
                decoration: InputDecoration(
                  labelText: 'QR code secret',
                  helperText: viewModel.qrController.text.isEmpty
                      ? 'Generate one, then print or show it away from the '
                          'bed so getting up is unavoidable.'
                      : viewModel.usesSharedQr
                          ? 'Your shared wake-up QR. Print once for all alarms using it.'
                          : 'Custom code for this alarm. Existing printed codes still work.',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.qr_code_2_outlined),
                    tooltip: 'Generate a custom code for this alarm',
                    onPressed: viewModel.generateCustomQrSecret,
                  ),
                ),
                onChanged: (_) => viewModel.clearValidation(),
              ),
              if (viewModel.hasQrValue)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.qr_code_scanner_outlined),
                    label: Text(viewModel.usesSharedQr ? 'Show wake-up QR' : 'Show QR code'),
                    onPressed: () => _showQrSheet(context, viewModel.trimmedQr),
                  ),
                ),
              if (viewModel.sharedQrValue != null && !viewModel.usesSharedQr)
                TextButton.icon(
                  icon: const Icon(Icons.link),
                  label: const Text('Use shared wake-up QR'),
                  onPressed: viewModel.useSharedQr,
                ),
            ],
            const SizedBox(height: 16),
            Text('Repeat', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              ChoiceChip(
                label: const Text('Once'),
                selected: !viewModel.repeatDaily,
                onSelected: (_) => viewModel.selectOnce(),
              ),
              ChoiceChip(
                label: const Text('Every day'),
                selected: viewModel.repeatDaily && viewModel.weekdays.isEmpty,
                onSelected: (_) => viewModel.selectEveryDay(),
              ),
              ChoiceChip(
                label: const Text('Selected days'),
                selected: viewModel.repeatDaily && viewModel.weekdays.isNotEmpty,
                onSelected: (_) => viewModel.selectSelectedDays(),
              ),
            ]),
            if (viewModel.repeatDaily && viewModel.weekdays.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (var day = 1; day <= 7; day++)
                    FilterChip(
                      label: Text(_weekdayNames[day - 1]),
                      selected: viewModel.weekdays.contains(day),
                      onSelected: (selected) => viewModel.toggleWeekday(day, selected),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  viewModel.weekdays.isEmpty ? 'Every day' : 'Selected weekdays only',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text('Wake challenge', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            SegmentedButton<ChallengeDifficulty>(
              segments: [
                for (final difficulty in ChallengeDifficulty.values)
                  ButtonSegment(
                    value: difficulty,
                    label: Text('${difficulty.label} (${difficulty.stepCount})'),
                  ),
              ],
              selected: {viewModel.difficulty},
              onSelectionChanged: (value) => viewModel.setDifficulty(value.first),
            ),
            const SizedBox(height: 16),
            Text('Sound', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'The alarm plays the tone you pick for as long as it rings. '
              'Previews play at your phone\'s current alarm volume.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            RadioGroup<AlarmSoundPack>(
              groupValue: viewModel.soundPack,
              onChanged: (value) => viewModel.setSoundPack(value ?? viewModel.soundPack),
              child: Column(
                children: [
                  for (final pack in AlarmSoundPack.values)
                    RadioListTile<AlarmSoundPack>(
                      contentPadding: EdgeInsets.zero,
                      value: pack,
                      title: Text(pack.label),
                      subtitle: Text(pack.description),
                      secondary: viewModel.previewing == pack.index
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : IconButton(
                              icon: const Icon(Icons.volume_up_outlined),
                              tooltip: 'Preview ${pack.label}',
                              onPressed:
                                  viewModel.previewingAny ? null : () => viewModel.preview(pack),
                            ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text('Snooze', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Text(
              'How long this alarm can be put off. "No snooze" hides the '
              'snooze button entirely, so the alarm only ends when you stop it.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final minutes in _snoozeChoices)
                  ChoiceChip(
                    label: Text(minutes == 0 ? 'No snooze' : '$minutes min'),
                    selected: viewModel.snoozeMinutes == minutes,
                    onSelected: (_) => viewModel.setSnoozeMinutes(minutes),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            if (viewModel.canCheckIn) ...[
              Text('Stay Awake check-in', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              const Text(
                  "After dismissal, tap ‘I'm up’ in a notification. You have 1 minute to respond; otherwise one follow-up alarm rings. Off by default."),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final minutes in [0, 3, 5, 10])
                  ChoiceChip(
                    label: Text(minutes == 0 ? 'Off' : '$minutes min'),
                    selected: viewModel.checkInMinutes == minutes,
                    onSelected: (_) => viewModel.setCheckInMinutes(minutes),
                  ),
              ]),
            ],
            if (viewModel.engine != null && viewModel.canPractice)
              TextButton.icon(
                onPressed: () => _practice(context),
                icon: const Icon(Icons.play_circle_outline),
                label: const Text('Practise this challenge — no alarm scheduled'),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: viewModel.saving ? null : () => _save(context),
              child: Text(viewModel.saving ? 'Saving…' : 'Save alarm'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _practice(BuildContext context) async {
    final error = await viewModel.practice();
    if (error == null || !context.mounted) return;
    showAppToast(context, kind: ToastKind.error, message: 'Could not start practice', detail: error);
  }

  Future<void> _save(BuildContext context) async {
    final alarm = await viewModel.save();
    if (alarm == null || !context.mounted) return;
    Navigator.pop(context, alarm);
  }

  void _showQrSheet(BuildContext context, String value) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Without this the sheet caps at 9/16 screen, clipping the code and labels.
      isScrollControlled: true,
      builder: (_) => QrSheet(value: value),
    );
  }
}
