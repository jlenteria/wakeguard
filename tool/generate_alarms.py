#!/usr/bin/env python3
"""Generates the WakeGuard alarm tones for Android and iOS.

One generator, both platforms, so a change to an alarm pattern cannot drift
between the APK and the IPA.

The user can pick one of several *sound families* (pulse, siren, radar, gong).
Each family is rendered at four escalation *tiers*, because the two platforms
consume the tiers differently:

  * Android loops inside a foreground service, so it plays `gentle` then jumps
    straight to `critical`.
  * iOS cannot loop in the background, so each tier is its own scheduled
    notification and all four are used in sequence.

Design constraints that come from the platforms themselves:

  * iOS refuses custom notification sounds longer than 30 seconds and never
    loops them.
  * Everything is generated from first principles here rather than checked in as
    opaque binaries, so the tones can be audited and re-tuned.

Usage: python3 tool/generate_alarms.py
"""

from __future__ import annotations

import math
import os
import shutil
import struct
import subprocess
import wave
from dataclasses import dataclass

SAMPLE_RATE = 44100
MAX_SECONDS = 25.0  # iOS hard limit is 30s; stay well under it.


@dataclass(frozen=True)
class Tone:
    """One pitched segment of a pattern."""

    freq: float
    seconds: float
    #: Relative amplitude of this segment, used to build emphasis ramps.
    gain: float = 1.0
    #: Exponent applied to a per-segment attack/decay envelope.
    attack: float = 0.01
    decay: float = 0.06


@dataclass(frozen=True)
class Pattern:
    name: str
    tones: tuple[Tone, ...]
    #: Added to every segment. Higher values get harsher, more square-ish
    #: partials, which is what actually makes a tone cut through sleep.
    brightness: float = 0.0
    #: Short percussive noise burst at the start of each segment.
    transient: float = 0.0
    gap: float = 0.0


# A minor-second interval pair: the classic alarm tritone-adjacent pairing that
# the ear detects as urgent even at low volume.
C4, D4, E4, F4, G4, A4, C5, D5, E5, F5, G5, A5, C6, D6, F6 = (
    261.63, 293.66, 329.63, 349.23, 392.00, 440.00, 523.25, 587.33, 659.25, 698.46,
    783.99, 880.00, 1046.50, 1174.66, 1396.91,
)

#: Sound families the user can choose between, each with four tiers.
#:
#: They differ in character rather than just volume, because a person who finds
#: one sound intolerable tends to find a louder version of it intolerable too:
#:
#:   pulse - short identical beeps; the least abrasive.
#:   siren - the classic rising/falling sweep that most reliably wakes people.
#:   radar - fast high pips; cuts through a noisy room.
#:   gong  - struck metal, long decay; harshest, hardest to sleep through.

FAMILIES: dict[str, tuple[Pattern, ...]] = {
    "pulse": (
        Pattern(
            name="pulse_gentle",
            tones=(
                Tone(A4, 0.22, gain=0.50),
                Tone(C5, 0.22, gain=0.50),
                Tone(A4, 0.22, gain=0.50),
                Tone(C5, 0.52, gain=0.55),
            ),
            brightness=0.08,
            gap=0.16,
        ),
        Pattern(
            name="pulse_firm",
            tones=tuple(
                Tone(f, 0.18, gain=0.78)
                for f in (C5, G5, C5, G5, E5, G5, E5)
            ),
            brightness=0.22,
            transient=0.12,
            gap=0.07,
        ),
        Pattern(
            name="pulse_urgent",
            tones=tuple(
                Tone(f, 0.13, gain=0.92)
                for f in (E5, A4, E5, A4, C5, G5, E5, A4, C5)
            ),
            brightness=0.38,
            transient=0.18,
            gap=0.03,
        ),
        Pattern(
            name="pulse_critical",
            tones=tuple(
                Tone(f, 0.10, gain=1.0)
                for f in (C6, E5, C6, E5, C6, E5, C6, E5, C6, G5, C6, G5)
            ),
            brightness=0.58,
            transient=0.24,
            gap=0.0,
        ),
    ),
    "siren": (
        Pattern(
            name="siren_gentle",
            tones=(
                Tone(A4, 0.60, gain=0.48),
                Tone(C5, 0.60, gain=0.42),
                Tone(A4, 1.10, gain=0.50),
            ),
            brightness=0.06,
            gap=0.20,
        ),
        Pattern(
            name="siren_firm",
            tones=(
                Tone(E5, 0.34, gain=0.74),
                Tone(A4, 0.34, gain=0.74),
                Tone(E5, 0.34, gain=0.74),
                Tone(A4, 0.60, gain=0.80),
            ),
            brightness=0.20,
            transient=0.12,
            gap=0.06,
        ),
        Pattern(
            name="siren_urgent",
            tones=(
                Tone(G5, 0.26, gain=0.90),
                Tone(A4, 0.26, gain=0.90),
                Tone(G5, 0.26, gain=0.90),
                Tone(A4, 0.26, gain=0.90),
                Tone(C6, 0.70, gain=0.95),
            ),
            brightness=0.36,
            transient=0.18,
            gap=0.03,
        ),
        Pattern(
            name="siren_critical",
            tones=(
                Tone(C6, 0.18, gain=1.0),
                Tone(G5, 0.18, gain=1.0),
                Tone(D4 + 2.0, 0.18, gain=1.0),
                Tone(C6, 0.18, gain=1.0),
                Tone(G5, 0.18, gain=1.0),
                Tone(D4 + 2.0, 0.18, gain=1.0),
                Tone(E5, 0.44, gain=1.0),
                Tone(C6, 0.44, gain=1.0),
            ),
            brightness=0.60,
            transient=0.26,
            gap=0.0,
        ),
    ),
    "radar": (
        Pattern(
            name="radar_gentle",
            tones=(
                Tone(E5, 0.10, gain=0.46),
                Tone(C5, 0.10, gain=0.46),
                Tone(E5, 0.10, gain=0.46),
                Tone(C5, 0.48, gain=0.52),
            ),
            brightness=0.10,
            gap=0.12,
        ),
        Pattern(
            name="radar_firm",
            tones=tuple(
                Tone(f, 0.12, gain=0.80)
                for f in (G5, E5, G5, E5, A5, E5, A5, E5, G5)
            ),
            brightness=0.26,
            transient=0.14,
            gap=0.05,
        ),
        Pattern(
            name="radar_urgent",
            tones=tuple(
                Tone(f, 0.09, gain=0.94)
                for f in (A5, F5, A5, F5, C6, F5, C6, F5, A5, F5)
            ),
            brightness=0.44,
            transient=0.20,
            gap=0.02,
        ),
        Pattern(
            name="radar_critical",
            tones=tuple(
                Tone(f, 0.07, gain=1.0)
                for f in (C6, A5, F5, A5, C6, A5, F5, A5, C6, A5, F5, A5)
            ),
            brightness=0.66,
            transient=0.26,
            gap=0.0,
        ),
    ),
    "gong": (
        Pattern(
            name="gong_gentle",
            tones=(
                Tone(D4, 1.10, gain=0.50),
                Tone(A4, 1.10, gain=0.42),
            ),
            brightness=0.30,
            gap=0.30,
        ),
        Pattern(
            name="gong_firm",
            tones=(
                Tone(D4, 0.62, gain=0.76),
                Tone(A4, 0.62, gain=0.72),
                Tone(D5, 0.90, gain=0.82),
            ),
            brightness=0.40,
            transient=0.16,
            gap=0.10,
        ),
        Pattern(
            name="gong_urgent",
            tones=(
                Tone(D4, 0.42, gain=0.92),
                Tone(A4, 0.42, gain=0.90),
                Tone(D5, 0.42, gain=0.90),
                Tone(F5, 0.42, gain=0.90),
                Tone(A5, 0.90, gain=0.96),
            ),
            brightness=0.50,
            transient=0.20,
            gap=0.04,
        ),
        Pattern(
            name="gong_critical",
            tones=(
                Tone(D5, 0.30, gain=1.0),
                Tone(A5, 0.30, gain=1.0),
                Tone(D6, 0.30, gain=1.0),
                Tone(C6 + 4.0, 0.30, gain=1.0),
                Tone(D5, 0.30, gain=1.0),
                Tone(A5, 0.30, gain=1.0),
                Tone(D6, 0.30, gain=1.0),
                Tone(F6, 0.80, gain=1.0),
            ),
            brightness=0.62,
            transient=0.28,
            gap=0.0,
        ),
    ),
}

TIERS = ("gentle", "firm", "urgent", "critical")

#: Android loops inside the service, so it uses two tiers per family: a soft
#: opener and the loudest variant. Referenced from RingingService.kt.
ANDROID_TIERS = ("gentle", "critical")

#: iOS schedules one notification per tier, so it uses all four.
IOS_TIERS = TIERS


def render(pattern: Pattern) -> bytes:
    total = sum(tone.seconds + pattern.gap for tone in pattern.tones)
    if total > MAX_SECONDS:
        raise ValueError(f"{pattern.name} is {total:.2f}s, over the iOS limit")

    samples: list[float] = []
    for index, tone in enumerate(pattern.tones):
        count = int(tone.seconds * SAMPLE_RATE)
        for n in range(count):
            t = n / SAMPLE_RATE
            phase = 2 * math.pi * tone.freq * t

            value = math.sin(phase)
            value += pattern.brightness * 0.5 * math.sin(2 * phase)
            value += pattern.brightness * 0.25 * math.sin(3 * phase)
            value += pattern.brightness * 0.15 * math.sin(4 * phase)

            if pattern.transient:
                # Deterministic noise, decaying within ~12ms.
                seed = (index * 7919 + n) % 4096
                noise = (seed / 2048.0 - 1.0) * math.exp(-t / 0.012)
                value += pattern.transient * noise

            envelope = min(1.0, t / tone.attack) * math.exp(-t / tone.decay)
            value *= envelope * tone.gain

            # Soft clip rather than hard clamp: keeps the harsh tiers loud
            # without the square-wave aliasing that a clamp would introduce.
            value = math.tanh(value * 1.4) * 0.86
            samples.append(value)

        gap_count = int(pattern.gap * SAMPLE_RATE)
        samples.extend([0.0] * gap_count)

    samples.extend([0.0] * int(0.05 * SAMPLE_RATE))
    pcm = struct.pack("<%dh" % len(samples), *(int(s * 32767) for s in samples))
    return pcm


def write_wav(path: str, pcm: bytes) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with wave.open(path, "wb") as handle:
        handle.setnchannels(1)
        handle.setsampwidth(2)
        handle.setframerate(SAMPLE_RATE)
        handle.writeframes(pcm)


def to_caf(wav_path: str) -> str:
    caf_path = os.path.splitext(wav_path)[0] + ".caf"
    subprocess.run(
        ["afconvert", "-f", "caff", "-d", "LEI16@44100", "-q", "127", wav_path, caf_path],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    os.remove(wav_path)
    return caf_path


def main() -> None:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    tmp = os.path.join(root, "build", "alarm_tones")
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp, exist_ok=True)

    android_dir = os.path.join(root, "android/app/src/main/res/raw")
    # Remove previously generated assets so a renamed family cannot leave a
    # stale sound in the build that nothing references any more.
    if os.path.isdir(android_dir):
        for name in os.listdir(android_dir):
            if name.startswith("tone_") or name.startswith("alarm_"):
                os.remove(os.path.join(android_dir, name))
    ios_dir = os.path.join(root, "ios/Runner")
    for name in os.listdir(ios_dir):
        if name.startswith("tone_") or name.startswith("alarm_"):
            os.remove(os.path.join(ios_dir, name))

    longest = 0.0
    for family, tiers in FAMILIES.items():
        for tier, pattern in zip(TIERS, tiers):
            pcm = render(pattern)
            longest = max(longest, len(pcm) / 2 / SAMPLE_RATE)

            android_path = os.path.join(android_dir, f"tone_{family}_{tier}.wav")
            write_wav(android_path, pcm)
            if tier in ANDROID_TIERS:
                print(f"android  tone_{family}_{tier}.wav")
            else:
                # Tier is not used on Android; do not ship dead weight.
                os.remove(android_path)

            staging = os.path.join(tmp, f"tone_{family}_{tier}.wav")
            write_wav(staging, pcm)
            to_caf(staging)
            caf = os.path.join(ios_dir, f"tone_{family}_{tier}.caf")
            shutil.move(os.path.splitext(staging)[0] + ".caf", caf)
            if tier in IOS_TIERS:
                print(f"ios      tone_{family}_{tier}.caf")
            else:
                os.remove(caf)

    shutil.rmtree(tmp, ignore_errors=True)
    print(f"\n{len(FAMILIES)} sound families, longest tone {longest:.2f}s "
          f"(iOS limit {MAX_SECONDS:.0f}s)")


if __name__ == "__main__":
    main()
