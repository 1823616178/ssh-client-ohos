/**
 * 日志基础设施（DESIGN §5.1 / §6.5.1，任务 X4）。
 *
 * 双输出：hilog（控制台）+ 应用 files 目录日志文件（context.filesDir/logs/app.log）。
 * 文件轮转：活动文件超过 BuildConfig.LOG_MAX_BYTES（默认 5 MiB）时顺移为
 * app.log.1 → app.log.2 → …，含活动文件在内最多保留 BuildConfig.LOG_MAX_FILES 个；
 * BuildConfig.LOG_TO_FILE = false 时只走 hilog。
 *
 * 纪律（§5.1）：只记录启动、同步状态、会话状态；不记录密码 / token / 私钥 / 密文。
 * 所有输出内容（hilog 与文件一致）统一先经 sanitize() 脱敏，命中的敏感片段替换为 ***。
 *
 * 使用方式：EntryAbility.onCreate 中调用 Logger.init(this.context) 注入上下文，
 * 之后各处直接 Logger.info('...')。文件写入为 fire-and-forget：
 * 内部串行队列保证写入顺序，不阻塞调用方。
 *
 * parseLogLevel / isLevelEnabled / sanitize / shouldRotate / logFileNames
 * 为不依赖 context 的纯函数，供单元测试直接覆盖。
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import fs from '@ohos.file.fs';
import { BuildConfig } from '../constants/BuildConfig';

/** hilog 域（合法十六进制）与标签 */
const HILOG_DOMAIN: number = 0x0901;
const HILOG_TAG: string = 'SshClient';
/** 活动日志文件名，轮转备份依次追加 .1 / .2 … */
const LOG_FILE_NAME: string = 'app.log';
/** 日志目录名（位于 context.filesDir 下） */
const LOG_DIR_NAME: string = 'logs';

/** 日志级别，数值越小越详细；BuildConfig.LOG_LEVEL 作为输出门槛 */
export enum LogLevel {
  DEBUG = 0,
  INFO = 1,
  WARN = 2,
  ERROR = 3
}

/** 解析构建配置的日志级别字符串；无法识别时回退 INFO（宁可少记，不放大输出面） */
export function parseLogLevel(text: string): LogLevel {
  switch (text.trim().toLowerCase()) {
    case 'debug':
      return LogLevel.DEBUG;
    case 'info':
      return LogLevel.INFO;
    case 'warn':
      return LogLevel.WARN;
    case 'error':
      return LogLevel.ERROR;
    default:
      return LogLevel.INFO;
  }
}

/** 级别过滤：level 达到门槛才输出（debug 门槛输出全部，info 门槛过滤掉 debug） */
export function isLevelEnabled(threshold: LogLevel, level: LogLevel): boolean {
  return level >= threshold;
}

/** 脱敏规则定义：模式集中在此，新增敏感格式只需追加一条 */
interface SanitizeRule {
  /** 规则名，便于排查命中来源 */
  readonly name: string;
  readonly pattern: RegExp;
  readonly replacement: string;
}

/** 需要脱敏的键名清单（JSON 键与 k=v / k:v 两种形态共用） */
const SECRET_KEYS: string =
  'password|passwd|passphrase|pwd|token|accessToken|refreshToken|privateKey|private_key|secret|authorization';

/** 裸 k=v / k:v 形态脱敏的键名：authorization 由独立规则整行处理，不在此列 */
const PLAIN_KV_KEYS: string =
  'password|passwd|passphrase|pwd|token|accessToken|refreshToken|privateKey|private_key|secret';

const SANITIZE_RULES: SanitizeRule[] = [
  {
    // PEM / OPENSSH 私钥块整体替换（跨多行，必须先于单行规则执行）
    name: 'private-key-block',
    pattern: /-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----/g,
    replacement: '***'
  },
  {
    // JSON 形态："password":"xxx"、"token" : "xxx"（键名大小写不敏感，保留键与引号；
    // 值部分兼容 \" 转义，避免转义引号截断导致后半段明文残留）
    name: 'json-kv',
    pattern: new RegExp(`("(?:${SECRET_KEYS})"\\s*:\\s*")(?:[^"\\\\]|\\\\.)*(")`, 'gi'),
    replacement: '$1***$2'
  },
  {
    // HTTP 头形态：Authorization: Bearer xxx / Basic xxx —— 值可能含空格，脱敏到行尾
    // （必须在 bearer-token 与 plain-kv 之前，避免「Authorization: Bearer」被当作普通 k:v 干扰）
    name: 'authorization-line',
    pattern: /\b(authorization\s*[=:]\s*)[^\n]*/gi,
    replacement: '$1***'
  },
  {
    // 无前缀的 Bearer xxx
    name: 'bearer-token',
    pattern: /\b(Bearer\s+)\S+/g,
    replacement: '$1***'
  },
  {
    // 裸 k=v / k: v 形态：password=xxx、token: xxx（值不含空白与常见分隔符）
    name: 'plain-kv',
    pattern: new RegExp(`\\b(${PLAIN_KV_KEYS})(\\s*[=:]\\s*)[^\\s,;&"']+`, 'gi'),
    replacement: '$1$2***'
  }
];

/**
 * 日志脱敏：把密码 / token / 私钥等敏感片段替换为 ***。
 * 对所有输出（hilog 与文件）生效；非敏感内容原样保留。
 */
export function sanitize(text: string): string {
  let result: string = text;
  for (let i = 0; i < SANITIZE_RULES.length; i++) {
    const rule: SanitizeRule = SANITIZE_RULES[i];
    result = result.replace(rule.pattern, rule.replacement);
  }
  return result;
}

/** 是否需要轮转：当前大小 + 即将写入的字节数超过上限（活动文件为空时不轮转） */
export function shouldRotate(currentBytes: number, incomingBytes: number, maxBytes: number): boolean {
  return currentBytes > 0 && currentBytes + incomingBytes > maxBytes;
}

/** 轮转链文件名：index 0 为活动文件，含活动文件在内共 maxFiles 个 */
export function logFileNames(maxFiles: number): string[] {
  const names: string[] = [LOG_FILE_NAME];
  for (let i = 1; i < maxFiles; i++) {
    names.push(`${LOG_FILE_NAME}.${i}`);
  }
  return names;
}

/** UTF-8 编码后的字节数（轮转按字节计量） */
function utf8ByteLength(text: string): number {
  return util.TextEncoder.create('utf-8').encodeInto(text).length;
}

function levelName(level: LogLevel): string {
  switch (level) {
    case LogLevel.DEBUG:
      return 'DEBUG';
    case LogLevel.INFO:
      return 'INFO';
    case LogLevel.WARN:
      return 'WARN';
    case LogLevel.ERROR:
      return 'ERROR';
    default:
      return 'UNKNOWN';
  }
}

export class Logger {
  private static threshold: LogLevel = parseLogLevel(BuildConfig.LOG_LEVEL);
  /** 日志目录绝对路径；空串表示未初始化（或初始化失败），此时只走 hilog */
  private static logDir: string = '';
  /** 活动文件当前字节数（init 时由 stat 播种，之后按实际写入累计） */
  private static currentFileBytes: number = 0;
  /** 文件写入串行队列：依次执行，单条失败不阻断后续 */
  private static writeQueue: Promise<void> = Promise.resolve();

  /**
   * 注入应用上下文以启用文件输出，由 EntryAbility.onCreate 调用一次。
   * LOG_TO_FILE = false 时不建目录、不落盘，仅 hilog。
   */
  static init(context: common.Context): void {
    Logger.threshold = parseLogLevel(BuildConfig.LOG_LEVEL);
    if (!BuildConfig.LOG_TO_FILE) {
      return;
    }
    try {
      const dir: string = `${context.filesDir}/${LOG_DIR_NAME}`;
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir, true);
      }
      Logger.logDir = dir;
      const active: string = Logger.activePath();
      Logger.currentFileBytes = fs.accessSync(active) ? fs.statSync(active).size : 0;
    } catch (err) {
      Logger.logDir = '';
      hilog.error(HILOG_DOMAIN, HILOG_TAG, 'Logger init failed: %{public}s', JSON.stringify(err));
    }
  }

  static debug(message: string, subTag: string = 'App'): void {
    Logger.log(LogLevel.DEBUG, subTag, message);
  }

  static info(message: string, subTag: string = 'App'): void {
    Logger.log(LogLevel.INFO, subTag, message);
  }

  static warn(message: string, subTag: string = 'App'): void {
    Logger.log(LogLevel.WARN, subTag, message);
  }

  static error(message: string, subTag: string = 'App'): void {
    Logger.log(LogLevel.ERROR, subTag, message);
  }

  /** 统一入口：级别过滤 → 脱敏 → hilog + 文件双写 */
  static log(level: LogLevel, subTag: string, message: string): void {
    if (!isLevelEnabled(Logger.threshold, level)) {
      return;
    }
    const clean: string = sanitize(message);
    switch (level) {
      case LogLevel.DEBUG:
        hilog.debug(HILOG_DOMAIN, HILOG_TAG, '[%{public}s] %{public}s', subTag, clean);
        break;
      case LogLevel.INFO:
        hilog.info(HILOG_DOMAIN, HILOG_TAG, '[%{public}s] %{public}s', subTag, clean);
        break;
      case LogLevel.WARN:
        hilog.warn(HILOG_DOMAIN, HILOG_TAG, '[%{public}s] %{public}s', subTag, clean);
        break;
      case LogLevel.ERROR:
        hilog.error(HILOG_DOMAIN, HILOG_TAG, '[%{public}s] %{public}s', subTag, clean);
        break;
      default:
        break;
    }
    if (BuildConfig.LOG_TO_FILE && Logger.logDir.length > 0) {
      Logger.enqueueFileWrite(`[${new Date().toISOString()}] [${levelName(level)}] [${subTag}] ${clean}\n`);
    }
  }

  private static activePath(): string {
    return `${Logger.logDir}/${LOG_FILE_NAME}`;
  }

  /** fire-and-forget：写入串行排队，失败只降级到 hilog，不抛给调用方 */
  private static enqueueFileWrite(line: string): void {
    Logger.writeQueue = Logger.writeQueue
      .then(() => Logger.writeLineToFile(line))
      .catch((err: Object) => {
        hilog.error(HILOG_DOMAIN, HILOG_TAG, 'write log file failed: %{public}s', JSON.stringify(err));
      });
  }

  private static async writeLineToFile(line: string): Promise<void> {
    if (Logger.logDir.length === 0) {
      return;
    }
    try {
      const incoming: number = utf8ByteLength(line);
      if (shouldRotate(Logger.currentFileBytes, incoming, BuildConfig.LOG_MAX_BYTES) && Logger.rotateFiles()) {
        Logger.currentFileBytes = 0;
      }
      const file: fs.File = fs.openSync(Logger.activePath(),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.APPEND);
      try {
        Logger.currentFileBytes += fs.writeSync(file.fd, line);
      } finally {
        fs.closeSync(file);
      }
    } catch (err) {
      // 文件写入失败只降级到 hilog，不中断后续队列，也不抛给调用方
      hilog.error(HILOG_DOMAIN, HILOG_TAG, 'write log file failed: %{public}s', JSON.stringify(err));
    }
  }

  /** 顺移轮转：app.log → app.log.1 → …，超出保留个数的最旧备份删除；返回是否成功 */
  private static rotateFiles(): boolean {
    const names: string[] = logFileNames(BuildConfig.LOG_MAX_FILES);
    try {
      if (names.length === 1) {
        // 只保留 1 个文件时，轮转即清空重来
        const only: string = `${Logger.logDir}/${names[0]}`;
        if (fs.accessSync(only)) {
          fs.unlinkSync(only);
        }
        return true;
      }
      for (let i = names.length - 1; i >= 1; i--) {
        const from: string = `${Logger.logDir}/${names[i - 1]}`;
        const to: string = `${Logger.logDir}/${names[i]}`;
        if (fs.accessSync(to)) {
          fs.unlinkSync(to);
        }
        if (fs.accessSync(from)) {
          fs.renameSync(from, to);
        }
      }
      return true;
    } catch (err) {
      // 轮转失败不阻断写入：本轮退化为继续追加（字节计数器不清零，下一条日志会重试轮转）
      hilog.error(HILOG_DOMAIN, HILOG_TAG, 'rotate log file failed: %{public}s', JSON.stringify(err));
      return false;
    }
  }
}
