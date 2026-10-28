import { display } from '@kit.ArkUI';
import { CardKind } from '../model/Types';
import { tr } from '../common/I18n';

/**
 * 程诺设计 Token：间距 / 圆角 / 字号 体系与卡片类型配色映射
 */
export class Theme {
  static readonly spaceXs: number = 4;
  static readonly spaceSm: number = 8;
  static readonly spaceMd: number = 12;
  static readonly spaceLg: number = 16;
  static readonly spaceXl: number = 20;
  static readonly spaceXxl: number = 24;

  static readonly radiusCard: number = 20;
  static readonly radiusBtn: number = 14;
  static readonly radiusTag: number = 10;
  static readonly radiusInput: number = 12;
  static readonly radiusModal: number = 24;

  static readonly fontPageTitle: number = 28;
  static readonly fontSectionTitle: number = 20;
  static readonly fontCardTitle: number = 17;
  static readonly fontBody: number = 15;
  static readonly fontCaption: number = 13;
  static readonly fontTag: number = 11;

  /** 默认主题色（珊瑚橙 = color.json brand）：AppStorage('themeColor') 未设置时的回退 */
  static readonly DEFAULT_THEME: string = '#FF7A59';
  /** 派生色缓存（键 = deep|hex / soft|hex），避免每帧重算 HSL/混色 */
  private static shadeCache: Map<string, string> = new Map();

  /** 当前主题色（'#RRGGBB'）：读 AppStorage('themeColor')，未设置回退默认珊瑚橙 */
  static brand(): string {
    return AppStorage.get<string>('themeColor') ?? Theme.DEFAULT_THEME;
  }

  /** 主题深色（渐变深端/强调文字）：HSL 亮度 ×0.87、饱和度微增，保持鲜亮不脏 */
  static brandDeep(): string {
    const base: string = Theme.brand();
    const key: string = `deep|${base}`;
    const cached: string | undefined = Theme.shadeCache.get(key);
    if (cached !== undefined) {
      return cached;
    }
    const rgb: number[] = Theme.hexToRgb(base);
    const hsl: number[] = Theme.rgbToHsl(rgb[0], rgb[1], rgb[2]);
    const outRgb: number[] =
      Theme.hslToRgb(hsl[0], Math.min(1, hsl[1] * 1.08), Math.max(0, hsl[2] * 0.87));
    const out: string = Theme.rgbToHex(outRgb[0], outRgb[1], outRgb[2]);
    Theme.shadeCache.set(key, out);
    return out;
  }

  /** 主题浅底（软色底/选中底）：向白色混入 88%（默认珊瑚橙时 ≈ #FFEFEB，贴近原 brand_soft） */
  static brandSoft(): string {
    const base: string = Theme.brand();
    const key: string = `soft|${base}`;
    const cached: string | undefined = Theme.shadeCache.get(key);
    if (cached !== undefined) {
      return cached;
    }
    const rgb: number[] = Theme.hexToRgb(base);
    const out: string = Theme.rgbToHex(
      rgb[0] + (255 - rgb[0]) * 0.88,
      rgb[1] + (255 - rgb[1]) * 0.88,
      rgb[2] + (255 - rgb[2]) * 0.88);
    Theme.shadeCache.set(key, out);
    return out;
  }

  /** 主题渐变浅端（明信片 A 款 / 活动卡头图 / 提醒弹层）：向白色混入 45%
   *  （默认珊瑚橙时 ≈ #FFB6A4，贴近原 postcard_a_from #FFB88C） */
  static brandTint(): string {
    const base: string = Theme.brand();
    const key: string = `tint|${base}`;
    const cached: string | undefined = Theme.shadeCache.get(key);
    if (cached !== undefined) {
      return cached;
    }
    const rgb: number[] = Theme.hexToRgb(base);
    const out: string = Theme.rgbToHex(
      rgb[0] + (255 - rgb[0]) * 0.45,
      rgb[1] + (255 - rgb[1]) * 0.45,
      rgb[2] + (255 - rgb[2]) * 0.45);
    Theme.shadeCache.set(key, out);
    return out;
  }

  /** 明信片渐变六款（浅端 → 深端），按 gradientIndex 取模轮换：多彩随机、白字可读 */
  private static readonly POSTCARD_GRADIENTS: string[][] = [
    ['#FFB88C', '#FF7A59'],
    ['#8FBAFF', '#5B8DEF'],
    ['#9BE8C5', '#35B37D'],
    ['#C9A7F5', '#9B59D0'],
    ['#FFB3D1', '#EC4899'],
    ['#FFD98E', '#F5A623']
  ];

  /** 明信片渐变浅端（六款按索引取模轮换） */
  static postcardGradientFrom(index: number): string {
    const pair: string[] = Theme.postcardGradientPair(index);
    return pair[0];
  }

  /** 明信片渐变深端（六款按索引取模轮换） */
  static postcardGradientTo(index: number): string {
    const pair: string[] = Theme.postcardGradientPair(index);
    return pair[1];
  }

  private static postcardGradientPair(index: number): string[] {
    const n: number = Theme.POSTCARD_GRADIENTS.length;
    const i: number = ((index % n) + n) % n;
    return Theme.POSTCARD_GRADIENTS[i];
  }

  /** 卡片封面渐变索引：按卡片唯一标识哈希取模（同一卡片颜色稳定、不同卡片近似随机取色） */
  static colorIndexOf(seed: string): number {
    let h: number = 0;
    for (let i = 0; i < seed.length; i++) {
      h = (h * 131 + seed.charCodeAt(i)) % 1000003;
    }
    return h % Theme.POSTCARD_GRADIENTS.length;
  }

  private static hexToRgb(hex: string): number[] {
    return [parseInt(hex.substring(1, 3), 16), parseInt(hex.substring(3, 5), 16),
      parseInt(hex.substring(5, 7), 16)];
  }

  private static rgbToHex(r: number, g: number, b: number): string {
    const clamp = (v: number): number => Math.max(0, Math.min(255, Math.round(v)));
    const part = (v: number): string => {
      const s: string = clamp(v).toString(16);
      return s.length < 2 ? `0${s}` : s;
    };
    return `#${part(r)}${part(g)}${part(b)}`;
  }

  private static rgbToHsl(r: number, g: number, b: number): number[] {
    const rn: number = r / 255;
    const gn: number = g / 255;
    const bn: number = b / 255;
    const max: number = Math.max(rn, gn, bn);
    const min: number = Math.min(rn, gn, bn);
    const l: number = (max + min) / 2;
    let h: number = 0;
    let s: number = 0;
    if (max !== min) {
      const d: number = max - min;
      s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
      if (max === rn) {
        h = (gn - bn) / d + (gn < bn ? 6 : 0);
      } else if (max === gn) {
        h = (bn - rn) / d + 2;
      } else {
        h = (rn - gn) / d + 4;
      }
      h *= 60;
    }
    return [h, s, l];
  }

  private static hslToRgb(h: number, s: number, l: number): number[] {
    const c: number = (1 - Math.abs(2 * l - 1)) * s;
    const hp: number = h / 60;
    const x: number = c * (1 - Math.abs(hp % 2 - 1));
    let r: number = 0;
    let g: number = 0;
    let b: number = 0;
    if (hp < 1) {
      r = c;
      g = x;
    } else if (hp < 2) {
      r = x;
      g = c;
    } else if (hp < 3) {
      g = c;
      b = x;
    } else if (hp < 4) {
      g = x;
      b = c;
    } else if (hp < 5) {
      r = x;
      b = c;
    } else {
      r = c;
      b = x;
    }
    const m: number = l - c / 2;
    return [(r + m) * 255, (g + m) * 255, (b + m) * 255];
  }

  /** 卡片类型底色：日程跟随主题色（软色底），任务/活动保持语义色 */
  static kindBg(kind: CardKind): ResourceColor {
    if (kind === CardKind.Schedule) {
      return Theme.brandSoft();
    }
    if (kind === CardKind.Task) {
      return $r('app.color.task_bg');
    }
    return $r('app.color.activity_bg');
  }

  /** 卡片类型强调色：日程跟随主题色，任务/活动保持语义色 */
  static kindAccent(kind: CardKind): ResourceColor {
    if (kind === CardKind.Schedule) {
      return Theme.brand();
    }
    if (kind === CardKind.Task) {
      return $r('app.color.task_accent');
    }
    return $r('app.color.activity_accent');
  }

  /** 卡片类型深色（渐变深端/翻面背面）：日程跟随主题色，任务/活动保持语义色 */
  static kindDeep(kind: CardKind): ResourceColor {
    if (kind === CardKind.Schedule) {
      return Theme.brandDeep();
    }
    if (kind === CardKind.Task) {
      return $r('app.color.task_deep');
    }
    return $r('app.color.activity_deep');
  }

  static kindLabel(kind: CardKind): string {
    if (kind === CardKind.Schedule) {
      return tr('日程');
    }
    if (kind === CardKind.Task) {
      return tr('任务');
    }
    return tr('活动');
  }

  /** 看板卡片宽度 = 页面宽度 72%（页面内容区有边距，需按整页宽折算），配 168 高保证比例一致 */
  static boardCardWidth(): number {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const density: number = d.densityPixels > 0 ? d.densityPixels : 3;
      return d.width / density * 0.72;
    } catch (e) {
      return 260;
    }
  }
}
