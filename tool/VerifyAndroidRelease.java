import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.Locale;
import java.util.Properties;
import java.util.jar.JarFile;

/** JDK 17 source-file launcher: validates signing config or every AAB payload entry. */
class VerifyAndroidRelease {
    public static void main(String[] args) {
        try {
            verify(args);
        } catch (Exception error) {
            System.err.println("Release verification failed: " + error.getMessage());
            System.exit(1);
        }
    }

    private static String value(Properties properties, String key, String environment) {
        String value = System.getenv(environment);
        if (value == null || value.isBlank()) value = properties.getProperty(key);
        if (value == null || value.isBlank()) {
            throw new IllegalArgumentException("Configure " + key + " in android/key.properties or " + environment);
        }
        return value;
    }

    private static void verify(String[] args) throws Exception {
        if (args.length != 2) {
            throw new IllegalArgumentException("Usage: java tool/VerifyAndroidRelease.java android <bundle.aab|--check>");
        }
        Path android = Path.of(args[0]);
        Properties properties = new Properties();
        Path config = android.resolve("key.properties");
        if (Files.exists(config)) {
            try (InputStream input = Files.newInputStream(config)) {
                properties.load(input);
            }
        }
        Path store = android.resolve(value(properties, "storeFile", "WAKEGUARD_KEYSTORE"));
        String alias = value(properties, "keyAlias", "WAKEGUARD_KEY_ALIAS");
        char[] storePassword = value(properties, "storePassword", "WAKEGUARD_STORE_PASSWORD").toCharArray();
        char[] keyPassword = value(properties, "keyPassword", "WAKEGUARD_KEY_PASSWORD").toCharArray();
        X509Certificate expected;
        try {
            KeyStore keys = KeyStore.getInstance(store.toFile(), storePassword);
            if (!keys.isKeyEntry(alias) || keys.getKey(alias, keyPassword) == null) {
                throw new IllegalArgumentException("Configured upload alias is not a private key entry");
            }
            expected = (X509Certificate) keys.getCertificate(alias);
            expected.checkValidity();
        } finally {
            Arrays.fill(storePassword, '\0');
            Arrays.fill(keyPassword, '\0');
        }
        if (args[1].equals("--check")) {
            System.out.println("Upload keystore, alias, passwords and certificate validity checked.");
            return;
        }

        int verified = 0;
        byte[] certificate = expected.getEncoded();
        // Reading to EOF makes JarFile check each entry's digest and signer.
        // No CA trust is required: Android upload certificates are normally self-signed.
        try (JarFile bundle = new JarFile(args[1], true)) {
            if (bundle.getJarEntry("base/manifest/AndroidManifest.xml") == null) {
                throw new IllegalArgumentException("Not an Android App Bundle: base manifest is missing");
            }
            var entries = bundle.entries();
            byte[] buffer = new byte[64 * 1024];
            while (entries.hasMoreElements()) {
                var entry = entries.nextElement();
                if (entry.isDirectory()) continue;
                try (InputStream input = bundle.getInputStream(entry)) {
                    while (input.read(buffer) != -1) { /* verify digest */ }
                }
                if (isSigningMetadata(entry.getName())) continue;
                var signers = entry.getCodeSigners();
                if (signers == null || signers.length == 0) {
                    throw new SecurityException("Unsigned bundle entry: " + entry.getName());
                }
                for (var signer : signers) {
                    var leaf = signer.getSignerCertPath().getCertificates().get(0);
                    if (!MessageDigest.isEqual(certificate, leaf.getEncoded())) {
                        throw new SecurityException("Unexpected signer on bundle entry: " + entry.getName());
                    }
                }
                verified++;
            }
        }
        if (verified == 0) throw new SecurityException("Bundle contains no signed payload");
        String fingerprint = HexFormat.ofDelimiter(":").withUpperCase()
            .formatHex(MessageDigest.getInstance("SHA-256").digest(certificate));
        System.out.println("Verified " + verified + " payload entries against the configured upload certificate.");
        System.out.println("Upload certificate SHA-256: " + fingerprint);
    }

    private static boolean isSigningMetadata(String name) {
        String upper = name.toUpperCase(Locale.ROOT);
        if (upper.equals("META-INF/MANIFEST.MF")) return true;
        if (!upper.startsWith("META-INF/")) return false;
        String file = upper.substring("META-INF/".length());
        if (file.contains("/")) return false;
        return file.endsWith(".SF") || file.endsWith(".RSA") ||
            file.endsWith(".DSA") || file.endsWith(".EC") || file.startsWith("SIG-");
    }
}
