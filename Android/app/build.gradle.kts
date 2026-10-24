import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.karaman.island"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.karaman.island"
        minSdk = 29
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"

        // The Firebase Web API key comes from Android/local.properties
        // (git-ignored), so it never sits in the repository.
        val localProps = Properties()
        rootProject.file("local.properties").takeIf { it.exists() }?.inputStream()?.use { localProps.load(it) }
        buildConfigField("String", "FIREBASE_KEY", "\"${localProps.getProperty("ISLAND_FIREBASE_KEY", "")}\"")
    }

    // Release key lives outside the project (~/.android/island-release.jks,
    // passwords in ~/.gradle/gradle.properties) so it never lands in iCloud
    // or a repo. Keep it: an update signed with any other key will not
    // install over the old app.
    val storePath = providers.gradleProperty("ISLAND_STORE_FILE").orNull
    signingConfigs {
        if (storePath != null) create("release") {
            storeFile = file(storePath)
            storePassword = providers.gradleProperty("ISLAND_STORE_PASSWORD").get()
            keyAlias = providers.gradleProperty("ISLAND_KEY_ALIAS").get()
            keyPassword = providers.gradleProperty("ISLAND_STORE_PASSWORD").get()
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"))
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    buildFeatures { compose = true; buildConfig = true }
}

dependencies {
    val bom = platform("androidx.compose:compose-bom:2024.12.01")
    implementation(bom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.core:core-ktx:1.15.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.7")
    implementation("androidx.savedstate:savedstate-ktx:1.2.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}
