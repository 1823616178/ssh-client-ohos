'use strict';
// @ohos/hypium 的最小兼容实现：describe / it / beforeAll / beforeEach / afterEach / afterAll / expect。
const suites = [];
let current = null;
let currentFile = '';

function describe(name, body) {
  const suite = { name, file: currentFile, tests: [], beforeAll: [], beforeEach: [], afterEach: [], afterAll: [] };
  const prev = current;
  current = suite;
  try {
    body();
  } finally {
    current = prev;
  }
  suites.push(suite);
}
function it(name, _level, body) {
  const fn = typeof _level === 'function' ? _level : body;
  current.tests.push({ name, fn });
}
function beforeAll(fn) { current.beforeAll.push(fn); }
function beforeEach(fn) { current.beforeEach.push(fn); }
function afterEach(fn) { current.afterEach.push(fn); }
function afterAll(fn) { current.afterAll.push(fn); }

function fmt(v) {
  try {
    if (v instanceof Uint8Array) return `Uint8Array[${Array.from(v).join(',')}]`;
    return JSON.stringify(v);
  } catch (e) {
    return String(v);
  }
}
function deepEq(a, b) {
  if (a === b) return true;
  if (typeof a === 'number' && typeof b === 'number' && isNaN(a) && isNaN(b)) return true;
  if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object') return false;
  if (ArrayBuffer.isView(a) && ArrayBuffer.isView(b)) {
    if (a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
  }
  if (Array.isArray(a) !== Array.isArray(b)) return false;
  const ka = Object.keys(a);
  const kb = Object.keys(b);
  if (ka.length !== kb.length) return false;
  for (const k of ka) if (!deepEq(a[k], b[k])) return false;
  return true;
}
function expect(actual) {
  const make = (negate) => {
    const check = (ok, msg) => {
      if (negate ? ok : !ok) throw new Error((negate ? 'NOT ' : '') + msg);
    };
    const api = {
      assertEqual: (e) => check(actual === e, `expected ${fmt(actual)} to equal ${fmt(e)}`),
      assertDeepEquals: (e) => check(deepEq(actual, e), `expected ${fmt(actual)} to deep-equal ${fmt(e)}`),
      assertTrue: () => check(actual === true, `expected ${fmt(actual)} to be true`),
      assertFalse: () => check(actual === false, `expected ${fmt(actual)} to be false`),
      assertNull: () => check(actual === null, `expected ${fmt(actual)} to be null`),
      assertUndefined: () => check(actual === undefined, `expected ${fmt(actual)} to be undefined`),
      assertNaN: () => check(typeof actual === 'number' && isNaN(actual), `expected NaN`),
      assertContain: (e) => check(actual != null && actual.indexOf(e) >= 0, `expected ${fmt(actual)} to contain ${fmt(e)}`),
      assertLarger: (e) => check(actual > e, `expected ${fmt(actual)} > ${fmt(e)}`),
      assertLess: (e) => check(actual < e, `expected ${fmt(actual)} < ${fmt(e)}`),
      assertLargerOrEqual: (e) => check(actual >= e, `expected ${fmt(actual)} >= ${fmt(e)}`),
      assertLessOrEqual: (e) => check(actual <= e, `expected ${fmt(actual)} <= ${fmt(e)}`),
      assertClose: (e, delta) => check(Math.abs(actual - e) <= delta, `expected ${fmt(actual)} ≈ ${fmt(e)} ±${delta}`),
      assertInstanceOf: (t) => check(Object.prototype.toString.call(actual) === `[object ${t}]` ||
        (actual != null && actual.constructor && actual.constructor.name === t), `expected instance of ${t}`),
      assertThrowError: (msg) => {
        let threw = false;
        let m = '';
        try { actual(); } catch (err) { threw = true; m = err && err.message; }
        check(threw && (msg === undefined || m === msg || (m && m.indexOf(msg) >= 0)), `expected throw ${fmt(msg)}, got ${fmt(m)}`);
      }
    };
    return api;
  };
  const api = make(false);
  api.not = () => make(true);
  return api;
}

async function __run() {
  let passed = 0;
  let failed = 0;
  for (const s of suites) {
    try {
      for (const f of s.beforeAll) await f();
    } catch (e) {
      console.log(`✗ [${s.file}] ${s.name} beforeAll: ${e.message}`);
      failed += s.tests.length;
      continue;
    }
    for (const t of s.tests) {
      try {
        for (const f of s.beforeEach) await f();
        let doneResolve;
        const donePromise = new Promise((r) => { doneResolve = r; });
        const ret = t.fn.length > 0 ? t.fn(doneResolve) : t.fn();
        if (ret && typeof ret.then === 'function') await ret;
        if (t.fn.length > 0) await Promise.race([donePromise, new Promise((r) => setTimeout(r, 2000))]);
        for (const f of s.afterEach) await f();
        passed++;
      } catch (e) {
        failed++;
        console.log(`✗ [${s.file}] ${s.name} › ${t.name}\n    ${e && e.message}`);
      }
    }
    for (const f of s.afterAll) {
      try { await f(); } catch (e) { /* ignore */ }
    }
  }
  return { passed, failed };
}

module.exports = {
  describe, it, expect, beforeAll, beforeEach, afterEach, afterAll,
  TestType: {}, Size: {}, Level: {},
  __run,
  __setFile: (f) => { currentFile = f; }
};
