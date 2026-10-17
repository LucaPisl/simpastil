import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Secrets may be injected as environment variables or through a gitignored
// properties file. Never print the loaded values to Gradle output.
val signingProperties = Properties()
val signingPropertiesPath = providers.environmentVariable("SIMPASTIL_SIGNING_PROPERTIES")
    .orNull
    ?.takeIf(String::isNotBlank)
    ?: "signing.properties"
val signingPropertiesFile = rootProject.file(signingPropertiesPath)
if (signingPropertiesFile.isFile) {
    signingPropertiesFile.inputStream().use { signingProperties.load(it) }
}

fun signingValue(name: String): String? = providers.environmentVariable(name)
    .orNull
    ?.takeIf(String::isNotBlank)
    ?: signingProperties.getProperty(name)?.trim()?.takeIf(String::isNotBlank)

val releaseKeystorePath = signingValue("SIMPASTIL_KEYSTORE_PATH")
val releaseKeyAlias = signingValue("SIMPASTIL_KEY_ALIAS")
val releaseStorePassword = signingValue("SIMPASTIL_STORE_PASSWORD")
val releaseKeyPassword = signingValue("SIMPASTIL_KEY_PASSWORD")
val expectedCertificateFingerprint = signingValue("SIMPASTIL_EXPECTED_CERT_SHA256")
    ?.replace(":", "")
    ?.uppercase()
val releaseKeystoreFile = releaseKeystorePath?.let { rootProject.file(it) }
val releaseSigningConfigured = !releaseKeyAlias.isNullOrBlank() &&
    !releaseStorePassword.isNullOrBlank() &&
    !releaseKeyPassword.isNullOrBlank() &&
    releaseKeystoreFile?.isFile == true &&
    expectedCertificateFingerprint?.matches(Regex("[A-F0-9]{64}")) == true
val simpastilCompileSdkVersion = flutter.compileSdkVersion
val simpastilNdkVersion = flutter.ndkVersion

android {
    namespace = "com.simpastil.simpastil"
    compileSdk = simpastilCompileSdkVersion
    ndkVersion = simpastilNdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    sourceSets {
        getByName("test").resources.srcDir("../../../contracts/fixtures")
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.simpastil.simpastil"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    if (releaseSigningConfigured) {
        signingConfigs {
            create("productionRelease") {
                storeFile = releaseKeystoreFile
                storePassword = releaseStorePassword
                keyAlias = releaseKeyAlias
                keyPassword = releaseKeyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = if (releaseSigningConfigured) {
                signingConfigs.getByName("productionRelease")
            } else {
                null
            }
        }
    }
}

tasks.register("printSimpastilToolchain") {
    doLast {
        println("SIMPASTIL_ANDROID_COMPILE_SDK=$simpastilCompileSdkVersion")
        println("SIMPASTIL_ANDROID_BUILD_TOOLS=${android.buildToolsVersion}")
        println("SIMPASTIL_ANDROID_NDK=$simpastilNdkVersion")
    }
}

// Check the resolved task graph so aggregate tasks such as `assemble` cannot
// produce an unsigned/debug-signed release APK through a different task name.
gradle.taskGraph.whenReady {
    val releaseArtifactRequested = allTasks.any { task ->
        task.project.path == ":app" &&
            task.name.matches(Regex("(assemble|package|bundle|sign|install|publish).*Release.*"))
    }
    if (releaseArtifactRequested && !releaseSigningConfigured) {
        throw GradleException(
            "Release signing is required. Configure the complete Simpastil signing inputs; no signing values were logged."
        )
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("androidx.biometric:biometric:1.1.0")
    implementation("androidx.work:work-runtime-ktx:2.9.1")
    testImplementation("junit:junit:4.13.2")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
