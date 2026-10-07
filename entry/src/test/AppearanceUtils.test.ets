/**
 * ThemePresets / ThemeImport / SnippetVars / KeyManagerLogic / AdaptiveLayout
 * 纯函数单元测试（任务 A2/A4/U10/U3/U5）。
 */

import { describe, it, expect } from '@ohos/hypium';
import {
  THEME_PRESETS,
  appearanceFromThemePreset,
  isValidThemeColorSet,
  themePresetById
} from '../main/ets/theme/ThemePresets';
import {
  componentToHex,
  parseITerm2Colors,
  parseThemeImport,
  parseWindowsTerminalColors
} from '../main/ets/common/utils/ThemeImport';
import {
  encodeSnippetForTerminal,
  substituteSnippet,
  snippetVarsOf
} from '../main/ets/common/utils/SnippetVars';
import {
  detectPrivateKeyFormat,
  displayFingerprint,
  looksLikePrivateKey,
  parseOpenSshPublicKey,
  validateKeyImport
} from '../main/ets/common/utils/KeyManagerLogic';
import {
  RIGHT_PANEL_TABS,
  appBreakpointOfWidth,
  resolveLayoutRegions,
  rightPanelTabById,
  rightPanelWidthVp,
  showRightPanel,
  useHostListSidebar,
  useRightPanel,
  useThreeRegionLayout
} from '../main/ets/common/utils/AdaptiveLayout';
import {
  normalizeThemeMode,
  themeModeLabel,
  themeModeToColorModeName
} from '../main/ets/theme/ThemePresets';
import { OPEN_SOURCE_LICENSES } from '../main/ets/common/constants/OpenSourceLicenses';

const SAMPLE_OPENSSH_PUB: string =
  'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyMaterialForUnitTestOnly0001 user@host';

const SAMPLE_ITERM: string = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Ansi 0 Color</key>
  <dict>
    <key>Blue Component</key><real>0.2</real>
    <key>Green Component</key><real>0.1</real>
    <key>Red Component</key><real>0.0</real>
  </dict>
  <key>Ansi 1 Color</key>
  <dict>
    <key>Red Component</key><real>1</real>
    <key>Green Component</key><real>0</real>
    <key>Blue Component</key><real>0</real>
  </dict>
  <key>Foreground Color</key>
  <dict>
    <key>Red Component</key><real>1</real>
    <key>Green Component</key><real>1</real>
    <key>Blue Component</key><real>1</real>
  </dict>
</dict>
</plist>`;

const SAMPLE_WT: string = JSON.stringify({
  name: 'TestScheme',
  background: '#101010',
  foreground: '#EEEEEE',
  cursorColor: '#FFFFFF',
  selectionBackground: '#333333',
  black: '#000000',
  red: '#FF0000',
  green: '#00FF00',
  yellow: '#FFFF00',
  blue: '#0000FF',
  purple: '#FF00FF',
  cyan: '#00FFFF',
  white: '#C0C0C0',
  brightBlack: '#555555',
  brightRed: '#FF5555',
  brightGreen: '#55FF55',
  brightYellow: '#FFFF55',
  brightBlue: '#5555FF',
  brightPurple: '#FF55FF',
  brightCyan: '#55FFFF',
  brightWhite: '#FFFFFF'
});

export default function appearanceAndUtilsTest() {
  describe('AppearanceAndUtilsTest', () => {

    it('ThemePresets_九套主题且20色位齐全', 0, () => {
      expect(THEME_PRESETS.length).assertEqual(9);
      for (let i = 0; i < THEME_PRESETS.length; i++) {
        expect(isValidThemeColorSet(THEME_PRESETS[i].colors)).assertTrue();
      }
      expect(themePresetById('dracula') !== null).assertTrue();
      expect(themePresetById('missing')).assertNull();
    });

    it('ThemePresets_appearanceFromThemePreset_套色且palette独立', 0, () => {
      const nord = themePresetById('nord');
      expect(nord !== null).assertTrue();
      if (nord !== null) {
        const profile = appearanceFromThemePreset('id-nord', nord);
        expect(profile.name).assertEqual('Nord');
        expect(profile.background).assertEqual('#2E3440');
        expect(profile.palette.length).assertEqual(16);
        profile.palette[0] = '#000000';
        expect(nord.colors.palette[0]).assertEqual('#3B4252');
      }
    });

    it('ThemeImport_componentToHex_与iTerm样例', 0, () => {
      expect(componentToHex(0)).assertEqual('#00');
      expect(componentToHex(1)).assertEqual('#FF');
      expect(componentToHex(0.1)).assertEqual('#1A');
      const result = parseITerm2Colors(SAMPLE_ITERM);
      // 样例只含部分 ANSI 键 → 应失败并报缺色位
      expect(result.ok).assertFalse();
      expect(result.error.indexOf('缺少') >= 0).assertTrue();
      expect(parseITerm2Colors('not xml').ok).assertFalse();
    });

    it('ThemeImport_WindowsTerminal_完整scheme成功', 0, () => {
      const result = parseWindowsTerminalColors(SAMPLE_WT);
      expect(result.ok).assertTrue();
      expect(result.name).assertEqual('TestScheme');
      if (result.colors !== null) {
        expect(result.colors.background).assertEqual('#101010');
        expect(result.colors.palette[0]).assertEqual('#000000');
        expect(result.colors.palette[1]).assertEqual('#FF0000');
      }
      expect(parseWindowsTerminalColors('{bad').ok).assertFalse();
      expect(parseThemeImport('x.itermcolors', '<plist').ok).assertFalse();
      expect(parseThemeImport('x.json', SAMPLE_WT).ok).assertTrue();
    });

    it('SnippetVars_占位符替换与未知保留', 0, () => {
      const vars = snippetVarsOf('prod-web', '10.0.0.1', 'root', 2222);
      expect(substituteSnippet('ssh ${user}@${host}', vars)).assertEqual('ssh root@10.0.0.1');
      expect(substituteSnippet('echo ${port} ${name}', vars)).assertEqual('echo 2222 prod-web');
      expect(substituteSnippet('echo $HOME ${unknown}', vars)).assertEqual('echo $HOME ${unknown}');
      expect(substituteSnippet('', vars)).assertEqual('');
      expect(encodeSnippetForTerminal('ls ${host}', vars)).assertEqual('ls 10.0.0.1\n');
      expect(encodeSnippetForTerminal('', vars)).assertEqual('');
    });

    it('KeyManagerLogic_格式识别与校验', 0, () => {
      expect(detectPrivateKeyFormat('-----BEGIN OPENSSH PRIVATE KEY-----\nxx')).assertEqual('openssh');
      expect(detectPrivateKeyFormat('-----BEGIN RSA PRIVATE KEY-----')).assertEqual('pem');
      expect(detectPrivateKeyFormat('garbage')).assertEqual('unknown');
      expect(looksLikePrivateKey('-----BEGIN PRIVATE KEY-----')).assertTrue();
      expect(validateKeyImport('', '-----BEGIN OPENSSH PRIVATE KEY-----')).assertEqual('请填写密钥名称');
      expect(validateKeyImport('k', 'nope')).assertEqual('私钥内容不是受支持的 OpenSSH / PEM 格式');
      expect(validateKeyImport('k', '-----BEGIN OPENSSH PRIVATE KEY-----')).assertEqual('');
      const parts = parseOpenSshPublicKey(SAMPLE_OPENSSH_PUB);
      expect(parts.valid).assertTrue();
      expect(parts.keyType).assertEqual('ssh-ed25519');
      expect(parseOpenSshPublicKey('nope').valid).assertFalse();
      const fp1 = displayFingerprint('ssh-ed25519', 'abc');
      const fp2 = displayFingerprint('ssh-ed25519', 'abc');
      const fp3 = displayFingerprint('ssh-ed25519', 'abd');
      expect(fp1.length > 0).assertTrue();
      expect(fp1).assertEqual(fp2);
      expect(fp1 === fp3).assertFalse();
    });

    it('AdaptiveLayout_断点与侧栏策略', 0, () => {
      expect(appBreakpointOfWidth(320)).assertEqual('sm');
      expect(appBreakpointOfWidth(599)).assertEqual('sm');
      expect(appBreakpointOfWidth(600)).assertEqual('md');
      expect(appBreakpointOfWidth(840)).assertEqual('md');
      expect(appBreakpointOfWidth(841)).assertEqual('lg');
      expect(appBreakpointOfWidth(Number.NaN)).assertEqual('sm');
      expect(useHostListSidebar('sm')).assertFalse();
      expect(useHostListSidebar('md')).assertTrue();
      expect(useHostListSidebar('lg')).assertTrue();
      expect(useRightPanel('md')).assertFalse();
      expect(useRightPanel('lg')).assertTrue();
    });

    it('AdaptiveLayout_U5三栏与右侧面板解析', 0, () => {
      expect(useThreeRegionLayout('sm')).assertFalse();
      expect(useThreeRegionLayout('md')).assertFalse();
      expect(useThreeRegionLayout('lg')).assertTrue();
      expect(showRightPanel('lg', true)).assertTrue();
      expect(showRightPanel('lg', false)).assertFalse();
      expect(showRightPanel('md', true)).assertFalse();
      expect(rightPanelWidthVp(true)).assertEqual(260);
      expect(rightPanelWidthVp(false)).assertEqual(36);
      // sm：无侧栏无面板
      const sm = resolveLayoutRegions('sm', true, true, true);
      expect(sm.hostList).assertFalse();
      expect(sm.terminalEmbed).assertFalse();
      expect(sm.rightPanel).assertFalse();
      expect(sm.rightPanelWidthVp).assertEqual(0);
      // md：双栏，无右侧面板（即使 open=true）
      const md = resolveLayoutRegions('md', true, true, true);
      expect(md.hostList).assertTrue();
      expect(md.terminalEmbed).assertTrue();
      expect(md.rightPanel).assertFalse();
      expect(md.rightPanelOpen).assertFalse();
      // lg 展开 / 折叠
      const lgOpen = resolveLayoutRegions('lg', true, true, true);
      expect(lgOpen.rightPanel).assertTrue();
      expect(lgOpen.rightPanelOpen).assertTrue();
      expect(lgOpen.rightPanelWidthVp).assertEqual(260);
      const lgCollapsed = resolveLayoutRegions('lg', true, false, true);
      expect(lgCollapsed.rightPanel).assertTrue();
      expect(lgCollapsed.rightPanelOpen).assertFalse();
      expect(lgCollapsed.rightPanelWidthVp).assertEqual(36);
      // lg 未选中主机：中栏终端不挂
      const lgNoHost = resolveLayoutRegions('lg', false, true, true);
      expect(lgNoHost.terminalEmbed).assertFalse();
      expect(lgNoHost.rightPanel).assertTrue();
      // 面板功能关：与 md 同形
      const lgDisabled = resolveLayoutRegions('lg', true, true, false);
      expect(lgDisabled.rightPanel).assertFalse();
      expect(lgDisabled.rightPanelWidthVp).assertEqual(0);
      // tab 清单：片段/转发/SFTP 路由
      expect(RIGHT_PANEL_TABS.length).assertEqual(3);
      const snippets = rightPanelTabById('snippets');
      expect(snippets !== null).assertTrue();
      if (snippets !== null) {
        expect(snippets.route).assertEqual('pages/ConfigManagerPage');
        expect(snippets.needsHostId).assertFalse();
      }
      const forwards = rightPanelTabById('forwards');
      if (forwards !== null) {
        expect(forwards.route).assertEqual('pages/PortForwardPage');
        expect(forwards.needsHostId).assertTrue();
      }
      const sftp = rightPanelTabById('sftp');
      if (sftp !== null) {
        expect(sftp.route).assertEqual('pages/SftpPage');
        expect(sftp.needsHostId).assertTrue();
      }
      expect(RIGHT_PANEL_TABS.length >= 3).assertTrue();
    });

    it('ThemePresets_A6主题模式映射', 0, () => {
      expect(normalizeThemeMode('dark')).assertEqual('dark');
      expect(normalizeThemeMode('light')).assertEqual('light');
      expect(normalizeThemeMode('system')).assertEqual('system');
      expect(normalizeThemeMode('bogus')).assertEqual('system');
      expect(themeModeLabel('dark')).assertEqual('深色');
      expect(themeModeLabel('light')).assertEqual('浅色');
      expect(themeModeLabel('system')).assertEqual('跟随系统');
      expect(themeModeToColorModeName('system')).assertEqual('not_set');
      expect(themeModeToColorModeName('dark')).assertEqual('dark');
      expect(themeModeToColorModeName('light')).assertEqual('light');
    });

    it('OpenSourceLicenses_覆盖关键依赖', 0, () => {
      expect(OPEN_SOURCE_LICENSES.length >= 6).assertTrue();
      const names: string[] = [];
      for (const entry of OPEN_SOURCE_LICENSES) {
        names.push(entry.name);
        expect(entry.license.length > 0).assertTrue();
        expect(entry.usage.length > 0).assertTrue();
      }
      expect(names.join(',').indexOf('OpenSSL') >= 0).assertTrue();
      expect(names.join(',').indexOf('libssh2') >= 0).assertTrue();
      expect(names.join(',').indexOf('libvterm') >= 0).assertTrue();
      expect(names.join(',').indexOf('libargon2') >= 0).assertTrue();
    });
  });
}
