// 把本地文本成果推送到 video-fusion-prompts 仓库。
//
// # 为什么不用 git push
//
// 本机到 github.com 的 443 直连与 TLS 握手都不稳（schannel
// `server closed abruptly` / `failed to receive handshake`）。
// 但 `gh` CLI 走的是 API，能通。
//
// 因此这里用 GitHub Contents API 逐个文件 PUT。
//
// # 用法
//
//   node sync_to_prompts_repo.mjs            # 干跑，只列出要传什么
//   node sync_to_prompts_repo.mjs --apply    # 真传

import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const REPO = 'Hu-Yang-rui/video-fusion-prompts';
const BRANCH = 'main';
const APPLY = process.argv.includes('--apply');

// 源根目录：第一个非 `--` 开头的参数，默认 `..\Video Fusion`。
//
// 注意不能直接用 `process.argv[2]`：`--apply` 可能排在前面，
// 那样会把标志当成路径。
const SRC_ROOT = '.';

// 源 → 目标映射。
//
// 只同步**文本类**成果：报告、方法论、约定、实测记录。
// APK、so、探针产物、bundle 快照一律不同步。
const MAP = [
  ['AGENTS.md', '工程约定/AGENTS-项目约定.md'],
  ['APK样本/README.md', '逆向分析/APK样本目录说明.md'],
  ['APK样本/逆向分析/通用/README.md', '逆向分析/通用/逆向方法论.md'],
  ['APK样本/逆向分析/抖音/APK-API-逆向报告.md', '逆向分析/抖音/APK-API-逆向报告.md'],
  ['APK样本/逆向分析/抖音/合规与权限调查报告.md', '逆向分析/抖音/合规与权限调查报告.md'],
  ['APK样本/逆向分析/抖音/本地签名库接入说明.md', '逆向分析/抖音/本地签名库接入说明.md'],
  ['APK样本/逆向分析/抖音/签名资源自查报告.md', '逆向分析/抖音/签名资源自查报告.md'],
  ['APK样本/逆向分析/抖音/直播弹幕HTTP通道.md', '逆向分析/抖音/直播弹幕HTTP通道.md'],
  ['APK样本/逆向分析/抖音/包结构清单.txt', '逆向分析/抖音/包结构清单.txt'],
  ['archive/douyin-native-signer/README.md', '逆向分析/抖音/签名库封存说明.md'],
  ['APK样本/逆向分析/哔哩哔哩/包结构清单.txt', '逆向分析/哔哩哔哩/包结构清单.txt'],
  ['docs/SESSION-RESULTS.md', '实测记录-2026-10-19.md'],
];

function gh(args, opts = {}) {
  return execFileSync('gh', args, {
    encoding: 'utf8',
    maxBuffer: 200 * 1024 * 1024,
    ...opts,
  });
}

/** 取远端某文件的 blob sha（不存在返回 null）。 */
function remoteSha(remotePath) {
  try {
    const out = gh([
      'api',
      `repos/${REPO}/contents/${encodeURI(remotePath)}?ref=${BRANCH}`,
      '--jq',
      '.sha',
    ]);
    return out.trim() || null;
  } catch {
    return null;
  }
}

function push(remotePath, localPath) {
  const content = fs.readFileSync(localPath);
  const b64 = content.toString('base64');
  const sha = remoteSha(remotePath);

  // # 为什么用 --input 而不是 -f content=...
  //
  // 大文件的 base64 会把命令行撑爆（实测 46 KB 的文件就触发
  // `spawnSync gh ENAMETOOLONG`）。改成写临时 JSON 再用 --input 传入。
  const payload = {
    message: `${sha ? 'update' : 'add'}: ${remotePath}`,
    content: b64,
    branch: BRANCH,
    ...(sha ? { sha } : {}),
  };

  const tmp = path.join(
    os.tmpdir(),
    `gh-push-${Date.now()}-${Math.random().toString(36).slice(2)}.json`,
  );
  fs.writeFileSync(tmp, JSON.stringify(payload), 'utf8');

  try {
    gh([
      'api',
      '--method', 'PUT',
      `repos/${REPO}/contents/${encodeURI(remotePath)}`,
      '--input', tmp,
    ]);
  } finally {
    try {
      fs.unlinkSync(tmp);
    } catch {}
  }
  return sha ? 'updated' : 'created';
}

let ok = 0;
let skip = 0;
let fail = 0;

for (const [rel, remote] of MAP) {
  const local = path.join(SRC_ROOT, rel);
  if (!fs.existsSync(local)) {
    console.log(`SKIP  ${rel}  (本地不存在)`);
    skip++;
    continue;
  }
  const size = fs.statSync(local).size;
  if (!APPLY) {
    console.log(`DRY   ${rel}  →  ${remote}  (${(size / 1024).toFixed(1)} KB)`);
    ok++;
    continue;
  }
  try {
    const action = push(remote, local);
    console.log(`OK    ${action.padEnd(7)} ${remote}  (${(size / 1024).toFixed(1)} KB)`);
    ok++;
  } catch (e) {
    console.log(`FAIL  ${remote}`);
    console.log(`      ${String(e.stderr || e.message).slice(0, 300)}`);
    fail++;
  }
}

console.log(`\n汇总: ok=${ok} skip=${skip} fail=${fail}${APPLY ? '' : '  （干跑，加 --apply 真传）'}`);
