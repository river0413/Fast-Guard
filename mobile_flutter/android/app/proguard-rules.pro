# FastGuard 移动端 —— R8/ProGuard 保留规则
#
# 背景（真机实测，MEIZU 21 Pro / Android 16）：
#   Flutter 的 release 构建**默认开启 R8 收缩与混淆**（FlutterPluginUtils.shouldShrinkResources
#   默认 true），实测 classes.dex 里的类名已被改成 La00; / Lcc0; 这种短名。
#   而 ONNX Runtime 的原生库（libonnxruntime4j_jni.so）是按**原始类名与方法名**
#   做 JNI 查找的（FindClass / GetMethodID），一旦被混淆或裁剪就会失败：
#
#     1) java.lang.NoSuchMethodError:
#        no non-static method "Lai/onnxruntime/NodeInfo;.<init>(Ljava/lang/String;Lai/onnxruntime/ValueInfo;)V"
#     2) JNI DETECTED ERROR IN APPLICATION: java_class == null
#        in call to GetMethodID
#        from boolean[] ai.onnxruntime.OrtSession.run(...)
#     => 两者都以 SIGABRT 结束进程（无法在 Dart 侧捕获），表现为“打开即闪退”。
#
# 因此必须保留 ONNX Runtime 的全部类与成员，以及插件的入口类。

# --- ONNX Runtime Java API：JNI 按原名查找，禁止混淆与裁剪 ---
-keep class ai.onnxruntime.** { *; }
-keepclassmembers class ai.onnxruntime.** { *; }
-keepnames class ai.onnxruntime.** { *; }
-dontwarn ai.onnxruntime.**

# --- flutter_onnxruntime 插件：通过平台通道反射调用 ---
-keep class com.masicai.flutteronnxruntime.** { *; }
-dontwarn com.masicai.flutteronnxruntime.**

# --- 原生方法声明不可裁剪（JNI 注册依赖） ---
-keepclasseswithmembernames class * {
    native <methods>;
}

# --- 其它插件按 Flutter 官方建议保留 Flutter 引擎入口 ---
-keep class io.flutter.** { *; }
-dontwarn io.flutter.**
