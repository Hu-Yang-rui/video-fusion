/// 静态安全扫描：确保源码中不存在硬编码凭证或凭证读取逻辑。
///
/// 这是需求七第 7 条「不硬编码访问令牌、Cookie、签名密钥或账号凭证」
/// 与需求三「不得窃取、硬编码、提交或泄露账号凭证」的自动化验证。
///
/// 本测试直接扫描 lib/ 下的真实源码文件。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 需要扫描的源码根目录。
const String _libRoot = 'lib';

/// 禁止出现在源码中的模式。
///
/// 每条都对应一个具体的合规约束。使用正则匹配真实代码文本。
final List<({String name, RegExp pattern, String reason})> _forbidden = [
  (
    name: 'SESSDATA 硬编码赋值',
    pattern: RegExp(r'''SESSDATA\s*[=:]\s*["'][^"']{8,}["']'''),
    reason: 'B 站登录凭证不得硬编码',
  ),
  (
    name: 'bili_jct 硬编码赋值',
    pattern: RegExp(r'''bili_jct\s*[=:]\s*["'][^"']{8,}["']'''),
    reason: 'B 站 CSRF 令牌不得硬编码',
  ),
  (
    name: 'UIFID 硬编码赋值',
    pattern: RegExp(r'''UIFID[A-Z_]*\s*[=:]\s*["'][^"']{8,}["']'''),
    reason: '抖音风控 Cookie 不得硬编码',
  ),
  (
    name: 'Cookie 请求头硬编码',
    pattern: RegExp(r'''["']Cookie["']\s*:\s*["'][^"']{10,}["']'''),
    reason: '不得硬编码 Cookie 请求头取值',
  ),
  (
    name: 'Authorization 请求头硬编码',
    pattern: RegExp(r'''["']Authorization["']\s*:\s*["'][^"']{6,}["']'''),
    reason: '不得硬编码授权头',
  ),
  (
    name: 'Bearer 令牌字面量',
    pattern: RegExp(r'''Bearer\s+[A-Za-z0-9\-_\.]{20,}'''),
    reason: '不得硬编码 Bearer 令牌',
  ),
  (
    name: '账号密码字段',
    pattern: RegExp(r'''(password|passwd|pwd)\s*[=:]\s*["'][^"']{4,}["']'''),
    reason: '不得硬编码密码',
  ),
  (
    name: '私钥标记',
    pattern: RegExp(r'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY'),
    reason: '不得提交私钥',
  ),
  (
    name: 'API 密钥赋值',
    pattern: RegExp(
      r'''(api[_-]?key|secret[_-]?key|access[_-]?token)\s*[=:]\s*["'][^"']{12,}["']''',
    ),
    reason: '不得硬编码 API 密钥或访问令牌',
  ),
];

/// 允许的例外：脱敏工具自身的模式定义与文档注释。
///
/// 这些行是**安全机制**，不是凭证泄漏。
bool _isAllowed(String line, String filePath) {
  // 脱敏工具需要定义敏感字段名清单
  if (filePath.endsWith('logger.dart')) return true;
  // 测试文件自身
  if (filePath.contains('test')) return true;
  // 注释行（说明性文字）
  final trimmed = line.trimLeft();
  if (trimmed.startsWith('//') || trimmed.startsWith('///') || trimmed.startsWith('*')) {
    return true;
  }
  return false;
}

void main() {
  test('lib/ 源码中不得存在硬编码凭证', () {
    final root = Directory(_libRoot);
    expect(root.existsSync(), isTrue, reason: 'lib/ 目录必须存在');

    final violations = <String>[];

    final files = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (_isAllowed(line, file.path)) continue;

        for (final rule in _forbidden) {
          if (rule.pattern.hasMatch(line)) {
            violations.add(
              '${file.path}:${i + 1}  [${rule.name}] ${rule.reason}\n'
              '      > ${line.trim()}',
            );
          }
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason: '发现硬编码凭证：\n${violations.join('\n')}',
    );
  });

  test('适配器不得读取环境变量中的凭证', () {
    final violations = <String>[];
    final files = Directory('lib/src/adapters')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

    for (final file in files) {
      final content = file.readAsStringSync();
      for (final pattern in [
        RegExp(r'Platform\.environment'),
        RegExp(r'String\.fromEnvironment'),
      ]) {
        if (pattern.hasMatch(content)) {
          violations.add('${file.path}: 读取环境变量');
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('适配器不得持久化 Cookie', () {
    final violations = <String>[];
    final files = Directory('lib/src/adapters')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

    for (final file in files) {
      final content = file.readAsStringSync();
      // 不得出现写 Cookie 到存储的行为
      if (RegExp(r'setString\([^)]*[Cc]ookie').hasMatch(content)) {
        violations.add('${file.path}: 持久化 Cookie');
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('项目内不得存在凭证类文件', () {
    final suspicious = <String>[];
    for (final dir in ['lib', 'test', 'tool']) {
      final d = Directory(dir);
      if (!d.existsSync()) continue;
      for (final f in d.listSync(recursive: true).whereType<File>()) {
        final name = f.uri.pathSegments.last.toLowerCase();

        // 凭证「数据」文件的典型形态：.env / 密钥 / 导出的 cookie 文本。
        // 注意：不能简单匹配名字里含 "credential" 的**源码**文件——
        // 那会把实现凭证加密存储的模块（credential_vault.dart）
        // 误判为凭证泄漏。这里只检查数据文件特征。
        final isEnvFile = name == '.env' ||
            name.startsWith('.env.') ||
            name.endsWith('.env');
        final isKeyFile = name.endsWith('.pem') ||
            name.endsWith('.key') ||
            name.endsWith('.p12');
        final isCookieDump = name == 'cookies.txt' ||
            name == 'cookie.txt' ||
            name == 'cookies.json' ||
            name == 'cookie.json';
        final isCredentialDump = (name.contains('credential') ||
                name.contains('secret') ||
                name.contains('token')) &&
            (name.endsWith('.json') ||
                name.endsWith('.txt') ||
                name.endsWith('.yaml') ||
                name.endsWith('.yml'));

        if (isEnvFile || isKeyFile || isCookieDump || isCredentialDump) {
          suspicious.add(f.path);
        }
      }
    }
    expect(suspicious, isEmpty, reason: '发现疑似凭证文件：${suspicious.join(', ')}');
  });

  test('凭证保险库必须使用加密存储而非明文文件', () {
    final vault = File('lib/src/core/credential_vault.dart');
    expect(vault.existsSync(), isTrue, reason: '凭证保险库必须存在');

    final content = vault.readAsStringSync();
    // 核心层通过 SecureStore 抽象访问安全存储，不直接依赖具体插件
    expect(
      content.contains('SecureStore'),
      isTrue,
      reason: '凭证必须通过安全存储抽象保存，而非普通文件',
    );
    // 不得把凭证明文写入普通文件
    expect(
      RegExp(r'File\([^)]*\)\.writeAs').hasMatch(content),
      isFalse,
      reason: '不得将凭证明文写入普通文件',
    );
    // 不得把凭证写入未加密的普通键值存储
    expect(
      content.contains('SharedPreferences'),
      isFalse,
      reason: '凭证不得存入未加密的 SharedPreferences',
    );
    // 必须提供登出清理能力
    expect(content.contains('clear'), isTrue, reason: '必须提供凭证清除能力');
  });

  test('加密存储实现必须使用平台安全存储插件', () {
    // 实际接触安全存储插件的唯一文件
    final impl = File('lib/src/core/platform/flutter_secure_store.dart');
    expect(impl.existsSync(), isTrue,
        reason: '必须存在基于平台安全存储的实现');

    final content = impl.readAsStringSync();
    expect(
      content.contains('FlutterSecureStorage'),
      isTrue,
      reason: '必须使用平台安全存储（Android Keystore / iOS Keychain）加密凭证',
    );
    expect(
      content.contains('isEncrypted => true'),
      isTrue,
      reason: '加密实现必须如实声明 isEncrypted=true',
    );
  });

  test('非加密实现必须如实声明未加密', () {
    final mem = File('lib/src/core/secure_store.dart');
    expect(mem.existsSync(), isTrue);
    final content = mem.readAsStringSync();
    // 内存实现用于测试，绝不能声称已加密
    expect(
      content.contains('isEncrypted => false'),
      isTrue,
      reason: '不加密的实现必须如实声明 isEncrypted=false，不得误导用户',
    );
  });
}
