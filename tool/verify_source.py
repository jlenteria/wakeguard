"""Read-only source/resource consistency checks; not a Kotlin compiler or runtime test."""
from pathlib import Path
import re
import xml.etree.ElementTree as ET

root = Path(__file__).resolve().parents[1]
native = root / "android/app/src/main"
sources = list((native / "kotlin/app/wakeguard").glob("*.kt"))
text = "\n".join(path.read_text() for path in sources)
strings = ET.parse(native / "res/values/strings.xml").getroot()
declared = {entry.attrib["name"] for entry in strings if entry.tag == "string"}
used = set(re.findall(r"R\.string\.(\w+)", text))
assert not used - declared, f"Missing string resources: {used - declared}"
for path in (native / "res").rglob("*.xml"):
    ET.parse(path)
manifest = ET.parse(native / "AndroidManifest.xml").getroot()
android = "{http://schemas.android.com/apk/res/android}"
classes = set(re.findall(r"\bclass\s+(\w+)", text))
for node in manifest.findall("./application/receiver") + manifest.findall("./application/service") + manifest.findall("./application/activity"):
    name = node.attrib.get(android + "name", "")
    if name.startswith("."):
        assert name[1:] in classes, f"Missing manifest component {name}"
defaults = (native / "kotlin/app/wakeguard/AlarmStore.kt").read_text()
known = set(re.findall(r"(?:const val|val|fun)\s+(\w+)", defaults))
references = set(re.findall(r"AlarmDefaults\.(\w+)", text))
assert not references - known, f"Missing shared constants/helpers: {references - known}"
assert len(re.findall(r"const val MAX_RINGING_MS\s*=", text)) == 1
assert '"contractVersion" to 2' in text
assert "'contractVersion': 2" in (root / "lib/platform/alarm_engine.dart").read_text()
assert 'class CheckInReceiver' in text
assert 'AlarmPolicy.acceptsPrimary' in text
print(f"Source checks passed: {len(sources)} Kotlin files; XML parsed; string resources, manifest components, shared constants and contract version matched.")
print("This does not validate Kotlin/Dart types, compile resources, or exercise alarm delivery.")
