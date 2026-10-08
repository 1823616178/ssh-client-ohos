#!/usr/bin/env node
/**
 * ets-unit —— 在 Node 里跑 entry/src/test 下「纯逻辑」hypium 用例（无 DevEco/hvigor 时的回归网）。
 *
 * 原理：
 *   - require 钩子把 .ets 用 TypeScript transpileModule 转成 CommonJS 后执行
 *     （只做类型擦除，不做 ArkTS 严格校验——严格模式仍以 DevEco 编译为准）；
 *   - '@ohos/hypium' 映射到本目录 hypium-shim.js（describe/it/expect 常用断言）；
 *   - '@kit.*' / '@ohos.*' 系统模块映射到惰性桩（Proxy），保证「顺带 import 了系统
 *     能力、但被测函数是纯逻辑」的模块可以加载；真正调用系统能力的用例会失败——
 *     这类用例本就只能真机跑；
 *   - 含 @Component struct 的 .ets 无法转译：import 它的测试文件整体跳过并列出。
 *
 * 用法：
 *   npm i -g typescript   # 或 TS_PATH=/path/to/node_modules/typescript
 *   node scripts/ets-unit/run.js                 # 跑 entry/src/test/*.test.ets
 *   node scripts/ets-unit/run.js KeyMap Selection # 只跑文件名包含这些片段的测试
 * 退出码：有失败用例 = 1；仅有跳过 = 0。
 */
'use strict';
const fs = require('fs');
const path = require('path');
const Module = require('module');

function loadTs() {
  const candidates = [process.env.TS_PATH, 'typescript', '/tmp/etsrunner/node_modules/typescript'];
  for (const c of candidates) {
    if (!c) continue;
    try {
      return require(c);
    } catch (e) {
      // 尝试下一个
    }
  }
  console.error('[ets-unit] 找不到 typescript：npm i -g typescript 或设置 TS_PATH');
  process.exit(2);
}
const ts = loadTs();

const ROOT = path.resolve(__dirname, '..', '..');
const TEST_DIR = path.join(ROOT, 'entry', 'src', 'test');
const SHIM = path.join(__dirname, 'hypium-shim.js');
const STUB = path.join(__dirname, 'kit-stub.js');

class UntranspilableError extends Error {}

require.extensions['.ets'] = function (module, filename) {
  const src = fs.readFileSync(filename, 'utf8');
  if (/^\s*@(Component|ComponentV2|Entry|CustomDialog)\b/m.test(src) || /\bstruct\s+\w+\s*\{/.test(src)) {
    throw new UntranspilableError(`含 ArkUI struct，无法在 Node 转译：${path.relative(ROOT, filename)}`);
  }
  const out = ts.transpileModule(src, {
    fileName: filename,
    compilerOptions: {
      module: ts.ModuleKind.CommonJS,
      target: ts.ScriptTarget.ES2020,
      experimentalDecorators: true,
      useDefineForClassFields: false,
      esModuleInterop: true
    }
  });
  module._compile(out.outputText, filename);
};

const origResolve = Module._resolveFilename;
Module._resolveFilename = function (request, parent, isMain, options) {
  if (request === '@ohos/hypium') return SHIM;
  if (request.startsWith('@kit.') || request.startsWith('@ohos.') || request.startsWith('@hms.') ||
      request.endsWith('.so') || request === 'BuildProfile') {
    return STUB;
  }
  try {
    return origResolve.call(this, request, parent, isMain, options);
  } catch (e) {
    // 其余无法解析的裸模块名（hvigor 生成物等）同样落到桩
    if (!request.startsWith('.') && !request.startsWith('/')) {
      return STUB;
    }
    throw e;
  }
};

// ArkUI 状态管理装饰器在 Node 下按空操作处理（只影响 UI 刷新，不影响纯逻辑）
const noopDecorator = function () {
  if (arguments.length === 1 && typeof arguments[0] !== 'function') {
    return function () {}; // 带参装饰器工厂，如 @Watch('x')
  }
  return undefined;
};
for (const name of ['ObservedV2', 'Trace', 'Observed', 'Track', 'Local', 'Param', 'Once', 'Event',
  'Monitor', 'Computed', 'Provider', 'Consumer', 'Type', 'Sendable', 'Concurrent']) {
  global[name] = noopDecorator;
}

const shim = require(SHIM);
const filters = process.argv.slice(2);
const files = fs.readdirSync(TEST_DIR)
  .filter((f) => f.endsWith('.test.ets'))
  .filter((f) => filters.length === 0 || filters.some((x) => f.includes(x)))
  .sort();

const skipped = [];
for (const f of files) {
  const full = path.join(TEST_DIR, f);
  try {
    const mod = require(full);
    const fn = mod.default;
    if (typeof fn !== 'function') {
      skipped.push(`${f}（无 default 导出）`);
      continue;
    }
    shim.__setFile(f);
    fn();
  } catch (e) {
    if (e instanceof UntranspilableError || (e && e.constructor && e.constructor.name === 'UntranspilableError')) {
      skipped.push(`${f}：${e.message}`);
    } else {
      skipped.push(`${f}：加载失败 ${e && e.message}`);
    }
  }
}

shim.__run().then((r) => {
  if (skipped.length > 0) {
    console.log(`\n[ets-unit] 跳过 ${skipped.length} 个测试文件：`);
    for (const s of skipped) console.log(`  - ${s}`);
  }
  console.log(`\n[ets-unit] 通过 ${r.passed}，失败 ${r.failed}`);
  process.exit(r.failed > 0 ? 1 : 0);
});
