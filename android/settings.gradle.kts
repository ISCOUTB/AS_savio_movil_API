pluginManagement {
    val flutterSdkPath =
        run {
            val properties = java.util.Properties()
            val localPropsFile = file("local.properties")
            if (!localPropsFile.exists()) {
                throw GradleException("local.properties not found in ${rootDir}. Ensure you have a local.properties with flutter.sdk set")
            }
            localPropsFile.inputStream().use { properties.load(it) }
            val flutterSdkPath = properties.getProperty("flutter.sdk")
            require(!flutterSdkPath.isNullOrBlank()) { "flutter.sdk not set in local.properties" }
            flutterSdkPath
        }

    // Ensure the flutter tools gradle directory exists before including the build.
    val flutterToolsDir = file("$flutterSdkPath/packages/flutter_tools/gradle")
    if (!flutterToolsDir.exists()) {
        throw GradleException("Flutter gradle plugin not found at: ${flutterToolsDir.absolutePath}. Check flutter.sdk in local.properties")
    }
    includeBuild(flutterToolsDir.absolutePath)

    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.9.1" apply false
    id("org.jetbrains.kotlin.android") version "2.1.0" apply false
}

include(":app")
