# Keep audio service classes
-keep class com.ryanheise.just_audio.** { *; }
-keep class com.ryanheise.audio_service.** { *; }

# Keep Flutter audio plugin classes
-keep class io.flutter.plugins.audioplayers.** { *; }

# Keep YouTube downloader classes
-keep class com.github.ytdl.** { *; }

# Keep all native methods
-keepclasseswithmembernames class * {
    native <methods>;
}

# Keep audio service methods
-keep class * extends com.ryanheise.audio_service.AudioHandler {
    public <methods>;
}

# Keep MediaItem and related classes
-keep class androidx.media2.common.MediaItem { *; }
-keep class androidx.media2.session.MediaSession { *; }

# Keep all classes in the main package
-keep class com.example.jupotify.** { *; }

# Keep all classes with @Keep annotation
-keep @androidx.annotation.Keep class * { *; }

# Don't obfuscate method names for audio service
-keepclassmembers class * {
    @com.ryanheise.audio_service.AudioServiceMethod <methods>;
}

# Keep audio service callbacks
-keep class * implements com.ryanheise.audio_service.AudioHandler {
    public <methods>;
}
