import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val uploadProperties = Properties().apply {
    val path = rootProject.file("key.properties")
    if (path.exists()) path.inputStream().use { load(it) }
}
fun uploadValue(key: String, environment: String): String? =
    System.getenv(environment)?.takeIf { it.isNotBlank() }
        ?: uploadProperties.getProperty(key)?.takeIf { it.isNotBlank() }
val uploadStore = uploadValue("storeFile", "WAKEGUARD_KEYSTORE")
val uploadAlias = uploadValue("keyAlias", "WAKEGUARD_KEY_ALIAS")
val uploadStorePassword = uploadValue("storePassword", "WAKEGUARD_STORE_PASSWORD")
val uploadKeyPassword = uploadValue("keyPassword", "WAKEGUARD_KEY_PASSWORD")
val hasUploadKey = listOf(uploadStore, uploadAlias, uploadStorePassword, uploadKeyPassword).all { it != null }
val releaseRequested = gradle.startParameter.taskNames.any { it.contains("release", ignoreCase = true) }
if (releaseRequested && !hasUploadKey) {
    throw GradleException("Release signing is not configured. Add android/key.properties using key.properties.example or set WAKEGUARD signing environment variables. Debug builds remain available; release never uses the debug key.")
}

android {
    namespace = "com.bling.wakeguard"
    compileSdk = maxOf(36, flutter.compileSdkVersion)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.bling.wakeguard"
        // 24 is the floor for the CameraX/ML Kit versions below and for the
        // modern AlarmManager exact-alert path.
        minSdk = 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        resourceConfigurations += listOf("en")
    }

    signingConfigs {
        if (hasUploadKey) {
            create("upload") {
                storeFile = rootProject.file(uploadStore!!)
                storePassword = uploadStorePassword
                keyAlias = uploadAlias
                keyPassword = uploadKeyPassword
            }
        }
    }

    buildTypes {
        release {
            if (hasUploadKey) signingConfig = signingConfigs.getByName("upload")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    buildFeatures {
        viewBinding = true
    }

    sourceSets.getByName("main").assets.srcDir("../../resources")

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    // The wake challenge is implemented natively so that dismissing an alarm
    // never depends on the Flutter engine or the Dart isolate. The bundled
    // ML Kit models are offline-only: no first-run model download, which
    // matters at 05:00 on a poor connection.
    val cameraxVersion = "1.4.1"
    implementation("androidx.camera:camera-core:${cameraxVersion}")
    implementation("androidx.camera:camera-camera2:${cameraxVersion}")
    implementation("androidx.camera:camera-lifecycle:${cameraxVersion}")
    implementation("androidx.camera:camera-view:${cameraxVersion}")

    implementation("com.google.mlkit:face-detection:16.1.7")
    implementation("com.google.mlkit:barcode-scanning:17.3.0")
    // Bundled model: exact Sink/Cup labels work offline on first launch.
    implementation("com.google.mlkit:image-labeling:17.0.9")

    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.media:media:1.7.0")
}

flutter {
    source = "../.."
}
