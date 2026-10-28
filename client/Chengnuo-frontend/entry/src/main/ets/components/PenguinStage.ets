/**
 * 装饰整图/组合条资源映射：素材为用户提供的"企鹅+装备"预合成图，
 * 统一按 (280,220)-(1160,1300) 裁剪为 880×1080（水印与边缘噪点全部裁除）
 */
function compositeOf(decorId: string): Resource {
  switch (decorId) {
    case 'hat_red':
      return $r('app.media.pet_hat_red');
    case 'hat_blue':
      return $r('app.media.pet_hat_blue');
    case 'hat_yellow':
      return $r('app.media.pet_hat_yellow');
    case 'hat_green':
      return $r('app.media.pet_hat_green');
    case 'hat_purple':
      return $r('app.media.pet_hat_purple');
    case 'scarf_orange':
      return $r('app.media.pet_scarf_orange');
    case 'scarf_cyan':
      return $r('app.media.pet_scarf_cyan');
    case 'scarf_lavender':
      return $r('app.media.pet_scarf_lavender');
    case 'scarf_coral':
      return $r('app.media.pet_scarf_coral');
    case 'scarf_pink':
      return $r('app.media.pet_scarf_pink');
    default:
      return $r('app.media.penguin_original');
  }
}

/** 帽+巾同戴时的围巾条（围巾图 y680-1300 段，顶部 30px 渐隐，避免双下巴接缝） */
function scarfStripOf(decorId: string): Resource {
  switch (decorId) {
    case 'scarf_orange':
      return $r('app.media.pet_strip_orange');
    case 'scarf_cyan':
      return $r('app.media.pet_strip_cyan');
    case 'scarf_lavender':
      return $r('app.media.pet_strip_lavender');
    case 'scarf_coral':
      return $r('app.media.pet_strip_coral');
    case 'scarf_pink':
      return $r('app.media.pet_strip_pink');
    default:
      return $r('app.media.penguin_original');
  }
}

/**
 * 企鹅舞台：按佩戴态整图渲染
 * - 帽子/围巾各戴一件时直接铺对应合成整图；帽+巾同戴 = 帽图打底 + 围巾条叠加
 *   （条对应合成图 y680-1300 区域，即画布 y 42.593% 起的 57.407% 高度）
 * - 裸企鹅用 original 底图底部对齐（脚底 ≈ 合成图脚底）
 * - 画布比例 880:1080，素材等比铺满，任意容器尺寸不跑偏
 */
@Component
export struct PenguinStage {
  /** 头饰装饰 id（空串 = 未佩戴） */
  @Prop headId: string = '';
  /** 颈饰装饰 id（空串 = 未佩戴） */
  @Prop neckId: string = '';

  build() {
    Stack() {
      if (this.headId.length === 0 && this.neckId.length === 0) {
        Image($r('app.media.penguin_original'))
          .width('100%')
          .aspectRatio(654 / 720)
          .objectFit(ImageFit.Fill)
          .position({ x: '0%', y: '10.3%' })
      } else {
        if (this.headId.length > 0) {
          Image(compositeOf(this.headId))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Fill)
        } else {
          Image(compositeOf(this.neckId))
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Fill)
        }

        if (this.headId.length > 0 && this.neckId.length > 0) {
          Image(scarfStripOf(this.neckId))
            .width('100%')
            .height('57.407%')
            .objectFit(ImageFit.Fill)
            .position({ x: '0%', y: '42.593%' })
        }
      }
    }
    .width('100%')
    .aspectRatio(880 / 1080)
  }
}
