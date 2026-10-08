'use strict';
// 系统模块惰性桩：任意属性访问/调用/构造都返回同一个桩（不抛错），
// 仅为让「顺带 import 系统能力」的纯逻辑模块可以加载。
function makeStub(name) {
  const fn = function () { return stub; };
  const stub = new Proxy(fn, {
    get(target, prop) {
      if (prop === '__esModule') return false;
      // @kit.ArkTS 的 JSON 与全局 JSON 同语义：纯逻辑模块（布局解析等）依赖它
      if (prop === 'JSON') return JSON;
      if (prop === 'default') return stub;
      if (prop === Symbol.toPrimitive) return () => 0;
      if (prop === 'then') return undefined;
      return stub;
    },
    apply() { return stub; },
    construct() { return stub; }
  });
  return stub;
}
module.exports = makeStub('kit');
