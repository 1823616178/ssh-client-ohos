/**
 * ConfigManagerPage —— 配置管理中心。
 *
 * 集中呈现与管理本地数据库中的所有配置项：
 *   - 主机列表 (HostProfile)
 *   - 主机分组 (HostGroup)
 *   - 端口转发 (PortForwardRule)
 *   - 外观主题 (AppearanceProfile)
 *   - 命令片段 (Snippet)
 *   - Known Hosts 指纹记录 (KnownHostEntry)
 *
 * 支持全文搜索、分类查看、增删管理，并清晰标识「云端同步」与「本机专有」属性。
 */

import { router } from '@kit.ArkUI';
import {
  AppearanceProfile,
  HostGroup,
  HostProfile,
  KnownHostEntry,
  PortForwardRule,
  Snippet
} from '../common/model/models';
import { Tokens } from '../theme/Tokens';
import { PageHeader, PageHeaderAction } from '../view/PageHeader';
import { ConfigManagerViewModel, ConfigTabType } from '../viewmodel/ConfigManagerViewModel';
import { Logger } from '../common/utils/Logger';
import { previewSnippet, snippetVarsOf } from '../common/utils/SnippetVars';
import { SnippetSendHub } from '../view/terminal/SnippetSendHub';

const LOG_TAG: string = 'ConfigManagerPage';
/** 行内次级按钮高度（vp）：Token 表无「按钮高度」项，页内统一取值 */
const ACTION_BTN_HEIGHT_VP: number = 32;

/**
 * 必须是 @ComponentV2：ConfigManagerViewModel 是 @ObservedV2 + @Trace，
 * V1 的 @Component 订阅不到它（旧实现的 uiSeq 甚至没在 build 里被读过，整页是静止的）。
 * V2 组件对 @Trace 字段原生响应，故 vm 用普通成员即可，无需任何手动刷新。
 */
@Entry
@ComponentV2
struct ConfigManagerPage {
  private readonly vm: ConfigManagerViewModel = new ConfigManagerViewModel();
  @Local private newGroupName: string = '';
  @Local private showAddGroupDialog: boolean = false;
  @Local private newSnippetName: string = '';
  @Local private newSnippetContent: string = '';
  @Local private showAddSnippetDialog: boolean = false;

  onPageShow(): void {
    this.vm.reload();
  }

  aboutToAppear(): void {
    this.vm.reload();
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (err) {
      Logger.warn(`Toast 弹出失败: ${JSON.stringify(err)}`, LOG_TAG);
    }
  }

  /** 片段发送前预览：无会话时提示占位符；有终端会话时展示原文（发送时按主机替换） */
  private snippetPreview(content: string): string {
    const hub = SnippetSendHub.get();
    if (!hub.available) {
      return previewSnippet(content, snippetVarsOf('(未连接)', '(host)', '(user)', 22));
    }
    return content;
  }

  /** U10：发送片段到聚焦终端（TerminalViewModel 经 SnippetSendHub 注册的出口） */
  private sendSnippet(snippet: Snippet): void {
    const hub = SnippetSendHub.get();
    if (!hub.available) {
      this.toast('请先打开并聚焦一个终端会话');
      return;
    }
    // Hub 契约：传片段原文；${host}/${user} 等在 TerminalViewModel.sendSnippet
    // 内按聚焦会话的主机配置替换后补 \n 写入终端。
    const ok: boolean = hub.send(snippet.content, snippet.content);
    this.toast(ok ? `已发送「${snippet.name}」到聚焦终端` : '发送失败：终端通道未就绪');
  }

  build() {
    const headerActions: PageHeaderAction[] = [
      {
        label: '刷新',
        onClick: (): void => {
          this.vm.reload();
          this.toast('配置数据已刷新');
        }
      }
    ];
    Column() {
      PageHeader({
        title: '配置中心',
        subtitle: '主机、分组、转发与本机配置',
        actions: headerActions
      })

      // 同步边界说明条
      Row() {
        Column()
          .width(Tokens.space.xs2)
          .height(Tokens.space.xl)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.xs)
          .margin({ right: Tokens.space.xs })
        Text('主机、分组、端口转发会自动参与云同步；外观主题、命令片段、主机指纹属于本机专有配置。')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .layoutWeight(1)
          .lineHeight(17)
      }
      .width('100%')
      .padding(Tokens.space.sm)
      .backgroundColor(Tokens.Color.surface)
      .borderRadius(Tokens.radius.sm)
      .margin({ top: Tokens.space.sm, left: Tokens.space.md, right: Tokens.space.md })

      // 搜索框：实时过滤当前配置（名称 / IP / 端口 / 内容）
      TextInput({ placeholder: '搜索配置 (名称 / IP / 用户 / 端口 / 内容)...', text: this.vm.searchText })
        .fontSize(Tokens.fontSize.body)
        .fontColor(Tokens.Color.text)
        .placeholderColor(Tokens.Color.textFaint)
        .backgroundColor(Tokens.Color.surface)
        .borderRadius(Tokens.radius.sm)
        .height(42)
        .width('100%')
        .margin({ top: Tokens.space.sm, left: Tokens.space.md, right: Tokens.space.md })
        .onChange((value: string) => {
          this.vm.setSearchText(value);
        })

      // 横向滚动 Tab 栏
      Scroll() {
        Row() {
          this.TabButton('hosts', `主机 (${this.vm.hosts.length})`, '同步')
          this.TabButton('groups', `分组 (${this.vm.groups.length})`, '同步')
          this.TabButton('forwards', `转发 (${this.vm.forwards.length})`, '同步')
          this.TabButton('themes', `主题 (${this.vm.appearances.length})`, '本机')
          this.TabButton('snippets', `片段 (${this.vm.snippets.length})`, '本机')
          this.TabButton('knownHosts', `指纹 (${this.vm.knownHosts.length})`, '本机')
        }
        .padding({ top: Tokens.space.xs, bottom: Tokens.space.xs, left: Tokens.space.md })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
      .margin({ top: Tokens.space.xs })

      // 内容列表区
      Scroll() {
        Column() {
          if (this.vm.currentTab === 'hosts') {
            this.HostsSection()
          } else if (this.vm.currentTab === 'groups') {
            this.GroupsSection()
          } else if (this.vm.currentTab === 'forwards') {
            this.ForwardsSection()
          } else if (this.vm.currentTab === 'themes') {
            this.ThemesSection()
          } else if (this.vm.currentTab === 'snippets') {
            this.SnippetsSection()
          } else if (this.vm.currentTab === 'knownHosts') {
            this.KnownHostsSection()
          }
        }
        .width('100%')
        .padding({ left: Tokens.space.md, right: Tokens.space.md, bottom: Tokens.space.md })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
      .margin({ top: Tokens.space.xs })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Tokens.Color.appBg)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP, SafeAreaEdge.BOTTOM])
  }

  @Builder
  TabButton(tab: ConfigTabType, label: string, badge: string) {
    Row() {
      Text(badge)
        .fontSize(Tokens.fontSize.caption)
        .fontColor(this.vm.currentTab === tab ? Tokens.Color.onAccent : Tokens.Color.textDim)
        .margin({ right: Tokens.space.xs2 })
      Text(label)
        .fontSize(Tokens.fontSize.body)
        .fontWeight(this.vm.currentTab === tab ? FontWeight.Bold : FontWeight.Regular)
        .fontColor(this.vm.currentTab === tab ? Tokens.Color.onAccent : Tokens.Color.textDim)
    }
    .height(Tokens.space.xl)
    .padding({ left: Tokens.space.md, right: Tokens.space.md })
    .backgroundColor(this.vm.currentTab === tab ? Tokens.Color.accent : Tokens.Color.surface)
    .borderRadius(Tokens.radius.sm)
    .margin({ right: Tokens.space.xs })
    .onClick(() => {
      this.vm.setTab(tab);
    })
  }

  // ---------------------------------------------------------------- 主机列表
  @Builder
  HostsSection() {
    Column() {
      Row() {
        Text('已配置的主机')
          .fontSize(Tokens.fontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
        Blank()
        Button('+ 新建主机')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.sm)
          .height(ACTION_BTN_HEIGHT_VP)
          .onClick(() => {
            router.pushUrl({ url: 'pages/HostEditPage' });
          })
      }
      .width('100%')
      .margin({ bottom: Tokens.space.sm })

      if (this.vm.hosts.length === 0) {
        this.EmptyCard('暂无主机', '点击右上角「+ 新建主机」或通过云同步同步配置')
      } else if (this.vm.filteredHosts().length === 0) {
        this.EmptyCard('无匹配主机', `未找到与「${this.vm.searchText.trim()}」相关的主机配置`)
      } else {
        ForEach(this.vm.filteredHosts(), (host: HostProfile) => {
          Column() {
            Row() {
              Column() {
                Text(host.name.length > 0 ? host.name : host.host)
                  .fontSize(Tokens.fontSize.title)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Tokens.Color.text)

                Text(`${host.username}@${host.host}:${host.port}`)
                  .fontSize(Tokens.fontSize.caption)
                  .fontColor(Tokens.Color.textDim)
                  .margin({ top: Tokens.space.xs2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              // 认证方式与分组徽标
              Column() {
                Text(host.authType === 'password' ? '密码认证' : (host.authType === 'key' ? '密钥认证' : 'Agent'))
                  .fontSize(Tokens.fontSize.caption)
                  .fontColor(Tokens.Color.accent)
                  .backgroundColor(Tokens.Color.accentMuted)
                  .borderRadius(Tokens.radius.xs)
                  .padding({ left: Tokens.space.xs, right: Tokens.space.xs, top: 2, bottom: 2 })

                if (host.groupId !== null && this.vm.groupNameMap[host.groupId] !== undefined) {
                  Text(this.vm.groupNameMap[host.groupId])
                    .fontSize(Tokens.fontSize.caption)
                    .fontColor(Tokens.Color.textFaint)
                    .backgroundColor(Tokens.Color.surfaceHover)
                    .borderRadius(Tokens.radius.xs)
                    .padding({ left: Tokens.space.xs, right: Tokens.space.xs, top: 2, bottom: 2 })
                    .margin({ top: Tokens.space.xs2 })
                }
              }
              .alignItems(HorizontalAlign.End)
            }
            .width('100%')

            Divider()
              .color(Tokens.Color.border)
              .strokeWidth(0.5)
              .margin({ top: Tokens.space.sm, bottom: Tokens.space.sm })

            Row() {
              Text(`心跳 ${host.keepalive}秒 · 终端 ${host.termType}`)
                .fontSize(Tokens.fontSize.caption)
                .fontColor(Tokens.Color.textFaint)

              Blank()

              Button('编辑')
                .fontSize(Tokens.fontSize.caption)
                .fontColor(Tokens.Color.text)
                .backgroundColor(Tokens.Color.surfaceHover)
                .borderRadius(Tokens.radius.sm)
                .height(ACTION_BTN_HEIGHT_VP)
                .margin({ right: Tokens.space.xs })
                .onClick(() => {
                  const params: Record<string, Object> = {};
                  params['hostId'] = host.id;
                  router.pushUrl({ url: 'pages/HostEditPage', params: params });
                })

              Button('删除')
                .fontSize(Tokens.fontSize.caption)
                .fontColor(Tokens.Color.danger)
                .backgroundColor(Tokens.Color.surfaceHover)
                .borderRadius(Tokens.radius.sm)
                .height(ACTION_BTN_HEIGHT_VP)
                .onClick(() => {
                  if (this.vm.deleteHost(host.id)) {
                    this.toast('已删除主机');
                  }
                })
            }
            .width('100%')
          }
          .padding(Tokens.space.md)
          .backgroundColor(Tokens.Color.surface)
          .borderRadius(Tokens.radius.md)
          .width('100%')
          .margin({ bottom: Tokens.space.sm })
        }, (host: HostProfile) => host.id)
      }
    }
    .width('100%')
  }

  // ---------------------------------------------------------------- 分组列表
  @Builder
  GroupsSection() {
    Column() {
      Row() {
        Text('主机分组')
          .fontSize(Tokens.fontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
        Blank()
        Button('+ 新建分组')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.sm)
          .height(ACTION_BTN_HEIGHT_VP)
          .onClick(() => {
            this.showAddGroupDialog = !this.showAddGroupDialog;
          })
      }
      .width('100%')
      .margin({ bottom: Tokens.space.sm })

      if (this.showAddGroupDialog) {
        Column() {
          Text('新建主机分组')
            .fontSize(Tokens.fontSize.body)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.Color.text)

          TextInput({ placeholder: '请输入分组名称 (如 开发环境 / 生产服务器)', text: this.newGroupName })
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.text)
            .backgroundColor(Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.sm)
            .height(40)
            .width('100%')
            .margin({ top: Tokens.space.xs })
            .onChange((v: string) => {
              this.newGroupName = v;
            })

          Row() {
            Blank()
            Button('取消')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.textDim)
              .backgroundColor(Tokens.Color.surfaceHover)
              .borderRadius(Tokens.radius.sm)
              .height(ACTION_BTN_HEIGHT_VP)
              .margin({ right: Tokens.space.xs })
              .onClick(() => {
                this.showAddGroupDialog = false;
                this.newGroupName = '';
              })

            Button('确定创建')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.onAccent)
              .backgroundColor(Tokens.Color.accent)
              .borderRadius(Tokens.radius.sm)
              .height(ACTION_BTN_HEIGHT_VP)
              .onClick(() => {
                if (this.vm.createGroup(this.newGroupName)) {
                  this.toast('分组创建成功');
                  this.newGroupName = '';
                  this.showAddGroupDialog = false;
                } else {
                  this.toast('请输入有效的分组名称');
                }
              })
          }
          .width('100%')
          .margin({ top: Tokens.space.sm })
        }
        .padding(Tokens.space.md)
        .backgroundColor(Tokens.Color.surface)
        .borderRadius(Tokens.radius.md)
        .width('100%')
        .margin({ bottom: Tokens.space.sm })
      }

      if (this.vm.groups.length === 0) {
        this.EmptyCard('暂无分组', '点击「+ 新建分组」将主机按环境或业务分类管理')
      } else if (this.vm.filteredGroups().length === 0) {
        this.EmptyCard('无匹配分组', `未找到与「${this.vm.searchText.trim()}」相关的分组`)
      } else {
        ForEach(this.vm.filteredGroups(), (group: HostGroup) => {
          Row() {
            Column() {
              Text(group.name)
                .fontSize(Tokens.fontSize.title)
                .fontWeight(FontWeight.Bold)
                .fontColor(Tokens.Color.text)

              Text(`包含 ${this.vm.getGroupHostCount(group.id)} 台主机 · 排序号: ${group.order}`)
                .fontSize(Tokens.fontSize.caption)
                .fontColor(Tokens.Color.textDim)
                .margin({ top: Tokens.space.xs2 })
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)

            Button('删除')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.danger)
              .backgroundColor(Tokens.Color.surfaceHover)
              .borderRadius(Tokens.radius.sm)
              .height(ACTION_BTN_HEIGHT_VP)
              .onClick(() => {
                if (this.vm.deleteGroup(group.id)) {
                  this.toast('已删除分组');
                }
              })
          }
          .width('100%')
          .padding(Tokens.space.md)
          .backgroundColor(Tokens.Color.surface)
          .borderRadius(Tokens.radius.md)
          .margin({ bottom: Tokens.space.sm })
        }, (group: HostGroup) => group.id)
      }
    }
    .width('100%')
  }

  // ---------------------------------------------------------------- 端口转发
  @Builder
  ForwardsSection() {
    Column() {
      Row() {
        Text('端口转发隧道')
          .fontSize(Tokens.fontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
        Blank()
      }
      .width('100%')
      .margin({ bottom: Tokens.space.sm })

      if (this.vm.forwards.length === 0) {
        this.EmptyCard('暂无端口转发规则', '在主机编辑页面中可配置本地(-L)/远程(-R)/动态(-D)端口转发')
      } else if (this.vm.filteredForwards().length === 0) {
        this.EmptyCard('无匹配端口转发', `未找到与「${this.vm.searchText.trim()}」相关的端口转发规则`)
      } else {
        ForEach(this.vm.filteredForwards(), (rule: PortForwardRule) => {
          Column() {
            Row() {
              Text(rule.type.toUpperCase())
                .fontSize(Tokens.fontSize.caption)
                .fontWeight(FontWeight.Bold)
                .fontColor(Tokens.Color.onAccent)
                .backgroundColor(Tokens.Color.accent)
                .borderRadius(Tokens.radius.xs)
                .padding({ left: Tokens.space.xs, right: Tokens.space.xs, top: 2, bottom: 2 })

              Column() {
                Text(rule.type === 'dynamic' ? `SOCKS5 :${rule.localPort}` : `${rule.bindAddress}:${rule.localPort} → ${rule.remoteHost}:${rule.remotePort}`)
                  .fontSize(Tokens.fontSize.body)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Tokens.Color.text)

                Text(`所属主机: ${this.vm.hostNameMap[rule.hostId] ?? rule.hostId}`)
                  .fontSize(Tokens.fontSize.caption)
                  .fontColor(Tokens.Color.textDim)
                  .margin({ top: Tokens.space.xs2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              .margin({ left: Tokens.space.sm })

              Toggle({ type: ToggleType.Switch, isOn: rule.enabled })
                .onChange((isOn: boolean) => {
                  this.vm.toggleForward(rule.id, isOn);
                })
            }
            .width('100%')

            Divider()
              .color(Tokens.Color.border)
              .strokeWidth(0.5)
              .margin({ top: Tokens.space.sm, bottom: Tokens.space.sm })

            Row() {
              Text(rule.enabled ? '● 规则已启用' : '○ 规则已禁用')
                .fontSize(Tokens.fontSize.caption)
                .fontColor(rule.enabled ? Tokens.Color.success : Tokens.Color.textFaint)

              Blank()

              Button('删除')
                .fontSize(Tokens.fontSize.caption)
                .fontColor(Tokens.Color.danger)
                .backgroundColor(Tokens.Color.surfaceHover)
                .borderRadius(Tokens.radius.sm)
                .height(ACTION_BTN_HEIGHT_VP)
                .onClick(() => {
                  if (this.vm.deleteForward(rule.id)) {
                    this.toast('已删除端口转发规则');
                  }
                })
            }
            .width('100%')
          }
          .padding(Tokens.space.md)
          .backgroundColor(Tokens.Color.surface)
          .borderRadius(Tokens.radius.md)
          .width('100%')
          .margin({ bottom: Tokens.space.sm })
        }, (rule: PortForwardRule) => rule.id)
      }
    }
    .width('100%')
  }

  // ---------------------------------------------------------------- 外观主题
  @Builder
  ThemesSection() {
    Column() {
      Row() {
        Text('终端外观主题')
          .fontSize(Tokens.fontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
        Blank()
        Button('外观页')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.sm)
          .height(ACTION_BTN_HEIGHT_VP)
          .onClick(() => {
            router.pushUrl({ url: 'pages/AppearancePage' });
          })
      }
      .width('100%')
      .margin({ bottom: Tokens.space.sm })

      if (this.vm.appearances.length === 0) {
        this.EmptyCard('暂无自定义主题', '系统默认使用 Harmony Dark 预设主题')
      } else if (this.vm.filteredAppearances().length === 0) {
        this.EmptyCard('无匹配外观主题', `未找到与「${this.vm.searchText.trim()}」相关的主题`)
      } else {
        ForEach(this.vm.filteredAppearances(), (app: AppearanceProfile) => {
          Column() {
            Row() {
              Column() {
                Text(app.name)
                  .fontSize(Tokens.fontSize.title)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Tokens.Color.text)

                Text(`字号: ${app.fontSize}vp · 行高: ${app.lineHeight} · 光标: ${app.cursorStyle}`)
                  .fontSize(Tokens.fontSize.caption)
                  .fontColor(Tokens.Color.textDim)
                  .margin({ top: Tokens.space.xs2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              if (this.vm.appearances.length > 1) {
                Button('删除')
                  .fontSize(Tokens.fontSize.caption)
                  .fontColor(Tokens.Color.danger)
                  .backgroundColor(Tokens.Color.surfaceHover)
                  .borderRadius(Tokens.radius.sm)
                  .height(ACTION_BTN_HEIGHT_VP)
                  .onClick(() => {
                    if (this.vm.deleteAppearance(app.id)) {
                      this.toast('已删除外观主题');
                    }
                  })
              }
            }
            .width('100%')

            // 调色板预览条
            Row() {
              ForEach(app.palette.slice(0, 16), (color: string) => {
                Column()
                  .height(14)
                  .layoutWeight(1)
                  .backgroundColor(color)
              })
            }
            .width('100%')
            .borderRadius(Tokens.radius.xs)
            .margin({ top: Tokens.space.sm })
          }
          .padding(Tokens.space.md)
          .backgroundColor(Tokens.Color.surface)
          .borderRadius(Tokens.radius.md)
          .width('100%')
          .margin({ bottom: Tokens.space.sm })
        }, (app: AppearanceProfile) => app.id)
      }
    }
    .width('100%')
  }

  // ---------------------------------------------------------------- 命令片段
  @Builder
  SnippetsSection() {
    Column() {
      Row() {
        Text('命令片段')
          .fontSize(Tokens.fontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
        Blank()
        Button('+ 新建片段')
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.onAccent)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.sm)
          .height(ACTION_BTN_HEIGHT_VP)
          .onClick(() => {
            this.showAddSnippetDialog = !this.showAddSnippetDialog;
          })
      }
      .width('100%')
      .margin({ bottom: Tokens.space.sm })

      if (this.showAddSnippetDialog) {
        Column() {
          Text('新建常用命令片段')
            .fontSize(Tokens.fontSize.body)
            .fontWeight(FontWeight.Bold)
            .fontColor(Tokens.Color.text)

          TextInput({ placeholder: '片段名称 (如 查看系统状态 / 重启 Nginx)', text: this.newSnippetName })
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.text)
            .backgroundColor(Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.sm)
            .height(40)
            .width('100%')
            .margin({ top: Tokens.space.xs })
            .onChange((v: string) => {
              this.newSnippetName = v;
            })

          TextArea({ placeholder: '命令内容 (如 top -b -n 1 | head -n 20)', text: this.newSnippetContent })
            .fontSize(Tokens.fontSize.body)
            .fontColor(Tokens.Color.text)
            .backgroundColor(Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.sm)
            .height(72)
            .width('100%')
            .margin({ top: Tokens.space.xs })
            .onChange((v: string) => {
              this.newSnippetContent = v;
            })

          Row() {
            Blank()
            Button('取消')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.textDim)
              .backgroundColor(Tokens.Color.surfaceHover)
              .borderRadius(Tokens.radius.sm)
              .height(ACTION_BTN_HEIGHT_VP)
              .margin({ right: Tokens.space.xs })
              .onClick(() => {
                this.showAddSnippetDialog = false;
                this.newSnippetName = '';
                this.newSnippetContent = '';
              })

            Button('确定创建')
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.onAccent)
              .backgroundColor(Tokens.Color.accent)
              .borderRadius(Tokens.radius.sm)
              .height(ACTION_BTN_HEIGHT_VP)
              .onClick(() => {
                if (this.vm.createSnippet(this.newSnippetName, this.newSnippetContent)) {
                  this.toast('命令片段创建成功');
                  this.newSnippetName = '';
                  this.newSnippetContent = '';
                  this.showAddSnippetDialog = false;
                } else {
                  this.toast('请填写完整名称与命令内容');
                }
              })
          }
          .width('100%')
          .margin({ top: Tokens.space.sm })
        }
        .padding(Tokens.space.md)
        .backgroundColor(Tokens.Color.surface)
        .borderRadius(Tokens.radius.md)
        .width('100%')
        .margin({ bottom: Tokens.space.sm })
      }

      if (this.vm.snippets.length === 0) {
        this.EmptyCard('暂无命令片段', '创建常用命令片段后可在终端界面中一键发送执行')
      } else if (this.vm.filteredSnippets().length === 0) {
        this.EmptyCard('无匹配命令片段', `未找到与「${this.vm.searchText.trim()}」相关的命令片段`)
      } else {
        ForEach(this.vm.filteredSnippets(), (snippet: Snippet) => {
          Column() {
            Row() {
              Text(snippet.name)
                .fontSize(Tokens.fontSize.title)
                .fontWeight(FontWeight.Bold)
                .fontColor(Tokens.Color.text)
                .layoutWeight(1)

              Button('发送')
                .fontSize(Tokens.fontSize.caption)
                .fontColor(Tokens.Color.onAccent)
                .backgroundColor(Tokens.Color.accent)
                .borderRadius(Tokens.radius.sm)
                .height(ACTION_BTN_HEIGHT_VP)
                .margin({ right: Tokens.space.xs })
                .onClick(() => {
                  this.sendSnippet(snippet);
                })
              Button('删除')
                .fontSize(Tokens.fontSize.caption)
                .fontColor(Tokens.Color.danger)
                .backgroundColor(Tokens.Color.surfaceHover)
                .borderRadius(Tokens.radius.sm)
                .height(ACTION_BTN_HEIGHT_VP)
                .onClick(() => {
                  if (this.vm.deleteSnippet(snippet.id)) {
                    this.toast('已删除命令片段');
                  }
                })
            }
            .width('100%')

            Row() {
              Text(this.snippetPreview(snippet.content))
                .fontSize(Tokens.fontSize.caption)
                .fontColor(Tokens.Color.accent)
                .fontFamily('monospace')
                .maxLines(3)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding(Tokens.space.sm)
            .backgroundColor(Tokens.Color.surfaceHover)
            .borderRadius(Tokens.radius.sm)
            .margin({ top: Tokens.space.xs })
          }
          .padding(Tokens.space.md)
          .backgroundColor(Tokens.Color.surface)
          .borderRadius(Tokens.radius.md)
          .width('100%')
          .margin({ bottom: Tokens.space.sm })
        }, (snippet: Snippet) => snippet.id)
      }
    }
    .width('100%')
  }

  // ---------------------------------------------------------------- Known Hosts
  @Builder
  KnownHostsSection() {
    Column() {
      Row() {
        Text('已信任的主机密钥指纹')
          .fontSize(Tokens.fontSize.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(Tokens.Color.text)
        Blank()
      }
      .width('100%')
      .margin({ bottom: Tokens.space.sm })

      if (this.vm.knownHosts.length === 0) {
        this.EmptyCard('暂无主机指纹记录', '首次连接并确认主机指纹后自动记录')
      } else if (this.vm.filteredKnownHosts().length === 0) {
        this.EmptyCard('无匹配主机指纹', `未找到与「${this.vm.searchText.trim()}」相关的指纹记录`)
      } else {
        ForEach(this.vm.filteredKnownHosts(), (entry: KnownHostEntry) => {
          Column() {
            Row() {
              Column() {
                Text(`${entry.host}:${entry.port}`)
                  .fontSize(Tokens.fontSize.body)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Tokens.Color.text)

                Text(`类型: ${entry.keyType} · 首次记录: ${entry.addedAt}`)
                  .fontSize(Tokens.fontSize.caption)
                  .fontColor(Tokens.Color.textDim)
                  .margin({ top: Tokens.space.xs2 })
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)

              Button('删除')
                .fontSize(Tokens.fontSize.caption)
                .fontColor(Tokens.Color.danger)
                .backgroundColor(Tokens.Color.surfaceHover)
                .borderRadius(Tokens.radius.sm)
                .height(ACTION_BTN_HEIGHT_VP)
                .onClick(() => {
                  if (this.vm.deleteKnownHost(entry.id)) {
                    this.toast('已删除主机指纹');
                  }
                })
            }
            .width('100%')

            Text(entry.fingerprint)
              .fontSize(Tokens.fontSize.caption)
              .fontColor(Tokens.Color.textFaint)
              .fontFamily('monospace')
              .margin({ top: Tokens.space.xs })
          }
          .padding(Tokens.space.md)
          .backgroundColor(Tokens.Color.surface)
          .borderRadius(Tokens.radius.md)
          .width('100%')
          .margin({ bottom: Tokens.space.sm })
        }, (entry: KnownHostEntry) => entry.id)
      }
    }
    .width('100%')
  }

  @Builder
  EmptyCard(title: string, hint: string) {
    Column() {
      Text(title)
        .fontSize(Tokens.fontSize.body)
        .fontWeight(FontWeight.Bold)
        .fontColor(Tokens.Color.textDim)

      Text(hint)
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textFaint)
        .textAlign(TextAlign.Center)
        .margin({ top: Tokens.space.xs2 })
    }
    .width('100%')
    .padding(Tokens.space.xl)
    .backgroundColor(Tokens.Color.surface)
    .borderRadius(Tokens.radius.md)
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
  }
}
