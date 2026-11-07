/**
 * AstroSplashOverlay —— 应用冷启动 3D 吉祥物「Astro 星航员」开屏动画弹层。
 *
 * 视觉编排（三幕式真 3D 吉祥物主秀）：
 *   1. 第一幕 · 星门点火：42 颗 3D 星尘粒子向镜头加速飞掠，三道正交倾角 3D 能量轨道环
 *      自中心急速展开，吉祥物「Astro 星航员」携双翼推进器尾焰自深空弹性跃出；
 *   2. 第二幕 · 领航致意：Astro 悬停于星环中央并抬起右臂向用户挥手致意，两枚 3D 正八面体
 *      加密密钥晶石在宇航员前后方沿三维轨道公转穿插，径向能量冲击波向外扩散；
 *   3. 第三幕 · 空间跃迁揭幕（Portal Dive）：引擎自检进度条满格后，Astro 面罩切换为跃迁高光，
 *      整层开屏以 3D 透视纵深向镜头冲刺放大淡出，平滑揭幕底层首页工作台（支持轻触随时跳过）。
 */

import { Tokens } from '../theme/Tokens';
import { Motion } from '../theme/Motion';
import {
  AstroSplashFrame,
  OctahedronEdge2D,
  ProjectedPoint,
  RingSegment3D,
  StarParticle3D,
  WarpTransform,
  buildOctahedronEdges,
  buildOrbitRingSegments,
  computeAstroSplashFrame,
  computeWarpTransform,
  createStarfield,
  projectPoint3D,
  stepStarfield
} from '../viewmodel/Astro3DSceneModel';

/** 开屏 3D 舞台画布边长（vp） */
const SPLASH_STAGE_SIZE_VP: number = 252;
/** 底部能量进度条总宽（vp） */
const ENERGY_BAR_WIDTH_VP: number = 196;
/** 底部能量进度条高度（vp） */
const ENERGY_BAR_HEIGHT_VP: number = 5;
/** 3D 相机焦距与视距 */
const CAMERA_FOV: number = 250;
const CAMERA_DIST: number = 265;
/** 帧间隔（~30fps 稳定帧率） */
const FRAME_INTERVAL_MS: number = 30;

@Component
export struct AstroSplashOverlay {
  /** 开屏跃迁开始时通知父页同步执行首页缩放拉近 */
  onWarpStart: () => void = () => {};
  /** 开屏完全结束时通知父页卸载开屏层 */
  onFinished: () => void = () => {};

  @State private statusLabel: string = '星际引擎点火 · 唤醒 Astro';
  @State private energyBarRatio: number = 0.08;
  @State private warpScale: number = 1.0;
  @State private warpRotateXDeg: number = 0;
  @State private warpOpacity: number = 1.0;

  private readonly settings: RenderingContextSettings = new RenderingContextSettings(true);
  private readonly ctx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings);
  private readonly stars: StarParticle3D[] = createStarfield(42, 130, 220);
  private loopTimerId: number = -1;
  private finishTimerId: number = -1;
  private elapsedMs: number = 0;
  private warpProgress: number = 0;
  private warpingOut: boolean = false;
  private canvasReady: boolean = false;

  aboutToAppear(): void {
    if (!Motion.enabled) {
      this.onFinished();
      return;
    }
    this.startLoop();
  }

  aboutToDisappear(): void {
    this.clearTimers();
  }

  private clearTimers(): void {
    if (this.loopTimerId !== -1) {
      clearInterval(this.loopTimerId);
      this.loopTimerId = -1;
    }
    if (this.finishTimerId !== -1) {
      clearTimeout(this.finishTimerId);
      this.finishTimerId = -1;
    }
  }

  private startLoop(): void {
    if (this.loopTimerId !== -1) {
      return;
    }
    const holdMs: number = Math.max(1, Motion.splashHoldDuration());
    const warpMs: number = Math.max(1, Motion.splashWarpDuration());

    this.loopTimerId = setInterval(() => {
      this.elapsedMs += FRAME_INTERVAL_MS;
      if (!this.warpingOut && this.elapsedMs >= holdMs) {
        this.beginWarpExit();
      }
      if (this.warpingOut && this.warpProgress < 1) {
        this.warpProgress = Math.min(1, this.warpProgress + FRAME_INTERVAL_MS / warpMs);
      }
      const speedZ: number = this.warpingOut ? 15.0 : 5.2;
      stepStarfield(this.stars, speedZ, 220);

      const frame: AstroSplashFrame = computeAstroSplashFrame(this.elapsedMs, holdMs, this.warpProgress);
      this.statusLabel = frame.statusLabel;
      this.energyBarRatio = frame.energyBarRatio;

      if (this.canvasReady) {
        this.drawSplashScene(frame);
      }
    }, FRAME_INTERVAL_MS);
  }

  /** 启动第三幕：3D 星门冲刺揭幕（或用户轻触提前触发） */
  private beginWarpExit(): void {
    if (this.warpingOut) {
      return;
    }
    this.warpingOut = true;
    this.onWarpStart();
    const target: WarpTransform = computeWarpTransform(1);
    const warpMs: number = Motion.splashWarpDuration();
    this.getUIContext().animateTo({
      duration: warpMs,
      curve: Curve.FastOutSlowIn
    }, () => {
      this.warpScale = target.overlayScale;
      this.warpRotateXDeg = target.overlayRotateXDeg;
      this.warpOpacity = target.overlayOpacity;
    });
    this.finishTimerId = setTimeout(() => {
      this.clearTimers();
      this.onFinished();
    }, warpMs);
  }

  // ---------------------------------------------------------------- 3D 舞台深度排序绘制

  private drawSplashScene(frame: AstroSplashFrame): void {
    const size: number = SPLASH_STAGE_SIZE_VP;
    const cx: number = size * 0.5;
    const cy: number = size * 0.5;
    const timeSec: number = this.elapsedMs / 1000;

    this.ctx.clearRect(0, 0, size, size);

    // 0. 深空双色能量星云径向光晕与扩散冲击波
    const nebulaGrad = this.ctx.createRadialGradient(cx, cy, 8, cx, cy, 118);
    nebulaGrad.addColorStop(0, 'rgba(0, 245, 160, 0.34)');
    nebulaGrad.addColorStop(0.45, 'rgba(0, 229, 255, 0.20)');
    nebulaGrad.addColorStop(1, 'rgba(3, 6, 10, 0.0)');
    this.ctx.fillStyle = nebulaGrad;
    this.ctx.beginPath();
    this.ctx.arc(cx, cy, 118, 0, Math.PI * 2);
    this.ctx.fill();

    if (frame.shockwaveAlpha > 0.01) {
      this.ctx.save();
      this.ctx.strokeStyle = '#00F5A0';
      this.ctx.globalAlpha = frame.shockwaveAlpha;
      this.ctx.lineWidth = 2.2;
      this.ctx.beginPath();
      this.ctx.arc(cx, cy, Math.max(12, 102 * frame.shockwaveRadiusRatio), 0, Math.PI * 2);
      this.ctx.stroke();
      this.ctx.restore();
    }

    // 1. 后景层：3D 星际隧道高速流光星尘
    this.drawStarfield(cx, cy);

    // 计算三道 3D 能量轨道环（随 ringExpandScale 弹性张开）
    const rScale: number = frame.ringExpandScale;
    const ring1: RingSegment3D[] = buildOrbitRingSegments(
      92 * rScale, 40,
      1.10 + Math.sin(timeSec * 1.4) * 0.16,
      timeSec * 1.9,
      0.38,
      cx, cy, CAMERA_FOV, CAMERA_DIST, 0
    );
    const ring2: RingSegment3D[] = buildOrbitRingSegments(
      74 * rScale, 36,
      -0.88,
      -timeSec * 2.4,
      0.92 + Math.cos(timeSec * 1.5) * 0.18,
      cx, cy, CAMERA_FOV, CAMERA_DIST, 1
    );
    const ring3: RingSegment3D[] = buildOrbitRingSegments(
      106 * rScale, 44,
      0.42 + Math.cos(timeSec * 1.1) * 0.22,
      timeSec * 1.2,
      -0.78,
      cx, cy, CAMERA_FOV, CAMERA_DIST, 2
    );
    const allSegments: RingSegment3D[] = ring1.concat(ring2).concat(ring3);

    // 计算双子 3D 正八面体密钥晶石的三维公转坐标
    const orbitR: number = 64 * rScale;
    const angleA: number = frame.crystalOrbitAngleRad;
    const angleB: number = frame.crystalOrbitAngleRad + Math.PI;
    const crystalA: ProjectedPoint = projectPoint3D(
      { x: Math.cos(angleA) * orbitR, y: Math.sin(angleA) * 18, z: Math.sin(angleA) * orbitR },
      0.35, 0, -0.22, cx, cy, CAMERA_FOV, CAMERA_DIST
    );
    const crystalB: ProjectedPoint = projectPoint3D(
      { x: Math.cos(angleB) * orbitR, y: Math.sin(angleB) * 18, z: Math.sin(angleB) * orbitR },
      0.35, 0, -0.22, cx, cy, CAMERA_FOV, CAMERA_DIST
    );

    // 2. 远端层：绘制位于宇航员背后（z > 0）的半圈轨道弧与远端公转晶石
    this.drawRings(allSegments, true, timeSec);
    if (crystalA.z > 0) {
      this.drawCrystal(crystalA.x, crystalA.y, 13 * crystalA.scale, timeSec, '#00E5FF', '#00F5A0');
    }
    if (crystalB.z > 0) {
      this.drawCrystal(crystalB.x, crystalB.y, 13 * crystalB.scale, timeSec + 1.2, '#00F5A0', '#00E5FF');
    }

    // 3. 主角层：绘制 3D 吉祥物「Astro 星航员」（含弹性缩放、喷气尾焰与挥手致意）
    this.drawHeroAstro(cx, cy, frame, timeSec);

    // 4. 近端层：绘制穿插在宇航员前方（z <= 0）的近端公转晶石与近端轨道弧
    if (crystalA.z <= 0) {
      this.drawCrystal(crystalA.x, crystalA.y, 15 * crystalA.scale, timeSec, '#00E5FF', '#00F5A0');
    }
    if (crystalB.z <= 0) {
      this.drawCrystal(crystalB.x, crystalB.y, 15 * crystalB.scale, timeSec + 1.2, '#00F5A0', '#00E5FF');
    }
    this.drawRings(allSegments, false, timeSec);
  }

  private drawStarfield(cx: number, cy: number): void {
    for (let i = 0; i < this.stars.length; i++) {
      const s: StarParticle3D = this.stars[i];
      const curr: ProjectedPoint = projectPoint3D(
        { x: s.x, y: s.y, z: s.z },
        0, 0, 0, cx, cy, CAMERA_FOV, CAMERA_DIST
      );
      const prev: ProjectedPoint = projectPoint3D(
        { x: s.x, y: s.y, z: s.prevZ },
        0, 0, 0, cx, cy, CAMERA_FOV, CAMERA_DIST
      );
      const alpha: number = Math.max(0.15, Math.min(0.92, (220 - s.z) / 280));
      const color: string = s.colorIndex === 0 ? '#00E5FF' : (s.colorIndex === 1 ? '#00F5A0' : '#D6F6FF');

      this.ctx.strokeStyle = color;
      this.ctx.globalAlpha = alpha * 0.8;
      this.ctx.lineWidth = Math.max(1.0, curr.scale * 1.8);
      this.ctx.beginPath();
      this.ctx.moveTo(prev.x, prev.y);
      this.ctx.lineTo(curr.x, curr.y);
      this.ctx.stroke();

      this.ctx.fillStyle = color;
      this.ctx.globalAlpha = alpha;
      this.ctx.beginPath();
      this.ctx.arc(curr.x, curr.y, Math.max(1.2, curr.scale * 2.0), 0, Math.PI * 2);
      this.ctx.fill();
    }
    this.ctx.globalAlpha = 1.0;
  }

  private drawRings(segments: RingSegment3D[], behindMascot: boolean, timeSec: number): void {
    const pulsePhase: number = (timeSec * 1.15) % 1.0;
    for (let i = 0; i < segments.length; i++) {
      const seg: RingSegment3D = segments[i];
      const isBehind: boolean = seg.avgZ > 0;
      if (isBehind !== behindMascot) {
        continue;
      }
      const ringColor: string = seg.ringIndex === 1 ? '#00F5A0' : '#00E5FF';
      let distToPulse: number = Math.abs(seg.t - pulsePhase);
      if (distToPulse > 0.5) {
        distToPulse = 1.0 - distToPulse;
      }
      const isHighlight: boolean = distToPulse < 0.09;
      const depthAlpha: number = behindMascot ? 0.30 : 0.84;

      this.ctx.strokeStyle = ringColor;
      this.ctx.globalAlpha = isHighlight ? Math.min(1.0, depthAlpha + 0.32) : depthAlpha;
      const baseWidth: number = seg.ringIndex === 2 ? 1.3 : 2.2;
      this.ctx.lineWidth = Math.max(0.9, baseWidth * seg.p1.scale * (isHighlight ? 1.6 : 1.0));

      this.ctx.beginPath();
      this.ctx.moveTo(seg.p1.x, seg.p1.y);
      this.ctx.lineTo(seg.p2.x, seg.p2.y);
      this.ctx.stroke();

      if (isHighlight && distToPulse < 0.03) {
        this.ctx.fillStyle = '#D6F6FF';
        this.ctx.globalAlpha = behindMascot ? 0.6 : 0.98;
        this.ctx.beginPath();
        this.ctx.arc(seg.p1.x, seg.p1.y, Math.max(2.2, 3.8 * seg.p1.scale), 0, Math.PI * 2);
        this.ctx.fill();
      }
    }
    this.ctx.globalAlpha = 1.0;
  }

  private drawCrystal(
    cx: number,
    cy: number,
    radius: number,
    timeSec: number,
    primaryHex: string,
    secondaryHex: string
  ): void {
    const edges: OctahedronEdge2D[] = buildOctahedronEdges(
      radius,
      timeSec * 2.2,
      timeSec * 3.1,
      0.45,
      cx,
      cy,
      CAMERA_FOV,
      CAMERA_DIST
    );
    this.ctx.save();
    for (let i = 0; i < edges.length; i++) {
      const e: OctahedronEdge2D = edges[i];
      const front: boolean = e.avgZ <= 0;
      this.ctx.strokeStyle = front ? secondaryHex : primaryHex;
      this.ctx.globalAlpha = front ? 0.94 : 0.40;
      this.ctx.lineWidth = front ? 1.9 : 1.1;
      this.ctx.beginPath();
      this.ctx.moveTo(e.x1, e.y1);
      this.ctx.lineTo(e.x2, e.y2);
      this.ctx.stroke();
    }
    this.ctx.restore();
  }

  /**
   * 绘制开屏主角 3D「Astro 星航员」：支持入场 3D 弹性缩放、双推进尾焰与右臂挥手致意。
   */
  private drawHeroAstro(
    cx: number,
    cy: number,
    frame: AstroSplashFrame,
    timeSec: number
  ): void {
    const s: number = frame.mascotScale;
    const mx: number = cx;
    const my: number = cy + frame.mascotDropY - 4;
    const yawOffset: number = (frame.mascotYawDeg / 14.0) * 5.2 * s;
    const pitchOffset: number = (frame.mascotPitchDeg / 6.5) * 3.6 * s;

    this.ctx.save();

    // 1. 背部推进器双翼与高能尾焰
    const packX: number = mx - yawOffset * 0.45;
    const packY: number = my + 14 * s - pitchOffset * 0.3;
    const flameLen: number = (24 + Math.sin(timeSec * 14) * 7) * s;

    this.ctx.fillStyle = '#00F5A0';
    this.ctx.globalAlpha = 0.65;
    this.ctx.beginPath();
    this.ctx.moveTo(packX - 13 * s, packY + 19 * s);
    this.ctx.lineTo(packX, packY + 19 * s + flameLen);
    this.ctx.lineTo(packX + 13 * s, packY + 19 * s);
    this.ctx.closePath();
    this.ctx.fill();

    this.ctx.fillStyle = '#122033';
    this.ctx.strokeStyle = '#00E5FF';
    this.ctx.lineWidth = 1.6 * s;
    this.ctx.globalAlpha = 0.94;
    this.ctx.beginPath();
    this.ctx.moveTo(packX - 31 * s, packY - 4 * s);
    this.ctx.lineTo(packX + 31 * s, packY - 4 * s);
    this.ctx.lineTo(packX + 24 * s, packY + 18 * s);
    this.ctx.lineTo(packX - 24 * s, packY + 18 * s);
    this.ctx.closePath();
    this.ctx.fill();
    this.ctx.stroke();

    // 2. 宇航服立体躯干与核心反应釜
    const bodyX: number = mx + yawOffset * 0.25;
    const bodyY: number = my + 18 * s;
    this.ctx.fillStyle = '#182C42';
    this.ctx.strokeStyle = '#7A9BB0';
    this.ctx.lineWidth = 1.6 * s;
    this.ctx.beginPath();
    this.ctx.arc(bodyX, bodyY, 19 * s, 0, Math.PI * 2);
    this.ctx.fill();
    this.ctx.stroke();

    this.ctx.fillStyle = '#00F5A0';
    this.ctx.beginPath();
    this.ctx.arc(bodyX + yawOffset * 0.3, bodyY - 1 * s, 5.2 * s, 0, Math.PI * 2);
    this.ctx.fill();

    // 左臂自然悬浮，右臂高举挥手致意（saluteAngleRad）
    const leftHandX: number = bodyX - 24 * s;
    const leftHandY: number = bodyY + 1 * s + Math.sin(timeSec * 3.5) * 3 * s;
    const rightShoulderX: number = bodyX + 16 * s;
    const rightShoulderY: number = bodyY - 6 * s;
    const rightHandX: number = rightShoulderX + Math.cos(frame.saluteAngleRad) * 14 * s;
    const rightHandY: number = rightShoulderY + Math.sin(frame.saluteAngleRad) * 14 * s;

    this.ctx.strokeStyle = '#B3D4DE';
    this.ctx.lineWidth = 4.2 * s;
    this.ctx.lineCap = 'round';
    this.ctx.beginPath();
    this.ctx.moveTo(rightShoulderX, rightShoulderY);
    this.ctx.lineTo(rightHandX, rightHandY);
    this.ctx.stroke();

    this.ctx.fillStyle = '#D6F6FF';
    this.ctx.beginPath();
    this.ctx.arc(leftHandX, leftHandY, 5.8 * s, 0, Math.PI * 2);
    this.ctx.arc(rightHandX, rightHandY, 6.2 * s, 0, Math.PI * 2);
    this.ctx.fill();

    // 3. 3D 宇航头盔与耳侧通讯舱
    const headX: number = mx + yawOffset * 0.55;
    const headY: number = my - 11 * s + pitchOffset * 0.45;
    const headRadius: number = 28 * s;

    this.ctx.fillStyle = '#00E5FF';
    this.ctx.beginPath();
    this.ctx.arc(headX - headRadius - 2 * s, headY, 6.0 * s, 0, Math.PI * 2);
    this.ctx.arc(headX + headRadius + 2 * s, headY, 6.0 * s, 0, Math.PI * 2);
    this.ctx.fill();

    // 头顶信号天线与双层扩频脉冲波
    const antX: number = headX - yawOffset * 0.2;
    const antTopY: number = headY - headRadius - 12 * s;
    this.ctx.strokeStyle = '#00E5FF';
    this.ctx.lineWidth = 2.2 * s;
    this.ctx.beginPath();
    this.ctx.moveTo(headX, headY - headRadius + 2 * s);
    this.ctx.lineTo(antX, antTopY);
    this.ctx.stroke();

    this.ctx.fillStyle = '#00F5A0';
    this.ctx.beginPath();
    this.ctx.arc(antX, antTopY, 4.2 * s, 0, Math.PI * 2);
    this.ctx.fill();

    const pulse: number = (Math.sin(timeSec * 5.2) + 1) * 0.5;
    const waveR: number = (6 + pulse * 16) * s;
    this.ctx.strokeStyle = '#00F5A0';
    this.ctx.globalAlpha = Math.max(0.12, 0.82 * (1 - pulse));
    this.ctx.lineWidth = 1.5 * s;
    this.ctx.beginPath();
    this.ctx.arc(antX, antTopY, waveR, 0, Math.PI * 2);
    this.ctx.stroke();
    this.ctx.globalAlpha = 1.0;

    // 头盔球体主体渐变
    const helmetGrad = this.ctx.createRadialGradient(
      headX - 9 * s,
      headY - 10 * s,
      3 * s,
      headX,
      headY,
      headRadius
    );
    helmetGrad.addColorStop(0, '#F4FAFC');
    helmetGrad.addColorStop(0.55, '#B3D4DE');
    helmetGrad.addColorStop(1, '#264458');
    this.ctx.fillStyle = helmetGrad;
    this.ctx.strokeStyle = '#00E5FF';
    this.ctx.lineWidth = 2.0 * s;
    this.ctx.beginPath();
    this.ctx.arc(headX, headY, headRadius, 0, Math.PI * 2);
    this.ctx.fill();
    this.ctx.stroke();

    // 4. 曲面 HUD 护目镜与表情
    const visorX: number = headX + yawOffset * 0.75;
    const visorY: number = headY + 1 * s + pitchOffset * 0.55;
    const visorR: number = 19.5 * s;

    this.ctx.fillStyle = '#050C16';
    this.ctx.strokeStyle = '#00F5A0';
    this.ctx.lineWidth = 1.6 * s;
    this.ctx.beginPath();
    this.ctx.arc(visorX, visorY, visorR, 0, Math.PI * 2);
    this.ctx.fill();
    this.ctx.stroke();

    this.ctx.strokeStyle = 'rgba(214, 246, 255, 0.6)';
    this.ctx.lineWidth = 2.2 * s;
    this.ctx.beginPath();
    this.ctx.arc(visorX, visorY, visorR - 4 * s, Math.PI * 1.12, Math.PI * 1.48);
    this.ctx.stroke();

    this.ctx.fillStyle = '#00F5A0';
    this.ctx.font = `bold ${Math.max(9, Math.round(12 * s))}vp monospace`;
    this.ctx.textAlign = 'center';
    this.ctx.textBaseline = 'middle';
    this.ctx.fillText(frame.visorText, visorX, visorY + 1 * s);

    this.ctx.restore();
  }

  // ---------------------------------------------------------------- 视图树

  build() {
    Column() {
      // 3D 星际舞台容器（底部居中悬浮领航员徽标）
      Stack({ alignContent: Alignment.Bottom }) {
        Canvas(this.ctx)
          .width(SPLASH_STAGE_SIZE_VP)
          .height(SPLASH_STAGE_SIZE_VP)
          .onReady(() => {
            this.canvasReady = true;
            const frame: AstroSplashFrame = computeAstroSplashFrame(
              this.elapsedMs,
              Math.max(1, Motion.splashHoldDuration()),
              this.warpProgress
            );
            this.drawSplashScene(frame);
          })

        Row() {
          Text('Astro · 星际领航员')
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
      .width(SPLASH_STAGE_SIZE_VP)
      .height(SPLASH_STAGE_SIZE_VP)

      // 品牌主标题与动态引擎自检副标题
      Text('星航终端 · Astro SSH')
        .fontSize(Tokens.fontSize.headline)
        .fontWeight(FontWeight.Bold)
        .fontColor(Tokens.Color.text)
        .textAlign(TextAlign.Center)
        .margin({ top: Tokens.space.md })

      Text(this.statusLabel)
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textDim)
        .textAlign(TextAlign.Center)
        .margin({ top: Tokens.space.xs })

      // 能量自检流光进度条
      Stack({ alignContent: Alignment.Start }) {
        Row()
          .width(ENERGY_BAR_WIDTH_VP)
          .height(ENERGY_BAR_HEIGHT_VP)
          .backgroundColor(Tokens.Color.surfaceHover)
          .borderRadius(Tokens.radius.xs)

        Row()
          .width(Math.max(12, Math.round(ENERGY_BAR_WIDTH_VP * this.energyBarRatio)))
          .height(ENERGY_BAR_HEIGHT_VP)
          .backgroundColor(Tokens.Color.accent)
          .borderRadius(Tokens.radius.xs)
      }
      .width(ENERGY_BAR_WIDTH_VP)
      .height(ENERGY_BAR_HEIGHT_VP)
      .margin({ top: Tokens.space.md })

      Text('轻触屏幕直接进入')
        .fontSize(Tokens.fontSize.caption)
        .fontColor(Tokens.Color.textFaint)
        .textAlign(TextAlign.Center)
        .margin({ top: Tokens.space.lg })
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .padding(Tokens.space.lg)
    .backgroundColor(Tokens.Color.appBg)
    .scale({ x: this.warpScale, y: this.warpScale })
    .rotate({
      x: 1,
      y: 0,
      z: 0,
      angle: this.warpRotateXDeg,
      perspective: Motion.PERSPECTIVE_VP
    })
    .opacity(this.warpOpacity)
    .hitTestBehavior(this.warpingOut ? HitTestMode.None : HitTestMode.Default)
    .onClick(() => {
      this.beginWarpExit();
    })
  }
}
