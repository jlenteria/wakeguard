"""Generate only the short Stay Awake notification chime, leaving alarm tones untouched."""
from pathlib import Path

from generate_alarms import Pattern, Tone, render, write_wav


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    pattern = Pattern(
        name="checkin_reminder",
        tones=(
            Tone(659.25, 0.22, gain=0.60, decay=0.18),
            Tone(880.00, 0.32, gain=0.60, decay=0.22),
        ),
        gap=0.10,
    )
    path = root / "android/app/src/main/res/raw/checkin_reminder.wav"
    write_wav(str(path), render(pattern))
    print("Generated the short Stay Awake check-in chime.")


if __name__ == "__main__":
    main()
