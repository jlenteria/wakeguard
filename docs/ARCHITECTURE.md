# Architecture

Flutter owns the editor and product UI. Native Android owns what actually rings,
active occurrence state, check-ins and event outcomes. A challenge never requires
a live Dart isolate.

## Channel contract (version 2)

`com.bling.wakeguard/alarm` accepts `schedule`, `cancel`, `alarms`, `history`,
`clearHistory`, `practice`, `objectTargetVerified`, `dismiss`, health/permissions and sound previews.
Capabilities report `contractVersion`, `canPractice` and `canCheckIn` so a
platform lacking these features does not offer the controls. Android schedules
require version 2; Flutter sends it separately from persisted alarm JSON.

The editor supplies configuration. Android returns the complete native configuration,
`enabled`, object-practice state and `nextTriggerAt`.
The controller serializes saves, deletes, reloads and health/history reads through
one queue; internal reloads do not enqueue recursively. Native-confirmed trigger
times are preferred over UI calculations. Failed edits restore the previous native
primary where possible and roll back the mirror; failed saves retain the draft.
Engine discovery is retryable and an unavailable engine cannot report a successful save.

## Configuration versus occurrences

- `StoredAlarm` stores time, weekdays, sound, escapes, snooze, check-in delay,
  skip boundary and next primary trigger.
- `AlarmSession` snapshots the alarm for one occurrence and carries a UUID,
  scheduled time, ring-start wall/elapsed times, boot count, snooze count,
  phase and follow-up flag. Sessions are device-protected and persisted before
  a foreground-service start.
- `AlarmPolicy` contains pure acceptance/timing rules covered by JVM tests.

Primary broadcasts must have a positive timestamp matching the current native
trigger and must not arrive early. Already-started occurrences are not repeated.
Watchdog, snooze, dismissal and check-in operations must match a saved session
token and phase. Legacy broadcasts without these fields are rejected. A package
replacement/boot broadcast re-arms valid configurations with the new extras.

Android normally replaces alarms with matching PendingIntents. Explicit cleanup
also cancels separate watchdog and snooze identities. It is not a substitute for
validating an operation that has already been delivered.

## Lifecycle

```
primary trigger -> validate occurrence -> snapshot session
                                      -> arm next repeat / retire one-time
                                      -> ring or queue behind another alarm
ringing -> snoozed -> ringing
ringing -> dismissed -> done OR check-in
ringing -> timed out -> missed -> done
check-in -> confirmed -> done
check-in -> unanswered -> one follow-up (ringing or queued) -> done
```

Only one occurrence plays at once. A queued alarm gets a fresh ring window on
activation; one queued for at least 15 minutes is recorded as missed instead of
starting unexpectedly. Pending queues are drained after the stopped service has
released audio and volume ownership.

The next regular primary is armed at fire time. A one-time configuration is
disabled then, but its session snapshot remains usable for snoozing and dismissal.
Dismissal only ends that session; it never cancels/recreates tomorrow's alarm.
Disabling or deleting invalidates pending session work. Editing re-arms an
in-flight snooze and a pending check-in against the new configuration (unless
check-ins are turned off in that edit); any other live phase is reset.

Watchdogs exist **only during a ring**, at 45 seconds, 2, 5, 10 and 15 minutes.
Each carries the session token; even a matching stale stop broadcast cannot stop
a new ring before its actual elapsed timeout. Ring duration uses monotonic time
within a boot and wall time only when restoring across a reboot.

## Snooze and Stay Awake

Snooze uses the saved session settings, validates the token and positive snooze
length, and arms the snooze before stopping sound. No-snooze alarms hide the
notification action. Tomorrow's regular primary survives snoozing.

Stay Awake is off by default. The persisted check-in begins 3/5/10 minutes after
dismissal, with a one-minute response window. Separate token-bearing operations
prompt, confirm or expire it. Alarm-clock scheduling avoids idle-exact-alarm
quotas consuming the response window. An unanswered check produces one follow-up
with no snooze; dismissing it cannot create another check-in. A substantially
overdue check-in restored after reboot expires instead of sounding hours later.

The prompt notification carries a full-screen PendingIntent for the native
`StayAwakeActivity`, allowing Android to present the response page over the lock
screen when full-screen alerts are permitted. Tapping the notification opens the
same page. The Flutter shell also presents a `Consumer<StayAwakeViewModel>` card
while a response window is active. Page, card and notification action all use
`StayAwake.confirm`, which checks the persisted token, phase and original deadline.
Opening, closing or recreating the page never confirms or extends a check-in.
The page closes when its window expires or another surface confirms it; the native
deadline receiver remains responsible for the follow-up alarm.

## UI and camera

Practice uses the same native screen but no ringing session, audio, scheduling
or history. It has Back and Exit controls and is refused while an alarm rings.
Normal ringing validates its token before showing a challenge.

Camera acquisition/detectors are lazy. Optional Tap does not bind a camera.
Analysis targets 640x480, throttles frames to at most one per 180ms, and permits
one in-flight inference. Generation/lifecycle checks reject stale callbacks.
Face uses the front camera; Object/QR use the rear. No brightness override or
hold-to-stop exists on Android. Only selected challenges may dismiss.

Object recognition uses the bundled ML Kit image-labeler and exact Sink (7) and
Cup (315) labels. Sink starts at confidence >= 0.70 and stays tracked at >= 0.60;
Cup requires >= 0.80. At least eight matches and three seconds of confirmed time
are required. Only intervals between consecutive matching frames add time.
Sink dropouts up to 600ms pause progress; longer losses, inference gaps over 700ms,
and any Cup miss reset it. Plant is no longer selectable; saved Plant object alarms
are disabled and require supported-target setup without retaining Plant verification.
Successful Object practice records a device-local verification boolean.
There are no reference photos, cloud inference or first-run model downloads.
The animated guide is a framing aid, not a claimed object bounding box.

Pattern-only/invalid legacy configurations become disabled Object drafts marked
Setup required. Other valid selected challenges are preserved. Old history
labels remain readable. Object recognition encourages target placement outside
the bedroom but cannot prove location or distinguish an object from every photo.

The Flutter app theme listens only to settings. Alarm rows and history use lazy
lists; visible countdowns refresh once per minute while foregrounded. Audio is
prepared asynchronously; the volume guard checks once per second and keeps the
existing 50% start / five-second mute grace / 20% recovery policy.

## Storage and progress

Device-protected alarm preferences are canonical; credential storage is a
compatibility mirror. Deletion tombstones override stale credential records.
Sessions and new events are device-protected, as are service volume preferences.
Native ringing components are direct-boot aware.

Events are bounded to 500 and include session/alarm IDs, label, outcome, duration,
snooze count and follow-up/check-in metadata. Legacy dismissal history remains
readable and can be cleared together with new events. Starts and misses never
count as completed days. A check-in-enabled dismissal counts once confirmed or
after completion of its follow-up. Streaks skip unscheduled days of the current
enabled repeating schedule; historical schedule edits are not reconstructed.
This measures alarm interaction, not actual wakefulness or sleep quality.

Backup and device-transfer rules exclude local configuration, sessions and
history. QR sharing is an explicit user action through the platform share sheet.

## Verification

See `docs/VERIFICATION.md` and `docs/ANDROID_RELEASE.md`. This session follows the
developer's build-only verification request. Workspace permissions currently deny
agent-run Flutter/Gradle builds; a native build and real-device verification are
still needed. Source review is not proof of alarm delivery or detector accuracy.
