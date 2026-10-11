plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.fastguard.fastguard_mobile"
    compileSdk = flutter.compileSdkVersion
    // 本项目不含任何原生（C/C++）代码：
    //   * camera / path_provider / shared_preferences 的 Android 端为 Kotlin/Java；
    //   * flutter_onnxruntime 的 Android 端同样为 Kotlin，ONNX Runtime 由 Maven
    //     依赖 com.microsoft.onnxruntime:onnxruntime-android 提供（预编译 AAR）。
    // 因此这里**不使用** flutter.ndkVersion —— 否则 Gradle 会额外下载约 1 GB 的
    // Android NDK（实测该下载还会因网络中断而失败），而它对构建毫无必要。
    // 若日后加入了带 C/C++ 的插件，请删除下面这行注释并恢复 ndkVersion。
    // ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.fastguard.fastguard_mobile"
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

        // 只打包 64 位 ABI。
        // 注意：ONNX Runtime 的 AAR（com.microsoft.onnxruntime:onnxruntime-android）自带
        // armeabi-v7a / arm64-v8a / x86 / x86_64 四套 .so，若不过滤会把 32 位的
        // armeabi-v7a 也打进包（实测多出约 20 MB）。
        ndk {
            abiFilters += listOf("arm64-v8a", "x86_64")
        }
    }

    // 实测 defaultConfig.ndk.abiFilters **不会**过滤预编译 AAR 里的 jniLibs，
    // 因此这里在打包阶段再排除一次 32 位目录，确保产物只含 64 位原生库。
    packaging {
        jniLibs {
            excludes += listOf("lib/armeabi-v7a/**", "lib/armeabi/**", "lib/x86/**")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")

            // Flutter 的 release 构建默认开启 R8 收缩/混淆（shouldShrinkResources 默认 true）。
            // ONNX Runtime 的原生库按“原始类名/方法名”做 JNI 查找，被混淆或裁剪后会出现
            // java_class == null 的 JNI 致命错误（实测：应用启动即闪退）。
            // 因此显式挂上保留规则 proguard-rules.pro。
            isMinifyEnabled = true
            isShrinkResources = true
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
