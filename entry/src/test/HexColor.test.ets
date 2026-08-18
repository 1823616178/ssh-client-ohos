/**
 * HexColor 纯函数测试：#RRGGBB 校验、HSV 往返、预设去重。
 */
import { describe, it, expect } from '@ohos/hypium';
import {
  HsvColor,
  clamp01,
  hexToHsv,
  hsvToHex,
  hueToHex,
  isHexColor,
  normalizeHexColor,
  uniqueHexColors
} from '../main/ets/common/utils/HexColor';

function hexChannel(hex: string, index: number): number {
  return parseInt(hex.slice(1 + index * 2, 3 + index * 2), 16);
}

function hexDistance(a: string, b: string): number {
  let max: number = 0;
  for (let i = 0; i < 3; i++) {
    const d: number = Math.abs(hexChannel(a, i) - hexChannel(b, i));
    if (d > max) {
      max = d;
    }
  }
  return max;
}

export default function hexColorTest() {
  describe('HexColorTest', () => {
    it('isHexColor_只接受六位十六进制', 0, () => {
      expect(isHexColor('#0E131D')).assertTrue();
      expect(isHexColor('#e8eefb')).assertTrue();
      expect(isHexColor('#FFF')).assertFalse();
      expect(isHexColor('0E131D')).assertFalse();
      expect(isHexColor('#0E131D80')).assertFalse();
      expect(isHexColor('')).assertFalse();
    });

    it('normalizeHexColor_合法则转大写', 0, () => {
      expect(normalizeHexColor('#e8eefb')).assertEqual('#E8EEFB');
      expect(normalizeHexColor('bad')).assertEqual('bad');
    });

    it('hsvToHex_纯色相与灰度', 0, () => {
      expect(hsvToHex(0, 1, 1)).assertEqual('#FF0000');
      expect(hsvToHex(120, 1, 1)).assertEqual('#00FF00');
      expect(hsvToHex(240, 1, 1)).assertEqual('#0000FF');
      expect(hsvToHex(0, 0, 0)).assertEqual('#000000');
      expect(hsvToHex(0, 0, 1)).assertEqual('#FFFFFF');
      expect(hueToHex(60)).assertEqual('#FFFF00');
    });

    it('hexToHsv_再转回同一颜色', 0, () => {
      const samples: string[] = ['#0E131D', '#E8EEFB', '#4D8DFF', '#FF0000', '#00FF00', '#0000FF',
        '#000000', '#FFFFFF'];
      for (let i = 0; i < samples.length; i++) {
        const hsv: HsvColor = hexToHsv(samples[i]);
        const back: string = hsvToHex(hsv.h, hsv.s, hsv.v);
        expect(hexDistance(samples[i], back) <= 1).assertTrue();
      }
    });

    it('hexToHsv_非法输入回落到黑', 0, () => {
      const hsv: HsvColor = hexToHsv('nope');
      expect(hsv.h).assertEqual(0);
      expect(hsv.s).assertEqual(0);
      expect(hsv.v).assertEqual(0);
    });

    it('uniqueHexColors_保序去重并丢弃非法项', 0, () => {
      const out: string[] = uniqueHexColors(['#0e131d', 'x', '#0E131D', '#E8EEFB', '#e8eefb']);
      expect(out.length).assertEqual(2);
      expect(out[0]).assertEqual('#0E131D');
      expect(out[1]).assertEqual('#E8EEFB');
    });

    it('clamp01_边界', 0, () => {
      expect(clamp01(-1)).assertEqual(0);
      expect(clamp01(2)).assertEqual(1);
      expect(clamp01(0.4)).assertEqual(0.4);
    });
  });
}
