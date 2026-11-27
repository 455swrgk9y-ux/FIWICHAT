plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.fiwichat.fiwichat"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.fiwichat.fiwichat"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 29 // Android 10+ : nécessaire pour le réseau invité FIWICHAT
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Clé de signature PERMANENTE de FIWICHAT. Toujours la même : c'est ce qui permet
    // d'installer une nouvelle version par-dessus l'ancienne. Le fichier n'est jamais
    // dans le dépôt : GitHub le recrée à partir du secret FIWICHAT_KEYSTORE.
    val releaseKey = file("fiwichat.p12")
    signingConfigs {
        create("release") {
            if (releaseKey.exists()) {
                storeFile = releaseKey
                storeType = "pkcs12"
                storePassword = "fiwichat"
                keyAlias = "fiwichat"
                keyPassword = "fiwichat"
            }
        }
    }

    buildTypes {
        release {
            // Sans la clé (sur un ordinateur de développeur), on signe avec la clé de test.
            signingConfig =
                if (releaseKey.exists()) signingConfigs.getByName("release")
                else signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation("androidx.core:core:1.13.1")
}
