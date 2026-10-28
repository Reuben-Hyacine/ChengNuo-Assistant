import { Theme } from '../common/Theme';
import { PageHeader } from '../components/PageHeader';
import { tr, trf } from '../common/I18n';
import { appStore } from '../store/AppStore';
import { petStore, petPointsOfTime, PET_DECOR_SLOT_HEAD, PET_DECOR_SLOT_NECK } from '../store/PetStore';
import { PenguinStage } from '../components/PenguinStage';
import { postcardStore, PostcardRecord } from '../store/PostcardStore';
import { ServerGateway } from '../net/ServerGateway';
import { LibraryListOutcome } from '../net/ServerModels';

/** 点击企鹅的台词池（每次点击随机一条，不与上一次重复） */
const PET_CHATTERS: string[] = [
  '咕咕嘎嘎，主人，今天准备做什么呀',
  '呃啊，谢谢主人来陪我',
  '咕咕咕，今天也超喜欢主人！',
  '嘎嘎！新的一天要元气满满哦',
  '呃啊……有点困，主人陪我眯一会？',
  '咕咕！攒够积分就给我带新装饰嘛',
  '嘎嘎嘎，主人的日程卡也要加油鸭',
  '咕咕嘎嘎，我最最最喜欢主人啦',
  '呃啊，主人辛苦了，摸摸头'
];

/** 围巾专属台词：只在脖子上围着围巾时才进入台词池 */
const PET_CHATTER_SCARF: string = '咕咕嘎嘎，围巾暖乎乎的，好幸福';

/**
 * 宠物页（第二主 tab）：企鹅伙伴 + 积分 + 装饰商城
 * - 问候：每次启动会话第一次进宠物页先「咕咕嘎嘎！」再向主人打招呼（后续进入只打招呼）
 * - 互动：点击企鹅随机说一句咕咕嘎嘎台词（不与上一次重复）
 * - 改名：企鹅名字按账号持久化（≤12 字），弹窗修改
 * - 积分：完成日程卡按时长折算（每 1 小时 500、单点卡按 1 小时、单卡封顶 24 小时），
 *   在 62 完成处即记入本地积分账本（在线/离线都记）；进页时顺带把仍在组内的已完成卡
 *   （出稿失败未删卡）经 54 补记进账本，并一次性补记功能上线前已归档的明信片；
 *   余额 = 账本累计获得 - 已消费总账
 * - 商城：入口卡跳装饰商城页（帽子/围巾 5000 积分一件），兑换/佩戴在商城页完成
 */
@Component
export struct PetPage {
  @StorageProp('appLang') appLang: string = 'zh';
  /** 宠物数据变化（改名/积分刷新/兑换/佩戴）→ 重读本地展示态 */
  @StorageProp('petStamp') @Watch('onPetStampChange') petStamp: number = 0;
  /** 主框架切进宠物 tab 的通知（保活页不走 aboutToAppear，靠令牌触发问候与积分刷新） */
  @StorageProp('petShowToken') @Watch('onPetShow') petShowToken: number = 0;
  @State petName: string = '小企鹅';
  @State balance: number = 0;
  @State wornHead: string = '';
  @State wornNeck: string = '';
  @State speech: string = '';
  @State speechVisible: boolean = false;
  @State computing: boolean = false;
  /** 改名弹窗 */
  @State renameVisible: boolean = false;
  @State renameInput: string = '';
  /** 问候气泡自动切换/收起计时器 */
  private speechTimer: number = -1;
  /** 上一次点击台词（避免连点重复） */
  private lastChatter: string = '';
  /** 积分刷新重入标记 */
  private refreshing: boolean = false;

  aboutToDisappear(): void {
    this.cancelSpeechTimer();
  }

  /** 宠物本地数据变化：重读名字/积分/装扮 */
  private onPetStampChange(): void {
    this.syncFromStore();
  }

  /** 进宠物 tab：刷新积分并播放问候（本次会话首次进入先「咕咕嘎嘎」再打招呼） */
  private onPetShow(): void {
    this.syncFromStore();
    this.refreshPoints();
    this.playGreeting();
  }

  private syncFromStore(): void {
    const account: string = appStore.getAccount();
    this.petName = petStore.nameOf(account);
    this.balance = petStore.balanceOf(account);
    this.wornHead = petStore.wornInSlot(account, PET_DECOR_SLOT_HEAD);
    this.wornNeck = petStore.wornInSlot(account, PET_DECOR_SLOT_NECK);
  }

  /** 问候气泡：首次进入先「咕咕嘎嘎！」约 1.4 秒，再向主人打招呼，3.2 秒后自动收起 */
  private playGreeting(): void {
    this.cancelSpeechTimer();
    const greetText: string = trf('你好呀，{0}！', appStore.getUserName());
    if (petStore.consumeGreet()) {
      this.speech = tr('咕咕嘎嘎！');
      this.speechVisible = true;
      this.speechTimer = setTimeout(() => {
        this.speech = greetText;
        this.scheduleSpeechHide();
      }, 1400);
    } else {
      this.speech = greetText;
      this.speechVisible = true;
      this.scheduleSpeechHide();
    }
  }

  private scheduleSpeechHide(): void {
    this.speechTimer = setTimeout(() => {
      this.speechVisible = false;
    }, 3200);
  }

  /** 点击企鹅：台词池随机一句（不与上一次重复；围巾专属台词只在佩戴围巾时进入池子），3.2 秒后自动收起 */
  private playChatter(): void {
    const pool: string[] = PET_CHATTERS.slice();
    if (this.wornNeck.length > 0) {
      pool.push(PET_CHATTER_SCARF);
    }
    let index: number = Math.floor(Math.random() * pool.length);
    if (pool[index] === this.lastChatter) {
      index = (index + 1) % pool.length;
    }
    this.lastChatter = pool[index];
    this.cancelSpeechTimer();
    this.speech = tr(pool[index]);
    this.speechVisible = true;
    this.scheduleSpeechHide();
  }

  private cancelSpeechTimer(): void {
    if (this.speechTimer >= 0) {
      clearTimeout(this.speechTimer);
      this.speechTimer = -1;
    }
  }

  /** 刷新积分：先一次性补记功能上线前已归档的明信片，再把仍在组内的已完成卡（出稿失败未删卡）
   *  经 54 补记进账本（账本按 key 查重，不会重复记），最后按账本重算余额 */
  private async refreshPoints(): Promise<void> {
    const account: string = appStore.getAccount();
    if (account.length === 0 || this.refreshing) {
      return;
    }
    this.refreshing = true;
    this.computing = true;
    const records: PostcardRecord[] = postcardStore.listOf(account);
    const dates: string[] = [];
    for (let i = 0; i < records.length; i++) {
      dates.push(records[i].date);
    }
    petStore.seedLegacyOnce(account, dates);
    const libOutcome: LibraryListOutcome = await ServerGateway.myLibraryList();
    if (libOutcome.ok) {
      for (let i = 0; i < libOutcome.entries.length; i++) {
        const entry = libOutcome.entries[i];
        if (entry.completed) {
          petStore.addEarned(account, `lib-${entry.groupId}-${entry.card.index}`,
            petPointsOfTime(entry.card.time));
        }
      }
    }
    this.computing = false;
    this.refreshing = false;
    this.syncFromStore();
  }

  /** 打开改名弹窗：预填当前名字 */
  private openRenameDialog(): void {
    this.renameInput = this.petName;
    this.renameVisible = true;
  }

  private handleRenameConfirm(): void {
    const account: string = appStore.getAccount();
    const trimmed: string = this.renameInput.trim();
    if (trimmed.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: tr('名字不能为空') });
      return;
    }
    petStore.setName(account, trimmed);
    this.renameVisible = false;
  }

  @Builder
  speechBubble() {
    if (this.speechVisible) {
      Text(this.speech)
        .fontSize(Theme.fontBody)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .backgroundColor($r('app.color.nav_bg'))
        .border({ width: 1, color: $r('app.color.divider') })
        .borderRadius(14)
        .padding({ left: 14, right: 14, top: 8, bottom: 8 })
        .constraintSize({ maxWidth: '70%' })
        .shadow({ radius: 8, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 3 })
        .translate({ y: 6 })
    }
  }

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: tr('宠物'),
          showSearch: false
        })

        Scroll() {
          Column({ space: Theme.spaceXl }) {
            Column({ space: Theme.spaceLg }) {
              Stack({ alignContent: Alignment.TopEnd }) {
                PenguinStage({ headId: this.wornHead, neckId: this.wornNeck })
                  .width('100%')
                  .onClick(() => {
                    this.playChatter();
                  })

                this.speechBubble()
              }
              .width('100%')

              Row({ space: 10 }) {
                Text(this.petName)
                  .fontSize(Theme.fontSectionTitle)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))

                Column() {
                  Text(tr('改名'))
                    .fontSize(Theme.fontCaption)
                    .fontColor($r('app.color.text_secondary'))
                }
                .padding({ left: 12, right: 12, top: 5, bottom: 5 })
                .backgroundColor($r('app.color.chip_bg'))
                .borderRadius(Theme.radiusTag)
                .onClick(() => {
                  this.openRenameDialog();
                })

                Blank()

                Text(tr('咕咕嘎嘎！'))
                  .fontSize(Theme.fontCaption)
                  .fontColor($r('app.color.text_tertiary'))
                  .opacity(0)
              }
              .width('100%')
            }
            .width('100%')
            .padding(Theme.spaceXxl)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(Theme.radiusCard)

            Column({ space: Theme.spaceSm }) {
              Row({ space: 6 }) {
                Text('⭐')
                  .fontSize(18)
                Text(tr('我的积分'))
                  .fontSize(Theme.fontSectionTitle)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                Blank()
                Text(this.computing ? '…' : `${this.balance}`)
                  .fontSize(Theme.fontSectionTitle)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Theme.brand())
              }
              .width('100%')

              Text(tr('完成日程卡获得积分：每 1 小时 500（2 小时 1000）；单点卡按 1 小时，单卡最长计 24 小时'))
                .fontSize(Theme.fontCaption)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
            }
            .width('100%')
            .padding(Theme.spaceXxl)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(Theme.radiusCard)

            Row({ space: 12 }) {
              Text('🛍️')
                .fontSize(22)

              Column({ space: 2 }) {
                Text(tr('装饰商城'))
                  .fontSize(Theme.fontSectionTitle)
                  .fontWeight(FontWeight.Bold)
                  .fontColor($r('app.color.text_primary'))
                Text(tr('帽子、围巾 5000 积分一件，攒积分给企鹅换新装'))
                  .fontSize(Theme.fontCaption)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)

              Column() {
                Text(tr('去逛逛'))
                  .fontSize(Theme.fontCaption)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Color.White)
              }
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .linearGradient({
                angle: 135,
                colors: [[Theme.brand(), 0.0], [Theme.brandDeep(), 1.0]]
              })
              .borderRadius(Theme.radiusBtn)
              .onClick(() => {
                this.getUIContext().getRouter().pushUrl({ url: 'pages/PetShopPage' });
              })
            }
            .width('100%')
            .padding(Theme.spaceXxl)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(Theme.radiusCard)
          }
          .width('100%')
          .padding({ left: Theme.spaceXl, right: Theme.spaceXl, top: Theme.spaceXl, bottom: Theme.spaceXxl })
        }
        .scrollBar(BarState.Off)
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')

      if (this.renameVisible) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0, 0, 0, 0.45)')
          .onClick(() => {
            this.renameVisible = false;
          })

        Column({ space: 16 }) {
          Text(tr('宠物改名'))
            .fontSize(Theme.fontCardTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Text(tr('给企鹅起个名字吧（12 字以内）'))
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          TextInput({ placeholder: tr('新名字'), text: this.renameInput })
            .fontSize(Theme.fontBody)
            .fontColor($r('app.color.text_primary'))
            .placeholderColor($r('app.color.text_tertiary'))
            .backgroundColor($r('app.color.input_bg'))
            .borderRadius(Theme.radiusInput)
            .height(48)
            .padding({ left: 14, right: 14 })
            .onChange((value: string) => {
              this.renameInput = value;
            })

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
              this.renameVisible = false;
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
              this.handleRenameConfirm();
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
