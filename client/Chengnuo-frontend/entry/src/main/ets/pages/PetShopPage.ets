import { Theme } from '../common/Theme';
import { tr, trf } from '../common/I18n';
import { appStore } from '../store/AppStore';
import { petStore, PetDecor, PET_DECORS, PET_DECOR_SLOT_HEAD, PET_DECOR_SLOT_NECK } from '../store/PetStore';
import { PenguinStage } from '../components/PenguinStage';

/**
 * 装饰商城页（宠物页「去逛逛」进入）：
 * - 顶栏：返回 + 标题 + ⭐实时余额
 * - 商品：帽子 / 围巾两区双列卡片，每件 5000 积分；卡片支持
 *   预览（全屏试穿：预览件 + 另一槽位当前佩戴件一起合成）与
 *   兑换（二次确认 → 扣积分并自动戴上）
 * - 已拥有件可佩戴 / 取下（同槽位 toggle，再点已佩戴的那件 = 取下）
 * - 数据全部本地（PetStore），操作后 petStamp 自增通知宠物页同步
 */
@Entry
@Component
struct PetShopPage {
  @StorageProp('appLang') appLang: string = 'zh';
  @StorageProp('petStamp') @Watch('onPetStampChange') petStamp: number = 0;
  @State balance: number = 0;
  @State owned: string[] = [];
  @State wornHead: string = '';
  @State wornNeck: string = '';
  /** 全屏试穿预览的装饰 id（空串 = 关闭） */
  @State previewDecorId: string = '';
  /** 兑换二次确认的装饰 id（空串 = 关闭） */
  @State buyDecorId: string = '';

  aboutToAppear(): void {
    this.syncFromStore();
  }

  /** 宠物本地数据变化（本页或宠物页操作）→ 重读余额/已拥有/佩戴态 */
  private onPetStampChange(): void {
    this.syncFromStore();
  }

  private syncFromStore(): void {
    const account: string = appStore.getAccount();
    this.balance = petStore.balanceOf(account);
    this.owned = petStore.ownedOf(account);
    this.wornHead = petStore.wornInSlot(account, PET_DECOR_SLOT_HEAD);
    this.wornNeck = petStore.wornInSlot(account, PET_DECOR_SLOT_NECK);
  }

  /** 某槽位的商城条目列表 */
  private shopItemsOf(slot: string): PetDecor[] {
    const items: PetDecor[] = [];
    for (let i = 0; i < PET_DECORS.length; i++) {
      if (PET_DECORS[i].slot === slot) {
        items.push(PET_DECORS[i]);
      }
    }
    return items;
  }

  /** 商城卡片产品图（decor_*.png 成品图，按 id 静态映射） */
  private cardArtOf(decorId: string): Resource {
    switch (decorId) {
      case 'hat_red':
        return $r('app.media.decor_hat_red');
      case 'hat_blue':
        return $r('app.media.decor_hat_blue');
      case 'hat_yellow':
        return $r('app.media.decor_hat_yellow');
      case 'hat_green':
        return $r('app.media.decor_hat_green');
      case 'hat_purple':
        return $r('app.media.decor_hat_purple');
      case 'scarf_orange':
        return $r('app.media.decor_scarf_orange');
      case 'scarf_cyan':
        return $r('app.media.decor_scarf_cyan');
      case 'scarf_lavender':
        return $r('app.media.decor_scarf_lavender');
      case 'scarf_coral':
        return $r('app.media.decor_scarf_coral');
      case 'scarf_pink':
        return $r('app.media.decor_scarf_pink');
      default:
        return $r('app.media.decor_hat_red');
    }
  }

  private decorById(id: string): PetDecor | null {
    for (let i = 0; i < PET_DECORS.length; i++) {
      if (PET_DECORS[i].id === id) {
        return PET_DECORS[i];
      }
    }
    return null;
  }

  /** 弹窗文案辅助（id 无效时给安全占位；弹窗只在有效 id 时打开） */
  private nameOfId(id: string): string {
    const decor: PetDecor | null = this.decorById(id);
    return decor !== null ? decor.name : '';
  }

  private priceOfId(id: string): number {
    const decor: PetDecor | null = this.decorById(id);
    return decor !== null ? decor.price : 0;
  }

  /** 试穿预览：预览件 + 另一槽位当前佩戴件一起合成 */
  private previewHeadId(): string {
    const decor: PetDecor | null = this.decorById(this.previewDecorId);
    if (decor === null) {
      return '';
    }
    return decor.slot === PET_DECOR_SLOT_HEAD ? decor.id : this.wornHead;
  }

  private previewNeckId(): string {
    const decor: PetDecor | null = this.decorById(this.previewDecorId);
    if (decor === null) {
      return '';
    }
    return decor.slot === PET_DECOR_SLOT_NECK ? decor.id : this.wornNeck;
  }

  /** 佩戴 / 取下（同槽位再点已佩戴的那件 = 取下） */
  private handleWear(decorId: string): void {
    petStore.wearDecor(appStore.getAccount(), decorId);
    this.syncFromStore();
  }

  /** 兑换确认：扣积分并自动戴上 */
  private handleBuyConfirm(): void {
    const account: string = appStore.getAccount();
    const decor: PetDecor | null = this.decorById(this.buyDecorId);
    this.buyDecorId = '';
    if (decor === null) {
      return;
    }
    if (!petStore.buyDecor(account, decor)) {
      this.getUIContext().getPromptAction().showToast({ message: tr('积分不足') });
      return;
    }
    petStore.wearDecor(account, decor.id);
    this.getUIContext().getPromptAction().showToast({ message: tr('兑换成功，已为企鹅戴上！') });
    this.syncFromStore();
  }

  @Builder
  shopCard(item: PetDecor) {
    Column({ space: 8 }) {
      Image(this.cardArtOf(item.id))
        .height(72)
        .width('100%')
        .objectFit(ImageFit.Contain)

      Text(tr(item.name))
        .fontSize(Theme.fontBody)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      Text(trf('{0} 积分', item.price))
        .fontSize(Theme.fontCaption)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.brand())

      Row({ space: 6 }) {
        Column() {
          Text(tr('预览'))
            .fontSize(Theme.fontCaption)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_secondary'))
        }
        .layoutWeight(1)
        .height(30)
        .justifyContent(FlexAlign.Center)
        .backgroundColor($r('app.color.chip_bg'))
        .borderRadius(Theme.radiusBtn)
        .onClick(() => {
          this.previewDecorId = item.id;
        })

        if (this.owned.indexOf(item.id) < 0) {
          if (this.balance >= item.price) {
            Column() {
              Text(tr('兑换'))
                .fontSize(Theme.fontCaption)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
            }
            .layoutWeight(1)
            .height(30)
            .justifyContent(FlexAlign.Center)
            .linearGradient({
              angle: 135,
              colors: [[Theme.brand(), 0.0], [Theme.brandDeep(), 1.0]]
            })
            .borderRadius(Theme.radiusBtn)
            .onClick(() => {
              this.buyDecorId = item.id;
            })
          } else {
            Column() {
              Text(tr('积分不足'))
                .fontSize(Theme.fontCaption)
                .fontColor($r('app.color.text_tertiary'))
            }
            .layoutWeight(1)
            .height(30)
            .justifyContent(FlexAlign.Center)
            .backgroundColor($r('app.color.chip_bg'))
            .borderRadius(Theme.radiusBtn)
          }
        } else {
          if (this.wornHead === item.id || this.wornNeck === item.id) {
            Column() {
              Text(tr('已佩戴'))
                .fontSize(Theme.fontCaption)
                .fontWeight(FontWeight.Bold)
                .fontColor(Theme.brand())
            }
            .layoutWeight(1)
            .height(30)
            .justifyContent(FlexAlign.Center)
            .backgroundColor(Theme.brandTint())
            .borderRadius(Theme.radiusBtn)
            .onClick(() => {
              this.handleWear(item.id);
            })
          } else {
            Column() {
              Text(tr('佩戴'))
                .fontSize(Theme.fontCaption)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
            }
            .layoutWeight(1)
            .height(30)
            .justifyContent(FlexAlign.Center)
            .backgroundColor($r('app.color.chip_bg'))
            .borderRadius(Theme.radiusBtn)
            .onClick(() => {
              this.handleWear(item.id);
            })
          }
        }
      }
      .width('100%')
    }
    .width('48.5%')
    .padding(Theme.spaceLg)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(Theme.radiusCard)
    .shadow({ radius: 8, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 3 })
  }

  @Builder
  sectionCard(title: string, slot: string) {
    Column({ space: Theme.spaceLg }) {
      Text(title)
        .fontSize(Theme.fontSectionTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')

      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.SpaceBetween }) {
        ForEach(this.shopItemsOf(slot), (item: PetDecor) => {
          this.shopCard(item)
        }, (item: PetDecor) => item.id)
      }
      .width('100%')
    }
    .width('100%')
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Text('‹')
            .fontSize(24)
            .fontColor($r('app.color.text_secondary'))
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .onClick(() => {
              this.getUIContext().getRouter().back();
            })

          Text(tr('装饰商城'))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)

          Row({ space: 4 }) {
            Text('⭐')
              .fontSize(15)
            Text(`${this.balance}`)
              .fontSize(Theme.fontBody)
              .fontWeight(FontWeight.Bold)
              .fontColor(Theme.brand())
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 8 })

        Scroll() {
          Column({ space: Theme.spaceXl }) {
            Column({ space: Theme.spaceSm }) {
              Text(tr('完成日程卡攒积分：每 1 小时 500，来这里给企鹅挑新装扮'))
                .fontSize(Theme.fontCaption)
                .fontColor($r('app.color.text_secondary'))
                .width('100%')
              Text(tr('帽子、围巾 5000 积分一件，攒积分给企鹅换新装'))
                .fontSize(Theme.fontCaption)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
            }
            .width('100%')
            .padding(Theme.spaceXxl)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(Theme.radiusCard)

            this.sectionCard(tr('帽子'), PET_DECOR_SLOT_HEAD)

            this.sectionCard(tr('围巾'), PET_DECOR_SLOT_NECK)
          }
          .width('100%')
          .padding({ left: Theme.spaceXl, right: Theme.spaceXl, top: Theme.spaceLg, bottom: Theme.spaceXxl })
        }
        .scrollBar(BarState.Off)
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')

      if (this.previewDecorId.length > 0) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0, 0, 0, 0.62)')
          .onClick(() => {
            this.previewDecorId = '';
          })

        Column({ space: Theme.spaceMd }) {
          PenguinStage({ headId: this.previewHeadId(), neckId: this.previewNeckId() })
            .width('82%')

          Text(tr(this.nameOfId(this.previewDecorId)))
            .fontSize(Theme.fontCardTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))

          Text(trf('{0} 积分', this.priceOfId(this.previewDecorId)))
            .fontSize(Theme.fontCaption)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.brand())

          Text(tr('点击任意处关闭'))
            .fontSize(Theme.fontTag)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('80%')
        .padding(Theme.spaceLg)
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(Theme.radiusModal)
        .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
        .onClick(() => {
          this.previewDecorId = '';
        })
      }

      if (this.buyDecorId.length > 0) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0, 0, 0, 0.45)')
          .onClick(() => {
            this.buyDecorId = '';
          })

        Column({ space: 16 }) {
          Text(tr('确认兑换'))
            .fontSize(Theme.fontCardTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Text(trf('用 {0} 积分把「{1}」带回家？', this.priceOfId(this.buyDecorId), tr(this.nameOfId(this.buyDecorId))))
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          Row({ space: 12 }) {
            Column() {
              Text(tr('取消'))
                .fontSize(Theme.fontBody)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_secondary'))
            }
            .layoutWeight(1)
            .height(44)
            .justifyContent(FlexAlign.Center)
            .backgroundColor($r('app.color.chip_bg'))
            .borderRadius(Theme.radiusBtn)
            .onClick(() => {
              this.buyDecorId = '';
            })

            Column() {
              Text(tr('确认'))
                .fontSize(Theme.fontBody)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
            }
            .layoutWeight(1)
            .height(44)
            .justifyContent(FlexAlign.Center)
            .linearGradient({
              angle: 135,
              colors: [[Theme.brand(), 0.0], [Theme.brandDeep(), 1.0]]
            })
            .borderRadius(Theme.radiusBtn)
            .onClick(() => {
              this.handleBuyConfirm();
            })
          }
          .width('100%')
        }
        .width('86%')
        .padding(22)
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(Theme.radiusModal)
        .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
        .onClick(() => {
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.bg_page'))
  }
}
