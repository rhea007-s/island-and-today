plugins {
    id("com.android.application") version "8.7.3" apply false
    id("org.jetbrains.kotlin.android") version "2.0.21" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.21" apply false
}

// Build output lives outside ~/Desktop: the iCloud-synced Desktop would
// otherwise upload every intermediate class file.
allprojects {
    layout.buildDirectory.set(file("${System.getProperty("user.home")}/Library/Caches/IslandAndroid/${project.name}"))
}
