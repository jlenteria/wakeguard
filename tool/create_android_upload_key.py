"""Generate an Android upload key without putting passwords in terminal output.

Only creates new files. Never replaces a keystore or signing configuration.
Requires keytool (a JDK); invoked explicitly by the developer or coding agent.
"""
from pathlib import Path
import os
import secrets
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
android = root / "android"
keystore = android / "app/upload-keystore.jks"
properties = android / "key.properties"
if keystore.exists() or properties.exists():
    raise SystemExit("Signing files already exist; refusing to overwrite them.")
keytool = shutil.which("keytool")
if not keytool:
    raise SystemExit("Install a JDK with keytool before creating the upload key.")
password = secrets.token_urlsafe(36)
environment = dict(os.environ, WAKEGUARD_NEW_KEY_PASSWORD=password)
subprocess.run([
    keytool, "-genkeypair", "-v", "-keystore", str(keystore),
    "-storetype", "JKS", "-alias", "upload", "-keyalg", "RSA",
    "-keysize", "3072", "-validity", "10000", "-dname", "CN=Jonel Lenteria",
    "-storepass:env", "WAKEGUARD_NEW_KEY_PASSWORD",
    "-keypass:env", "WAKEGUARD_NEW_KEY_PASSWORD",
], check=True, env=environment)
keystore.chmod(0o600)
descriptor = os.open(properties, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, "w") as output:
    output.write("storeFile=app/upload-keystore.jks\nkeyAlias=upload\n")
    output.write(f"storePassword={password}\nkeyPassword={password}\n")
print("Created android/app/upload-keystore.jks and android/key.properties (private, gitignored).")
print("Passwords were not printed. Back up both files securely before publishing.")
