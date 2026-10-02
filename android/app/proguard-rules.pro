# google_mlkit_text_recognition references optional script recognizers that
# FinBro does not bundle (only the Latin model is used).
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**

# ML Kit text recognition crashed in the R8 release build (NPE in
# mlkit_vision_common.zzmj.<init> on every recognize call): its internal
# registries/protos are reached reflectively. Keep ML Kit and its internals.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_common.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_text_bundled_common.** { *; }
