# Verification before release

The implementation includes regression tests, but they have not been executed
by the coding agent: this project's command permissions prohibit builds/tests.
`dart format --output=none lib test` checks parsing only, not types or runtime.

The repository's `opencode.json` restricts agent-run build, test, and analysis
commands, including Flutter/Dart checks, Gradle, and Xcode builds. Developers
should run the checks below in their own environment; source checks alone do
not establish that a lock-screen alarm works on a device.

## Automated checks (developer-run)

- `flutter analyze`
- `flutter test`
- From `android/`: `./gradlew :app:testDebugUnitTest :app:assembleDebug`
- `python3 tool/verify_source.py` (resource/contract/source consistency only)

`AlarmPolicyTest` covers edit-time stale broadcasts, session/phase rejection,
single-follow-up policy and monotonic duration across wall-clock changes/reboots.
Flutter tests cover serialized reconciliation during an edit, disabled duplicates,
skip/restore boundaries, check-in compatibility, outcome filtering, weekday
streaks, QR setup and practice using the current unscheduled draft.

## Device acceptance

Use short future times for repeatable checks, including on a locked device and
with the app process absent. At least one real Android device is needed; an
emulator is insufficient evidence for OEM, camera, volume or lock-screen behavior.

1. Create an alarm two minutes ahead. Edit it to four minutes ahead. The old
   time and its recovery offsets must not ring; the new time rings once.
2. Dismiss a repeating alarm. Wait through the 15-minute recovery window.
   No re-ring; the next repeat remains scheduled.
3. Let a one-time alarm time out. It becomes disabled and records Missed.
   It must not re-arm tomorrow. Snoozing a one-time session still works.
4. Set No snooze. The ringing notification has no snooze action. Repeat with
   5/9/15 minutes and verify the chosen delay rather than the default.
5. Set two nearby alarms. The second queues; dismissing either stale screen
   or stale notification must not stop the other occurrence.
6. Skip a weekday repeat. It resumes on its next selected weekday. Restore
   the skipped occurrence and verify the next date/time and actual delivery.
7. Duplicate an alarm. The copy starts disabled with an independent ID.
8. Practice each preset. Exit via Back/Exit. No audio, history, schedule change
   or follow-up should be created. Repeat while a real alarm rings: practice
   must be refused.
9. Enable a three-minute Stay Awake check. Dismiss, wait for the notification,
   verify a short system notification sound, then confirm inside one minute.
   No follow-up; History shows Confirmed. Repeat on an upgraded installation
   that previously created the check-in channel. Updating an already-visible
   prompt must not replay its sound; system channel sound settings remain honored.
10. Leave a check unanswered. Exactly one follow-up rings, has no snooze,
    and cannot create a second check-in after dismissal or timeout.
11. Edit/delete/disable during a pending check-in. Old prompt/confirmation and
    deadline operations must have no effect.
12. Kill the process during ringing/snooze/check-in. Verify token-scoped
    recovery and a bounded timeout, then reboot before first unlock.
13. Change wall time during a ring. Its remaining window follows elapsed time,
    while future ordinary alarms are recalculated for local wall time.
14. Switch Face -> Pattern while camera startup/inference is pending. No
    camera prompt/analysis may overwrite the pattern or complete an old mode.
15. Test camera denial, QR mismatch, no front camera, dark room and TalkBack.
     Selected alternatives and the hold escape must remain usable.
     Holding for one uninterrupted minute stops the alarm; releasing early
     or leaving the screen resets the hold countdown.
16. Use large system text, narrow screens and both themes; verify editor,
    history and native buttons remain readable/reachable.
17. Clear history. Streak and local history clear; existing alarms/check-ins
    remain. Reinstalling does not restore sessions or old alarms via backup.
18. Reboot with a one-time alarm due while the device was off. Inside the ring
    window it rings once after unlock; outside it is recorded Missed, stays
    disabled, and never re-arms. Repeating alarms resume at their next slot.
    Changing wall time or time zone only recalculates future triggers.

Record device model, Android version, build revision, scenario and actual result.
For shared QR reuse, create two QR alarms and verify both accept the QR shown
in Settings after restarting the app. An existing custom alarm must keep its
old code until explicitly saved with "Use shared wake-up QR". Generating a custom
code for one alarm must not change the shared code or any other alarm.
With camera permission denied, saving a Face/QR draft must leave stored alarms
unchanged and open Health. Grant permission through Camera's Fix action, then
use Return to alarm to save the retained draft. Pattern/Tap alarms must still
save without camera permission; disabling an existing alarm must always work.
Source-level improvements are not measured battery/performance results: profile
camera inference, app startup, memory and APK size after a successful build.
