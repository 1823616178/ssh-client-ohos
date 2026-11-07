/**
 * Astro3DSceneModel 单元测试：
 * 覆盖 3D 旋转/透视投影、星环前后半圈分割、八面体密钥晶体、星空隧道 Z 轴步进、
 * 连接状态阶段映射、Astro 星航员姿态计算、3D 跃迁穿越（Portal Dive）与脉冲骨架屏行规格。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  Point3D,
  ProjectedPoint,
  RingSegment3D,
  OctahedronEdge2D,
  StarParticle3D,
  AstroStageSpec,
  AstroPose,
  WarpTransform,
  SkeletonRowSpec,
  AstroSplashFrame,
  rotatePoint3D,
  projectPoint3D,
  buildOrbitRingSegments,
  buildOctahedronEdges,
  createStarfield,
  stepStarfield,
  resolveAstroStage,
  getAstroStageSpec,
  computeAstroPose,
  computeWarpTransform,
  buildSkeletonRowSpecs,
  computeAstroSplashFrame
} from '../main/ets/viewmodel/Astro3DSceneModel';

export default function astro3DSceneModelTest() {
  describe('Astro3DSceneModelTest', () => {

    it('rotatePoint3D_零角度保持原坐标且范数守恒', 0, () => {
      const p: Point3D = { x: 30, y: -40, z: 50 };
      const r0: Point3D = rotatePoint3D(p, 0, 0, 0);
      expect(Math.abs(r0.x - 30) < 1e-6).assertTrue();
      expect(Math.abs(r0.y - (-40)) < 1e-6).assertTrue();
      expect(Math.abs(r0.z - 50) < 1e-6).assertTrue();

      const r1: Point3D = rotatePoint3D(p, 0.7, -1.1, 0.4);
      const norm0: number = p.x * p.x + p.y * p.y + p.z * p.z;
      const norm1: number = r1.x * r1.x + r1.y * r1.y + r1.z * r1.z;
      expect(Math.abs(norm0 - norm1) < 1e-4).assertTrue();
    });

    it('projectPoint3D_近大远小透视缩放正确', 0, () => {
      const near: ProjectedPoint = projectPoint3D({ x: 40, y: 0, z: -100 }, 0, 0, 0, 200, 200, 320, 320);
      const center: ProjectedPoint = projectPoint3D({ x: 40, y: 0, z: 0 }, 0, 0, 0, 200, 200, 320, 320);
      const far: ProjectedPoint = projectPoint3D({ x: 40, y: 0, z: 100 }, 0, 0, 0, 200, 200, 320, 320);
      expect(near.scale > center.scale).assertTrue();
      expect(center.scale > far.scale).assertTrue();
      expect(near.x > center.x).assertTrue();
      expect(center.x > far.x).assertTrue();
    });

    it('buildOrbitRingSegments_生成完整闭合分段且包含前后深度', 0, () => {
      const segs: RingSegment3D[] = buildOrbitRingSegments(80, 24, 0.6, 0.2, 1.0, 150, 150, 320, 320, 0);
      expect(segs.length).assertEqual(24);
      let frontCount: number = 0;
      let backCount: number = 0;
      for (let i = 0; i < segs.length; i++) {
        if (segs[i].avgZ <= 0) {
          frontCount++;
        } else {
          backCount++;
        }
      }
      expect(frontCount > 0).assertTrue();
      expect(backCount > 0).assertTrue();
    });

    it('buildOctahedronEdges_返回12条按深度排序的棱', 0, () => {
      const edges: OctahedronEdge2D[] = buildOctahedronEdges(20, 0.4, 0.7, 0.2, 150, 150, 320, 320);
      expect(edges.length).assertEqual(12);
      for (let i = 1; i < edges.length; i++) {
        expect(edges[i - 1].avgZ >= edges[i].avgZ).assertTrue();
      }
    });

    it('createStarfield_与_stepStarfield_推进Z轴并循环包裹', 0, () => {
      const stars: StarParticle3D[] = createStarfield(16, 120, 220);
      expect(stars.length).assertEqual(16);
      const z0: number = stars[0].z;
      stepStarfield(stars, 15, 220);
      expect(stars[0].z !== z0).assertTrue();
      // 步进越过近裁剪面 (-165) 后自动循环回远端
      stepStarfield(stars, 200, 220);
      for (let i = 0; i < stars.length; i++) {
        expect(stars[i].z >= -165 && stars[i].z <= 280).assertTrue();
      }
    });

    it('resolveAstroStage_与_getAstroStageSpec_覆盖全部会话状态', 0, () => {
      expect(resolveAstroStage('connecting', 'connecting', '', false)).assertEqual('connecting');
      expect(resolveAstroStage('connecting', 'handshaking', '', false)).assertEqual('handshaking');
      expect(resolveAstroStage('connecting', 'authenticating', '', false)).assertEqual('authenticating');
      expect(resolveAstroStage('connecting', 'connecting', '阶段 2/3 · 密钥交换', false)).assertEqual('handshaking');
      expect(resolveAstroStage('connecting', 'connecting', '阶段 3/3 · 身份认证', false)).assertEqual('authenticating');
      expect(resolveAstroStage('reconnecting', 'reconnecting', '', false)).assertEqual('reconnecting');
      expect(resolveAstroStage('error', 'error', '', false)).assertEqual('error');
      expect(resolveAstroStage('closed', 'disconnected', '', false)).assertEqual('closed');
      expect(resolveAstroStage('connecting', 'established', '', true)).assertEqual('warping');

      const authSpec: AstroStageSpec = getAstroStageSpec('authenticating');
      expect(authSpec.stepIndex).assertEqual(2);
      expect(authSpec.showKeyCrystal).assertTrue();
      expect(authSpec.badgeLabel).assertEqual('身份认证');

      const errSpec: AstroStageSpec = getAstroStageSpec('error');
      expect(errSpec.stepIndex).assertEqual(-1);
      expect(errSpec.badgeLabel).assertEqual('连接中断');
    });

    it('computeAstroPose_随时间产生悬浮位移与周期眨眼', 0, () => {
      const p0: AstroPose = computeAstroPose(0, 'connecting', 0);
      const p1: AstroPose = computeAstroPose(0.65, 'connecting', 0);
      expect(Math.abs(p0.bobY - p1.bobY) > 0.5).assertTrue();
      expect(p0.visorText).assertEqual('~ ◉ ~');
      // 3.50 秒处于 (3.46, 3.6) 眨眼窗口
      const pBlink: AstroPose = computeAstroPose(3.50, 'connecting', 0);
      expect(pBlink.visorText).assertEqual('~ - ~');
    });

    it('computeWarpTransform_3D空间穿越起止与中点插值符合契约', 0, () => {
      const w0: WarpTransform = computeWarpTransform(0);
      expect(Math.abs(w0.overlayScale - 1.0) < 1e-6).assertTrue();
      expect(Math.abs(w0.overlayOpacity - 1.0) < 1e-6).assertTrue();
      expect(Math.abs(w0.canvasScale - 0.92) < 1e-6).assertTrue();
      expect(Math.abs(w0.canvasRotateXDeg - 8.0) < 1e-6).assertTrue();

      const wMid: WarpTransform = computeWarpTransform(0.5);
      expect(wMid.overlayScale > 1.2).assertTrue();
      expect(wMid.overlayOpacity < 0.8 && wMid.overlayOpacity >= 0).assertTrue();
      expect(wMid.canvasScale > 0.94 && wMid.canvasScale < 1.0).assertTrue();

      const w1: WarpTransform = computeWarpTransform(1);
      expect(Math.abs(w1.overlayScale - 1.85) < 1e-6).assertTrue();
      expect(Math.abs(w1.overlayOpacity) < 1e-6).assertTrue();
      expect(Math.abs(w1.canvasScale - 1.0) < 1e-6).assertTrue();
      expect(Math.abs(w1.canvasRotateXDeg) < 1e-6).assertTrue();
      expect(Math.abs(w1.canvasOpacity - 1.0) < 1e-6).assertTrue();
    });

    it('buildSkeletonRowSpecs_生成交错呼吸骨架行规格', 0, () => {
      const specs: SkeletonRowSpec[] = buildSkeletonRowSpecs(5);
      expect(specs.length).assertEqual(5);
      expect(specs[0].titleWidth !== specs[1].titleWidth).assertTrue();
      expect(specs[0].subtitleWidth !== specs[1].subtitleWidth).assertTrue();
      expect(specs[0].badgeWidthVp).assertEqual(48);
    });

    it('computeAstroSplashFrame_三幕式开屏吉祥物入场挥手与跃迁编排', 0, () => {
      const fStart: AstroSplashFrame = computeAstroSplashFrame(0, 1150, 0);
      expect(fStart.progress).assertEqual(0);
      expect(fStart.mascotScale < 0.4).assertTrue();
      expect(fStart.ringExpandScale < 0.35).assertTrue();
      expect(fStart.visorText).assertEqual('✦ ‿ ✦');

      const fMid: AstroSplashFrame = computeAstroSplashFrame(600, 1150, 0);
      expect(fMid.mascotScale > 0.95).assertTrue();
      expect(fMid.ringExpandScale > 0.95).assertTrue();
      expect(fMid.shockwaveAlpha > 0).assertTrue();
      expect(fMid.visorText).assertEqual('★ ‿ ★');
      expect(fMid.energyBarRatio > 0.5).assertTrue();

      const fWarp: AstroSplashFrame = computeAstroSplashFrame(1150, 1150, 0.8);
      expect(fWarp.progress).assertEqual(1);
      expect(fWarp.mascotScale > 1.25).assertTrue();
      expect(fWarp.visorText).assertEqual('★ ≫ ★');
      expect(fWarp.energyBarRatio).assertEqual(1);
    });
  });
}
