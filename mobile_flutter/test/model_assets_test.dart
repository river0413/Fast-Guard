/// 模型资产的回归测试（无需真机、无需 ONNX Runtime）。
///
/// 这里守住两类最容易犯、又最难在真机上定位的错误：
/// 1. 代码引用了模型资产，但**忘了在 pubspec.yaml 里声明** → 运行期 asset 找不到；
/// 2. 声明了资产但**文件不存在**（例如只提交了代码没提交模型）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:fastguard_mobile/inference/model_assets.dart';
import 'package:fastguard_mobile/settings.dart';

void main() {
  group('模型资产', () {
    test('按设置选择 FP32 / INT8 资产', () {
      expect(modelAssetFor(int8: false), kModelAssetFp32);
      expect(modelAssetFor(int8: true), kModelAssetInt8);
      expect(kModelAssetFp32, isNot(kModelAssetInt8));
    });

    test('两个资产都在 pubspec.yaml 中声明', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      for (final asset in <String>[kModelAssetFp32, kModelAssetInt8]) {
        expect(pubspec, contains('- $asset'),
            reason: '$asset 未在 pubspec.yaml 的 flutter.assets 下声明，运行期会加载失败');
      }
    });

    test('两个资产文件都真实存在，且是合理的 ONNX 大小', () {
      for (final asset in <String>[kModelAssetFp32, kModelAssetInt8]) {
        final file = File(asset);
        expect(file.existsSync(), isTrue, reason: '缺少模型文件：$asset');
        final sizeMb = file.lengthSync() / 1024 / 1024;
        expect(sizeMb, greaterThan(1.0), reason: '$asset 太小，可能没下载完整');
        expect(sizeMb, lessThan(20.0), reason: '$asset 过大，可能放错文件');
      }
    });

    test('INT8 模型确实比 FP32 小', () {
      final fp32 = File(kModelAssetFp32).lengthSync();
      final int8 = File(kModelAssetInt8).lengthSync();
      expect(int8, lessThan(fp32),
          reason: 'INT8 应显著更小（量化后约 4 MB vs 10 MB），否则可能导出错了');
    });

    test('每个资产都有界面标签', () {
      for (final asset in <String>[kModelAssetFp32, kModelAssetInt8]) {
        expect(kModelAssetLabels[asset], isNotNull);
        expect(kModelAssetLabels[asset], contains('MB'));
      }
    });
  });

  group('AppSettings.useInt8Model', () {
    test('默认使用 FP32（量化需要先在真机确认）', () {
      expect(AppSettings().useInt8Model, isFalse);
    });

    test('copy 深拷贝并进入摘要', () {
      final original = AppSettings(useInt8Model: false);
      final draft = original.copy()..useInt8Model = true;
      expect(original.useInt8Model, isFalse);
      expect(draft.useInt8Model, isTrue);
      expect(draft.summary, contains('INT8'));
      expect(original.summary, contains('FP32'));
    });

    test('copyFrom 覆盖模型精度', () {
      final target = AppSettings();
      target.copyFrom(AppSettings(useInt8Model: true));
      expect(target.useInt8Model, isTrue);
    });
  });
}
