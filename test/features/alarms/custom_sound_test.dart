import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakeguard/features/alarms/alarm_editor_screen_view_model.dart';
import 'package:wakeguard/features/alarms/tone_names.dart';
import 'package:wakeguard/models/alarm.dart';
import 'package:wakeguard/platform/alarm_engine.dart';

class _SoundEngine extends EngineUnavailable implements CustomSoundEngine {
  bool supported = true;
  PickedSound? next;
  Object? failWith;
  final previews = <String>[];
  final previewVibrate = <bool>[];
  List<PickedSound> deviceSounds = const [];
  final imported = <String>[];

  /// What the phone's file store calls the imported copy (not the list title).
  String? importedName;

  @override
  bool get supportsCustomSounds => supported;

  @override
  Future<List<PickedSound>> listSystemSounds() async => deviceSounds;

  @override
  Future<PickedSound> importSystemSound(String uri) async {
    final failure = failWith;
    if (failure != null) throw failure;
    imported.add(uri);
    final name = importedName;
    if (name != null) return PickedSound(id: 'stored-$uri', name: name);
    return deviceSounds.firstWhere(
      (sound) => sound.id == uri,
      orElse: () => PickedSound(id: uri, name: uri),
    );
  }

  @override
  Future<PickedSound?> pickCustomSound() async {
    final failure = failWith;
    if (failure != null) throw failure;
    return next;
  }

  @override
  Future<void> previewCustomSound(String id, {bool vibrate = false}) async {
    previews.add(id);
    previewVibrate.add(vibrate);
  }

  @override
  Future<void> stopAudibilitySample() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Alarm model', () {
    test('custom sound survives a JSON round trip', () {
      const alarm = Alarm(
        id: 'a',
        hour: 6,
        minute: 30,
        label: 'x',
        customSoundId: 'abc.mp3',
        customSoundName: 'Morning.mp3',
      );
      final copy = Alarm.fromJson(alarm.toJson());
      expect(copy.customSoundId, 'abc.mp3');
      expect(copy.customSoundName, 'Morning.mp3');
      expect(copy.hasCustomSound, isTrue);
    });

    test('alarms saved before uploads existed load with no custom sound', () {
      final json = const Alarm(id: 'a', hour: 6, minute: 0, label: 'x').toJson()
        ..remove('customSoundId')
        ..remove('customSoundName');
      final alarm = Alarm.fromJson(json);
      expect(alarm.hasCustomSound, isFalse);
      expect(alarm.soundPack, AlarmSoundPack.pulse);
    });

    test('copyWith can set and keep the custom sound', () {
      const alarm = Alarm(id: 'a', hour: 6, minute: 0, label: 'x');
      final withSound = alarm.copyWith(customSoundId: 'f.wav');
      expect(withSound.customSoundId, 'f.wav');
      expect(withSound.copyWith(label: 'y').customSoundId, 'f.wav');
    });
  });

  group('editor view model', () {
    test('is not offered without a supporting engine', () {
      final none = AlarmEditorScreenViewModel();
      final plain = AlarmEditorScreenViewModel(engine: EngineUnavailable());
      final unsupported = AlarmEditorScreenViewModel(
        engine: _SoundEngine()..supported = false,
      );
      addTearDown(none.dispose);
      addTearDown(plain.dispose);
      addTearDown(unsupported.dispose);
      expect(none.canUseCustomSound, isFalse);
      expect(plain.canUseCustomSound, isFalse);
      expect(unsupported.canUseCustomSound, isFalse);
    });

    test('a picked file is saved on the alarm', () async {
      final engine = _SoundEngine()
        ..next = const PickedSound(id: 'f1.mp3', name: 'Rooster.mp3');
      final vm = AlarmEditorScreenViewModel(engine: engine);
      addTearDown(vm.dispose);
      expect(vm.canUseCustomSound, isTrue);

      expect(await vm.pickCustomSound(), isNull);
      expect(vm.hasCustomSound, isTrue);
      expect(vm.pickingSound, isFalse);

      final saved = await vm.save();
      expect(saved!.customSoundId, 'f1.mp3');
      expect(saved.customSoundName, 'Rooster.mp3');
    });

    test('cancelling the picker changes nothing', () async {
      final vm = AlarmEditorScreenViewModel(
        engine: _SoundEngine(),
        existing: const Alarm(
          id: 'a',
          hour: 7,
          minute: 0,
          label: 'x',
          customSoundId: 'keep.mp3',
          customSoundName: 'Keep',
        ),
      );
      addTearDown(vm.dispose);
      expect(await vm.pickCustomSound(), isNull);
      expect(vm.customSoundId, 'keep.mp3');
      expect(vm.pickingSound, isFalse);
    });

    test(
      'an unusable file reports why and keeps the previous choice',
      () async {
        final engine = _SoundEngine()
          ..failWith = EngineException('CUSTOM_SOUND', 'Larger than 25 MB.');
        final vm = AlarmEditorScreenViewModel(engine: engine);
        addTearDown(vm.dispose);
        expect(await vm.pickCustomSound(), 'Larger than 25 MB.');
        expect(vm.hasCustomSound, isFalse);
        expect(vm.pickingSound, isFalse);
      },
    );

    test('choosing a bundled tone replaces the uploaded one', () async {
      final engine = _SoundEngine()
        ..next = const PickedSound(id: 'f1.mp3', name: 'Rooster.mp3');
      final vm = AlarmEditorScreenViewModel(engine: engine);
      addTearDown(vm.dispose);
      await vm.pickCustomSound();
      vm.setSoundPack(AlarmSoundPack.gong);
      expect(vm.hasCustomSound, isFalse);
      expect((await vm.save())!.soundPack, AlarmSoundPack.gong);
    });

    test('removing keeps the bundled fallback tone', () async {
      final engine = _SoundEngine()
        ..next = const PickedSound(id: 'f1.mp3', name: 'Rooster.mp3');
      final vm = AlarmEditorScreenViewModel(engine: engine);
      addTearDown(vm.dispose);
      vm.setSoundPack(AlarmSoundPack.radar);
      await vm.pickCustomSound();
      expect(vm.soundPack, AlarmSoundPack.radar);
      vm.removeCustomSound();
      expect(vm.hasCustomSound, isFalse);
      expect(vm.soundPack, AlarmSoundPack.radar);
    });

    test('previews the uploaded file and releases the loading state', () async {
      final engine = _SoundEngine()
        ..next = const PickedSound(id: 'f1.mp3', name: 'Rooster.mp3');
      final vm = AlarmEditorScreenViewModel(engine: engine);
      addTearDown(vm.dispose);
      expect(await vm.previewCustom(), isNull);
      expect(engine.previews, isEmpty, reason: 'nothing uploaded yet');

      await vm.pickCustomSound();
      expect(await vm.previewCustom(), isNull);
      expect(engine.previews, ['f1.mp3']);
      expect(vm.previewingAny, isFalse);
    });

    test(
      'loads device sounds and imports the chosen one into storage',
      () async {
        final engine = _SoundEngine()
          ..deviceSounds = const [
            PickedSound(id: 'content://media/1', name: 'Aurora'),
            PickedSound(id: 'content://media/2', name: 'Constellation'),
          ];
        final vm = AlarmEditorScreenViewModel(engine: engine);
        addTearDown(vm.dispose);

        await vm.loadSystemSounds();
        expect(vm.systemSounds, hasLength(2));
        expect(vm.systemSoundsError, isNull);

        expect(await vm.selectSystemSound(vm.systemSounds.first), isNull);
        expect(engine.imported, ['content://media/1']);
        expect(vm.isSoundSelected('Aurora'), isTrue);
        // A chosen device sound is a normal custom sound on the saved alarm.
        final saved = await vm.save();
        expect(saved!.customSoundName, 'Aurora');
        expect(saved.customSoundId, 'content://media/1');
        expect(vm.importingUri, isEmpty);
      },
    );

    test(
      'a failing device-sound import reports why and keeps the choice',
      () async {
        final engine = _SoundEngine()
          ..deviceSounds = const [PickedSound(id: 'uri', name: 'Aurora')]
          ..failWith = EngineException(
            'CUSTOM_SOUND',
            'Cannot read that file.',
          );
        final vm = AlarmEditorScreenViewModel(engine: engine);
        addTearDown(vm.dispose);
        await vm.loadSystemSounds();

        final error = await vm.selectSystemSound(vm.systemSounds.single);
        expect(error, 'Cannot read that file.');
        expect(vm.hasCustomSound, isFalse);
        expect(vm.importingUri, isEmpty);
      },
    );

    test('vibrate defaults on and survives a save round trip', () async {
      final vm = AlarmEditorScreenViewModel();
      addTearDown(vm.dispose);
      expect(vm.vibrate, isTrue);

      vm.setVibrate(false);
      expect(vm.vibrate, isFalse);
      // Save is one-shot, so the round trip happens on its single result.
      final saved = await vm.save();
      expect(saved!.vibrate, isFalse);
      expect(Alarm.fromJson(saved.toJson()).vibrate, isFalse);
    });

    test('an existing alarm keeps its vibrate setting when edited', () {
      final vm = AlarmEditorScreenViewModel(
        existing: const Alarm(
          id: 'a',
          hour: 6,
          minute: 0,
          label: 'x',
          vibrate: false,
        ),
      );
      addTearDown(vm.dispose);
      expect(vm.vibrate, isFalse);
      vm.setVibrate(true);
      expect(vm.vibrate, isTrue);
    });
    test(
      'device tones are shown in English only and stay checked after import',
      () async {
        final engine = _SoundEngine()
          ..importedName = 'Time.ogg'
          ..deviceSounds = const [
            PickedSound(id: 'u1', name: '光阴;Time'),
            PickedSound(id: 'u2', name: 'Go Beyond 八音盒版;Go Beyond Muisc Box'),
            PickedSound(id: 'u3', name: '唤醒'),
          ];
        final vm = AlarmEditorScreenViewModel(engine: engine);
        addTearDown(vm.dispose);
        await vm.loadSystemSounds();
        expect(vm.systemSounds.map((s) => s.name), [
          'Alarm tone 3',
          'Go Beyond Muisc Box',
          'Time',
        ]);

        final time = vm.systemSounds.firstWhere((s) => s.name == 'Time');
        expect(await vm.selectSystemSound(time), isNull);
        // The stored copy is called Time.ogg, but the list row must still match.
        expect(vm.customSoundName, 'Time');
        expect(vm.isSoundSelected('Time'), isTrue);
        expect(vm.isSoundSelected('Alarm tone 3'), isFalse);
      },
    );
    test('previews vibrate only while vibration is on', () async {
      final engine = _SoundEngine()
        ..next = const PickedSound(id: 'f1.mp3', name: 'Rooster.mp3');
      final vm = AlarmEditorScreenViewModel(engine: engine);
      addTearDown(vm.dispose);
      await vm.pickCustomSound();

      await vm.previewCustom();
      vm.setVibrate(false);
      await vm.previewCustom();
      expect(engine.previewVibrate, [true, false]);
    });
  });

  group('tone names', () {
    test('keeps only the English part of a bilingual title', () {
      expect(englishToneName('光阴;Time'), 'Time');
      expect(
        englishToneName('Go Beyond 电子版;Go Beyond Electronic'),
        'Go Beyond Electronic',
      );
      expect(englishToneName('Creek'), 'Creek');
      expect(englishToneName('唤醒'), isNull);
    });
  });
}
