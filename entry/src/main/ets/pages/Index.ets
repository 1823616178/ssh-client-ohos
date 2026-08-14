import { BuildConfig } from '../common/constants/BuildConfig';
import { Tokens } from '../theme/Tokens';
import { SshNativeSession, SshEvent } from '../napi/SshNative';
import libsshCore from 'libssh_core.so';
import { util } from '@kit.ArkTS';

/**
 * 首页：当前作为 Design Token（X2）、构建期配置（X5）与 NAPI 桥接层（N11）的
 * 演示与验证点。颜色与尺寸一律取自 Tokens。
 * 「测试原生库」为 N3 验证点：调用 libssh_core.so 展示四个原生依赖版本。
 * 「连接冒烟」为 N11/M1 出口雏形：主机/端口/用户/密码 → 创建会话 → 连接 →
 * 密码认证 → 开 shell → 写一条命令 → 把 stateChange 与 shell 输出显示出来。
 * （M1 的极简命令行式界面；T3/T4 终端引擎落地后由 TerminalPage 取代）
 */
@Entry
@Component
struct Index {
  // X5 运行时验证点：直接展示构建期注入的同步服务器地址
  @State message: string = `同步服务器: ${BuildConfig.SYNC_API_URL}`;
  // N3 验证点：原生依赖版本信息或错误文本
  @State nativeResult: string = '';

  // ---- N11 连接冒烟（表单值不需要响应式，用普通成员即可）----
  private host: string = '';
  private port: string = '22';
  private user: string = '';
  private password: string = '';
  @State sshLog: string = '';
  private sshSession: SshNativeSession | null = null;
  private shellChannelId: number = -1;
  // 流式解码器：channelData 聚合批次可能切断 UTF-8 序列，stream 模式保序拼接
  private textDecoder: util.TextDecoder = util.TextDecoder.create('utf-8');

  private appendLog(text: string): void {
    const merged = this.sshLog + text;
    // 封顶 6000 字符防无限增长（冒烟页不考虑回滚，M2 终端引擎接管）
    this.sshLog = merged.length > 6000 ? merged.slice(merged.length - 6000) : merged;
  }

  private onSshEvent = (event: SshEvent): void => {
    switch (event.type) {
      case 'stateChange':
        this.appendLog(`\n[state] ${event.from ?? ''} -> ${event.to ?? ''}\n`);
        // 极简编排：到 authenticating 自动发密码，established 自动开 shell
        if (event.to === 'authenticating') {
          this.sshSession?.authenticatePassword(this.password);
        } else if (event.to === 'established') {
          this.sshSession?.openShell('xterm-256color', 80, 24);
        }
        break;
      case 'hostKey':
        this.appendLog(`\n[hostKey] ${event.keyType ?? ''} ${event.fingerprintSha256 ?? ''}\n`);
        break;
      case 'authResult':
        this.appendLog(`\n[auth] ${event.method ?? ''} success=${event.success === true} ` +
          `${event.error ?? ''} ${event.message ?? ''}\n`);
        break;
      case 'channelOpen':
        this.appendLog(`\n[channelOpen] id=${event.channelId ?? -1} success=${event.success === true}\n`);
        if (event.success === true && event.channelId !== undefined) {
          this.shellChannelId = event.channelId;
          // 冒烟命令：看到回显输出即证明「写→收事件」通路
          this.sshSession?.write(event.channelId, 'echo N11_SMOKE_OK; uname -a\n');
        }
        break;
      case 'channelData':
        if (event.data !== undefined) {
          // decodeToString + stream：聚合批次可能切断 UTF-8 序列，
          // 不完整尾字节由解码器内部缓冲、下次调用续上
          this.appendLog(this.textDecoder.decodeToString(new Uint8Array(event.data), { stream: true }));
        }
        break;
      case 'channelClose':
        this.appendLog(`\n[channelClose] id=${event.channelId ?? -1} ` +
          `reason=${event.reason ?? ''} exit=${event.exitStatus ?? 0}\n`);
        break;
      case 'error':
        this.appendLog(`\n[error] ${event.code ?? ''} ${event.message ?? ''}\n`);
        break;
      default:
        break;
    }
  }

  private connectSmoke(): void {
    if (this.sshSession !== null) {
      this.appendLog('\n[ui] 会话已存在，请先关闭\n');
      return;
    }
    const portNum: number = parseInt(this.port, 10);
    if (this.host.length === 0 || this.user.length === 0 ||
      Number.isNaN(portNum) || portNum < 1 || portNum > 65535) {
      this.appendLog('\n[ui] 请填写主机/用户/合法端口\n');
      return;
    }
    const session = SshNativeSession.create(this.onSshEvent);
    if (session === null) {
      this.appendLog('\n[ui] createSession 失败\n');
      return;
    }
    this.sshSession = session;
    this.sshLog = '';
    if (!session.connect(this.host, portNum, this.user)) {
      this.appendLog('[ui] connect 未受理\n');
    }
  }

  private closeSmoke(): void {
    this.sshSession?.close();
    this.sshSession = null;
    this.shellChannelId = -1;
    this.appendLog('\n[ui] 已关闭\n');
  }

  build() {
    Scroll() {
      Column() {
        // 卡片：app_surface + radius_md + space_md
        Column() {
          Text($r('app.string.app_name'))
            .fontSize(Tokens.fontSize.headline)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.Color.text)

          Text(this.message)
            .id('SyncApiUrl')
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.textDim)
            .margin({ top: Tokens.space.sm })

          // 强调色元素：app_accent
          Text('立即连接')
            .fontSize(Tokens.fontSize.title)
            .fontColor(Color.White)
            .backgroundColor(Tokens.Color.accent)
            .borderRadius(Tokens.radius.sm)
            .padding({
              left: Tokens.space.lg,
              right: Tokens.space.lg,
              top: Tokens.space.xs,
              bottom: Tokens.space.xs
            })
            .margin({ top: Tokens.space.lg })

          // N3 验证点：调用原生库，展示 libssh2/OpenSSL/vterm/argon2 版本
          Button('测试原生库')
            .fontSize(Tokens.fontSize.body)
            .fontColor(Color.White)
            .backgroundColor(Tokens.Color.accent)
            .borderRadius(Tokens.radius.sm)
            .margin({ top: Tokens.space.lg })
            .onClick(() => {
              try {
                this.nativeResult = [
                  `libssh2: ${libsshCore.getLibssh2Version()}`,
                  `OpenSSL: ${libsshCore.getOpensslVersion()}`,
                  `libvterm: ${libsshCore.getVtermVersion()}`,
                  `argon2: ${libsshCore.getArgon2Version()}`
                ].join('\n');
              } catch (e) {
                this.nativeResult = `原生调用失败: ${JSON.stringify(e)}`;
              }
            })

          if (this.nativeResult.length > 0) {
            Text(this.nativeResult)
              .id('NativeResult')
              .fontSize(Tokens.fontSize.body)
              .fontColor(Tokens.Color.textDim)
              .margin({ top: Tokens.space.sm })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .backgroundColor(Tokens.Color.surface)
        .borderRadius(Tokens.radius.md)
        .padding(Tokens.space.md)
        .width('100%')

        // N11 验证点：连接冒烟表单（M1 出口 demo 雏形，保持极简）
        Column() {
          Text('连接冒烟（N11）')
            .fontSize(Tokens.fontSize.title)
            .fontColor(Tokens.Color.text)

          TextInput({ placeholder: '主机（如 192.168.1.1）' })
            .fontSize(Tokens.fontSize.body)
            .margin({ top: Tokens.space.sm })
            .onChange((value: string) => {
              this.host = value;
            })
          TextInput({ placeholder: '端口', text: '22' })
            .fontSize(Tokens.fontSize.body)
            .margin({ top: Tokens.space.sm })
            .onChange((value: string) => {
              this.port = value;
            })
          TextInput({ placeholder: '用户名' })
            .fontSize(Tokens.fontSize.body)
            .margin({ top: Tokens.space.sm })
            .onChange((value: string) => {
              this.user = value;
            })
          TextInput({ placeholder: '密码' })
            .type(InputType.Password)
            .fontSize(Tokens.fontSize.body)
            .margin({ top: Tokens.space.sm })
            .onChange((value: string) => {
              this.password = value;
            })

          Row() {
            Button('连接')
              .fontSize(Tokens.fontSize.body)
              .fontColor(Color.White)
              .backgroundColor(Tokens.Color.accent)
              .borderRadius(Tokens.radius.sm)
              .onClick(() => {
                this.connectSmoke();
              })
            Button('关闭')
              .fontSize(Tokens.fontSize.body)
              .fontColor(Tokens.Color.text)
              .backgroundColor(Tokens.Color.surfaceHover)
              .borderRadius(Tokens.radius.sm)
              .margin({ left: Tokens.space.md })
              .onClick(() => {
                this.closeSmoke();
              })
          }
          .margin({ top: Tokens.space.md })

          if (this.sshLog.length > 0) {
            Text(this.sshLog)
              .id('SshSmokeLog')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.textDim)
              .margin({ top: Tokens.space.sm })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .backgroundColor(Tokens.Color.surface)
        .borderRadius(Tokens.radius.md)
        .padding(Tokens.space.md)
        .width('100%')
        .margin({ top: Tokens.space.md })
      }
      .width('100%')
      .padding(Tokens.space.md)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tokens.Color.appBg)
  }
}
