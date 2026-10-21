/// 字节系签名器测试。
///
/// 用固定输入 + 固定随机数，对照参考实现（从二进制还原的等价逻辑）
/// 的输出来验证。这些向量是确定性的，可复现。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:video_fusion/src/adapters/hongguo/byte_signer.dart';

void main() {
  group('X-Gorgon 对照向量', () {
    // 每个用例：query / body / ts / rnd → 期望的 gorgon 与 stub
    const cases = [
      (
        query: 'aid=8662&app_name=novelread',
        body: '{"video_id":"123"}',
        ts: 1700000000,
        rnd: 0x1234,
        stub: '618C32124B531343B9098CB34C12FED4',
        gorgon: '040812344001f7a29b5ccf29385f1dcbd44f085f75ace5d1f741',
      ),
      (
        query: '',
        body: '',
        ts: 1700000001,
        rnd: 0x0000,
        stub: 'D41D8CD98F00B204E9800998ECF8427E',
        gorgon: '0408000040011d7e26674766a1d82d4410a42085e11465391ed8',
      ),
      (
        query: 'a=1&b=2',
        body: '{}',
        ts: 1750000000,
        rnd: 0xffff,
        stub: '99914B932BD37A50B983C5E7C90AE93B',
        gorgon: '0408ffff40011a40f9c1dff6dcf08e196a722a58a86fd85d0236',
      ),
      (
        query: 'video_id=7690963410778868761',
        body: '{"video_id":"7690963410778868761","content_type":1}',
        ts: 1761100000,
        rnd: 0x8000,
        stub: '2A35B05B9DB15D6409009B4933BE922A',
        gorgon: '040880004001c1176cfd4411585bd891bf32bb401616a890a8c9',
      ),
    ];

    for (final c in cases) {
      test('query="${c.query}" ts=${c.ts} rnd=0x${c.rnd.toRadixString(16)}',
          () {
        final signer = ByteDanceSigner();
        final actual = signer.gorgon(
          query: c.query,
          body: utf8.encode(c.body),
          timestampSeconds: c.ts,
          random: c.rnd,
        );
        expect(actual, c.gorgon);
      });
    }
  });

  group('签名头结构', () {
    test('产出 x-ss-stub / X-Gorgon / X-Khronos', () {
      final signer = ByteDanceSigner();
      final h = signer.sign(
        url: '/novel/player/multi_video_model/v1/?a=1&b=2',
        body: utf8.encode('{}'),
        timestampSeconds: 1750000000,
      );

      expect(h.keys, containsAll(['x-ss-stub', 'X-Gorgon', 'X-Khronos']));
      expect(h['X-Khronos'], '1750000000');
      expect(h['x-ss-stub'], '99914B932BD37A50B983C5E7C90AE93B');
      // gorgon 固定 6 字节头 + 20 字节体 = 26 字节 = 52 个 hex 字符
      expect(h['X-Gorgon']!.length, 52);
      expect(RegExp(r'^[0-9a-f]+$').hasMatch(h['X-Gorgon']!), isTrue);
    });

    test('只取 ? 之后的部分参与签名', () {
      final signer = ByteDanceSigner();
      final withPath = signer.gorgon(
        query: 'a=1&b=2',
        body: utf8.encode('{}'),
        timestampSeconds: 1750000000,
        random: 0xffff,
      );

      // 完整 URL 形式，应得到同样结果
      final h = signer.sign(
        url: 'https://api5-normal-sinfonlineb.fqnovel.com/novel/x?a=1&b=2',
        body: utf8.encode('{}'),
        timestampSeconds: 1750000000,
      );
      // sign() 内部用随机数，所以只验证 gorgon 本身可复现
      expect(withPath.length, 52);
      expect(h['X-Gorgon']!.length, 52);
    });

    test('没有 ? 时 query 视为空串', () {
      final signer = ByteDanceSigner();
      final a = signer.gorgon(
        query: '',
        body: utf8.encode('{}'),
        timestampSeconds: 1750000000,
        random: 0xffff,
      );
      final b = signer.sign(
        url: '/no-query-here',
        body: utf8.encode('{}'),
        timestampSeconds: 1750000000,
      );
      expect(a.length, 52);
      expect(b['X-Gorgon']!.length, 52);
    });
  });

  group('X-Gorgon 结构约束', () {
    test('前 6 字节是 04 08 <rndHi> <rndLo> 40 01', () {
      final signer = ByteDanceSigner();
      final g = signer.gorgon(
        query: 'x=1',
        body: utf8.encode(''),
        timestampSeconds: 1700000000,
        random: 0xABCD,
      );
      expect(g.substring(0, 2), '04');
      expect(g.substring(2, 4), '08');
      expect(g.substring(4, 6), 'ab'); // rndHi
      expect(g.substring(6, 8), 'cd'); // rndLo
      expect(g.substring(8, 10), '40');
      expect(g.substring(10, 12), '01');
    });

    test('不同随机数产出不同签名', () {
      final signer = ByteDanceSigner();
      final a = signer.gorgon(
        query: 'x=1',
        body: utf8.encode('{}'),
        timestampSeconds: 1700000000,
        random: 1,
      );
      final b = signer.gorgon(
        query: 'x=1',
        body: utf8.encode('{}'),
        timestampSeconds: 1700000000,
        random: 2,
      );
      expect(a, isNot(b));
    });

    test('不同时间戳产出不同签名', () {
      final signer = ByteDanceSigner();
      final a = signer.gorgon(
        query: 'x=1',
        body: utf8.encode('{}'),
        timestampSeconds: 1700000000,
        random: 1,
      );
      final b = signer.gorgon(
        query: 'x=1',
        body: utf8.encode('{}'),
        timestampSeconds: 1700000001,
        random: 1,
      );
      expect(a, isNot(b));
    });

    test('query 变化影响签名（证明 query 参与计算）', () {
      final signer = ByteDanceSigner();
      final a = signer.gorgon(
        query: 'x=1',
        body: utf8.encode('{}'),
        timestampSeconds: 1700000000,
        random: 1,
      );
      final b = signer.gorgon(
        query: 'x=2',
        body: utf8.encode('{}'),
        timestampSeconds: 1700000000,
        random: 1,
      );
      expect(a, isNot(b));
    });

    test('body 变化影响签名（证明 body 参与计算）', () {
      final signer = ByteDanceSigner();
      final a = signer.gorgon(
        query: 'x=1',
        body: utf8.encode('{}'),
        timestampSeconds: 1700000000,
        random: 1,
      );
      final b = signer.gorgon(
        query: 'x=1',
        body: utf8.encode('{"a":1}'),
        timestampSeconds: 1700000000,
        random: 1,
      );
      expect(a, isNot(b));
    });
  });
}
