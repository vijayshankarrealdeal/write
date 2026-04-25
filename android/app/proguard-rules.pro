# ── InkSpaceX ProGuard Rules ──

# Flutter
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Firebase
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }

# Google Sign-In
-keep class com.google.android.gms.auth.** { *; }

# Keep model classes (Firestore serialization)
-keepattributes Signature
-keepattributes *Annotation*
-keepattributes EnclosingMethod
-keepattributes InnerClasses

# Prevent R8 from removing Google Play services
-dontwarn com.google.android.gms.**
-dontwarn com.google.firebase.**

# Play Core (SplitCompat)
-dontwarn com.google.android.play.core.**
-keep class com.google.android.play.core.** { *; }
