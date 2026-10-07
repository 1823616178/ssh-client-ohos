/**
 * 命令片段变量替换 —— 任务 U10（DESIGN §7.2）。
 *
 * 支持 `${host}` / `${user}`（及 `${port}` / `${name}` 扩展位）；
 * 未知占位符原样保留，避免误伤 shell 变量（如 `$HOME`、`${PWD}` 中非本表键）。
 * 纯函数，hypium 全覆盖。
 */

/** 片段替换上下文（来自 HostProfile / 临时连接） */
export interface SnippetVars {
  readonly host: string;
  readonly user: string;
  readonly port: number;
  readonly name: string;
}

/** 从主机配置构造替换变量 */
export function snippetVarsOf(hostName: string, host: string, user: string, port: number): SnippetVars {
  return { host: host, user: user, port: port, name: hostName };
}

/**
 * 替换片段中的已知占位符。
 * 仅识别本表键：host / user / port / name；其余 `${...}` 原样保留。
 */
export function substituteSnippet(content: string, vars: SnippetVars): string {
  if (content.length === 0) {
    return content;
  }
  let result: string = '';
  let index: number = 0;
  while (index < content.length) {
    const ch: string = content.charAt(index);
    if (ch === '$' && index + 1 < content.length && content.charAt(index + 1) === '{') {
      const close: number = content.indexOf('}', index + 2);
      if (close > index + 2) {
        const key: string = content.substring(index + 2, close);
        const value: string | null = lookupSnippetVar(key, vars);
        if (value !== null) {
          result += value;
          index = close + 1;
          continue;
        }
      }
    }
    result += ch;
    index++;
  }
  return result;
}

function lookupSnippetVar(key: string, vars: SnippetVars): string | null {
  if (key === 'host') {
    return vars.host;
  }
  if (key === 'user') {
    return vars.user;
  }
  if (key === 'port') {
    return `${vars.port}`;
  }
  if (key === 'name') {
    return vars.name;
  }
  return null;
}

/** 发送前预览：若含占位符，返回替换后的完整文本（UI 展示用） */
export function previewSnippet(content: string, vars: SnippetVars): string {
  return substituteSnippet(content, vars);
}

/** 写入终端时的载荷：片段内容替换后补 `\n`（等同敲回车）；空片段返回空串 */
export function encodeSnippetForTerminal(content: string, vars: SnippetVars): string {
  const substituted: string = substituteSnippet(content, vars);
  if (substituted.length === 0) {
    return '';
  }
  return `${substituted}\n`;
}
