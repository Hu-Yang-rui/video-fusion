# Flutter 与插件的基础 keep 规则

# Flutter 引擎入口
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.**

# flutter_inappwebview
#
# 该插件的 AAR 在 R8 的 filtered-proguard-rules 变换阶段会触发
# "Unexpected end of ZLIB input stream"，因此这里显式 keep 其全部类，
# 并关闭相关告警，避免 R8 去解析其内置规则文件。
-keep class com.pichillilorenzo.flutter_inappwebview_android.** { *; }
-keep class com.pichillilorenzo.flutter_inappwebview_platform_interface.** { *; }
-dontwarn com.pichillilorenzo.flutter_inappwebview_android.**
-dontwarn com.pichillilorenzo.flutter_inappwebview_platform_interface.**

# WebView 与 JS 接口反射调用
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
-keepattributes JavascriptInterface
-keepattributes *Annotation*

# media_kit / libmpv 通过 JNI 调用
-keep class com.alexmercerind.** { *; }
-dontwarn com.alexmercerind.**

# 通用：保留行号便于崩溃分析（配合 --split-debug-info）
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# 不因第三方库的缺失类而失败
-dontwarn org.jetbrains.annotations.**
-dontwarn javax.annotation.**
