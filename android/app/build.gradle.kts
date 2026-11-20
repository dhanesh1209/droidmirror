import java.util.Properties

plugins {
    id("com.android.application")
}

android {
    namespace = "dev.droidmirror.companion"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.droidmirror.companion"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0"
    }

    // Release signing comes from a properties file OUTSIDE the repo (never commit keys or passwords).
    // Point DROIDMIRROR_SIGNING at a file with: storeFile, storePassword, keyAlias, keyPassword.
    val signingFile = System.getenv("DROIDMIRROR_SIGNING")?.let { File(it) }?.takeIf { it.exists() }
    if (signingFile != null) {
        val props = Properties().apply { signingFile.inputStream().use { load(it) } }
        signingConfigs {
            create("release") {
                storeFile = File(props.getProperty("storeFile"))
                storePassword = props.getProperty("storePassword")
                keyAlias = props.getProperty("keyAlias")
                keyPassword = props.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            if (signingFile != null) signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    // QR scanning through Google Play services (no camera permission needed in our app).
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.json:json:20240303")
}
