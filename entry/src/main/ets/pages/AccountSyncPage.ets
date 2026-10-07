/**
 * 账号与云同步（任务 U6）+ 冲突解决（任务 U7）。
 *
 * 登录/注册、同步状态、设备、历史回滚、敏感开关、轮换、冲突「保留本机 / 使用云端」。
 * 与桌面端 ssh-tool 共用保险库与同步文档（SyncDocumentV1），可同账号双向同步。
 */

import { router } from '@kit.ArkUI';
import { Tokens } from '../theme/Tokens';
import { PageHeader } from '../view/PageHeader';
import { DeviceItem } from '../service/sync/ApiTypes';
import { RevisionItem } from '../service/sync/ApiTypes';
import { SyncConflict } from '../service/sync/SyncMerge';
import { SyncRuntime } from '../service/sync/SyncRuntime';
import { AccountSyncViewModel } from '../viewmodel/AccountSyncViewModel';

/**
 * 必须是 @ComponentV2：AccountSyncViewModel 是 @ObservedV2 + @Trace，
 * V1 的 @Component 订阅不到它，页面会停在首帧（旧实现靠 uiSeq 自增 + 一个
 * .opacity 绑定试图兜底，但 V1 是逐元素观察，Builder / if / ForEach 根本不会重算）。
 * V2 组件对 @Trace 字段原生响应，故 vm 用普通成员即可，无需任何手动刷新。
 */
@Entry
@ComponentV2
struct AccountSyncPage {
  @Local private isSyncing: boolean = false;
  private readonly vm: AccountSyncViewModel = SyncRuntime.get().createViewModel();

  /** VM 的 async 方法内部已把异常收敛为 errorText，这里只兜底防止未处理拒绝 */
  private run(task: Promise<void>): void {
    task.catch((err: Object) => {
      this.toast(err instanceof Error ? err.message : '操作失败，请重试');
    });
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (_err) {
      // Prompt toast error fallback
    }
  }

  aboutToAppear(): void {
    // start() 是 fire-and-forget；这里等一次 hydrate 完成，避免冷启动瞬间读到空 token
    // 而误判「未登录」（token 落 asset，读取是异步的）
    void this.refreshAfterHydrate();
  }

  private async refreshAfterHydrate(): Promise<void> {
    await SyncRuntime.get().ensureHydrated();
    this.vm.refreshFromAuth();
  }

  build() {
    Column() {
      PageHeader({
        title: '账号与同步',
        subtitle: '登录后可与桌面端双向同步配置'
      })

      Scroll() {
        Column() {
          // 同步边界说明条
          Row() {
            Column()
              .width(Tokens.space.xs2)
              .height(36)
              .backgroundColor(Tokens.Color.accent)
              .borderRadius(Tokens.radius.xs)
              .margin({ right: Tokens.space.xs })
            Text('与桌面端 ssh-tool 共用同一账号即可双向同步。仅同步主机、端口转发与分组；外观、片段、主机指纹、跳板与终端设置为本机专有，不上云。')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.textDim)
              .layoutWeight(1)
              .lineHeight(18)
          }
          .width('100%')
          .padding(Tokens.space.sm)
          .backgroundColor(Tokens.Color.surface)
          .borderRadius(Tokens.radius.sm)
          .margin({ top: Tokens.space.sm })

          this.StatusCard()

          if (!this.vm.signedIn) {
            this.AuthForm()
          } else if (this.vm.vaultMissing) {
            this.CreateVaultBlock()
          } else if (this.vm.vaultLocked) {
            this.UnlockBlock()
          } else {
            if (this.vm.envelopeNeedsRepair) {
              this.RepairEnvelopeBlock()
            }
            this.SessionBlock()
            this.SensitiveBlock()
            if (this.vm.conflicts.length > 0) {
              this.ConflictBlock()
            }
            this.DeviceBlock()
            this.HistoryBlock()
            this.AccountBlock()
          }

          if (this.vm.errorText.length > 0) {
            Row() {
              Text(this.vm.errorText)
                .fontSize(Tokens.fontSize.body)
                .fontColor(Tokens.Color.danger)
                .layoutWeight(1)
                .lineHeight(20)
            }
            .width('100%')
            .padding(Tokens.space.sm)
            .backgroundColor(Tokens.Color.surface)
            .borderRadius(Tokens.radius.sm)
            .margin({ top: Tokens.space.sm })
          }

          if (this.vm.recoveryKey.length > 0 && !this.vm.recoveryAck) {
            this.RecoveryBlock()
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ bottom: Tokens.space.md })
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .padding({
      left: Tokens.space.md,
      right: Tokens.space.md,
      bottom: 0
    })
    .backgroundColor(Tokens.Color.appBg)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  StatusCard() {
    Column() {
      Row() {
        Column() {
          Text('同步状态')
            .fontSize(Tokens.fontSize.title)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.Color.text)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        // 状态徽标
        Row() {
          Column()
            .width(Tokens.space.xs)
            .height(Tokens.space.xs)
            .borderRadius(Tokens.space.xs2)
            .backgroundColor(this.vm.signedIn ? Tokens.Color.success : Tokens.Color.textFaint)
            .margin({ right: Tokens.space.xs })
          Text(this.vm.signedIn ? '已登录' : '未连接')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(this.vm.signedIn ? Tokens.Color.success : Tokens.Color.textDim)
            .fontWeight(FontWeight.Medium)
        }
        .padding({ left: Tokens.space.sm, right: Tokens.space.sm, top: Tokens.space.xs2, bottom: Tokens.space.xs2 })
        .backgroundColor(Tokens.Color.surfaceHover)
        .borderRadius(Tokens.radius.xs)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Divider()
        .color(Tokens.Color.border)
        .strokeWidth(0.5)
        .margin({ top: Tokens.space.sm, bottom: Tokens.space.sm })

      Text(this.vm.statusText)
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.text)
        .lineHeight(20)

      if (this.vm.signedIn && this.vm.userEmail.length > 0) {
        Row() {
          Text('账号：')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
          Text(this.vm.userEmail)
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.accent)
            .fontWeight(FontWeight.Medium)
        }
        .margin({ top: Tokens.space.xs })
      }

      if (this.vm.lastSyncSummary.length > 0) {
        Row() {
          Text('最新同步：')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
          Text(this.vm.lastSyncSummary)
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.success)
            .fontWeight(FontWeight.Medium)
            .layoutWeight(1)
        }
        .margin({ top: Tokens.space.xs2 })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .margin({ top: Tokens.space.sm })
  }

  @Builder
  AuthForm() {
    Column() {
      Column() {
        Text('登录 / 注册')
          .fontSize(Tokens.fontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
        Text('账号密码只用于身份认证。解密云端配置需要独立的同步密码。')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .margin({ top: Tokens.space.xs2 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Column() {
        Text('邮箱地址')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .margin({ top: Tokens.space.sm, bottom: Tokens.space.xs2 })
        TextInput({ placeholder: 'name@example.com', text: this.vm.email })
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .placeholderColor(Tokens.Color.textFaint)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(44)
          .width('100%')
          .onChange((v: string) => {
            this.vm.email = v;
          })

        Text('账号密码')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .margin({ top: Tokens.space.sm, bottom: Tokens.space.xs2 })
        TextInput({ placeholder: '至少 10 位字符（仅用于登录）', text: this.vm.password })
          .type(InputType.Password)
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .placeholderColor(Tokens.Color.textFaint)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(44)
          .width('100%')
          .onChange((v: string) => {
            this.vm.password = v;
          })

        Text('邀请码（可选）')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .margin({ top: Tokens.space.sm, bottom: Tokens.space.xs2 })
        TextInput({ placeholder: '若服务器开放注册无需填写', text: this.vm.invite })
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .placeholderColor(Tokens.Color.textFaint)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(44)
          .width('100%')
          .onChange((v: string) => {
            this.vm.invite = v;
          })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Column() {
        Button('登录')
          .fontSize(Tokens.fontSize.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.sm)
          .height(42)
          .width('100%')
          .onClick(() => {
            this.run(this.vm.login());
          })

        Button('注册')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(42)
          .width('100%')
          .margin({ top: Tokens.space.xs })
          .onClick(() => {
            this.run(this.vm.register());
          })
      }
      .width('100%')
      .margin({ top: Tokens.space.md })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .margin({ top: Tokens.space.md })
  }

  @Builder
  CreateVaultBlock() {
    Column() {
      Column() {
        Text('创建加密保险库')
          .fontSize(Tokens.fontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
        Text('首次同步需设置独立的同步密码（至少 10 位）。用于在本地派生端到端加密密钥，服务端无法解密。')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .lineHeight(18)
          .margin({ top: Tokens.space.xs2 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Column() {
        Text('同步密码')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .margin({ top: Tokens.space.sm, bottom: Tokens.space.xs2 })
        TextInput({ placeholder: '输入同步密码（至少 10 位）', text: this.vm.createSyncPassword })
          .type(InputType.Password)
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .placeholderColor(Tokens.Color.textFaint)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(44)
          .width('100%')
          .onChange((v: string) => {
            this.vm.createSyncPassword = v;
          })

        Text('确认同步密码')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .margin({ top: Tokens.space.sm, bottom: Tokens.space.xs2 })
        TextInput({ placeholder: '再次输入同步密码', text: this.vm.createSyncPassword2 })
          .type(InputType.Password)
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .placeholderColor(Tokens.Color.textFaint)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(44)
          .width('100%')
          .onChange((v: string) => {
            this.vm.createSyncPassword2 = v;
          })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Button('创建保险库')
        .fontSize(Tokens.fontSize.body)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.Color.onAccent)
        .backgroundColor(Tokens.Color.accent)
        .borderRadius(Tokens.radius.sm)
        .height(42)
        .width('100%')
        .margin({ top: Tokens.space.md })
        .onClick(() => {
          this.run(this.vm.createVault());
        })

      Button('退出登录')
        .fontSize(Tokens.fontSize.caption)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.Color.onAccent)
        .backgroundColor(Tokens.Color.danger)
        .borderRadius(Tokens.radius.sm)
        .height(36)
        .width('100%')
        .margin({ top: Tokens.space.xs })
        .onClick(() => {
          this.run(this.vm.logout());
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .margin({ top: Tokens.space.md })
  }

  /** 信封被旧版轮换缺陷写坏：已按旧版本号解锁，提示尽快重新包装 */
  @Builder
  RepairEnvelopeBlock() {
    Column() {
      Column() {
        Text('需要处理')
          .fontSize(Tokens.fontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.warn)
        Text('保险库信封需要修复')
          .fontSize(Tokens.fontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.warn)
          .margin({ top: Tokens.space.xs2 })
        Text('云端信封的版本号与其密钥包装不一致（旧版轮换遗留）。本次已自动兼容解锁，但换设备时会解不开。请重新包装一次；完成后会生成新的恢复密钥。')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .lineHeight(18)
          .margin({ top: Tokens.space.xs2 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Column() {
        Text('账号密码')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .margin({ top: Tokens.space.sm, bottom: Tokens.space.xs2 })
        TextInput({ placeholder: '当前登录密码', text: this.vm.repairAccountPassword })
          .type(InputType.Password)
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .placeholderColor(Tokens.Color.textFaint)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(44)
          .width('100%')
          .onChange((v: string) => {
            this.vm.repairAccountPassword = v;
          })

        Text('同步密码')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .margin({ top: Tokens.space.sm, bottom: Tokens.space.xs2 })
        TextInput({ placeholder: '当前同步密码', text: this.vm.repairSyncPassword })
          .type(InputType.Password)
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .placeholderColor(Tokens.Color.textFaint)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(44)
          .width('100%')
          .onChange((v: string) => {
            this.vm.repairSyncPassword = v;
          })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Button('重新包装')
        .fontSize(Tokens.fontSize.body)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.Color.onAccent)
        .backgroundColor(Tokens.Color.accent)
        .borderRadius(Tokens.radius.sm)
        .height(42)
        .width('100%')
        .margin({ top: Tokens.space.md })
        .onClick(() => {
          this.run(this.vm.repairEnvelope());
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .margin({ top: Tokens.space.md })
  }

  @Builder
  UnlockBlock() {
    Column() {
      Column() {
        Text('解锁保险库')
          .fontSize(Tokens.fontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
        Text('云端同步文档已加密。请输入同步密码或使用应急恢复密钥进行解密。')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .lineHeight(18)
          .margin({ top: Tokens.space.xs2 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Column() {
        Text('同步密码解锁')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .margin({ top: Tokens.space.sm, bottom: Tokens.space.xs2 })
        TextInput({ placeholder: '请输入同步密码', text: this.vm.unlockPassword })
          .type(InputType.Password)
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .placeholderColor(Tokens.Color.textFaint)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(44)
          .width('100%')
          .onChange((v: string) => {
            this.vm.unlockPassword = v;
          })

        Button('密码解锁')
          .fontSize(Tokens.fontSize.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.sm)
          .height(40)
          .width('100%')
          .margin({ top: Tokens.space.xs })
          .onClick(() => {
            this.run(this.vm.unlockVault());
          })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Divider()
        .color(Tokens.Color.border)
        .strokeWidth(0.5)
        .margin({ top: Tokens.space.md, bottom: Tokens.space.sm })

      Column() {
        Text('或使用应急恢复密钥')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .margin({ bottom: Tokens.space.xs2 })
        TextInput({ placeholder: 'SPM1-XXXXX-XXXXX...', text: this.vm.recoveryUnlock })
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .placeholderColor(Tokens.Color.textFaint)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(44)
          .width('100%')
          .onChange((v: string) => {
            this.vm.recoveryUnlock = v;
          })

        Button('密钥解锁')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(40)
          .width('100%')
          .margin({ top: Tokens.space.xs })
          .onClick(() => {
            this.run(this.vm.unlockWithRecovery());
          })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Button('退出登录')
        .fontSize(Tokens.fontSize.caption)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.Color.onAccent)
        .backgroundColor(Tokens.Color.danger)
        .borderRadius(Tokens.radius.sm)
        .height(36)
        .width('100%')
        .margin({ top: Tokens.space.sm })
        .onClick(() => {
          this.run(this.vm.logout());
        })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .margin({ top: Tokens.space.md })
  }

  @Builder
  SessionBlock() {
    Column() {
      Column() {
        Text('同步控制')
          .fontSize(Tokens.fontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Button(this.isSyncing ? '同步中…' : '立即同步')
        .enabled(!this.isSyncing)
        .opacity(this.isSyncing ? 0.6 : 1.0)
        .fontSize(Tokens.fontSize.body)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.Color.onAccent)
        .backgroundColor(Tokens.Color.accent)
        .borderRadius(Tokens.radius.sm)
        .height(42)
        .width('100%')
        .margin({ top: Tokens.space.sm })
        .onClick(() => {
          if (this.isSyncing) {
            return;
          }
          this.isSyncing = true;
          this.toast('开始同步配置…');
          this.vm.sync()
            .then(() => {
              this.isSyncing = false;
              if (this.vm.errorText.length > 0) {
                this.toast(`同步完成（提示: ${this.vm.errorText}）`);
              } else if (this.vm.conflicts.length > 0) {
                this.toast('同步发现配置冲突，请在下方处理');
              } else if (this.vm.lastSyncSummary.length > 0) {
                this.toast(this.vm.lastSyncSummary);
              } else {
                this.toast('配置同步完成');
              }
            })
            .catch((err: Object) => {
              this.isSyncing = false;
              const msg: string = err instanceof Error ? err.message : '';
              this.toast(msg.length > 0 && msg.indexOf(' ') < 0 ? `同步失败：${msg}` : '操作失败，请重试');
            });
        })

      Button('配置中心')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.accent)
        .backgroundColor(Tokens.Color.surfaceHover)
        .borderRadius(Tokens.radius.sm)
        .height(36)
        .width('100%')
        .margin({ top: Tokens.space.xs })
        .onClick(() => {
          router.pushUrl({ url: 'pages/ConfigManagerPage' });
        })

      Divider()
        .color(Tokens.Color.border)
        .strokeWidth(0.5)
        .margin({ top: Tokens.space.md, bottom: Tokens.space.xs })

      Row() {
        Button('退出登录')
          .fontSize(Tokens.fontSize.caption)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.danger)
          .borderRadius(Tokens.radius.sm)
          .height(34)
          .onClick(() => {
            this.run(this.vm.logout());
          })

        Blank()

        Button('全部退出')
          .fontSize(Tokens.fontSize.caption)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.danger)
          .borderRadius(Tokens.radius.sm)
          .height(34)
          .onClick(() => {
            this.run(this.vm.logoutAll());
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .margin({ top: Tokens.space.md })
  }

  @Builder
  SensitiveBlock() {
    Column() {
      Column() {
        Text('敏感凭据同步')
          .fontSize(Tokens.fontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
        Text('主机登录密码与 SSH 私钥。出于安全考虑默认关闭。')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .margin({ top: Tokens.space.xs2 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Column() {
        Row() {
          Column() {
            Text('同步主机密码')
              .fontSize(Tokens.fontSize.body)
              .fontColor(Tokens.Color.text)
            Text('将已保存的主机密码加密上传至云端')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.textDim)
              .margin({ top: Tokens.space.xs2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.vm.syncPasswords })
            .selectedColor(Tokens.Color.accent)
            .onChange((on: boolean) => {
              this.vm.setSyncPasswords(on);
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: Tokens.space.sm, bottom: Tokens.space.sm })

        Divider()
          .color(Tokens.Color.border)
          .strokeWidth(0.5)

        Row() {
          Column() {
            Text('同步私钥')
              .fontSize(Tokens.fontSize.body)
              .fontColor(Tokens.Color.text)
            Text('将已导入的 SSH 私钥加密上传至云端')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.textDim)
              .margin({ top: Tokens.space.xs2 })
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Toggle({ type: ToggleType.Switch, isOn: this.vm.syncPrivateKeys })
            .selectedColor(Tokens.Color.accent)
            .onChange((on: boolean) => {
              this.vm.setSyncPrivateKeys(on);
            })
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)
        .padding({ top: Tokens.space.sm, bottom: Tokens.space.sm })
      }
      .width('100%')
      .margin({ top: Tokens.space.xs })

      if (this.vm.rotateHint) {
        Column() {
          Row() {
            Text('建议轮换密钥')
              .fontSize(Tokens.fontSize.body)
              .fontWeight(FontWeight.Bold)
              .fontColor(Tokens.Color.warn)
          }
          Text('已关闭敏感同步：需提供账号密码与同步密码以重新包裹密钥并清空云端历史。')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textDim)
            .lineHeight(18)
            .margin({ top: Tokens.space.xs2, bottom: Tokens.space.sm })

          TextInput({ placeholder: '账号密码', text: this.vm.rotateAccountPassword })
            .type(InputType.Password)
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.text)
            .placeholderColor(Tokens.Color.textFaint)
            .backgroundColor(Tokens.Color.surface)
            .borderRadius(Tokens.radius.sm)
            .height(44)
            .width('100%')
            .onChange((v: string) => {
              this.vm.rotateAccountPassword = v;
            })

          TextInput({ placeholder: '同步密码', text: this.vm.rotatePassword })
            .type(InputType.Password)
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.text)
            .placeholderColor(Tokens.Color.textFaint)
            .backgroundColor(Tokens.Color.surface)
            .borderRadius(Tokens.radius.sm)
            .height(44)
            .width('100%')
            .margin({ top: Tokens.space.xs })
            .onChange((v: string) => {
              this.vm.rotatePassword = v;
            })

          Button('轮换密钥')
            .fontSize(Tokens.fontSize.body)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.Color.onAccent)
            .backgroundColor(Tokens.Color.warn)
            .borderRadius(Tokens.radius.sm)
            .height(40)
            .width('100%')
            .margin({ top: Tokens.space.sm })
            .onClick(() => {
              this.run(this.vm.rotateVault());
            })
        }
        .width('100%')
        .padding(Tokens.space.sm)
        .backgroundColor(Tokens.Color.surfaceHover)
        .borderRadius(Tokens.radius.sm)
        .margin({ top: Tokens.space.xs })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .margin({ top: Tokens.space.md })
  }

  @Builder
  ConflictBlock() {
    Column() {
      Column() {
        Text('配置冲突')
          .fontSize(Tokens.fontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.warn)
        Text('检测到配置冲突：云端版本与本机配置在同条目产生修改冲突，请选择解决方式：')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .margin({ top: Tokens.space.xs2 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Column() {
        ForEach(this.vm.conflicts, (item: SyncConflict) => {
          Row() {
            Column()
              .width(6)
              .height(6)
              .borderRadius(3)
              .backgroundColor(Tokens.Color.warn)
              .margin({ right: Tokens.space.xs })
            Text(this.vm.conflictLabel(item))
              .fontSize(Tokens.fontSize.body)
              .fontColor(Tokens.Color.text)
              .layoutWeight(1)
          }
          .width('100%')
          .padding({ top: Tokens.space.xs, bottom: Tokens.space.xs })
        }, (item: SyncConflict) => `${item.entity}:${item.id}:${item.kind}`)
      }
      .width('100%')
      .padding(Tokens.space.sm)
      .backgroundColor(Tokens.Color.surfaceHover)
      .borderRadius(Tokens.radius.sm)
      .margin({ top: Tokens.space.sm })

      Row() {
        Button('保留本机')
          .fontSize(Tokens.fontSize.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.sm)
          .layoutWeight(1)
          .height(40)
          .onClick(() => {
            this.run(this.vm.resolveKeepLocal());
          })

        Button('使用云端')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .layoutWeight(1)
          .height(40)
          .margin({ left: Tokens.space.xs })
          .onClick(() => {
            this.run(this.vm.resolveUseCloud());
          })
      }
      .width('100%')
      .margin({ top: Tokens.space.md })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .margin({ top: Tokens.space.md })
  }

  @Builder
  DeviceBlock() {
    Column() {
      Column() {
        Text('已授权设备')
          .fontSize(Tokens.fontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      if (this.vm.devices.length === 0) {
        Row() {
          Text('尚无设备列表（同步后刷新）')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textFaint)
        }
        .padding({ top: Tokens.space.sm, bottom: Tokens.space.sm })
      } else {
        Column() {
          ForEach(this.vm.devices, (d: DeviceItem, index: number) => {
            Column() {
              if (index > 0) {
                Divider()
                  .color(Tokens.Color.border)
                  .strokeWidth(0.5)
              }
              Row() {
                Column() {
                  Row() {
                    Text(d.name.length > 0 ? d.name : d.id)
                      .fontSize(Tokens.fontSize.body)
                      .fontColor(Tokens.Color.text)
                      .fontWeight(d.current ? FontWeight.Medium : FontWeight.Regular)

                    if (d.current) {
                      Text('本机')
                        .fontSize(Tokens.fontSize.caption)
                        .fontColor(Tokens.Color.accent)
                        .backgroundColor(Tokens.Color.accentMuted)
                        .borderRadius(Tokens.radius.xs)
                        .padding({
                          left: Tokens.space.xs,
                          right: Tokens.space.xs,
                          top: Tokens.space.xs2,
                          bottom: Tokens.space.xs2
                        })
                        .margin({ left: Tokens.space.xs })
                    }
                  }
                  .alignItems(VerticalAlign.Center)

                  Text(`ID: ${d.id}`)
                    .fontSize(Tokens.fontSize.caption)
                    .fontColor(Tokens.Color.textFaint)
                    .margin({ top: Tokens.space.xs2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                if (!d.current) {
                  Button('撤销')
                    .fontSize(Tokens.fontSize.caption)
                    .fontColor(Tokens.Color.danger)
                    .backgroundColor(Tokens.Color.surface)
                    .border({ width: 1, color: Tokens.Color.danger })
                    .borderRadius(Tokens.radius.xs)
                    .height(32)
                    .padding({ left: Tokens.space.sm, right: Tokens.space.sm })
                    .onClick(() => {
                      this.run(this.vm.revokeDevice(d.id));
                    })
                }
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ top: Tokens.space.sm, bottom: Tokens.space.sm })
            }
            .width('100%')
          }, (d: DeviceItem) => d.id)
        }
        .width('100%')
        .margin({ top: Tokens.space.xs })
      }

      Divider()
        .color(Tokens.Color.border)
        .strokeWidth(0.5)
        .margin({ top: Tokens.space.sm, bottom: Tokens.space.sm })

      Text('重命名本机设备')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
        .margin({ bottom: Tokens.space.xs2 })

      Row() {
        TextInput({ placeholder: '新设备名', text: this.vm.renameDraft })
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .placeholderColor(Tokens.Color.textFaint)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(40)
          .layoutWeight(1)
          .onChange((v: string) => {
            this.vm.renameDraft = v;
          })

        Button('更新')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(40)
          .margin({ left: Tokens.space.xs })
          .onClick(() => {
            this.run(this.vm.renameSelectedDevice(this.vm.deviceId));
          })
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .margin({ top: Tokens.space.md })
  }

  @Builder
  HistoryBlock() {
    Column() {
      Column() {
        Text('历史快照')
          .fontSize(Tokens.fontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
        Text('可随时将云端配置回滚至指定历史版本')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .margin({ top: Tokens.space.xs2 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      if (this.vm.revisions.length === 0) {
        Row() {
          Text('暂无历史版本（同步后生成快照）')
            .fontSize(Tokens.fontSize.caption)
            .fontColor(Tokens.Color.textFaint)
        }
        .padding({ top: Tokens.space.sm, bottom: Tokens.space.sm })
      } else {
        Column() {
          ForEach(this.vm.revisions, (item: RevisionItem, index: number) => {
            Column() {
              if (index > 0) {
                Divider()
                  .color(Tokens.Color.border)
                  .strokeWidth(0.5)
              }
              Row() {
                Column() {
                  Text(`版本 #${item.revision}`)
                    .fontSize(Tokens.fontSize.body)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Tokens.Color.text)
                  Text(item.createdAt)
                    .fontSize(Tokens.fontSize.caption)
                    .fontColor(Tokens.Color.textDim)
                    .margin({ top: Tokens.space.xs2 })
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Button('回滚')
                  .fontSize(Tokens.fontSize.caption)
                  .fontColor(Tokens.Color.text)
                  .backgroundColor(Tokens.Color.surfaceHover)
                  .borderRadius(Tokens.radius.xs)
                  .height(30)
                  .padding({ left: Tokens.space.sm, right: Tokens.space.sm })
                  .onClick(() => {
                    this.run(this.vm.restoreRevision(item.revision));
                  })
              }
              .width('100%')
              .alignItems(VerticalAlign.Center)
              .padding({ top: Tokens.space.sm, bottom: Tokens.space.sm })
            }
            .width('100%')
          }, (item: RevisionItem) => item.revision)
        }
        .width('100%')
        .margin({ top: Tokens.space.xs })
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .margin({ top: Tokens.space.md })
  }

  @Builder
  AccountBlock() {
    Column() {
      Column() {
        Text('账号管理')
          .fontSize(Tokens.fontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      // 修改密码区
      Column() {
        Text('修改登录密码')
          .fontSize(Tokens.fontSize.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.Color.text)
          .margin({ top: Tokens.space.sm, bottom: Tokens.space.xs2 })

        TextInput({ placeholder: '当前登录密码', text: this.vm.currentPassword })
          .type(InputType.Password)
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .placeholderColor(Tokens.Color.textFaint)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(44)
          .width('100%')
          .onChange((v: string) => {
            this.vm.currentPassword = v;
          })

        TextInput({ placeholder: '新登录密码（至少 10 位）', text: this.vm.newPassword })
          .type(InputType.Password)
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .placeholderColor(Tokens.Color.textFaint)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(44)
          .width('100%')
          .margin({ top: Tokens.space.xs })
          .onChange((v: string) => {
            this.vm.newPassword = v;
          })

        Button('更新密码')
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(40)
          .width('100%')
          .margin({ top: Tokens.space.sm })
          .onClick(() => {
            this.run(this.vm.changePassword());
          })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Divider()
        .color(Tokens.Color.border)
        .strokeWidth(0.5)
        .margin({ top: Tokens.space.md, bottom: Tokens.space.md })

      // 注销账号区
      Column() {
        Text('注销账号')
          .fontSize(Tokens.fontSize.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.Color.danger)

        Text('注销将永久删除该账号在云端的所有同步数据与密钥库，该操作不可撤销。')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .lineHeight(18)
          .margin({ top: Tokens.space.xs2, bottom: Tokens.space.xs })

        TextInput({ placeholder: '请输入当前密码以确认注销', text: this.vm.deletePassword })
          .type(InputType.Password)
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .placeholderColor(Tokens.Color.textFaint)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.sm)
          .height(44)
          .width('100%')
          .onChange((v: string) => {
            this.vm.deletePassword = v;
          })

        Button('注销账号')
          .fontSize(Tokens.fontSize.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.danger)
          .borderRadius(Tokens.radius.sm)
          .height(40)
          .width('100%')
          .margin({ top: Tokens.space.sm })
          .onClick(() => {
            this.run(this.vm.deleteAccount());
          })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(Tokens.space.md)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .margin({ top: Tokens.space.md })
  }

  @Builder
  RecoveryBlock() {
    Column() {
      Column() {
        Text('应急恢复密钥')
          .fontSize(Tokens.fontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.warn)
        Text('恢复密钥仅在此处展示一次，请妥善抄写并离线保存。若遗忘同步密码，该密钥是解密云端配置的唯一途径。')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .lineHeight(18)
          .margin({ top: Tokens.space.xs2 })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Column() {
        Text(this.vm.recoveryKey)
          .fontSize(Tokens.fontSize.body)
          .fontColor(Tokens.Color.text)
          .fontWeight(FontWeight.Bold)
          .fontFamily('monospace')
          .letterSpacing(1)
          .copyOption(CopyOptions.LocalDevice)
          .width('100%')
          .textAlign(TextAlign.Center)
      }
      .width('100%')
      .padding(Tokens.space.md)
      .backgroundColor(Tokens.Color.surfaceHover)
      .borderRadius(Tokens.radius.sm)
      .margin({ top: Tokens.space.sm })

      Button('已保存')
        .fontSize(Tokens.fontSize.body)
        .fontWeight(FontWeight.Medium)
        .fontColor(Tokens.Color.onAccent)
        .backgroundColor(Tokens.Color.accent)
        .borderRadius(Tokens.radius.sm)
        .height(42)
        .width('100%')
        .margin({ top: Tokens.space.md })
        .onClick(() => {
          this.vm.ackRecovery();
        })
    }
    .width('100%')
    .padding(Tokens.space.md)
    .margin({ top: Tokens.space.md })
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
  }
}
