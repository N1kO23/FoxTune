pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            file("local.properties").inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

// Pinned to the Gradle 8 / AGP 8 line on purpose - do not bump without
// checking the note below.
//
// Gradle 9.0 removed the `jcenter()` repository method. The flutter_libserialport
// plugin (0.6.0, the current release) still calls it in its android/build.gradle,
// so any Gradle 9 build of this app fails while evaluating that subproject with
// "Could not find method jcenter()". The plugin is only used on desktop; Android
// serial goes through usb_serial. Until upstream drops jcenter, the Android build
// has to stay on Gradle 8.
//
// The window is narrow: Flutter 3.47 hard-errors below Gradle 8.14.0 and AGP
// 8.11.1, jcenter disappears at Gradle 9.0, and AGP 9 needs Gradle 9. Hence the
// last releases of each 8.x line: Gradle 8.14.5 and AGP 8.13.2.
plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.13.2" apply false
    id("org.jetbrains.kotlin.android") version "2.4.20" apply false
}

include(":app")
