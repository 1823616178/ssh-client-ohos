/**
 * 实体模型工厂函数单元测试（任务 C3）。
 *
 * 断言各工厂函数的默认值与 DESIGN §4.4 / §5.2 一致
 * （字号 14、行高 1.2、块光标闪烁、termType xterm-256color、Harmony Dark 16 色调色板等）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  AppearanceProfile,
  HARMONY_DARK_PALETTE,
  HostGroup,
  HostProfile,
  PortForwardRule,
  Snippet,
  createDefaultAppearanceProfile,
  createDefaultHostGroup,
  createDefaultHostProfile,
  createDefaultPortForwardRule,
  createDefaultSnippet
} from '../main/ets/common/model/models';

export default function modelTest() {
  describe('ModelTest', () => {

    it('AppearanceProfile_默认值对齐设计', 0, () => {
      const p: AppearanceProfile = createDefaultAppearanceProfile('appearance-1');
      expect(p.id).assertEqual('appearance-1');
      expect(p.name).assertEqual('Harmony Dark');
      expect(p.fontFamily).assertEqual('JetBrains Mono');
      expect(p.fontSize).assertEqual(14);
      expect(p.lineHeight).assertEqual(1.2);
      expect(p.letterSpacing).assertEqual(0);
      expect(p.fontWeight).assertEqual(400);
      expect(p.ligatures).assertFalse();
      expect(p.boldAsBright).assertTrue();
      expect(p.cursorStyle).assertEqual('block');
      expect(p.cursorBlink).assertTrue();
      expect(p.backgroundOpacity).assertEqual(1);
      expect(p.padding).assertEqual(8);
    });

    it('AppearanceProfile_调色板16色且为RRGGBB格式', 0, () => {
      const p: AppearanceProfile = createDefaultAppearanceProfile('appearance-1');
      expect(p.palette.length).assertEqual(16);
      for (let i = 0; i < p.palette.length; i++) {
        const color: string = p.palette[i];
        expect(color.length).assertEqual(7);
        expect(color.startsWith('#')).assertTrue();
      }
    });

    it('AppearanceProfile_前景背景光标选区色', 0, () => {
      const p: AppearanceProfile = createDefaultAppearanceProfile('appearance-1');
      expect(p.foreground).assertEqual('#E8EEFB');
      expect(p.background).assertEqual('#0E131D');
      expect(p.cursorColor).assertEqual('#4D8DFF');
      expect(p.selectionColor).assertEqual('#26314A');
    });

    it('AppearanceProfile_调色板每次返回独立副本', 0, () => {
      const a: AppearanceProfile = createDefaultAppearanceProfile('a');
      const b: AppearanceProfile = createDefaultAppearanceProfile('b');
      a.palette[0] = '#000000';
      expect(b.palette[0]).assertEqual(HARMONY_DARK_PALETTE[0]);
    });

    it('HostProfile_默认值对齐设计', 0, () => {
      const h: HostProfile = createDefaultHostProfile('host-1');
      expect(h.id).assertEqual('host-1');
      expect(h.name).assertEqual('');
      expect(h.host).assertEqual('');
      expect(h.port).assertEqual(22);
      expect(h.username).assertEqual('');
      expect(h.authType).assertEqual('password');
      expect(h.hostFingerprint).assertEqual('');
      expect(h.keepalive).assertEqual(30);
      expect(h.groupId).assertNull();
      expect(h.appearanceId).assertNull();
      expect(h.jumpHostId).assertNull();
      expect(h.initCommands.length).assertEqual(0);
      expect(h.termType).assertEqual('xterm-256color');
    });

    it('Snippet_默认值', 0, () => {
      const s: Snippet = createDefaultSnippet('snippet-1');
      expect(s.id).assertEqual('snippet-1');
      expect(s.name).assertEqual('');
      expect(s.content).assertEqual('');
      expect(s.groupId).assertNull();
    });

    it('HostGroup_默认值', 0, () => {
      const g: HostGroup = createDefaultHostGroup('group-1');
      expect(g.id).assertEqual('group-1');
      expect(g.name).assertEqual('');
      expect(g.order).assertEqual(0);
    });

    it('PortForwardRule_默认值', 0, () => {
      const r: PortForwardRule = createDefaultPortForwardRule('rule-1', 'host-1');
      expect(r.id).assertEqual('rule-1');
      expect(r.hostId).assertEqual('host-1');
      expect(r.type).assertEqual('local');
      expect(r.bindAddress).assertEqual('127.0.0.1');
      expect(r.localPort).assertEqual(0);
      expect(r.remoteHost).assertEqual('');
      expect(r.remotePort).assertEqual(0);
      expect(r.enabled).assertTrue();
    });
  });
}
