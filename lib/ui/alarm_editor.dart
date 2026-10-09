import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../core/alarm.dart';
import '../core/wake_up_qr.dart';
import '../platform/alarm_engine.dart';

class AlarmEditor extends StatefulWidget {
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

  /// Used only to preview tone families. Null disables preview, which keeps the
  /// editor usable in widget tests and on the no-op engine.
  final AlarmEngine? engine;

  /// Snooze length for a brand-new alarm, taken from settings.
  final int? defaultSnoozeMinutes;
  final bool canCheckIn;
  final bool canPractice;
  final String? sharedQrValue;

  @override
  State<AlarmEditor> createState() => _AlarmEditorState();
}

class _AlarmEditorState extends State<AlarmEditor> {
  late TimeOfDay _time;
  late final TextEditingController _label;
  late final TextEditingController _qr;
  late bool _enabled;
  late bool _repeatDaily;
  late Set<int> _weekdays;
  late ChallengeDifficulty _difficulty;
  late AlarmSoundPack _soundPack;
  late int _snoozeMinutes;
  late int _checkInMinutes;
  int? _preset;
  bool _saving = false;
  late Set<EscapeKind> _escapes;
  String? _validationError;
  int? _previewing;


  static const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  /// Snooze lengths offered in the editor. Zero means the alarm cannot be
  /// snoozed at all, which is the point of a strict alarm.
  static const _snoozeChoices = [0, 5, 9, 15];

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    _time = existing == null
        ? const TimeOfDay(hour: 7, minute: 0)
        : TimeOfDay(hour: existing.hour, minute: existing.minute);
    _label = TextEditingController(text: existing?.label ?? 'Wake up');
    _qr = TextEditingController(text: existing?.qrValue ?? '');
    _enabled = existing?.enabled ?? true;
    _repeatDaily = existing?.repeatDaily ?? true;
    _weekdays = {...?existing?.weekdays};
    _difficulty = existing?.difficulty ?? ChallengeDifficulty.moderate;
    _soundPack = existing?.soundPack ?? AlarmSoundPack.pulse;
    _snoozeMinutes =
        existing?.snoozeMinutes ?? widget.defaultSnoozeMinutes ?? Alarm.defaultSnoozeMinutes;
    _checkInMinutes = existing?.checkInMinutes ?? 0;
    _escapes = {...?existing?.escapes};
    if (_escapes.isEmpty) _escapes = {...Alarm.defaultEscapes};
    // A record that offers QR without a code — one written before escapes
    // existed, or restored from a partial backup — must not open with Save
    // permanently blocked: the escape that has no code is simply not offered.
    // Turning the chip back on generates one.
    if (_escapes.contains(EscapeKind.qr) && _qr.text.trim().isEmpty) {
      _escapes.remove(EscapeKind.qr);
      if (_escapes.isEmpty) _escapes = {...Alarm.defaultEscapes};
    }
  }

  @override
  void dispose() {
    // Covers dismissing the sheet without saving (drag down, back gesture).
    unawaited(
      (widget.engine?.stopAudibilitySample() ?? Future<void>.value())
          .catchError((Object _) {}),
    );
    _label.dispose();
    _qr.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Both insets, same as the QR sheet: the keyboard and the Android
    // navigation bar are independent, and handling only the keyboard leaves
    // the Save button under the nav bar on every three-button device.
    final media = MediaQuery.of(context);
    final bottomInset = media.viewPadding.bottom + media.viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, 8, 24, bottomInset + 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.existing == null ? 'Make tomorrow morning easier' : 'Edit alarm',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final (index, name) in [(0, 'Simple'), (1, 'Challenge'), (2, 'Get out of bed')])
                ChoiceChip(label: Text(name), selected: _preset == index,
                    onSelected: (_) => _applyPreset(index)),
            ]),
            const SizedBox(height: 8),
            Text('Presets set the challenge, snooze and check-in. You can customise everything below.',
                style: Theme.of(context).textTheme.bodySmall),
            TextButton(
              onPressed: () async {
                final picked = await showTimePicker(context: context, initialTime: _time);
                if (picked != null) setState(() => _time = picked);
              },
              child: Text(
                _time.format(context),
                style: const TextStyle(fontSize: 52),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _label,
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
                    selected: _escapes.contains(escape),
                    onSelected: (selected) => setState(() {
                      if (selected) {
                        _escapes.add(escape);
                        // A selected QR escape with nothing to scan is a
                        // button on the ringing screen pointing at nothing,
                        // so the code exists before the chip lands.
                        if (escape == EscapeKind.qr && _qr.text.trim().isEmpty) {
                          _qr.text = widget.sharedQrValue ?? _newSecret();
                        }
                      } else {
                        _escapes.remove(escape);
                      }
                      _validationError = null;
                    }),
                  ),
              ],
            ),
            if (_validationError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _validationError!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 13,
                  ),
                ),
              ),
            // Only when the QR escape is on: a field for a code the alarm
            // will not ask for is one more thing to misread at 05:00.
            if (_escapes.contains(EscapeKind.qr)) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _qr,
                decoration: InputDecoration(
                  labelText: 'QR code secret',
                  helperText: _qr.text.isEmpty
                      ? 'Generate one, then print or show it away from the '
                          'bed so getting up is unavoidable.'
                       : _qr.text.trim() == widget.sharedQrValue
                           ? 'Your shared wake-up QR. Print once for all alarms using it.'
                           : 'Custom code for this alarm. Existing printed codes still work.',
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.qr_code_2_outlined),
                    tooltip: 'Generate a custom code for this alarm',
                    onPressed: _generateQrSecret,
                  ),
                ),
                onChanged: (_) => setState(() {
                  _validationError = null;
                }),
              ),
              if (_qr.text.trim().isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.qr_code_scanner_outlined),
                    label: Text(_qr.text.trim() == widget.sharedQrValue ? 'Show wake-up QR' : 'Show QR code'),
                    onPressed: () => _showQrSheet(context, _qr.text.trim()),
                  ),
                ),
              if (widget.sharedQrValue != null && _qr.text.trim() != widget.sharedQrValue)
                TextButton.icon(
                  icon: const Icon(Icons.link),
                  label: const Text('Use shared wake-up QR'),
                  onPressed: () => setState(() {
                    _qr.text = widget.sharedQrValue!;
                    _validationError = null;
                  }),
                ),
            ],
            const SizedBox(height: 16),
            Text('Repeat', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              ChoiceChip(label: const Text('Once'), selected: !_repeatDaily,
                  onSelected: (_) => setState(() { _repeatDaily = false; _weekdays.clear(); })),
              ChoiceChip(label: const Text('Every day'), selected: _repeatDaily && _weekdays.isEmpty,
                  onSelected: (_) => setState(() { _repeatDaily = true; _weekdays.clear(); })),
              ChoiceChip(label: const Text('Selected days'), selected: _repeatDaily && _weekdays.isNotEmpty,
                  onSelected: (_) => setState(() { _repeatDaily = true; if (_weekdays.isEmpty) _weekdays = {1, 2, 3, 4, 5}; })),
            ]),
            if (_repeatDaily && _weekdays.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  for (var day = 1; day <= 7; day++)
                    FilterChip(
                      label: Text(_weekdayNames[day - 1]),
                      selected: _weekdays.contains(day),
                      onSelected: (selected) => setState(() {
                        if (selected) {
                          _weekdays.add(day);
                        } else {
                          _weekdays.remove(day);
                        }
                      }),
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _weekdays.isEmpty
                      ? 'Every day'
                      : 'Selected weekdays only',
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
              selected: {_difficulty},
              onSelectionChanged: (value) =>
                  setState(() => _difficulty = value.first),
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
              groupValue: _soundPack,
              onChanged: (value) => setState(() => _soundPack = value ?? _soundPack),
              child: Column(
                children: [
                  for (final pack in AlarmSoundPack.values)
                    RadioListTile<AlarmSoundPack>(
                      contentPadding: EdgeInsets.zero,
                      value: pack,
                      title: Text(pack.label),
                      subtitle: Text(pack.description),
                      secondary: _previewing == pack.index
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : IconButton(
                              icon: const Icon(Icons.volume_up_outlined),
                              tooltip: 'Preview ${pack.label}',
                              onPressed: _previewing != null ? null : () => _preview(pack),
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
                    selected: _snoozeMinutes == minutes,
                    onSelected: (_) => setState(() => _snoozeMinutes = minutes),
                  ),
              ],
            ),
            const SizedBox(height: 24),
            if (widget.canCheckIn) ...[
            Text('Stay Awake check-in', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            const Text("After dismissal, tap ‘I'm up’ in a notification. You have 1 minute to respond; otherwise one follow-up alarm rings. Off by default."),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final minutes in [0, 3, 5, 10])
                ChoiceChip(label: Text(minutes == 0 ? 'Off' : '$minutes min'),
                    selected: _checkInMinutes == minutes,
                    onSelected: (_) => setState(() => _checkInMinutes = minutes)),
            ]),
            ],
            if (widget.engine != null && widget.canPractice) TextButton.icon(
              onPressed: _practice, icon: const Icon(Icons.play_circle_outline),
              label: const Text('Practise this challenge — no alarm scheduled')),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? 'Saving…' : 'Save alarm'),
            ),
          ],
        ),
      ),
    );
  }

  /// Generates a high-entropy secret. Uses [Random.secure] because this value
  /// is the only thing standing between a phone and a snooze, and a predictable
  /// code would let anyone nearby silence the alarm by guessing.
  void _generateQrSecret() => setState(() => _qr.text = _newSecret());

  void _applyPreset(int index) => setState(() {
    _preset = index;
    _difficulty = index == 2 ? ChallengeDifficulty.strict : ChallengeDifficulty.gentle;
    _escapes = switch (index) {
      0 => {EscapeKind.tap},
      2 => {EscapeKind.qr},
      _ => {EscapeKind.pattern},
    };
    _snoozeMinutes = index == 0 ? 9 : 0;
    _checkInMinutes = index == 2 && widget.canCheckIn ? 5 : 0;
    if (index == 2 && _qr.text.trim().isEmpty) _qr.text = widget.sharedQrValue ?? _newSecret();
    _validationError = null;
  });

  Future<void> _practice() async {
    final problem = _problem();
    if (problem != null) { setState(() => _validationError = problem); return; }
    try {
      await widget.engine?.stopAudibilitySample();
      await widget.engine?.practice(_build());
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not start practice: $error')));
    }
  }

  /// The secret itself, without touching the tree: `initState` writes it
  /// straight into the controller, where a rebuild would be pointless.
  String _newSecret() {
    return generateQrSecret();
  }

  /// Silences any running preview before closing, so the sample never keeps
  /// playing after the editor is gone.
  Future<void> _save() async {
    final problem = _problem();
    if (problem != null) {
      setState(() => _validationError = problem);
      return;
    }
    final alarm = _build();
    setState(() => _saving = true);
    try {
      await widget.engine?.stopAudibilitySample();
    } catch (_) {
      // Stopping the preview must never block saving.
    }
    if (!mounted) return;
    Navigator.pop(context, alarm);
  }

  /// Why this alarm cannot ring as configured, or null when it can.
  ///
  /// Both failures are things the challenge screen can only discover at 05:00
  /// otherwise: no escape but the hold, or a QR escape with nothing to scan.
  String? _problem() {
    if (_escapes.isEmpty) {
      return 'Choose at least one wake escape.';
    }
    if (_escapes.contains(EscapeKind.qr) && _qr.text.trim().isEmpty) {
      return 'The QR escape needs a code. Generate one, or turn QR off.';
    }
    return null;
  }

  Future<void> _preview(AlarmSoundPack pack) async {
    setState(() => _previewing = pack.index);
    try {
      // Audible on both platforms regardless of the notification volume, which
      // is the whole point of the check.
      await widget.engine?.playAudibilitySample(soundPack: pack);
    } catch (_) {
      // Preview is a convenience; failing it must not block saving.
    } finally {
      if (mounted) setState(() => _previewing = null);
    }
  }

  void _showQrSheet(BuildContext context, String value) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      // Without this the sheet is capped at 9/16 of the screen. The code plus
      // its labels is taller than that on most phones, so the content
      // overflowed and was clipped.
      isScrollControlled: true,
      builder: (_) => QrSheet(value: value),
    );
  }

  Alarm _build() {
    final existing = widget.existing;
    final label = _label.text.trim();
    return Alarm(
      id: existing?.id ?? Alarm.generateId(),
      hour: _time.hour,
      minute: _time.minute,
      label: label.isEmpty ? 'Wake up' : label,
      enabled: _enabled,
      repeatDaily: _repeatDaily,
      weekdays: _repeatDaily ? _weekdays : const {},
      qrValue: _qr.text.trim(),
      difficulty: _difficulty,
      soundPack: _soundPack,
      snoozeMinutes: _snoozeMinutes,
      escapes: {..._escapes},
      checkInMinutes: _checkInMinutes,
      skipUntilMillis: 0,
      createdAt: existing?.createdAt ?? DateTime.now(),
    );
  }
}
/// Renders [value] as a QR code the user can screenshot or share.
///
/// Deliberately shows the plain text underneath as well. A QR code that will not
/// scan is indistinguishable from a correct one until the alarm is ringing, and
/// a person who is awake at 6am with a phone in their face can read a code far
/// more reliably than they can aim a camera at a screen.
class QrSheet extends StatefulWidget {
  const QrSheet({super.key, required this.value});

  final String value;

  @override
  State<QrSheet> createState() => _QrSheetState();
}

class _QrSheetState extends State<QrSheet> {
  final _boundaryKey = GlobalKey();
  bool _saving = false;

  /// Renders the on-screen code to a PNG and hands it to the share sheet.
  ///
  /// Sharing rather than writing straight to the photo library on purpose:
  /// the share sheet already offers Save to Files / Save Image / Drive on both
  /// platforms, and needs no storage permission, so there is nothing to be
  /// denied at the moment the user wants to print an escape code.
  Future<void> _saveImage() async {
    setState(() => _saving = true);
    try {
      final boundary = _boundaryKey.currentContext?.findRenderObject();
      if (boundary is! RenderRepaintBoundary) {
        throw StateError('the code is not on screen yet');
      }
      // 4x so a printed copy, or a photo of the screen, still resolves.
      final image = await boundary.toImage(pixelRatio: 4);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final bytes = data?.buffer.asUint8List();
      if (bytes == null || bytes.isEmpty) {
        throw StateError('the code could not be encoded as an image');
      }

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/wakeguard-qr.png');
      await file.writeAsBytes(bytes, flush: true);

      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(file.path, mimeType: 'image/png')],
          subject: 'WakeGuard alarm code',
          text: 'WakeGuard QR code for the alarm: ${widget.value}',
          sharePositionOrigin: _shareOrigin(),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save the code: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// iPad and macOS need an anchor rect for the popover, or the share sheet
  /// silently never appears.
  Rect? _shareOrigin() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    // Two different insets, and the sheet needs the larger of the two:
    //   viewPadding - the system nav bar / gesture area, there whether or not
    //                 the keyboard is up. This is what was hiding the button.
    //   viewInsets  - the keyboard itself.
    // SafeArea is deliberately disabled here so these are applied once, in one
    // place, instead of being split across two mechanisms that silently
    // disagree.
    final media = MediaQuery.of(context);
    final navBar = media.viewPadding.bottom;
    final keyboard = media.viewInsets.bottom;

    final available = media.size.width - 72;
    final qrSize = available.clamp(160.0, 300.0);

    return SafeArea(
      top: false,
      bottom: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(24, 0, 24, 24 + navBar + keyboard),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Scan to stop the alarm',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            RepaintBoundary(
              key: _boundaryKey,
              // A transparent background shares as a black square on a dark
              // theme, so the captured image gets an explicit white card.
              child: ColoredBox(
                color: Colors.white,
                child: QrImageView(
                  data: widget.value,
                  size: qrSize,
                  backgroundColor: Colors.white,
                  // Without this, qr_flutter renders an encode failure as a
                  // blank square the same size as the code. A blank square is
                  // exactly what the user would mistake for "it just will not
                  // scan".
                  errorStateBuilder: (context, error) => SizedBox(
                    width: qrSize,
                    height: qrSize,
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline, size: 32, color: Colors.black87),
                        SizedBox(height: 8),
                        Text(
                          'Could not render this code.\nType it in instead.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.black87),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SelectableText(
              widget.value,
              style: Theme.of(context).textTheme.headlineSmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'If the code will not scan, type it in instead.',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _saving ? null : _saveImage,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_outlined),
              label: Text(_saving ? 'Preparing…' : 'Save image'),
            ),
          ],
        ),
      ),
    );
  }
}
