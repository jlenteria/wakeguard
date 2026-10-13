# Android verification before release

Scope: Android only, package/application ID `com.bling.wakeguard`. iOS release
verification is deferred. Run automated tests, analysis and source checks before
building the signed artifacts. Passing automated checks or a build is not evidence
of alarm delivery, classification accuracy or Play approval.

## Build and release artifact

Follow `docs/ANDROID_RELEASE.md`, then build the signed release APK and AAB:

```sh
flutter build apk --release
flutter build appbundle --release
```

Confirm the actual artifact's package, upload signature, target API 36, arm64
native libraries and 16 KB compatibility. Upload to an internal test track and
review Play's pre-launch report. Agent-run builds are currently blocked by
workspace permission rules; record developer-run build results explicitly.

## Device acceptance

Use at least one real Android device, including a lower-end device for object
classification. Include current Android and the oldest supported API 24–27
compatibility paths where devices/emulators are available. Repeat alarm-delivery
scenarios locked, unlocked, with the Flutter process absent, and after reboot.

1. **Onboarding:** allow notifications and test the sound. Deny permissions,
   revoke them in Settings, retry and resume the app. Blocked notifications must
   appear in Health. Skipping onboarding must not silently arm an unusable alarm.
   A persistence failure must report failure rather than claim completion.
2. **Engine/save failure:** an unavailable native channel must show an error and
   allow Retry. It must never show a successful enabled save. Failed edits must
   retain the draft and show the configuration actually stored natively.
3. **Edits:** create an alarm two minutes ahead, edit to four minutes. Only the
   new primary rings. Repeat with rejected camera/check-in permission changes;
   the old working configuration must not be presented as the failed edit.
4. **Optional Tap:** only an explicitly selected Tap alarm has a Stop button.
   Simple selects Tap; Challenge selects Face; Get out of bed selects Object.
   No hold-to-stop, hold timer, random confirmation or Pattern grid appears.
5. **Face:** practice every action, including your own left/right directions,
   two blinks and eyes-open duration. Switch challenges during inference. Stale
   results must not complete a different challenge. Turn the room light off/on;
   the app must not change screen brightness or offer a brightness slider.
   With WakeGuard open on any tab or sheet, a ringing alarm must open its native
   challenge without tapping the notification. Opening WakeGuard while an alarm
   is already ringing must do the same. Recovery refreshes must not restart a
   challenge already on screen. Repeat while a previous success screen is visible.
   With the phone locked, verify full-screen opening when permission is granted;
   with permission denied or another app visible, Android may show a notification.
6. **Object practice:** separately test Sink and Cup; Plant must not be offered.
   Sink starts at exact-label confidence >= 0.70, then maintains at >= 0.60.
   Cup requires >= 0.80. Completion needs at least eight matches and three seconds
   of confirmed time. Sink dropouts up to 600ms must pause without adding time;
   longer losses, Cup misses, inference stalls and backgrounding reset progress. Verify
   all targets offline on first launch: no model download may be required.
7. **Object enablement:** a target not successfully practised on this device
   cannot be enabled. A successful practice returns to the editor with Verified
   state; changing to an unverified target requires new practice. No reference
   photo is stored. Live Object completion must stop audio and schedule the
   configured Stay Awake reminder. A nearby object/photo is not proof of location;
   do not claim that recognition verifies the user physically left bed.
8. **QR:** two alarms sharing the Settings QR accept it after restarting. A custom
   code remains unchanged unless explicitly replaced. Wrong/empty codes cannot
   stop the alarm. Share and print with real destinations and scan the output.
9. **Animations:** searching, recognised state, progress, face-step transitions
   and success feedback remain smooth. Disable system animations; no scan-line
   motion or transition should remain. The alarm sound stops before the success
   animation. Progress must reflect inference rather than a decorative timer.
10. **Camera/accessibility:** deny or revoke permission, disable camera privacy
    access, test no/busy camera and low light. Retry and only selected alternatives
    remain available. Use TalkBack, large text, narrow/landscape screens and both
    Flutter themes. Instructions and controls must remain reachable.
11. **Legacy records:** Pattern-only/invalid old alarms show Setup required and
    remain disabled until the replacement is configured. Other selected valid
    challenges and old history remain. Migration must not introduce Tap or start
    a camera challenge without setup. The former app ID is a separate app, not an
    upgrade path sharing private preferences.
12. **Snooze/repeats:** No snooze hides the notification action. Test 5/9/15-minute
    delays, one-time retirement, weekday repeats and process death. Practice and
    follow-ups offer no snooze. Tomorrow's repeat survives dismissal/snooze;
    skip/restore and disabled duplication still work without camera permission.
13. **Stay Awake:** enable 3 minutes and dismiss using each selected challenge.
    History must show Check-in scheduled, then Reminder shown; verify the short
    bundled notification chime and vibration, including after upgrading an existing
    install. Ringing, fallback and alarm-stopped notifications must have no chime;
    the selected alarm tone must still play through the ringing service. Confirm
    I'm up within one minute. Confirming prevents follow-up.
    Unanswered checks create exactly one follow-up, with no snooze or further
    check-in. Practice creates no check-in. Block/mute the check-in channel and
    verify Health plus explicit blocked/failed history rather than silent success.
14. **Check-in recovery:** reboot or change time before/during/after the response
    window. A late restored prompt reports remaining seconds; an expired prompt
    is not shown as newly answerable. Editing/deleting/disabling an alarm cancels
    its old pending check-in; an ordinary app reload must not cancel it.
15. **Sessions:** nearby alarms queue without stopping each other. Stale tokens
    cannot dismiss/snooze a later occurrence. Playback, recovery, shutdown,
    timeout and queue draining must stay bounded; a forgotten alarm times out at
    15 minutes and records Missed rather than a successful wake-up.
16. **History/settings/privacy:** settings persist through restart; transient
    history reads retain the previous list; clearing history does not clear
    alarms/check-ins. Stats are labelled as saved-history totals. Settings shows
    the full Privacy policy and correct contact; the public Netlify policy URL
    serves that policy. Support shows only the QR, without account/recipient rows.

Record device model, Android version, build revision, selected target/challenge,
scenario and actual result. Performance was reported fixed by the developer;
new camera inference and animation performance still need device observation.
