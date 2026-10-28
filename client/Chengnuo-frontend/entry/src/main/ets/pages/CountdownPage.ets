import { Theme } from '../common/Theme';
import { tr, trf } from '../common/I18n';
import { appStore } from '../store/AppStore';
import { CountdownRecord, CountdownStore, countdownStore, CountdownRow, isoOf, sortedRowsOf } from '../store/CountdownStore';
import { photoAccessHelper } from '@kit.MediaLibraryKit';

/**
 * 倒计时（类「倒数日」，我的页/月历右滑预览进入）：
 * - 最近的日子置顶放大（hero 大数字卡）＋ 全部列表彩色卡（按记录 id 稳定取色）
 * - 每条倒计时可从系统相册上传一张背景图：hero 有图 = 图片全铺 + 暗色渐变 + 白字；
 *   无图 = 主题渐变暖底 + 企鹅压角（默认版式）；列表卡有图显示圆角缩略图
 * - 每年重复记录（生日/纪念日）过完自动数下一次；一次性记录显示「N 天前」沉底
 * - 点卡片 → 编辑浮层；底部大按钮添加；删除两次点击确认
 * - 纯本机持久化（按账号文件），不联网
 */
@Entry
@Component
struct CountdownPage {
  @State rows: CountdownRow[] = [];
  @State todayIso: string = '';
  @State editorVisible: boolean = false;
  /** 正在编辑的记录 id；空串 = 新建 */
  @State editingId: string = '';
  @State formTitle: string = '';
  @State formDate: string = '';
  @State formAnnual: boolean = false;
  @State deleteArmed: boolean = false;
  /** 正在编辑记录的背景图文件名（'' = 无图） */
  @State formBg: string = '';
  /** 新选待存背景图 uri（PhotoViewPicker 返回；保存时才拷贝进沙箱） */
  @State formBgPicked: string = '';
  /** 打开编辑器时的原始背景文件名（保存成功后清理被替换/清除的旧文件用） */
  private formBgOrig: string = '';

  aboutToAppear(): void {
    this.todayIso = isoOf(new Date());
    this.reload();
  }

  private reload(): void {
    this.rows = sortedRowsOf(appStore.getAccount(), this.todayIso);
  }

  private openNew(): void {
    this.editingId = '';
    this.formTitle = '';
    this.formDate = this.todayIso;
    this.formAnnual = false;
    this.deleteArmed = false;
    this.formBg = '';
    this.formBgPicked = '';
    this.formBgOrig = '';
    this.editorVisible = true;
  }

  private openEdit(row: CountdownRow): void {
    this.editingId = row.record.id;
    this.formTitle = row.record.title;
    this.formDate = row.record.targetDate;
    this.formAnnual = row.record.repeatAnnual;
    this.deleteArmed = false;
    this.formBg = row.record.bg;
    this.formBgPicked = '';
    this.formBgOrig = row.record.bg;
    this.editorVisible = true;
  }

  private formValid(): boolean {
    return this.formTitle.trim().length > 0 && this.formDate.length === 10;
  }

  private saveForm(): void {
    if (!this.formValid()) {
      this.getUIContext().getPromptAction().showToast({ message: tr('标题或日期不完整') });
      return;
    }
    const id: string = this.editingId.length > 0 ? this.editingId : `cd-${Date.now()}`;
    const rec: CountdownRecord = CountdownRecord.of(id, this.formTitle.trim(), this.formDate,
      this.formAnnual, this.todayIso);
    rec.bg = this.formBg;
    if (this.formBgPicked.length > 0) {
      const copied: string = countdownStore.copyBgFromUri(this.formBgPicked, id);
      if (copied.length > 0) {
        rec.bg = copied;
      } else {
        this.getUIContext().getPromptAction().showToast({ message: tr('图片保存失败') });
      }
    }
    if (countdownStore.upsert(appStore.getAccount(), rec)) {
      if (rec.bg !== this.formBgOrig) {
        countdownStore.removeBg(this.formBgOrig);
      }
      this.editorVisible = false;
      this.reload();
    }
  }

  private deleteEditing(): void {
    if (!this.deleteArmed) {
      this.deleteArmed = true;
      return;
    }
    if (this.editingId.length > 0) {
      countdownStore.remove(appStore.getAccount(), this.editingId);
    }
    this.editorVisible = false;
    this.reload();
  }

  private pickDate(): void {
    const selected: Date | null = CountdownStore.parseIso(this.formDate);
    this.getUIContext().showDatePickerDialog({
      start: new Date(1900, 0, 1),
      end: new Date(2100, 0, 1),
      selected: selected !== null ? selected : new Date(),
      onDateAccept: (value: Date) => {
        this.formDate = isoOf(value);
      }
    });
  }

  /** 系统相册选一张图作背景（PhotoViewPicker 免权限；选完先存 uri，点保存时才拷贝进沙箱） */
  private pickBg(): void {
    const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
    picker.select({
      MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
      maxSelectNumber: 1
    }).then((res: photoAccessHelper.PhotoSelectResult) => {
      if (res.photoUris.length > 0) {
        this.formBgPicked = res.photoUris[0];
      }
    }).catch(() => {
    });
  }

  private clearBg(): void {
    this.formBg = '';
    this.formBgPicked = '';
  }

  private hasBg(): boolean {
    return this.formBg.length > 0 || this.formBgPicked.length > 0;
  }

  /** 最近的日子 hero 卡：有背景图 = 图片全铺 + 暗色渐变 + 白字；无图 = 主题渐变暖底 + 企鹅压角
    *  （不接收入参：@Builder 按值传参不随状态刷新，直接访问 this.rows[0] 才能随增删改更新；
    *  背景经 backgroundImage/linearGradient 挂在内容 Column 上，随内容自适应高度） */
  @Builder
  heroCard() {
    Stack({ alignContent: Alignment.BottomEnd }) {
      Column({ space: 8 }) {
        Text(tr('最近的日子'))
          .fontSize(Theme.fontCaption)
          .fontColor(this.rows[0].record.bg.length > 0 ? Color.White : $r('app.color.text_secondary'))

        Text(this.rows[0].record.title)
          .fontSize(Theme.fontSectionTitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.rows[0].record.bg.length > 0 ? Color.White : $r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        if (this.rows[0].days === 0) {
          Row({ space: 10 }) {
            Text(tr('今天'))
              .fontSize(52)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.rows[0].record.bg.length > 0 ? Color.White : Theme.brandDeep())
            Text('🎉')
              .fontSize(30)
          }
          .alignItems(VerticalAlign.Bottom)
        } else {
          Row({ space: 4 }) {
            Text(`${Math.abs(this.rows[0].days)}`)
              .fontSize(64)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.rows[0].record.bg.length > 0 ? Color.White
                : (this.rows[0].days > 0 ? Theme.brandDeep() : $r('app.color.text_tertiary')))
            Text(this.rows[0].days > 0 ? tr('天') : tr('天前'))
              .fontSize(20)
              .fontColor(this.rows[0].record.bg.length > 0 ? Color.White
                : $r('app.color.text_secondary'))
              .padding({ bottom: 10 })
          }
          .alignItems(VerticalAlign.Bottom)
        }

        Text(this.rows[0].record.repeatAnnual
          ? `${this.rows[0].record.targetDate} · ${tr('每年重复')}` : this.rows[0].record.targetDate)
          .fontSize(Theme.fontCaption)
          .fontColor(this.rows[0].record.bg.length > 0 ? Color.White : $r('app.color.text_secondary'))
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 20, right: 96, top: 18, bottom: 18 })
      .backgroundImage(this.rows[0].record.bg.length > 0
        ? `file://${countdownStore.bgPathOf(this.rows[0].record.bg)}` : '')
      .backgroundImageSize(ImageSize.Cover)
      .linearGradient(this.rows[0].record.bg.length > 0
        ? { angle: 180, colors: [['#8C000000', 0], ['#40000000', 0.45], ['#73000000', 1]] }
        : { angle: 135, colors: [[Theme.brandTint(), 0], [Theme.brandSoft(), 1]] })

      if (this.rows[0].record.bg.length === 0) {
        Image($r('app.media.penguin'))
          .width(86)
          .height(86)
          .objectFit(ImageFit.Contain)
          .margin({ right: 12, bottom: 10 })
      }
    }
    .width('100%')
    .borderRadius(Theme.radiusCard)
    .clip(true)
    .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
    .onClick(() => {
      this.openEdit(this.rows[0]);
    })
  }

  /** 列表卡：彩色渐变条 + 圆角背景图缩略（无图 = 糖果色圆底 + 标题首字）+ 同色系天数（按 id 稳定取色） */
  @Builder
  cardRow(row: CountdownRow) {
    Row({ space: 12 }) {
      Column()
        .width(5)
        .height(46)
        .borderRadius(3)
        .linearGradient({
          angle: 90,
          colors: [[Theme.postcardGradientFrom(Theme.colorIndexOf(row.record.id)), 0],
            [Theme.postcardGradientTo(Theme.colorIndexOf(row.record.id)), 1]]
        })

      if (row.record.bg.length > 0) {
        Image(`file://${countdownStore.bgPathOf(row.record.bg)}`)
          .width(46)
          .height(46)
          .objectFit(ImageFit.Cover)
          .borderRadius(23)
      } else {
        Text(row.record.title.length > 0 ? row.record.title.charAt(0) : '·')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .width(46)
          .height(46)
          .textAlign(TextAlign.Center)
          .backgroundColor(Theme.postcardGradientFrom(Theme.colorIndexOf(row.record.id)))
          .borderRadius(23)
      }

      Column({ space: 4 }) {
        Text(row.record.title)
          .fontSize(Theme.fontBody)
          .fontWeight(FontWeight.Bold)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')

        Text(row.record.repeatAnnual ? `${row.record.targetDate} · ${tr('每年重复')}` : row.record.targetDate)
          .fontSize(Theme.fontCaption)
          .fontColor($r('app.color.text_tertiary'))
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (row.days === 0) {
        Column({ space: 2 }) {
          Text(tr('今天'))
            .fontSize(Theme.fontCardTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.badge_red'))
          Text('🎉')
            .fontSize(Theme.fontCaption)
        }
        .alignItems(HorizontalAlign.End)
      } else {
        Column({ space: 2 }) {
          Text(`${Math.abs(row.days)}`)
            .fontSize(30)
            .fontWeight(FontWeight.Bold)
            .fontColor(row.days > 0
              ? Theme.postcardGradientTo(Theme.colorIndexOf(row.record.id)) : $r('app.color.text_tertiary'))
          Text(row.days > 0 ? tr('天') : tr('天前'))
            .fontSize(Theme.fontTag)
            .fontColor(row.days > 0 ? $r('app.color.text_secondary') : $r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.End)
      }
    }
    .width('100%')
    .padding({ left: 14, right: 14, top: 14, bottom: 14 })
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(Theme.radiusCard)
    .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
    .onClick(() => {
      this.openEdit(row);
    })
  }

  @Builder
  editorSheet() {
    Column({ space: 14 }) {
      Text(this.editingId.length > 0 ? tr('编辑倒计时') : tr('添加倒计时'))
        .fontSize(Theme.fontSectionTitle)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))

      TextInput({ placeholder: tr('标题'), text: this.formTitle })
        .fontSize(Theme.fontBody)
        .height(44)
        .backgroundColor($r('app.color.chip_bg'))
        .borderRadius(Theme.radiusInput)
        .padding({ left: 12, right: 12 })
        .onChange((v: string) => {
          this.formTitle = v;
        })

      Text(tr('背景图'))
        .fontSize(Theme.fontCaption)
        .fontColor($r('app.color.text_secondary'))
        .width('100%')

      Row({ space: 10 }) {
        Stack() {
          if (this.formBgPicked.length > 0) {
            Image(this.formBgPicked)
              .width(56)
              .height(56)
              .objectFit(ImageFit.Cover)
              .borderRadius(12)
          } else if (this.formBg.length > 0) {
            Image(`file://${countdownStore.bgPathOf(this.formBg)}`)
              .width(56)
              .height(56)
              .objectFit(ImageFit.Cover)
              .borderRadius(12)
          } else {
            Text('🖼️')
              .fontSize(22)
              .width(56)
              .height(56)
              .textAlign(TextAlign.Center)
              .backgroundColor($r('app.color.chip_bg'))
              .borderRadius(12)
          }
        }
        .width(56)
        .height(56)

        Text(tr('选择图片'))
          .fontSize(Theme.fontBody)
          .fontColor(Theme.brandDeep())
          .padding({ left: 14, right: 14, top: 10, bottom: 10 })
          .backgroundColor($r('app.color.chip_bg'))
          .borderRadius(Theme.radiusBtn)
          .onClick(() => {
            this.pickBg();
          })

        if (this.hasBg()) {
          Text(tr('清除'))
            .fontSize(Theme.fontBody)
            .fontColor($r('app.color.error'))
            .padding({ left: 14, right: 14, top: 10, bottom: 10 })
            .onClick(() => {
              this.clearBg();
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row() {
        Text(tr('目标日期'))
          .fontSize(Theme.fontBody)
          .fontColor($r('app.color.text_primary'))
          .layoutWeight(1)
        Text(this.formDate.length === 10 ? this.formDate : tr('请选择'))
          .fontSize(Theme.fontBody)
          .fontWeight(FontWeight.Bold)
          .fontColor(Theme.brandDeep())
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .onClick(() => {
            this.pickDate();
          })
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })

      Row() {
        Column({ space: 2 }) {
          Text(tr('每年重复'))
            .fontSize(Theme.fontBody)
            .fontColor($r('app.color.text_primary'))
          Text(tr('生日/纪念日：过完自动数下一次'))
            .fontSize(Theme.fontTag)
            .fontColor($r('app.color.text_tertiary'))
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Toggle({ type: ToggleType.Switch, isOn: this.formAnnual })
          .onChange((on: boolean) => {
            this.formAnnual = on;
          })
      }
      .width('100%')

      Row({ space: 10 }) {
        if (this.editingId.length > 0) {
          Text(this.deleteArmed ? tr('再点一次确认删除') : tr('删除'))
            .fontSize(Theme.fontBody)
            .fontColor(this.deleteArmed ? Color.White : $r('app.color.error'))
            .backgroundColor(this.deleteArmed ? $r('app.color.error') : Color.Transparent)
            .padding({ left: 14, right: 14, top: 11, bottom: 11 })
            .borderRadius(Theme.radiusBtn)
            .onClick(() => {
              this.deleteEditing();
            })
        }

        Text(tr('保存'))
          .fontSize(Theme.fontBody)
          .fontWeight(FontWeight.Bold)
          .fontColor(Color.White)
          .backgroundColor(this.formValid() ? Theme.brand() : $r('app.color.text_tertiary'))
          .padding({ left: 20, right: 20, top: 11, bottom: 11 })
          .borderRadius(Theme.radiusBtn)
          .textAlign(TextAlign.Center)
          .layoutWeight(1)
          .onClick(() => {
            this.saveForm();
          })
      }
      .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('86%')
    .padding(20)
    .backgroundColor($r('app.color.bg_card'))
    .borderRadius(Theme.radiusModal)
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
          Text(tr('倒计时'))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 8 })

        if (this.rows.length === 0) {
          Column({ space: 12 }) {
            Image($r('app.media.penguin'))
              .width(104)
              .height(104)
              .objectFit(ImageFit.Contain)
            Text(tr('还没有倒数的日子'))
              .fontSize(Theme.fontBody)
              .fontColor($r('app.color.text_secondary'))
            Text(tr('点下方按钮添加第一个'))
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_tertiary'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Scroll() {
            Column({ space: 12 }) {
              this.heroCard()

              Row() {
                Text(tr('全部倒计时'))
                  .fontSize(Theme.fontSectionTitle)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                  .layoutWeight(1)
                Text(trf('{0} 条', this.rows.length))
                  .fontSize(Theme.fontCaption)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')
              .margin({ top: 4 })

              ForEach(this.rows, (row: CountdownRow) => {
                this.cardRow(row)
              }, (row: CountdownRow) => `${row.record.id}|${row.nextIso}|${row.days}|${row.record.bg}`)
            }
            .width('100%')
            .constraintSize({ minHeight: '100%' })
            .justifyContent(FlexAlign.Start)
            .padding({ left: Theme.spaceLg, right: Theme.spaceLg, top: 4, bottom: 24 })
          }
          .layoutWeight(1)
          .width('100%')
          .scrollBar(BarState.Off)
          .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        }

        Row() {
          Text(`＋  ${tr('添加倒计时')}`)
            .fontSize(17)
            .fontWeight(FontWeight.Bold)
            .fontColor(Color.White)
            .height(52)
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
            .borderRadius(26)
            .linearGradient({ angle: 90, colors: [[Theme.brand(), 0], [Theme.brandDeep(), 1]] })
            .shadow({ radius: 12, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 4 })
            .onClick(() => {
              this.openNew();
            })
        }
        .width('100%')
        .padding({ left: Theme.spaceLg, right: Theme.spaceLg, top: 8, bottom: 16 })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))

      if (this.editorVisible) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor($r('app.color.overlay_mask'))
          .onClick(() => {
            this.editorVisible = false;
          })

        this.editorSheet()
      }
    }
    .width('100%')
    .height('100%')
  }
}
