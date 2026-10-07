/**
 * AppearanceViewModel / KeyManagerViewModel 单元测试（任务 A3 / U3）。
 * 全部依赖注入 fake，不触碰 relationalStore / ASSET / native。
 */

import { describe, it, expect } from '@ohos/hypium';
import { AppearanceProfile } from '../main/ets/common/model/models';
import {
  AppearanceDaoLike,
  AppearanceViewModel,
  ThemeModeStore
} from '../main/ets/viewmodel/AppearanceViewModel';
import {
  KeyManagerDeps,
  KeyManagerViewModel,
  KeyMetaStore,
  KeySecretStore,
  parseKeyEntryList,
  serializeKeyEntryList
} from '../main/ets/viewmodel/KeyManagerViewModel';
import { AgentAuthPort } from '../main/ets/napi/AgentAuth';
import { NativeAgentKeygenResult } from '../main/ets/napi/SshNative';
import { CredentialKind } from '../main/ets/repository/CredentialStore';
import { ThemeMode } from '../main/ets/repository/SettingsRepository';
import { KeyEntryMeta } from '../main/ets/common/utils/KeyManagerLogic';
import { buildOpensshPublicKeyLine } from '../main/ets/common/utils/KeyManagerLogic';
import { normalizeThemeMode, themeModeToColorModeName } from '../main/ets/theme/ThemePresets';

class FakeAppearanceDao implements AppearanceDaoLike {
  private readonly map: Map<string, AppearanceProfile> = new Map();

  insert(profile: AppearanceProfile): void {
    const copy: AppearanceProfile = JSON.parse(JSON.stringify(profile)) as AppearanceProfile;
    this.map.set(profile.id, copy);
  }

  update(profile: AppearanceProfile): void {
    const copy: AppearanceProfile = JSON.parse(JSON.stringify(profile)) as AppearanceProfile;
    this.map.set(profile.id, copy);
  }

  deleteById(id: string): void {
    this.map.delete(id);
  }

  getById(id: string): AppearanceProfile | null {
    const found: AppearanceProfile | undefined = this.map.get(id);
    return found === undefined ? null : (JSON.parse(JSON.stringify(found)) as AppearanceProfile);
  }

  listAll(): AppearanceProfile[] {
    const result: AppearanceProfile[] = [];
    this.map.forEach((value: AppearanceProfile) => {
      result.push(JSON.parse(JSON.stringify(value)) as AppearanceProfile);
    });
    return result;
  }
}

class FakeAgent implements AgentAuthPort {
  private readonly keys: Map<string, string> = new Map();
  /** U3：是否模拟 native keygen 可用 */
  keygenEnabled: boolean = true;

  isLocked(keyId: string): boolean {
    return !this.keys.has(keyId);
  }

  unlock(keyId: string, privateKey: string, passphrase: string): boolean {
    if (privateKey.indexOf('BEGIN') < 0) {
      return false;
    }
    this.keys.set(keyId, privateKey);
    return true;
  }

  lock(keyId: string): boolean {
    return this.keys.delete(keyId);
  }

  lockAll(): void {
    this.keys.clear();
  }

  keyCount(): number {
    return this.keys.size;
  }

  keygenSupported(): boolean {
    return this.keygenEnabled;
  }

  keygen(comment: string, passphrase: string): NativeAgentKeygenResult | null {
    if (!this.keygenEnabled) {
      return null;
    }
    // 确定性 fake：32 字节公钥以 comment 长度派生，公钥行走真实 wire 格式
    const raw: Uint8Array = new Uint8Array(32);
    for (let i = 0; i < 32; i++) {
      raw[i] = (i + comment.length + passphrase.length) & 0xff;
    }
    const publicKeyLine: string = buildOpensshPublicKeyLine('ssh-ed25519', raw, comment);
    return {
      keyType: 'ssh-ed25519',
      privateKeyPem: '-----BEGIN PRIVATE KEY-----\nfakepkcs8\n-----END PRIVATE KEY-----\n',
      publicKeyLine: publicKeyLine,
      comment: comment
    };
  }
}

class FakeThemeModeStore implements ThemeModeStore {
  mode: string = 'system';
  getThemeMode(): ThemeMode {
    return normalizeThemeMode(this.mode) as ThemeMode;
  }

  setThemeMode(mode: ThemeMode): void {
    this.mode = mode;
  }
}

class FakeMetaStore implements KeyMetaStore {
  json: string = '[]';
  readJson(): string {
    return this.json;
  }

  writeJson(value: string): void {
    this.json = value;
  }
}

class FakeSecretStore implements KeySecretStore {
  private readonly map: Map<string, string> = new Map();
  setCalls: number = 0;

  setSecret(ownerId: string, kind: CredentialKind, value: string): Promise<void> {
    this.setCalls++;
    this.map.set(`${ownerId}:${kind}`, value);
    return Promise.resolve();
  }

  getSecret(ownerId: string, kind: CredentialKind): Promise<string | null> {
    const v = this.map.get(`${ownerId}:${kind}`);
    return Promise.resolve(v === undefined ? null : v);
  }

  removeAllSecrets(ownerId: string): Promise<void> {
    const prefix = `${ownerId}:`;
    const keys: string[] = [];
    this.map.forEach((_v: string, k: string) => {
      if (k.startsWith(prefix)) {
        keys.push(k);
      }
    });
    for (const k of keys) {
      this.map.delete(k);
    }
    return Promise.resolve();
  }
}

export default function appearanceViewModelTest() {
  describe('AppearanceAndKeyManagerVM', () => {

    it('AppearanceVM_预设创建_编辑预览_保存与还原', 0, () => {
      const dao = new FakeAppearanceDao();
      const vm = new AppearanceViewModel({ dao: dao, newId: (): string => 'a1' });
      expect(vm.profiles.length).assertEqual(0);
      const created = vm.createFromPreset('nord');
      expect(created !== null).assertTrue();
      expect(vm.profiles.length).assertEqual(1);
      expect(vm.draft !== null).assertTrue();
      expect(vm.preview !== null).assertTrue();
      if (vm.draft !== null && vm.preview !== null) {
        const originalSize = vm.draft.fontSize;
        vm.setFontSize(20);
        expect(vm.draft.fontSize).assertEqual(20);
        expect(vm.preview.fontSize).assertEqual(20);
        vm.discardDraft();
        expect(vm.draft.fontSize).assertEqual(originalSize);
        vm.setFontSize(18);
        expect(vm.saveDraft()).assertTrue();
        const stored = dao.getById('a1');
        expect(stored !== null).assertTrue();
        if (stored !== null) {
          expect(stored.fontSize).assertEqual(18);
        }
      }
    });

    it('AppearanceVM_色位与导入', 0, () => {
      const dao = new FakeAppearanceDao();
      const vm = new AppearanceViewModel({ dao: dao, newId: (): string => 'a2' });
      vm.createFromPreset('harmony-dark');
      vm.setColorSlot(0, '#123456');
      vm.setColorSlot(16, '#ABCDEF');
      expect(vm.colorSlot(0)).assertEqual('#123456');
      expect(vm.colorSlot(16)).assertEqual('#ABCDEF');
      const wt = JSON.stringify({
        name: 'WT',
        background: '#000000',
        foreground: '#FFFFFF',
        cursorColor: '#FFFFFF',
        selectionBackground: '#222222',
        black: '#000000', red: '#AA0000', green: '#00AA00', yellow: '#AAAA00',
        blue: '#0000AA', purple: '#AA00AA', cyan: '#00AAAA', white: '#AAAAAA',
        brightBlack: '#555555', brightRed: '#FF5555', brightGreen: '#55FF55',
        brightYellow: '#FFFF55', brightBlue: '#5555FF', brightPurple: '#FF55FF',
        brightCyan: '#55FFFF', brightWhite: '#FFFFFF'
      });
      const result = vm.importThemeToDraft('t.json', wt);
      expect(result.ok).assertTrue();
      if (vm.draft !== null) {
        expect(vm.draft.name).assertEqual('WT');
        expect(vm.draft.palette[1]).assertEqual('#AA0000');
      }
      expect(vm.deleteProfile('a2')).assertTrue();
      expect(vm.profiles.length).assertEqual(0);
    });

    it('KeyEntry序列化_往返', 0, () => {
      const entry: KeyEntryMeta = {
        id: 'k1',
        name: 'prod',
        keyType: 'openssh',
        fingerprint: 'openssh:ABCD',
        publicKey: 'ssh-ed25519 AAAA x',
        hasPassphrase: true,
        createdAt: '1'
      };
      const list: KeyEntryMeta[] = [entry];
      const parsed = parseKeyEntryList(serializeKeyEntryList(list));
      expect(parsed.length).assertEqual(1);
      expect(parsed[0].id).assertEqual('k1');
      expect(parsed[0].hasPassphrase).assertTrue();
      expect(parseKeyEntryList('not-json').length).assertEqual(0);
    });

    it('KeyManagerVM_导入_导出_解锁agent_删除', 0, async () => {
      const meta: KeyMetaStore = new FakeMetaStore();
      const secrets: KeySecretStore = new FakeSecretStore();
      const agent: AgentAuthPort = new FakeAgent();
      const fakeSecrets: FakeSecretStore = secrets as FakeSecretStore;
      let seq = 0;
      const deps: KeyManagerDeps = {
        metaStore: meta,
        secretStore: secrets,
        agentAuth: agent,
        newId: (): string => {
          seq++;
          return `key-${seq}`;
        }
      };
      const vm = new KeyManagerViewModel(deps);
      expect(vm.entries.length).assertEqual(0);
      vm.setDraft('', '-----BEGIN OPENSSH PRIVATE KEY-----\nxx', '', '');
      expect(await vm.importDraft()).assertEqual('');
      vm.setDraft('mykey', '-----BEGIN OPENSSH PRIVATE KEY-----\nxx', 'pp',
        'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyMaterialForUnitTestOnly0001 me@local');
      const id = await vm.importDraft();
      expect(id).assertEqual('key-1');
      expect(vm.entries.length).assertEqual(1);
      expect(fakeSecrets.setCalls >= 1).assertTrue();
      const pub = vm.exportPublicKey(id);
      expect(pub.indexOf('ssh-ed25519') === 0).assertTrue();
      expect(await vm.unlockToAgent(id, '')).assertTrue();
      expect(agent.isLocked(id)).assertFalse();
      expect(await vm.deleteEntry(id)).assertTrue();
      expect(vm.entries.length).assertEqual(0);
      expect(agent.isLocked(id)).assertTrue();
    });

    it('KeyManagerVM_generateSupported_与nativeKeygen落库', 0, async () => {
      const meta: KeyMetaStore = new FakeMetaStore();
      const secrets: KeySecretStore = new FakeSecretStore();
      const agent: FakeAgent = new FakeAgent();
      let seq = 0;
      const vm = new KeyManagerViewModel({
        metaStore: meta,
        secretStore: secrets,
        agentAuth: agent,
        newId: (): string => {
          seq++;
          return `gen-${seq}`;
        }
      });
      expect(vm.generateSupported()).assertTrue();
      const id = await vm.generateKeyPair('gen-key', '', 'me@ohos');
      expect(id).assertEqual('gen-1');
      expect(vm.entries.length).assertEqual(1);
      expect(vm.entries[0].keyType).assertEqual('ssh-ed25519');
      expect(vm.entries[0].publicKey.startsWith('ssh-ed25519 ')).assertTrue();
      expect(vm.entries[0].fingerprint.startsWith('SHA256:')).assertTrue();
      const fakeSecrets: FakeSecretStore = secrets as FakeSecretStore;
      expect(fakeSecrets.setCalls >= 1).assertTrue();
      // native 不可用时按钮说明与 generate 返回空
      agent.keygenEnabled = false;
      expect(vm.generateSupported()).assertFalse();
      expect(await vm.generateKeyPair('x', '', '')).assertEqual('');
      expect(vm.generateUnsupportedReason().length > 0).assertTrue();
    });

    it('AppearanceVM_A5背景图字段与A6主题模式', 0, () => {
      const dao = new FakeAppearanceDao();
      const themeStore = new FakeThemeModeStore();
      const vm = new AppearanceViewModel({
        dao: dao,
        newId: (): string => 'a5',
        themeModeStore: themeStore
      });
      expect(vm.createFromPreset('harmony-dark') !== null).assertTrue();
      if (vm.draft !== null) {
        expect(vm.draft.backgroundImagePath).assertEqual('');
        expect(vm.draft.backgroundImageOpacity).assertEqual(1);
        expect(vm.draft.backgroundBlur).assertEqual(0);
        vm.setBackgroundImagePath('/data/bg.png');
        vm.setBackgroundImageOpacity(0.55);
        vm.setBackgroundBlur(12);
        expect(vm.draft.backgroundImagePath).assertEqual('/data/bg.png');
        expect(vm.draft.backgroundImageOpacity).assertEqual(0.55);
        expect(vm.draft.backgroundBlur).assertEqual(12);
        expect(vm.saveDraft()).assertTrue();
        const stored = dao.getById('a5');
        expect(stored !== null).assertTrue();
        if (stored !== null) {
          expect(stored.backgroundImagePath).assertEqual('/data/bg.png');
          expect(stored.backgroundImageOpacity).assertEqual(0.55);
          expect(stored.backgroundBlur).assertEqual(12);
        }
        // 越界钳制
        vm.setBackgroundImageOpacity(2);
        vm.setBackgroundBlur(-3);
        if (vm.draft !== null) {
          expect(vm.draft.backgroundImageOpacity).assertEqual(1);
          expect(vm.draft.backgroundBlur).assertEqual(0);
        }
      }
      // A6
      expect(vm.themeMode).assertEqual('system');
      expect(vm.colorModeName()).assertEqual('not_set');
      vm.setThemeMode('dark');
      expect(vm.themeMode).assertEqual('dark');
      expect(themeStore.mode).assertEqual('dark');
      expect(vm.colorModeName()).assertEqual('dark');
      vm.setThemeMode('light');
      expect(vm.colorModeName()).assertEqual('light');
      expect(themeModeToColorModeName(normalizeThemeMode('bogus'))).assertEqual('not_set');
    });
  });
}
