import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── 发布签名 ────────────────────────────────────────────────────
//
// # 为什么必须有真证书
//
// 以前 release 用的是 `signingConfigs.getByName("debug")`，即
// `CN=Android Debug` 调试证书。部分系统（尤其国产 ROM）会拒绝安装
// debug 签名的 release 包，报「无证书 / 证书无效 / 应用未签名」。
// 用 `apksigner verify --print-certs` 可以确认：
//   Signer #1 certificate DN: C=US, O=Android, CN=Android Debug
//
// # 凭据怎么放
//
// `android/key.properties`（**不入库**，见 .gitignore）：
//   storeFile=video-fusion-release.jks
//   storePassword=...
//   keyAlias=video-fusion
//   keyPassword=...
//
// 文件缺失时回退到 debug 签名，保证 `flutter build` 不因缺凭据直接失败
// （CI / 新克隆的仓库仍能构建出可运行的包），但会在日志里明确警告。
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.example.video_fusion"
    compileSdk = flutter.compileSdkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")

                // # 必须显式开启 v1（JAR）签名
                //
                // AGP 8 默认只出 v2/v3，v1 是 false。实测
                // `apksigner verify --verbose` 显示：
                //   Verified using v1 scheme: false
                //   Verified using v2 scheme: true
                //
                // Android 7.0（API 24）以下**只认 v1**，没有 v1 的包
                // 在这些设备上会报"应用未签名/解析包失败"。
                // 开启 v1 后 v2 仍保留，两条路都能装。
                enableV1Signing = true
                enableV2Signing = true
            }
        }
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
            // 有真证书就用真证书；缺失时回退 debug（并警告），
            // 不让"缺凭据"把构建彻底堵死。
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "⚠️ android/key.properties 缺失 → release 回退 debug 签名。" +
                        "debug 签名的包在部分机型上会被拒绝安装（提示无证书）。"
                )
                signingConfigs.getByName("debug")
            }

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
