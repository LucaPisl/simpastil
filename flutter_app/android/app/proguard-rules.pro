# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Flutter references Play Core for deferred components; suppress warnings when
# the Play Core library is absent (sideload / non-Play-Store builds).
-dontwarn com.google.android.play.core.**

# OkHttp / Okio (used by Dio under the hood)
-dontwarn okhttp3.**
-dontwarn okio.**
-keep class okhttp3.** { *; }
-keep interface okhttp3.** { *; }
-keep class okio.** { *; }

# Drift / SQLite — keep generated DAO and table classes
-keep class com.simpastil.simpastil.**Dao { *; }
-keep class com.simpastil.simpastil.**Dao$** { *; }
-keep class com.simpastil.simpastil.**Table { *; }
-keepclassmembers class ** extends androidx.sqlite.db.SupportSQLiteOpenHelper$Callback { *; }

# flutter_secure_storage — Android Keystore classes
-keep class androidx.security.crypto.** { *; }
-keep class com.it_nomads.fluttersecurestorage.** { *; }

# flutter_local_notifications — BroadcastReceiver subclasses must be kept by name
-keep public class com.dexterous.flutterlocalnotifications.** { *; }
-keepclassmembers class com.dexterous.flutterlocalnotifications.** { *; }

# Gson TypeToken — flutter_local_notifications uses Gson to deserialize stored
# notification details. R8 strips generic Signature attributes from anonymous
# TypeToken subclasses (new TypeToken<...>() {}) even when -keepattributes Signature
# is set globally, causing IllegalStateException at runtime in the notification
# receivers and any cancel/reschedule operation. Keeping TypeToken subclasses as
# named entry points forces R8 to preserve their generic type arguments.
-keep class com.google.gson.reflect.TypeToken { *; }
-keep class * extends com.google.gson.reflect.TypeToken

# WorkManager (used by BootReceiver for background reschedule)
-keep class androidx.work.** { *; }
-keep class * extends androidx.work.Worker { *; }
-keep class * extends androidx.work.ListenableWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
}

# Gson / JSON (used by Drift serialization)
-keepattributes Signature
-keepattributes *Annotation*
-dontwarn sun.misc.**
