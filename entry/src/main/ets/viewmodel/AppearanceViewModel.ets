import { util } from '@kit.ArkTS';
import { AppearanceProfile, CursorStyle, createDefaultAppearanceProfile } from '../common/model/models';
import { Logger } from '../common/utils/Logger';
import { AppDatabase } from '../repository/AppDatabase';
import { SettingsRepository, ThemeMode } from '../repository/SettingsRepository';
import { TerminalAppearance, terminalAppearanceFromProfile } from '../view/terminal/TerminalAppearance';
import {
  AppThemeMode,
  THEME_PRESETS,
  ThemePreset,
  appearanceFromThemePreset,
  applyThemeColors,
  normalizeThemeMode,
  themeModeToColorModeName,
  themePresetById
} from '../theme/ThemePresets';
import { parseThemeImport, ThemeImportResult } from '../common/utils/ThemeImport';

const LOG_TAG: string = 'AppearanceVM';

export interface AppearanceDaoLike {
  insert(profile: AppearanceProfile): void;
  update(profile: AppearanceProfile): void;
  deleteById(id: string): void;
  getById(id: string): AppearanceProfile | null;
  listAll(): AppearanceProfile[];
}

/** A6：themeMode 持久化窄接口（生产 = SettingsRepository，单测 fake） */
export interface ThemeModeStore {
  getThemeMode(): ThemeMode;
  setThemeMode(mode: ThemeMode): void;
}

export interface AppearanceDeps {
  dao?: AppearanceDaoLike;
  newId?: () => string;
  themeModeStore?: ThemeModeStore;
}

class SettingsThemeModeStore implements ThemeModeStore {
  getThemeMode(): ThemeMode {
    return SettingsRepository.getThemeMode();
  }

  setThemeMode(mode: ThemeMode): void {
    SettingsRepository.setThemeMode(mode);
  }
}

function cloneProfile(source: AppearanceProfile): AppearanceProfile {
  return {
    id: source.id,
    name: source.name,
    fontFamily: source.fontFamily,
    fontSize: source.fontSize,
    lineHeight: source.lineHeight,
    letterSpacing: source.letterSpacing,
    fontWeight: source.fontWeight,
    ligatures: source.ligatures,
    boldAsBright: source.boldAsBright,
    cursorStyle: source.cursorStyle,
    cursorBlink: source.cursorBlink,
    backgroundOpacity: source.backgroundOpacity,
    padding: source.padding,
    palette: source.palette.slice(),
    foreground: source.foreground,
    background: source.background,
    cursorColor: source.cursorColor,
    selectionColor: source.selectionColor,
    backgroundImagePath: source.backgroundImagePath,
    backgroundImageOpacity: source.backgroundImageOpacity,
    backgroundBlur: source.backgroundBlur
  };
}

@ObservedV2
export class AppearanceViewModel {
  @Trace profiles: AppearanceProfile[] = [];
  /** 当前编辑草稿（null = 未选中） */
  @Trace draft: AppearanceProfile | null = null;
  /** 实时预览外观（随草稿字段同步） */
  @Trace preview: TerminalAppearance | null = null;
  @Trace lastMessage: string = '';
  @Trace presets: ThemePreset[] = THEME_PRESETS;
  /** A6：应用整体主题模式（system / dark / light） */
  @Trace themeMode: AppThemeMode = 'system';

  private readonly dao: AppearanceDaoLike;
  private readonly newId: () => string;
  private readonly themeModeStore: ThemeModeStore;
  /** 选中时的原始快照（取消编辑用） */
  private baseline: AppearanceProfile | null = null;

  constructor(deps?: AppearanceDeps) {
    this.dao = deps?.dao ?? AppDatabase.appearances();
    this.newId = deps?.newId ?? ((): string => util.generateRandomUUID());
    this.themeModeStore = deps?.themeModeStore ?? new SettingsThemeModeStore();
    this.reload();
    this.reloadThemeMode();
  }

  reload(): void {
    try {
      this.profiles = this.dao.listAll();
    } catch (err) {
      Logger.error('读取外观主题失败', LOG_TAG);
      this.profiles = [];
    }
  }

  /** A6：从持久化重读 themeMode */
  reloadThemeMode(): void {
    try {
      this.themeMode = normalizeThemeMode(this.themeModeStore.getThemeMode());
    } catch (err) {
      this.themeMode = 'system';
    }
  }

  /**
   * A6：设置应用主题模式并落库。
   * 调用方（AppearancePage / EntryAbility）据 themeModeToColorModeName 应用 colorMode。
   */
  setThemeMode(mode: AppThemeMode): void {
    const normalized: AppThemeMode = normalizeThemeMode(mode);
    this.themeMode = normalized;
    try {
      this.themeModeStore.setThemeMode(normalized as ThemeMode);
      this.lastMessage = `主题模式：${normalized}`;
    } catch (err) {
      this.lastMessage = '主题模式写入失败';
      Logger.error('写入 themeMode 失败', LOG_TAG);
    }
  }

  /** A6：当前 themeMode → colorMode 名（pure 映射，EntryAbility/页面据此 setColorMode） */
  colorModeName(): string {
    return themeModeToColorModeName(this.themeMode);
  }

  /** 选中一条进入编辑（复制草稿，不直接改 profiles） */
  select(id: string): void {
    const found: AppearanceProfile | null = this.dao.getById(id);
    if (found === null) {
      this.lastMessage = '主题不存在';
      return;
    }
    this.baseline = cloneProfile(found);
    this.draft = cloneProfile(found);
    this.syncPreview();
  }

  /** 从内置预设新建（落库并进入编辑） */
  createFromPreset(presetId: string): AppearanceProfile | null {
    const preset: ThemePreset | null = themePresetById(presetId);
    if (preset === null) {
      this.lastMessage = '未知主题预设';
      return null;
    }
    const id: string = this.newId();
    const profile: AppearanceProfile = appearanceFromThemePreset(id, preset);
    try {
      this.dao.insert(profile);
    } catch (err) {
      this.lastMessage = '保存主题失败';
      Logger.error('插入外观主题失败', LOG_TAG);
      return null;
    }
    this.reload();
    this.select(id);
    this.lastMessage = `已创建「${profile.name}」`;
    return profile;
  }

  /** 保存草稿 */
  saveDraft(): boolean {
    if (this.draft === null) {
      this.lastMessage = '没有正在编辑的主题';
      return false;
    }
    try {
      this.dao.update(this.draft);
    } catch (err) {
      this.lastMessage = '保存失败';
      Logger.error('更新外观主题失败', LOG_TAG);
      return false;
    }
    this.reload();
    this.select(this.draft.id);
    this.lastMessage = '已保存';
    return true;
  }

  /** 放弃编辑：草稿还原为 baseline */
  discardDraft(): void {
    if (this.baseline === null) {
      this.draft = null;
      this.preview = null;
      return;
    }
    this.draft = cloneProfile(this.baseline);
    this.syncPreview();
    this.lastMessage = '已还原未保存的修改';
  }

  deleteProfile(id: string): boolean {
    try {
      this.dao.deleteById(id);
    } catch (err) {
      this.lastMessage = '删除失败';
      return false;
    }
    if (this.draft !== null && this.draft.id === id) {
      this.draft = null;
      this.baseline = null;
      this.preview = null;
    }
    this.reload();
    this.lastMessage = '已删除主题';
    return true;
  }

  // ---- 草稿字段编辑（每项改完同步 preview）----

  setName(name: string): void {
    if (this.draft !== null) {
      this.draft.name = name;
    }
  }

  setFontSize(size: number): void {
    if (this.draft !== null) {
      this.draft.fontSize = Math.max(8, Math.min(32, size));
      this.syncPreview();
    }
  }

  setLineHeight(lineHeight: number): void {
    if (this.draft !== null) {
      this.draft.lineHeight = Math.max(1.0, Math.min(2.0, lineHeight));
      this.syncPreview();
    }
  }

  setLetterSpacing(spacing: number): void {
    if (this.draft !== null) {
      this.draft.letterSpacing = spacing;
      this.syncPreview();
    }
  }

  setFontWeight(weight: number): void {
    if (this.draft !== null) {
      this.draft.fontWeight = weight;
      this.syncPreview();
    }
  }

  setLigatures(enabled: boolean): void {
    if (this.draft !== null) {
      this.draft.ligatures = enabled;
    }
  }

  setBoldAsBright(enabled: boolean): void {
    if (this.draft !== null) {
      this.draft.boldAsBright = enabled;
      this.syncPreview();
    }
  }

  setCursorStyle(style: CursorStyle): void {
    if (this.draft !== null) {
      this.draft.cursorStyle = style;
      this.syncPreview();
    }
  }

  setCursorBlink(blink: boolean): void {
    if (this.draft !== null) {
      this.draft.cursorBlink = blink;
      this.syncPreview();
    }
  }

  setBackgroundOpacity(opacity: number): void {
    if (this.draft !== null) {
      this.draft.backgroundOpacity = Math.max(0, Math.min(1, opacity));
      this.syncPreview();
    }
  }

  setPadding(padding: number): void {
    if (this.draft !== null) {
      this.draft.padding = Math.max(0, padding);
      this.syncPreview();
    }
  }

  /** A5：背景图路径（'' = 清除） */
  setBackgroundImagePath(path: string): void {
    if (this.draft !== null) {
      this.draft.backgroundImagePath = path.trim();
      this.syncPreview();
    }
  }

  /** A5：背景图不透明度 0–1 */
  setBackgroundImageOpacity(opacity: number): void {
    if (this.draft !== null) {
      this.draft.backgroundImageOpacity = Math.max(0, Math.min(1, opacity));
      this.syncPreview();
    }
  }

  /** A5：背景模糊 vp（0–40，0 = 不模糊） */
  setBackgroundBlur(blur: number): void {
    if (this.draft !== null) {
      this.draft.backgroundBlur = Math.max(0, Math.min(40, blur));
      this.syncPreview();
    }
  }

  /** 20 色位之一：index 0–15 调色板；16 前景 17 背景 18 光标 19 选区 */
  setColorSlot(index: number, hex: string): void {
    if (this.draft === null) {
      return;
    }
    if (index >= 0 && index < 16) {
      this.draft.palette[index] = hex;
    } else if (index === 16) {
      this.draft.foreground = hex;
    } else if (index === 17) {
      this.draft.background = hex;
    } else if (index === 18) {
      this.draft.cursorColor = hex;
    } else if (index === 19) {
      this.draft.selectionColor = hex;
    }
    this.syncPreview();
  }

  /** 将预设色位套到当前草稿（保留字体等非色位项） */
  applyPresetToDraft(presetId: string): boolean {
    const preset: ThemePreset | null = themePresetById(presetId);
    if (preset === null || this.draft === null) {
      return false;
    }
    applyThemeColors(this.draft, preset.colors);
    this.syncPreview();
    this.lastMessage = `已套用「${preset.name}」配色`;
    return true;
  }

  /** 配色导入（iTerm2 / Windows Terminal）套到草稿 */
  importThemeToDraft(fileName: string, content: string): ThemeImportResult {
    const result: ThemeImportResult = parseThemeImport(fileName, content);
    if (!result.ok || result.colors === null || this.draft === null) {
      this.lastMessage = result.error.length > 0 ? result.error : '请先选中一个主题再导入';
      return result;
    }
    applyThemeColors(this.draft, result.colors);
    if (result.name.length > 0) {
      this.draft.name = result.name;
    }
    this.syncPreview();
    this.lastMessage = `已导入配色${result.name.length > 0 ? `「${result.name}」` : ''}`;
    return result;
  }

  /** 新建空白自定义主题（Harmony Dark 底） */
  createCustom(name: string): AppearanceProfile | null {
    const id: string = this.newId();
    const profile: AppearanceProfile = createDefaultAppearanceProfile(id);
    profile.name = name.trim().length > 0 ? name.trim() : '自定义主题';
    try {
      this.dao.insert(profile);
    } catch (err) {
      this.lastMessage = '创建失败';
      return null;
    }
    this.reload();
    this.select(id);
    return profile;
  }

  private syncPreview(): void {
    if (this.draft === null) {
      this.preview = null;
      return;
    }
    this.preview = terminalAppearanceFromProfile(this.draft);
  }

  /** 色位读取（UI 20 色列表） */
  colorSlot(index: number): string {
    if (this.draft === null) {
      return '#000000';
    }
    if (index >= 0 && index < 16) {
      return this.draft.palette[index];
    }
    if (index === 16) {
      return this.draft.foreground;
    }
    if (index === 17) {
      return this.draft.background;
    }
    if (index === 18) {
      return this.draft.cursorColor;
    }
    if (index === 19) {
      return this.draft.selectionColor;
    }
    return '#000000';
  }
}

/** 20 色位标签（AppearancePage 列表） */
export const COLOR_SLOT_LABELS: string[] = [
  '黑', '红', '绿', '黄', '蓝', '品红', '青', '白',
  '亮黑', '亮红', '亮绿', '亮黄', '亮蓝', '亮品红', '亮青', '亮白',
  '前景', '背景', '光标', '选区'
];
