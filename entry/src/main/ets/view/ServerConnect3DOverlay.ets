/**
 * ServerConnect3DOverlay —— 服务器连接 3D「Astro 星航员」吉祥物与空间跃迁蒙层。
 *
 * 视觉架构（五层深度排序真 3D 渲染 + ArkUI 3D 透视变换）：
 *   1. 后景层：3D 星际纵深隧道（28 颗三维星尘粒子向镜头透视飞掠，跃迁期拉出星轨流光）；
 *   2. 远端环层：三道正交倾角 3D 能量轨道环的远端半圈（z > 0，位于宇航员背后）；
 *   3. 吉祥物层：赛博宇航员「Astro 星航员」（立体多面体头盔、随偏航/俯仰产生 3D 视差的
 *      HUD 护目镜表情、头顶扩频信号天线、悬浮躯干与双翼推进器尾焰）；
 *   4. 密钥晶石层：SSH 握手与认证阶段悬浮于宇航员胸前的 3D 自转正八面体加密晶石；
 *   5. 近端环层：三道 3D 能量轨道环的近端半圈（z <= 0，穿插遮挡在宇航员前方）与轨道信标。
 *
 * 连接成功收尾（3D 空间穿越 Portal Dive）：
 *   当 warping = true 时，星环与 Astro 向镜头纵深加速冲出放大（scale 1→1.85, rotateX 0→-12°）
 *   并平滑淡出，与底层终端画布的 3D 远端拉近展开无缝衔接。
 */

import { Tokens } from '../theme/Tokens';
import { Motion } from '../theme/Motion';
import {
  AstroPose,
  AstroStageKind,
  AstroStageSpec,
  OctahedronEdge2D,
  ProjectedPoint,
  RingSegment3D,
  StarParticle3D,
  WarpTransform,
  buildOctahedronEdges,
  buildOrbitRingSegments,
  computeAstroPose,
  computeWarpTransform,
  createStarfield,
  getAstroStageSpec,
  projectPoint3D,
  resolveAstroStage,
  stepStarfield
} from '../viewmodel/Astro3DSceneModel';

/** 全页模式 3D 画布边长（vp） */
const SCENE_FULL_SIZE_VP: number = 216;
/** 紧凑模式（侧栏内嵌 / 小分屏）3D 画布边长（vp） */
const SCENE_COMPACT_SIZE_VP: number = 152;
/** 3D 相机焦距与视距 */
const CAMERA_FOV: number = 240;
const CAMERA_DIST: number = 260;
/** 帧间隔（~30fps 流畅合成，兼顾多窗格低功耗） */
const FRAME_INTERVAL_MS: number = 32;
/** 操作按钮高度（vp） */
const ACTION_BTN_HEIGHT_VP: number = 38;

interface StagePillDef {
  index: number;
  label: string;
}

const STAGE_PILLS: StagePillDef[] = [
  { index: 0, label: '建立连接' },
  { index: 1, label: '密钥交换' },
  { index: 2, label: '身份认证' }
];

@Component
export struct ServerConnect3DOverlay {
  @Prop @Watch('onStatePropsChanged') overlayKind: string = 'connecting';
  @Prop @Watch('onStatePropsChanged') sessionState: string = '';
  @Prop @Watch('onStatePropsChanged') titleText: string = '正在连接…';
  @Prop @Watch('onStatePropsChanged') detailText: string = '';
  @Prop @Watch('onWarpingChanged') warping: boolean = false;
  @Prop compact: boolean = false;
  @Prop showCancelReconnect: boolean = false;
  @Prop showReconnectNow: boolean = false;
  @Prop showClose: boolean = false;

  onCancelReconnect: () => void = () => {};
  onReconnectNow: () => void = () => {};
  onClose: () => void = () => {};

  @State private stageSpec: AstroStageSpec = getAstroStageSpec('connecting');
  @State private warpScale: number = 1.0;
  @State private warpRotateXDeg: number = 0;
  @State private warpOpacity: number = 1.0;

  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private readonly stars: StarParticle3D[] = createStarfield(28, 115, 210);
  private timerId: number = -1;
  private timeSec: number = 0;
  private canvasReady: boolean = false;
  private warpProgress: number = 0;

  aboutToAppear(): void {
    this.syncStageSpec();
    this.startLoop();
  }

  aboutToDisappear(): void {
    this.stopLoop();
  }

  private onStatePropsChanged(): void {
    this.syncStageSpec();
    if (this.canvasReady) {
      this.drawScene();
    }
  }

  private onWarpingChanged(): void {
    this.syncStageSpec();
    if (this.warping) {
      this.triggerWarpOut();
    } else {
      this.warpProgress = 0;
      this.warpScale = 1.0;
      this.warpRotateXDeg = 0;
      this.warpOpacity = 1.0;
    }
  }

  private syncStageSpec(): void {
    const kind: AstroStageKind = resolveAstroStage(
      this.overlayKind,
      this.sessionState,
      this.detailText,
      this.warping
    );
    this.stageSpec = getAstroStageSpec(kind);
  }

  /** 启动连接成功时的 3D 空间穿越（Portal Dive）收尾过渡 */
  private triggerWarpOut(): void {
    if (!Motion.enabled) {
      this.warpProgress = 1;
      this.warpOpacity = 0;
      return;
    }
    const target: WarpTransform = computeWarpTransform(1);
    this.getUIContext().animateTo({
      duration: Motion.warpDuration(),
      curve: Curve.FastOutSlowIn
    }, () => {
      this.warpScale = target.overlayScale;
      this.warpRotateXDeg = target.overlayRotateXDeg;
      this.warpOpacity = target.overlayOpacity;
    });
  }

  private startLoop(): void {
    if (this.timerId !== -1 || !Motion.enabled) {
      return;
    }
    this.timerId = setInterval(() => {
      this.timeSec += FRAME_INTERVAL_MS / 1000;
      if (this.warping && this.warpProgress < 1) {
        this.warpProgress = Math.min(1, this.warpProgress + FRAME_INTERVAL_MS / Math.max(1, Motion.WARP_TRANSITION_MS));
      }
      stepStarfield(this.stars, this.stageSpec.starSpeed, 210);
      if (this.canvasReady) {
        this.drawScene();
      }
    }, FRAME_INTERVAL_MS);
  }

  private stopLoop(): void {
    if (this.timerId !== -1) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private sceneSizeVp(): number {
    return this.compact ? SCENE_COMPACT_SIZE_VP : SCENE_FULL_SIZE_VP;
  }

  // ---------------------------------------------------------------- Canvas 真 3D 深度排序渲染

  private drawScene(): void {
    const size: number = this.sceneSizeVp();
    const cx: number = size * 0.5;
    const cy: number = size * 0.5;
    const scaleRatio: number = size / SCENE_FULL_SIZE_VP;
    const spec: AstroStageSpec = this.stageSpec;
    const pose: AstroPose = computeAstroPose(this.timeSec, spec.stage, this.warpProgress);

    this.ctx.clearRect(0, 0, size, size);

    // 0. 中心深空能量星云径向光晕
    const grad = this.ctx.createRadialGradient(cx, cy, 6 * scaleRatio, cx, cy, 98 * scaleRatio);
    grad.addColorStop(0, spec.glowRgba);
    grad.addColorStop(0.65, 'rgba(10, 18, 32, 0.08)');
    grad.addColorStop(1, 'rgba(3, 6, 10, 0.0)');
    this.ctx.fillStyle = grad;
    this.ctx.beginPath();
    this.ctx.arc(cx, cy, 98 * scaleRatio, 0, Math.PI * 2);
    this.ctx.fill();

    // 1. 后景层：3D 星际隧道星尘粒子（透视投影 + 跃迁星轨）
    this.drawStarfieldTunnel(cx, cy, scaleRatio, spec);

    // 计算三道交错倾角的 3D 能量轨道环
    const speed: number = this.timeSec * spec.ringSpeedMultiplier;
    const ring1: RingSegment3D[] = buildOrbitRingSegments(
      78 * scaleRatio, 36,
      1.12 + Math.sin(speed * 0.5) * 0.18,
      speed * 0.9,
      0.35,
      cx, cy, CAMERA_FOV, CAMERA_DIST, 0
    );
    const ring2: RingSegment3D[] = buildOrbitRingSegments(
      62 * scaleRatio, 32,
      -0.85,
      -speed * 1.25,
      0.95 + Math.cos(speed * 0.6) * 0.2,
      cx, cy, CAMERA_FOV, CAMERA_DIST, 1
    );
    const ring3: RingSegment3D[] = buildOrbitRingSegments(
      90 * scaleRatio, 40,
      0.45 + Math.cos(speed * 0.4) * 0.25,
      speed * 0.55,
      -0.75,
      cx, cy, CAMERA_FOV, CAMERA_DIST, 2
    );
    const allSegments: RingSegment3D[] = ring1.concat(ring2).concat(ring3);

    // 2. 远端环层：先绘制位于宇航员背后（avgZ > 0）的半圈轨道弧
    this.drawRingLayer(allSegments, true, spec, scaleRatio);

    // 3. 核心角色层：绘制 3D 悬浮吉祥物「Astro 星航员」
    this.drawAstroMascot(cx, cy, scaleRatio, pose, spec);

    // 4. 密钥晶石层：握手/认证阶段在宇航员右前方绘制 3D 自转正八面体密钥晶石
    if (spec.showKeyCrystal) {
      this.drawKeyCrystal(
        cx + 38 * scaleRatio,
        cy + (pose.bobY - 6) * scaleRatio,
        15 * scaleRatio,
        spec
      );
    }

    // 5. 近端环层：绘制位于宇航员前方（avgZ <= 0）的半圈轨道弧与脉冲信标（形成真实 3D 环绕穿插）
    this.drawRingLayer(allSegments, false, spec, scaleRatio);
  }

  private drawStarfieldTunnel(
    cx: number,
    cy: number,
    scaleRatio: number,
    spec: AstroStageSpec
  ): void {
    // 远端星门透视基准环
    this.ctx.strokeStyle = 'rgba(0, 229, 255, 0.14)';
    this.ctx.lineWidth = 1;
    this.ctx.beginPath();
    this.ctx.arc(cx, cy, 24 * scaleRatio, 0, Math.PI * 2);
    this.ctx.stroke();

    for (let i = 0; i < this.stars.length; i++) {
      const s: StarParticle3D = this.stars[i];
      const curr: ProjectedPoint = projectPoint3D(
        { x: s.x * scaleRatio, y: s.y * scaleRatio, z: s.z },
        0, 0, 0, cx, cy, CAMERA_FOV, CAMERA_DIST
      );
      const prev: ProjectedPoint = projectPoint3D(
        { x: s.x * scaleRatio, y: s.y * scaleRatio, z: s.prevZ },
        0, 0, 0, cx, cy, CAMERA_FOV, CAMERA_DIST
      );
      const alpha: number = Math.max(0.12, Math.min(0.85, (210 - s.z) / 280));
      const color: string = s.colorIndex === 0 ? spec.primaryHex : (s.colorIndex === 1 ? spec.secondaryHex : '#D6F6FF');

      this.ctx.strokeStyle = color;
      this.ctx.globalAlpha = alpha * 0.75;
      this.ctx.lineWidth = Math.max(1, curr.scale * 1.6 * scaleRatio);
      this.ctx.beginPath();
      this.ctx.moveTo(prev.x, prev.y);
      this.ctx.lineTo(curr.x, curr.y);
      this.ctx.stroke();

      this.ctx.fillStyle = color;
      this.ctx.globalAlpha = alpha;
      this.ctx.beginPath();
      this.ctx.arc(curr.x, curr.y, Math.max(1.1, curr.scale * 1.8 * scaleRatio), 0, Math.PI * 2);
      this.ctx.fill();
    }
    this.ctx.globalAlpha = 1.0;
  }

  private drawRingLayer(
    segments: RingSegment3D[],
    behindMascot: boolean,
    spec: AstroStageSpec,
    scaleRatio: number
  ): void {
    const pulsePhase: number = (this.timeSec * 0.85) % 1.0;

    for (let i = 0; i < segments.length; i++) {
      const seg: RingSegment3D = segments[i];
      const isBehind: boolean = seg.avgZ > 0;
      if (isBehind !== behindMascot) {
        continue;
      }

      const ringColor: string = seg.ringIndex === 1 ? spec.secondaryHex : spec.primaryHex;
      // 距离脉冲高光点的环向距离
      let distToPulse: number = Math.abs(seg.t - pulsePhase);
      if (distToPulse > 0.5) {
        distToPulse = 1.0 - distToPulse;
      }
      const isHighlight: boolean = distToPulse < 0.08;

      const depthAlpha: number = behindMascot ? 0.28 : 0.78;
      this.ctx.strokeStyle = ringColor;
      this.ctx.globalAlpha = isHighlight ? Math.min(1.0, depthAlpha + 0.35) : depthAlpha;
      const baseWidth: number = seg.ringIndex === 2 ? 1.1 : 2.0;
      this.ctx.lineWidth = Math.max(0.8, baseWidth * seg.p1.scale * scaleRatio * (isHighlight ? 1.55 : 1.0));

      this.ctx.beginPath();
      this.ctx.moveTo(seg.p1.x, seg.p1.y);
      this.ctx.lineTo(seg.p2.x, seg.p2.y);
      this.ctx.stroke();

      // 在脉冲波峰处绘制 3D 轨道能量信标球
      if (isHighlight && distToPulse < 0.028) {
        this.ctx.fillStyle = '#D6F6FF';
        this.ctx.globalAlpha = behindMascot ? 0.55 : 0.95;
        this.ctx.beginPath();
        this.ctx.arc(seg.p1.x, seg.p1.y, Math.max(2.0, 3.4 * seg.p1.scale * scaleRatio), 0, Math.PI * 2);
        this.ctx.fill();
      }
    }
    this.ctx.globalAlpha = 1.0;
  }

  /**
   * 绘制 3D 赛博宇航员「Astro 星航员」。
   * 通过 yawDeg / pitchDeg 驱动头盔、面罩、背包与躯干的多层视差位移（3D Parallax），
   * 呈现出饱满的立体转动感。
   */
  private drawAstroMascot(
    cx: number,
    cy: number,
    scaleRatio: number,
    pose: AstroPose,
    spec: AstroStageSpec
  ): void {
    const mx: number = cx + pose.swayX * scaleRatio;
    const my: number = cy + (pose.bobY - 4) * scaleRatio;
    // 3D 偏航与俯仰引起的各部件透视视差偏移
    const yawOffset: number = (pose.yawDeg / 14.0) * 5.0 * scaleRatio;
    const pitchOffset: number = (pose.pitchDeg / 6.5) * 3.5 * scaleRatio;

    this.ctx.save();

    // 1. 背部推进器双翼与尾焰（位于身体后方，视差反向移动）
    const packX: number = mx - yawOffset * 0.45;
    const packY: number = my + 12 * scaleRatio - pitchOffset * 0.3;

    // 推进器尾焰脉冲光锥
    const flameLen: number = 22 * pose.jetpackFlame * scaleRatio;
    this.ctx.fillStyle = spec.primaryHex;
    this.ctx.globalAlpha = 0.55;
    this.ctx.beginPath();
    this.ctx.moveTo(packX - 11 * scaleRatio, packY + 18 * scaleRatio);
    this.ctx.lineTo(packX, packY + 18 * scaleRatio + flameLen);
    this.ctx.lineTo(packX + 11 * scaleRatio, packY + 18 * scaleRatio);
    this.ctx.closePath();
    this.ctx.fill();

    // 喷气背包左右立体折翼
    this.ctx.fillStyle = '#122033';
    this.ctx.strokeStyle = spec.primaryHex;
    this.ctx.lineWidth = 1.4 * scaleRatio;
    this.ctx.globalAlpha = 0.92;
    this.ctx.beginPath();
    this.ctx.moveTo(packX - 28 * scaleRatio, packY - 4 * scaleRatio);
    this.ctx.lineTo(packX + 28 * scaleRatio, packY - 4 * scaleRatio);
    this.ctx.lineTo(packX + 22 * scaleRatio, packY + 16 * scaleRatio);
    this.ctx.lineTo(packX - 22 * scaleRatio, packY + 16 * scaleRatio);
    this.ctx.closePath();
    this.ctx.fill();
    this.ctx.stroke();

    // 2. 宇航服立体胸甲躯干
    const bodyX: number = mx + yawOffset * 0.25;
    const bodyY: number = my + 16 * scaleRatio;
    this.ctx.fillStyle = '#182C42';
    this.ctx.strokeStyle = '#7A9BB0';
    this.ctx.lineWidth = 1.5 * scaleRatio;
    this.ctx.beginPath();
    this.ctx.arc(bodyX, bodyY, 17 * scaleRatio, 0, Math.PI * 2);
    this.ctx.fill();
    this.ctx.stroke();

    // 胸前能量核心徽章
    this.ctx.fillStyle = spec.secondaryHex;
    this.ctx.beginPath();
    this.ctx.arc(bodyX + yawOffset * 0.3, bodyY - 1 * scaleRatio, 4.5 * scaleRatio, 0, Math.PI * 2);
    this.ctx.fill();

    // 失重悬浮双臂
    const armWave: number = Math.sin(this.timeSec * 3.2) * 3.5 * scaleRatio;
    this.ctx.fillStyle = '#D6F6FF';
    this.ctx.beginPath();
    this.ctx.arc(bodyX - 21 * scaleRatio, bodyY - 2 * scaleRatio + armWave, 5.2 * scaleRatio, 0, Math.PI * 2);
    this.ctx.arc(bodyX + 21 * scaleRatio, bodyY - 4 * scaleRatio - armWave, 5.2 * scaleRatio, 0, Math.PI * 2);
    this.ctx.fill();

    // 3. 3D 宇航头盔外罩（带立体高光与耳侧通讯舱）
    const headX: number = mx + yawOffset * 0.55;
    const headY: number = my - 10 * scaleRatio + pitchOffset * 0.45;
    const headRadius: number = 25 * scaleRatio;

    // 耳侧 3D 通讯耳机的左右视差（偏航时一侧露出更多）
    this.ctx.fillStyle = spec.primaryHex;
    this.ctx.beginPath();
    this.ctx.arc(headX - headRadius - 2 * scaleRatio, headY, 5.5 * scaleRatio, 0, Math.PI * 2);
    this.ctx.arc(headX + headRadius + 2 * scaleRatio, headY, 5.5 * scaleRatio, 0, Math.PI * 2);
    this.ctx.fill();

    // 头顶信号天线与扩频脉冲环
    const antX: number = headX - yawOffset * 0.2;
    const antTopY: number = headY - headRadius - 11 * scaleRatio;
    this.ctx.strokeStyle = spec.primaryHex;
    this.ctx.lineWidth = 2.0 * scaleRatio;
    this.ctx.beginPath();
    this.ctx.moveTo(headX, headY - headRadius + 2 * scaleRatio);
    this.ctx.lineTo(antX, antTopY);
    this.ctx.stroke();

    this.ctx.fillStyle = spec.secondaryHex;
    this.ctx.beginPath();
    this.ctx.arc(antX, antTopY, 3.6 * scaleRatio, 0, Math.PI * 2);
    this.ctx.fill();

    // 天线发射的 3D 信号波纹环
    if (spec.stage !== 'error' && spec.stage !== 'closed') {
      const waveRadius: number = (5 + pose.antennaPulse * 14) * scaleRatio;
      this.ctx.strokeStyle = spec.primaryHex;
      this.ctx.globalAlpha = Math.max(0.1, 0.75 * (1 - pose.antennaPulse));
      this.ctx.lineWidth = 1.3 * scaleRatio;
      this.ctx.beginPath();
      this.ctx.arc(antX, antTopY, waveRadius, 0, Math.PI * 2);
      this.ctx.stroke();
      this.ctx.globalAlpha = 1.0;
    }

    // 头盔球体主体（深海钛白渐变到科技蓝灰，凸显 3D 球面体积感）
    const helmetGrad = this.ctx.createRadialGradient(
      headX - 8 * scaleRatio,
      headY - 9 * scaleRatio,
      3 * scaleRatio,
      headX,
      headY,
      headRadius
    );
    helmetGrad.addColorStop(0, '#F4FAFC');
    helmetGrad.addColorStop(0.55, '#B3D4DE');
    helmetGrad.addColorStop(1, '#264458');
    this.ctx.fillStyle = helmetGrad;
    this.ctx.strokeStyle = spec.primaryHex;
    this.ctx.lineWidth = 1.8 * scaleRatio;
    this.ctx.beginPath();
    this.ctx.arc(headX, headY, headRadius, 0, Math.PI * 2);
    this.ctx.fill();
    this.ctx.stroke();

    // 4. 曲面 HUD 护目镜面罩（随偏航角产生最大正向视差位移，塑造转头立体感）
    const visorX: number = headX + yawOffset * 0.75;
    const visorY: number = headY + 1 * scaleRatio + pitchOffset * 0.55;
    const visorW: number = 17.5 * scaleRatio;
    const visorH: number = 12.5 * scaleRatio;

    this.ctx.fillStyle = '#050C16';
    this.ctx.strokeStyle = spec.primaryHex;
    this.ctx.lineWidth = 1.5 * scaleRatio;
    this.ctx.beginPath();
    this.ctx.arc(visorX, visorY, visorW, 0, Math.PI * 2);
    this.ctx.fill();
    this.ctx.stroke();

    // 护目镜左上角高光反射弧
    this.ctx.strokeStyle = 'rgba(214, 246, 255, 0.55)';
    this.ctx.lineWidth = 2.0 * scaleRatio;
    this.ctx.beginPath();
    this.ctx.arc(visorX, visorY, visorW - 3.5 * scaleRatio, Math.PI * 1.12, Math.PI * 1.48);
    this.ctx.stroke();

    // 护目镜内动态 HUD 符号表情
    this.ctx.fillStyle = spec.primaryHex;
    this.ctx.font = `bold ${Math.round(11 * scaleRatio)}vp monospace`;
    this.ctx.textAlign = 'center';
    this.ctx.textBaseline = 'middle';
    this.ctx.fillText(pose.visorText, visorX, visorY + 1 * scaleRatio);

    this.ctx.restore();
  }

  /**
   * 绘制悬浮于宇航员前方的 3D 自转正八面体加密晶石（握手 / 认证阶段）。
   */
  private drawKeyCrystal(
    cx: number,
    cy: number,
    radius: number,
    spec: AstroStageSpec
  ): void {
    const edges: OctahedronEdge2D[] = buildOctahedronEdges(
      radius,
      this.timeSec * 1.8,
      this.timeSec * 2.6,
      0.4,
      cx,
      cy,
      CAMERA_FOV,
      CAMERA_DIST
    );
    this.ctx.save();
    for (let i = 0; i < edges.length; i++) {
      const e: OctahedronEdge2D = edges[i];
      const front: boolean = e.avgZ <= 0;
      this.ctx.strokeStyle = front ? spec.secondaryHex : spec.primaryHex;
      this.ctx.globalAlpha = front ? 0.92 : 0.38;
      this.ctx.lineWidth = front ? 1.8 : 1.0;
      this.ctx.beginPath();
      this.ctx.moveTo(e.x1, e.y1);
      this.ctx.lineTo(e.x2, e.y2);
      this.ctx.stroke();
    }
    this.ctx.restore();
  }

  // ---------------------------------------------------------------- 视图树

  build() {
    Column() {
      // 3D 透视舞台容器（底部居中承载阶段状态胶囊，消除固定 x 坐标偏移）
      Stack({ alignContent: Alignment.Bottom }) {
        Canvas(this.ctx)
          .width(this.sceneSizeVp())
          .height(this.sceneSizeVp())
          .onReady(() => {
            this.canvasReady = true;
            this.drawScene();
          })

        // 底部水平居中的阶段状态胶囊徽标
        Row() {
          Text(`Astro · ${this.stageSpec.badgeLabel}`)
            .fontSize(Tokens.fontSize.caption)
            .fontWeight(FontWeight.Medium)
            .fontColor(Tokens.Color.accent)
        }
        .padding({
          left: Tokens.space.sm,
          right: Tokens.space.sm,
          top: Tokens.space.xs2,
          bottom: Tokens.space.xs2
        })
        .backgroundColor(Tokens.Color.surface)
        .borderRadius(Tokens.radius.lg)
        .border({ width: 1, color: Tokens.Color.border })
        .margin({ bottom: Tokens.space.xs2 })
      }
      .width(this.sceneSizeVp())
      .height(this.sceneSizeVp())

      // 三段式连接进度胶囊（建立连接 → 密钥交换 → 身份认证）
      if (this.stageSpec.stepIndex >= 0 && !this.compact) {
        Row({ space: Tokens.space.xs }) {
          ForEach(STAGE_PILLS, (pill: StagePillDef) => {
            Row() {
              Column()
                .width(6)
                .height(6)
                .borderRadius(3)
                .backgroundColor(this.stageSpec.stepIndex >= pill.index
                  ? Tokens.Color.accent : Tokens.Color.textFaint)
                .margin({ right: Tokens.space.xs2 })
              Text(pill.label)
                .fontSize(Tokens.fontSize.caption)
                .fontColor(this.stageSpec.stepIndex >= pill.index
                  ? Tokens.Color.text : Tokens.Color.textFaint)
                .fontWeight(this.stageSpec.stepIndex === pill.index
                  ? FontWeight.Bold : FontWeight.Normal)
            }
            .padding({
              left: Tokens.space.xs,
              right: Tokens.space.xs,
              top: Tokens.space.xs2,
              bottom: Tokens.space.xs2
            })
            .backgroundColor(this.stageSpec.stepIndex === pill.index
              ? Tokens.Color.surfaceHover : Tokens.Color.surface)
            .borderRadius(Tokens.radius.xs)
            .animation(Motion.colorAnim())
          }, (pill: StagePillDef) => `${pill.index}-${this.stageSpec.stepIndex}`)
        }
        .margin({ top: Tokens.space.sm })
      }

      // 主标题与阶段详情副文案
      Text(this.titleText.length > 0 ? this.titleText : '正在准备连接…')
        .fontSize(this.compact ? Tokens.fontSize.body : Tokens.fontSize.title)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.overlayKind === 'error' ? Tokens.Color.danger : Tokens.Color.text)
        .textAlign(TextAlign.Center)
        .margin({ top: Tokens.space.sm })

      if (this.detailText.length > 0) {
        Text(this.detailText)
          .fontSize(Tokens.fontSize.caption)
          .fontColor(Tokens.Color.textDim)
          .textAlign(TextAlign.Center)
          .margin({ top: Tokens.space.xs2 })
      }

      // 操作按钮组（取消重连 / 立即重连 / 关闭）
      if (this.showCancelReconnect || this.showReconnectNow || this.showClose) {
        Row({ space: Tokens.space.sm }) {
          if (this.showCancelReconnect) {
            Button('取消重连')
              .fontSize(Tokens.fontSize.body)
              .fontColor(Tokens.Color.text)
              .backgroundColor(Tokens.Color.surfaceHover)
              .borderRadius(Tokens.radius.sm)
              .height(ACTION_BTN_HEIGHT_VP)
              .clickEffect(Motion.pressEffect())
              .onClick(() => {
                this.onCancelReconnect();
              })
          }
          if (this.showReconnectNow) {
            Button(this.overlayKind === 'closed' ? '重新连接' : '立即重连')
              .fontSize(Tokens.fontSize.body)
              .fontWeight(FontWeight.Medium)
              .fontColor(Tokens.Color.onAccent)
              .backgroundColor(Tokens.Color.accent)
              .borderRadius(Tokens.radius.sm)
              .height(ACTION_BTN_HEIGHT_VP)
              .clickEffect(Motion.pressEffect())
              .onClick(() => {
                this.onReconnectNow();
              })
          }
          if (this.showClose) {
            Button('关闭')
              .fontSize(Tokens.fontSize.body)
              .fontColor(Tokens.Color.text)
              .backgroundColor(Tokens.Color.surfaceHover)
              .borderRadius(Tokens.radius.sm)
              .height(ACTION_BTN_HEIGHT_VP)
              .clickEffect(Motion.pressEffect())
              .onClick(() => {
                this.onClose();
              })
          }
        }
        .margin({ top: Tokens.space.md })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding(Tokens.space.lg)
    .scale({ x: this.warpScale, y: this.warpScale })
    .rotate({
      x: 1,
      y: 0,
      z: 0,
      angle: this.warpRotateXDeg,
      perspective: Motion.PERSPECTIVE_VP
    })
    .opacity(this.warpOpacity)
  }
}
