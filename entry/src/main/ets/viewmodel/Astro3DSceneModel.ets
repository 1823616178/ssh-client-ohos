/**
 * Astro3DSceneModel —— 服务器连接 3D 跃迁场景与「Astro 星航员」吉祥物纯逻辑模型。
 *
 * 职责（纯逻辑无 @Component，可在 Node 下由 ets-unit 直接单测）：
 *   1. 三维欧拉旋转与相机透视投影（支持 Z 深度排序，实现星环前后穿插遮挡宇航员）；
 *   2. 3D 轨道能量环、正八面体密钥晶石（Octahedron）、三维星尘隧道粒子生成与步进；
 *   3. 连接阶段状态机（connecting / handshaking / authenticating / reconnecting / error / closed / warping）
 *      到吉祥物姿态（Pitch/Yaw/Roll、HUD 面罩表情、推进器脉冲）与配色参数的映射；
 *   4. 连接成功瞬间「3D 空间穿越（Portal Dive）」的蒙层与终端画布联动变换参数计算；
 *   5. 列表脉冲骨架屏（ListLoadingSkeleton）自然行宽规格生成。
 */

/** 三维空间点（以场景中心为原点，z > 0 为远离镜头/后方，z < 0 为靠近镜头/前方） */
export interface Point3D {
  x: number;
  y: number;
  z: number;
}

/** 透视投影后的二维屏幕点及深度比例 */
export interface ProjectedPoint {
  x: number;
  y: number;
  /** 旋转后的相机空间 Z（>0 在角色后方，<=0 在角色前方） */
  z: number;
  /** 透视缩放系数 fov / (cameraDist + z) */
  scale: number;
}

/** 3D 能量轨道环的单个投影线段（用于深度分前后层绘制） */
export interface RingSegment3D {
  p1: ProjectedPoint;
  p2: ProjectedPoint;
  avgZ: number;
  ringIndex: number;
  /** 环上归一化位置 [0, 1)，用于计算流光脉冲高光 */
  t: number;
}

/** 3D 正八面体密钥晶石的投影棱边 */
export interface OctahedronEdge2D {
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  avgZ: number;
}

/** 3D 星际隧道中的单颗纵深粒子 */
export interface StarParticle3D {
  x: number;
  y: number;
  z: number;
  prevZ: number;
  colorIndex: number;
}

/** 连接 3D 场景所处阶段 */
export type AstroStageKind =
  | 'connecting'
  | 'handshaking'
  | 'authenticating'
  | 'reconnecting'
  | 'error'
  | 'closed'
  | 'warping';

/** 阶段视觉与动力学配置 */
export interface AstroStageSpec {
  readonly stage: AstroStageKind;
  /** 顶部 3D 阶段胶囊高亮索引：0=建立连接, 1=密钥交换, 2=身份认证, 3=空间跃迁, -1=异常/结束 */
  readonly stepIndex: number;
  /** 阶段短标签（中文） */
  readonly badgeLabel: string;
  /** 星环旋转倍速 */
  readonly ringSpeedMultiplier: number;
  /** 星尘隧道推进速度（vp/帧） */
  readonly starSpeed: number;
  /** 是否在宇航员胸前渲染旋转的 3D 密钥八面体 */
  readonly showKeyCrystal: boolean;
  /** Canvas 主能量色（对应 Tokens 电青 / 霓虹绿 / 琥珀 / 珊瑚红） */
  readonly primaryHex: string;
  /** Canvas 次能量色 */
  readonly secondaryHex: string;
  /** 辉光半透明色 */
  readonly glowRgba: string;
}

/** 「Astro 星航员」当前帧姿态与表情参数 */
export interface AstroPose {
  /** 垂直失重悬浮位移（vp） */
  readonly bobY: number;
  /** 水平微漂移（vp） */
  readonly swayX: number;
  /** 3D 俯仰角（度，绕 X 轴） */
  readonly pitchDeg: number;
  /** 3D 偏航角（度，绕 Y 轴） */
  readonly yawDeg: number;
  /** 3D 翻滚角（度，绕 Z 轴） */
  readonly rollDeg: number;
  /** 头盔 HUD 面罩内显示的符号表情 */
  readonly visorText: string;
  /** 头顶信号天线脉冲半径系数 [0, 1] */
  readonly antennaPulse: number;
  /** 背包推进器尾焰长度系数 [0.4, 1.2] */
  readonly jetpackFlame: number;
}

/** 连接成功时「3D 空间穿越（Portal Dive）」双层联动变换参数 */
export interface WarpTransform {
  /** 连接蒙层缩放：1.0 → 1.85（向镜头前冲） */
  readonly overlayScale: number;
  /** 连接蒙层绕 X 轴倾角：0° → -12° */
  readonly overlayRotateXDeg: number;
  /** 连接蒙层不透明度：1.0 → 0.0 */
  readonly overlayOpacity: number;
  /** 终端画布缩放：0.92 → 1.0（从纵深处拉近） */
  readonly canvasScale: number;
  /** 终端画布绕 X 轴透视倾角：8° → 0°（完全归零后不留任何 3D 变形） */
  readonly canvasRotateXDeg: number;
  /** 终端画布不透明度：0.25 → 1.0 */
  readonly canvasOpacity: number;
}

/** 列表脉冲骨架屏单行错落宽度规格 */
export interface SkeletonRowSpec {
  readonly index: number;
  readonly titleWidth: string;
  readonly subtitleWidth: string;
  readonly badgeWidthVp: number;
}

/** 开屏 3D 吉祥物「Astro 星航员」主秀单帧编排参数 */
export interface AstroSplashFrame {
  /** 主秀阶段归一化进度 [0, 1] */
  readonly progress: number;
  /** 吉祥物 3D 弹性入场与冲刺缩放系数 */
  readonly mascotScale: number;
  /** 吉祥物垂直喷气降落与升空偏移（vp） */
  readonly mascotDropY: number;
  /** 吉祥物 3D 偏航角（度） */
  readonly mascotYawDeg: number;
  /** 吉祥物 3D 俯仰角（度） */
  readonly mascotPitchDeg: number;
  /** 右臂向用户挥手致意摆角（弧度） */
  readonly saluteAngleRad: number;
  /** 三道 3D 能量轨道环展开半径倍率 [0.25, 1.15] */
  readonly ringExpandScale: number;
  /** 深空脉冲冲击波归一化半径 [0, 1.3] */
  readonly shockwaveRadiusRatio: number;
  /** 深空脉冲冲击波不透明度 [0, 0.78] */
  readonly shockwaveAlpha: number;
  /** 双子 3D 密钥晶石环绕公转角（弧度） */
  readonly crystalOrbitAngleRad: number;
  /** 头盔 HUD 面罩表情符号 */
  readonly visorText: string;
  /** 底部引擎自检状态副文案 */
  readonly statusLabel: string;
  /** 能量自检进度条填充比 [0, 1] */
  readonly energyBarRatio: number;
}

// ---------------------------------------------------------------- 3D 旋转与透视投影

/**
 * 绕 X → Y → Z 轴依次旋转三维点（弧度）。
 */
export function rotatePoint3D(p: Point3D, rx: number, ry: number, rz: number): Point3D {
  // 绕 X 轴
  const cosX: number = Math.cos(rx);
  const sinX: number = Math.sin(rx);
  const y1: number = p.y * cosX - p.z * sinX;
  const z1: number = p.y * sinX + p.z * cosX;

  // 绕 Y 轴
  const cosY: number = Math.cos(ry);
  const sinY: number = Math.sin(ry);
  const x2: number = p.x * cosY + z1 * sinY;
  const z2: number = -p.x * sinY + z1 * cosY;

  // 绕 Z 轴
  const cosZ: number = Math.cos(rz);
  const sinZ: number = Math.sin(rz);
  const x3: number = x2 * cosZ - y1 * sinZ;
  const y3: number = x2 * sinZ + y1 * cosZ;

  return { x: x3, y: y3, z: z2 };
}

/**
 * 将三维点旋转后透视投影到画布像素/vp 坐标系 (cx, cy)。
 */
export function projectPoint3D(
  p: Point3D,
  rx: number,
  ry: number,
  rz: number,
  cx: number,
  cy: number,
  fov: number,
  cameraDist: number
): ProjectedPoint {
  const rot: Point3D = rotatePoint3D(p, rx, ry, rz);
  const denom: number = Math.max(20, cameraDist + rot.z);
  const scale: number = fov / denom;
  return {
    x: cx + rot.x * scale,
    y: cy + rot.y * scale,
    z: rot.z,
    scale: scale
  };
}

/**
 * 生成单道 3D 轨道能量环的所有透视投影线段。
 */
export function buildOrbitRingSegments(
  radius: number,
  segments: number,
  rx: number,
  ry: number,
  rz: number,
  cx: number,
  cy: number,
  fov: number,
  cameraDist: number,
  ringIndex: number
): RingSegment3D[] {
  const count: number = Math.max(8, segments);
  const projected: ProjectedPoint[] = [];
  for (let i = 0; i < count; i++) {
    const angle: number = (i / count) * Math.PI * 2;
    const pt: Point3D = {
      x: Math.cos(angle) * radius,
      y: Math.sin(angle) * radius,
      z: 0
    };
    projected.push(projectPoint3D(pt, rx, ry, rz, cx, cy, fov, cameraDist));
  }
  const result: RingSegment3D[] = [];
  for (let i = 0; i < count; i++) {
    const p1: ProjectedPoint = projected[i];
    const p2: ProjectedPoint = projected[(i + 1) % count];
    result.push({
      p1: p1,
      p2: p2,
      avgZ: (p1.z + p2.z) * 0.5,
      ringIndex: ringIndex,
      t: i / count
    });
  }
  return result;
}

/**
 * 生成 3D 正八面体（SSH 密钥晶石）的 12 条透视投影棱边，并按深度从远到近排序。
 */
export function buildOctahedronEdges(
  radius: number,
  rx: number,
  ry: number,
  rz: number,
  cx: number,
  cy: number,
  fov: number,
  cameraDist: number
): OctahedronEdge2D[] {
  const vertices: Point3D[] = [
    { x: 0, y: -radius, z: 0 }, // 0: 顶
    { x: 0, y: radius, z: 0 },  // 1: 底
    { x: -radius, y: 0, z: 0 }, // 2: 左
    { x: radius, y: 0, z: 0 },  // 3: 右
    { x: 0, y: 0, z: -radius }, // 4: 前
    { x: 0, y: 0, z: radius }   // 5: 后
  ];
  const proj: ProjectedPoint[] = [];
  for (let i = 0; i < vertices.length; i++) {
    proj.push(projectPoint3D(vertices[i], rx, ry, rz, cx, cy, fov, cameraDist));
  }
  const pairs: number[][] = [
    [0, 2], [0, 3], [0, 4], [0, 5],
    [1, 2], [1, 3], [1, 4], [1, 5],
    [2, 4], [4, 3], [3, 5], [5, 2]
  ];
  const edges: OctahedronEdge2D[] = [];
  for (let i = 0; i < pairs.length; i++) {
    const a: ProjectedPoint = proj[pairs[i][0]];
    const b: ProjectedPoint = proj[pairs[i][1]];
    edges.push({
      x1: a.x,
      y1: a.y,
      x2: b.x,
      y2: b.y,
      avgZ: (a.z + b.z) * 0.5
    });
  }
  edges.sort((e1: OctahedronEdge2D, e2: OctahedronEdge2D) => e2.avgZ - e1.avgZ);
  return edges;
}

// ---------------------------------------------------------------- 3D 星尘隧道粒子

/**
 * 创建确定性分布的 3D 星尘粒子群（无 Math.random 抖动，保证单测可复现与首帧均匀分布）。
 */
export function createStarfield(count: number, spreadXY: number = 120, maxZ: number = 220): StarParticle3D[] {
  const stars: StarParticle3D[] = [];
  const total: number = Math.max(1, count);
  // 黄金角螺旋分布，确保 3D 隧道四周均匀环绕、无中心盲区碰撞
  const goldenAngle: number = 2.399963229728653;
  for (let i = 0; i < total; i++) {
    const angle: number = i * goldenAngle;
    const ringRadius: number = (0.35 + ((i * 7) % 13) / 13 * 0.65) * spreadXY;
    const zPos: number = -maxZ * 0.6 + ((i * 29) % 100) / 100 * (maxZ * 1.6);
    stars.push({
      x: Math.cos(angle) * ringRadius,
      y: Math.sin(angle) * ringRadius,
      z: zPos,
      prevZ: zPos + 8,
      colorIndex: i % 3
    });
  }
  return stars;
}

/**
 * 推进 3D 星尘粒子向镜头方向飞掠（z 递减），越过近裁剪面后循环回到远端。
 */
export function stepStarfield(stars: StarParticle3D[], speedZ: number, maxZ: number = 220): void {
  const nearPlane: number = -maxZ * 0.75;
  const farSpan: number = maxZ * 1.75;
  for (let i = 0; i < stars.length; i++) {
    const s: StarParticle3D = stars[i];
    s.prevZ = s.z;
    s.z -= speedZ;
    if (s.z < nearPlane) {
      s.z += farSpan;
      s.prevZ = s.z + speedZ;
    }
  }
}

// ---------------------------------------------------------------- 阶段映射与吉祥物姿态

/**
 * 从会话状态名、蒙层类型与阶段文案推导 3D 场景阶段。
 */
export function resolveAstroStage(
  overlayKind: string,
  sessionState: string,
  detailText: string,
  warping: boolean
): AstroStageKind {
  if (warping) {
    return 'warping';
  }
  if (overlayKind === 'error') {
    return 'error';
  }
  if (overlayKind === 'closed') {
    return 'closed';
  }
  if (overlayKind === 'reconnecting') {
    return 'reconnecting';
  }
  if (sessionState === 'authenticating' || detailText.indexOf('身份认证') >= 0) {
    return 'authenticating';
  }
  if (sessionState === 'handshaking' || detailText.indexOf('密钥交换') >= 0) {
    return 'handshaking';
  }
  return 'connecting';
}

/**
 * 获取指定阶段的视觉与动力学参数。
 */
export function getAstroStageSpec(stage: AstroStageKind): AstroStageSpec {
  switch (stage) {
    case 'handshaking':
      return {
        stage: 'handshaking',
        stepIndex: 1,
        badgeLabel: '密钥交换',
        ringSpeedMultiplier: 1.75,
        starSpeed: 4.2,
        showKeyCrystal: true,
        primaryHex: '#00E5FF',
        secondaryHex: '#00F5A0',
        glowRgba: 'rgba(0, 229, 255, 0.28)'
      };
    case 'authenticating':
      return {
        stage: 'authenticating',
        stepIndex: 2,
        badgeLabel: '身份认证',
        ringSpeedMultiplier: 2.25,
        starSpeed: 5.8,
        showKeyCrystal: true,
        primaryHex: '#00F5A0',
        secondaryHex: '#00E5FF',
        glowRgba: 'rgba(0, 245, 160, 0.30)'
      };
    case 'warping':
      return {
        stage: 'warping',
        stepIndex: 3,
        badgeLabel: '跃迁就绪',
        ringSpeedMultiplier: 3.6,
        starSpeed: 16.0,
        showKeyCrystal: false,
        primaryHex: '#00F5A0',
        secondaryHex: '#00E5FF',
        glowRgba: 'rgba(0, 245, 160, 0.42)'
      };
    case 'reconnecting':
      return {
        stage: 'reconnecting',
        stepIndex: 0,
        badgeLabel: '信号重连',
        ringSpeedMultiplier: 0.85,
        starSpeed: 2.0,
        showKeyCrystal: false,
        primaryHex: '#FFB020',
        secondaryHex: '#00E5FF',
        glowRgba: 'rgba(255, 176, 32, 0.25)'
      };
    case 'error':
      return {
        stage: 'error',
        stepIndex: -1,
        badgeLabel: '连接中断',
        ringSpeedMultiplier: 0.2,
        starSpeed: 0.4,
        showKeyCrystal: false,
        primaryHex: '#FF3D6B',
        secondaryHex: '#FFB020',
        glowRgba: 'rgba(255, 61, 107, 0.24)'
      };
    case 'closed':
      return {
        stage: 'closed',
        stepIndex: -1,
        badgeLabel: '已休眠',
        ringSpeedMultiplier: 0.15,
        starSpeed: 0.2,
        showKeyCrystal: false,
        primaryHex: '#7A9BB0',
        secondaryHex: '#4A6578',
        glowRgba: 'rgba(122, 155, 176, 0.18)'
      };
    case 'connecting':
    default:
      return {
        stage: 'connecting',
        stepIndex: 0,
        badgeLabel: '星际寻路',
        ringSpeedMultiplier: 1.1,
        starSpeed: 2.8,
        showKeyCrystal: false,
        primaryHex: '#00E5FF',
        secondaryHex: '#0088A3',
        glowRgba: 'rgba(0, 229, 255, 0.24)'
      };
  }
}

/**
 * 计算「Astro 星航员」在时刻 timeSec 下的 3D 悬浮姿态与护目镜 HUD 表情。
 */
export function computeAstroPose(
  timeSec: number,
  stage: AstroStageKind,
  warpProgress: number = 0
): AstroPose {
  const isResting: boolean = stage === 'error' || stage === 'closed';
  const verticalFactor: number = isResting ? 0.35 : 1.0;
  const horizontalFactor: number = isResting ? 0.0 : 1.0;
  const bobY: number = Math.sin(timeSec * 2.4) * 5.0 * verticalFactor - warpProgress * 18;
  const swayX: number = Math.sin(timeSec * 1.6) * 2.0 * horizontalFactor;
  const pitchDeg: number = Math.sin(timeSec * 1.9) * 5.5 * verticalFactor - warpProgress * 14;
  const yawDeg: number = Math.sin(timeSec * 1.3) * 11.0 * horizontalFactor;
  const rollDeg: number = Math.sin(timeSec * 1.7) * 3.5 * horizontalFactor;

  // 眨眼周期：每 3.6 秒眨眼 140ms
  const blinkPhase: number = timeSec % 3.6;
  const isBlinking: boolean = blinkPhase > 3.46;

  let visorText: string = '~ ◉ ~';
  if (stage === 'warping') {
    visorText = '★ ≫ ★';
  } else if (stage === 'error') {
    visorText = '! ︵ !';
  } else if (stage === 'closed') {
    visorText = '— ‿ —';
  } else if (stage === 'reconnecting') {
    visorText = isBlinking ? '↻ - -' : '↻ ◉ ◉';
  } else if (stage === 'authenticating') {
    visorText = '⟦ ✓ ⟧';
  } else if (stage === 'handshaking') {
    visorText = isBlinking ? '◊ - ◊' : '◊ ⇄ ◊';
  } else {
    visorText = isBlinking ? '~ - ~' : '~ ◉ ~';
  }

  const antennaPulse: number = (Math.sin(timeSec * 4.2) + 1) * 0.5;
  const jetpackFlame: number = 0.55 + Math.sin(timeSec * 9.5) * 0.25 + warpProgress * 0.45;

  return {
    bobY: bobY,
    swayX: swayX,
    pitchDeg: pitchDeg,
    yawDeg: yawDeg,
    rollDeg: rollDeg,
    visorText: visorText,
    antennaPulse: antennaPulse,
    jetpackFlame: jetpackFlame
  };
}

/**
 * 计算连接成功瞬间「3D 空间穿越（Portal Dive）」的蒙层与画布变换矩阵参数。
 * @param warpProgress 穿越归一化进度 [0, 1]，0=尚未开始穿越，1=穿越完成终端完全就位
 */
export function computeWarpTransform(warpProgress: number): WarpTransform {
  const p: number = Math.max(0, Math.min(1, warpProgress));
  // Ease-out cubic 曲线：起步凌厉，落位平稳
  const eased: number = 1 - Math.pow(1 - p, 3);
  return {
    overlayScale: 1 + eased * 0.85,
    overlayRotateXDeg: -eased * 12,
    overlayOpacity: Math.max(0, 1 - eased * 1.15),
    canvasScale: 0.92 + eased * 0.08,
    canvasRotateXDeg: (1 - eased) * 8,
    canvasOpacity: 0.25 + eased * 0.75
  };
}

// ---------------------------------------------------------------- 列表骨架屏规格生成

const TITLE_WIDTHS: string[] = ['56%', '72%', '64%', '48%', '68%', '60%'];
const SUBTITLE_WIDTHS: string[] = ['78%', '62%', '84%', '70%', '66%', '74%'];
const BADGE_WIDTHS: number[] = [48, 56, 44, 52, 60, 46];

/**
 * 生成指定行数的列表骨架行宽度配置（错落有致，避免机械重复）。
 */
export function buildSkeletonRowSpecs(count: number): SkeletonRowSpec[] {
  const n: number = Math.max(1, Math.min(12, count));
  const specs: SkeletonRowSpec[] = [];
  for (let i = 0; i < n; i++) {
    specs.push({
      index: i,
      titleWidth: TITLE_WIDTHS[i % TITLE_WIDTHS.length],
      subtitleWidth: SUBTITLE_WIDTHS[i % SUBTITLE_WIDTHS.length],
      badgeWidthVp: BADGE_WIDTHS[i % BADGE_WIDTHS.length]
    });
  }
  return specs;
}

// ---------------------------------------------------------------- 开屏 3D 吉祥物「Astro」主秀编排

/**
 * 计算开屏 3D 吉祥物动画在 elapsedMs 时刻的完整编排帧。
 *   - 阶段 I (0.00 ~ 0.38)：深空点火，Astro 携喷气尾焰自星门纵深弹性跃出，三道 3D 星环展开；
 *   - 阶段 II (0.38 ~ 0.78)：Astro 悬停挥手致意（saluteAngleRad），双子 3D 密钥晶石环绕公转，冲击波扩散；
 *   - 阶段 III (0.78 ~ 1.00 + warpProgress)：星际引擎满载，面罩切换为跃迁高光，向镜头 3D 冲刺揭幕首页。
 */
export function computeAstroSplashFrame(
  elapsedMs: number,
  holdMs: number,
  warpProgress: number = 0
): AstroSplashFrame {
  const totalHold: number = Math.max(1, holdMs);
  const p: number = Math.max(0, Math.min(1, elapsedMs / totalHold));
  const wp: number = Math.max(0, Math.min(1, warpProgress));

  // 阶段 I：弹性入场曲线（0 ~ 0.42 完成入场落位并带轻微回弹）
  const enterT: number = Math.min(1, p / 0.42);
  const invEnter: number = 1 - enterT;
  const easeOutBack: number = 1 - invEnter * invEnter * (2.6 * invEnter - 1.6);

  const mascotScale: number = (0.36 + 0.64 * easeOutBack) * (1 + wp * 0.45);
  const floatBob: number = enterT >= 1 ? Math.sin((p - 0.42) * Math.PI * 3.5) * 4.5 : 0;
  const mascotDropY: number = (1 - easeOutBack) * 38 + floatBob - wp * 28;

  const mascotYawDeg: number = (1 - enterT) * -22 + Math.sin(p * Math.PI * 2.2) * 9 * (1 - wp);
  const mascotPitchDeg: number = (1 - enterT) * 12 + Math.cos(p * Math.PI * 2.0) * 4.5 - wp * 14;

  // 右臂挥手致意：入场后高举挥动两次
  const saluteAngleRad: number = -0.75 - Math.sin(p * Math.PI * 5.0) * 0.42;

  // 3D 轨道环展开与能量冲击波
  const ringEase: number = 1 - Math.pow(1 - Math.min(1, p / 0.5), 3);
  const ringExpandScale: number = (0.28 + 0.72 * ringEase) * (1 + wp * 0.35);

  const waveT: number = Math.max(0, Math.min(1, (p - 0.15) / 0.75));
  const shockwaveRadiusRatio: number = waveT * 1.25;
  const shockwaveAlpha: number = waveT <= 0 ? 0 : Math.max(0, (1 - waveT) * 0.72);

  // 双子 3D 密钥晶石公转角
  const crystalOrbitAngleRad: number = p * Math.PI * 3.2 + wp * 1.8;

  // 面罩表情与状态文案随进度演进
  let visorText: string = '✦ ‿ ✦';
  let statusLabel: string = '星际引擎点火 · 唤醒 Astro';
  if (wp > 0 || p >= 0.80) {
    visorText = '★ ≫ ★';
    statusLabel = '星航员就绪 · 正在开启工作台';
  } else if (p >= 0.38) {
    visorText = '★ ‿ ★';
    statusLabel = 'SSH2 · SFTP · 3D 终端矩阵已就绪';
  }

  // 底部能量进度条平滑填充
  const energyBarRatio: number = Math.min(1, 1 - Math.pow(1 - p, 2.4));

  return {
    progress: p,
    mascotScale: mascotScale,
    mascotDropY: mascotDropY,
    mascotYawDeg: mascotYawDeg,
    mascotPitchDeg: mascotPitchDeg,
    saluteAngleRad: saluteAngleRad,
    ringExpandScale: ringExpandScale,
    shockwaveRadiusRatio: shockwaveRadiusRatio,
    shockwaveAlpha: shockwaveAlpha,
    crystalOrbitAngleRad: crystalOrbitAngleRad,
    visorText: visorText,
    statusLabel: statusLabel,
    energyBarRatio: energyBarRatio
  };
}
