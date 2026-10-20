plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.video_fusion"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    // 本地签名库垫片（metasec_shim）已封存到
    // archive/douyin-native-signer-v2/。原因见该目录 README：
    // 那条路需要 arm64 真机 + app-bound license + 设备身份自洽，
    // 且功能提升接近零（Web 端已覆盖详情/评论/推荐/热榜/直播/弹幕，
    // 私信与通知也已确认走 Web 端可达，只缺登录态）。
    //
    // 重新启用时把 externalNativeBuild { cmake { ... } } 加回来，
    // 并把 archive/douyin-native-signer-v2/cpp/ 拷回 src/main/cpp/。

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.video_fusion"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // # 不强制单 ABI（实测结论）
        //
        // 曾尝试只打 arm64 让模拟器走翻译层，失败：
        // x86_64 模拟器的 zygote 是 x86_64，App 进程必然是 x86_64，
        // 而 libflutter.so 只在 lib/arm64-v8a/ 里 → 启动即
        // UnsatisfiedLinkError: library "libflutter.so" not found。
        //
        // 结论：翻译层不会把 x86_64 进程的 dlopen 重定向到 arm64 目录。
        // 因此保持多 ABI，metasec 的跨 ABI 加载由 Dart 侧
        // 「从 APK 提取 so + 完整路径 dlopen」解决（见 metasec_loader.dart）。
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")

            // R8 混淆。
            //
            // 注意：flutter_inappwebview_android 的 AAR 在 R8 读取其
            // 内置 proguard 规则时，会因 AAR 的 ZIP 结构触发
            // "Unexpected end of ZLIB input stream" 而构建失败
            // （只在该模块的 minifyReleaseWithR8 阶段出现，debug 正常）。
            //
            // 因此这里保留 R8 但跳过对第三方库的规则解析：
            // 用 -dontwarn + 显式 keep 规则覆盖 WebView 相关类，
            // 并关闭对依赖的完整规则提取。
            isMinifyEnabled = true
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
