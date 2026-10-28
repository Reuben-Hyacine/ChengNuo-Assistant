import { Backend, ProfileRecord } from '@chengnuo/backend';
import { fileIo } from '@kit.CoreFileKit';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { util } from '@kit.ArkTS';
import { appStore } from '../store/AppStore';
import { Theme } from '../common/Theme';
import { tr, trf } from '../common/I18n';
import { uidText } from '../common/Format';
import { ServerGateway } from '../net/ServerGateway';
import { AccountOutcome, MessageOutcome, ProfileOutcome } from '../net/ServerModels';
import { regionProvinceNames, regionProvinceOf } from '../common/RegionData';

/**
 * 个人空间（我的页头像账号板块进入）：账号名（82 改名）/ 头像 / 性别 / 生日 / 个性签名（审核）/ 地区（省市两级）。
 * 账号名即昵称：修改账号名（auth.rename 82，服务器全库级联 + 客户端本地库同步）在本页「账号名」行弹窗进行。
 * 双端记录：客户端 ProfileStore 一份 + 服务器（90/91）一份；单「保存修改」整份持久化（字段+头像一次存）。
 * 签名先过本机词库审核（ModerationService），服务器再复审（409 toast）；所有资料字段都可留空。
 * 选择弹窗（头像/性别）为自定义样式：按钮竖排、整宽居中、带按钮框（系统 ActionSheet 为纯文字行，不满足样式要求）。
 */
@Entry
@Component
struct PersonalSpacePage {
  @StorageProp('userName') userName: string = tr('程诺用户');
  @StorageProp('serverUserId') serverUserId: number = 0;
  @State genderSel: string = '';
  @State birthdaySel: string = '';
  @State signInput: string = '';
  @State provinceSel: string = '';
  @State citySel: string = '';
  @State saving: boolean = false;
  /** 刚选好的头像预览（保存前）；undefined = 无新头像 */
  @State previewAvatar: image.PixelMap | undefined = undefined;
  /** 已落盘头像的 file:// URI（保存后） */
  @State savedAvatarUri: string = '';
  /** 头像选择弹窗（自定义：按钮竖排、居中、带框） */
  @State avatarSheetVisible: boolean = false;
  /** 性别选择弹窗（同上自定义样式，当前选中项品牌描边高亮） */
  @State genderSheetVisible: boolean = false;
  /** 修改账号名弹窗（82） */
  @State renameVisible: boolean = false;
  @State renameInput: string = '';
  @State renameBusy: boolean = false;
  /** 头像待存字节：undefined = 不动 / null = 删除 / Uint8Array = 覆盖（JPEG） */
  private pendingAvatarBytes: Uint8Array | null | undefined = undefined;

  aboutToAppear(): void {
    this.loadProfile();
  }

  private fillFrom(gender: string, birthday: string,
    signature: string, province: string, city: string): void {
    this.genderSel = gender;
    this.birthdaySel = birthday;
    this.signInput = signature;
    this.provinceSel = province;
    this.citySel = city;
  }

  /** 读取个人空间：先本机副本；本机没有且在线 → 拉服务器副本（含头像）采纳到本机 */
  private async loadProfile(): Promise<void> {
    const account: string = appStore.getAccount();
    const local: ProfileRecord | null = Backend.getProfileRecord(account);
    if (local !== null) {
      this.fillFrom(local.gender, local.birthday,
        local.signature, local.province, local.city);
      this.savedAvatarUri = Backend.profileAvatarUri(account);
      return;
    }
    if (!appStore.serverOnline) {
      return;
    }
    const remote: ProfileOutcome = await ServerGateway.getProfile(true);
    if (!remote.ok || !remote.found) {
      return;
    }
    const record: ProfileRecord = new ProfileRecord(account,
      remote.gender, remote.birthday, remote.signature, remote.province, remote.city,
      remote.hasAvatar, '');
    let avatarBytes: Uint8Array | undefined = undefined;
    if (remote.hasAvatar && remote.avatarBase64.length > 0) {
      const helper: util.Base64Helper = new util.Base64Helper();
      avatarBytes = helper.decodeSync(remote.avatarBase64);
    }
    Backend.saveProfileRecord(record, avatarBytes);
    this.fillFrom(record.gender, record.birthday,
      record.signature, record.province, record.city);
    this.savedAvatarUri = Backend.profileAvatarUri(account);
    // 采纳即本地资料已变化：通知「我的」页板块刷新小头像
    AppStorage.setOrCreate('profileStamp', Date.now());
  }

  private openAvatarSheet(): void {
    this.avatarSheetVisible = true;
  }

  /** 相册选图 → 解码 → 压到 512 边内 → JPEG(q70) 字节，预览 + 待存 */
  private async pickPhoto(): Promise<void> {
    try {
      const picker: photoAccessHelper.PhotoViewPicker = new photoAccessHelper.PhotoViewPicker();
      const options: photoAccessHelper.PhotoSelectOptions = {
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      };
      const result: photoAccessHelper.PhotoSelectResult = await picker.select(options);
      if (result.photoUris.length === 0) {
        return;
      }
      const file: fileIo.File = fileIo.openSync(result.photoUris[0], fileIo.OpenMode.READ_ONLY);
      let source: image.ImageSource | undefined = undefined;
      let pixelMap: image.PixelMap | undefined = undefined;
      try {
        source = image.createImageSource(file.fd);
        pixelMap = await source.createPixelMap();
        const info: image.ImageInfo = await pixelMap.getImageInfo();
        const maxSide: number = Math.max(info.size.width, info.size.height);
        if (maxSide > 512) {
          const scale: number = 512 / maxSide;
          await pixelMap.scale(scale, scale);
        }
        const packer: image.ImagePacker = image.createImagePacker();
        const packingOption: image.PackingOption = { format: 'image/jpeg', quality: 70 };
        const packed: ArrayBuffer = await packer.packing(pixelMap, packingOption);
        packer.release();
        const bytes: Uint8Array = new Uint8Array(packed);
        if (this.previewAvatar !== undefined) {
          this.previewAvatar.release();
        }
        this.previewAvatar = pixelMap;
        this.pendingAvatarBytes = bytes;
        pixelMap = undefined;
      } finally {
        if (pixelMap !== undefined) {
          pixelMap.release();
        }
        if (source !== undefined) {
          source.release();
        }
        fileIo.closeSync(file);
      }
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: tr('头像处理失败，请换一张 📷') });
    }
  }

  private removeAvatar(): void {
    this.avatarSheetVisible = false;
    if (this.previewAvatar !== undefined) {
      this.previewAvatar.release();
      this.previewAvatar = undefined;
    }
    this.pendingAvatarBytes = null;
  }

  private openGenderSheet(): void {
    this.genderSheetVisible = true;
  }

  /** 打开改名弹窗：预填当前账号名 */
  private openRenameDialog(): void {
    this.renameInput = appStore.getAccount();
    this.renameBusy = false;
    this.renameVisible = true;
  }

  /** 修改账号名（82）：服务器全库级联改名 + 客户端本地库同步换名（LocalRouter 已处理）；
   *  成功后以服务器返回的规范名更新本地会话与显示名 */
  private async handleRenameConfirm(): Promise<void> {
    if (this.renameBusy) {
      return;
    }
    const newName: string = this.renameInput.trim();
    if (newName.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: tr('请输入新的账号名 ✍️') });
      return;
    }
    if (newName === appStore.getAccount()) {
      this.renameVisible = false;
      return;
    }
    this.renameBusy = true;
    const outcome: AccountOutcome = await ServerGateway.renameAccount(newName);
    this.renameBusy = false;
    if (!outcome.ok) {
      this.getUIContext().getPromptAction().showToast({ message: outcome.message });
      return;
    }
    const canonical: string = outcome.account.length > 0 ? outcome.account : newName;
    ServerGateway.setSession(ServerGateway.getToken(), canonical, appStore.getPassword());
    AppStorage.setOrCreate('serverAccount', canonical);
    appStore.setUserName(canonical);
    this.renameVisible = false;
    this.getUIContext().getPromptAction().showToast({ message: trf('账号名已改为 {0} ✨', canonical) });
  }

  private formatDate(d: Date): string {
    const m: number = d.getMonth() + 1;
    const day: number = d.getDate();
    return `${d.getFullYear()}-${m < 10 ? '0' : ''}${m}-${day < 10 ? '0' : ''}${day}`;
  }

  private openBirthdayPicker(): void {
    let selected: Date = new Date(2000, 0, 1);
    if (this.birthdaySel.length === 10) {
      const parts: string[] = this.birthdaySel.split('-');
      const parsed: Date = new Date(Number(parts[0]), Number(parts[1]) - 1, Number(parts[2]));
      if (!Number.isNaN(parsed.getTime())) {
        selected = parsed;
      }
    }
    // end 取明天零点：selected==end（同一天）时选择器不生效、轮子会跌回起点，
    // 推后一天让今天/已存生日严格落在 (start, end) 区间内即可正常生效
    const now: Date = new Date();
    const endAt: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
    this.getUIContext().showDatePickerDialog({
      start: new Date(1900, 0, 1),
      end: endAt,
      selected: selected,
      onDateAccept: (value: Date) => {
        this.birthdaySel = this.formatDate(value);
      }
    });
  }

  private openProvincePicker(): void {
    const names: string[] = regionProvinceNames();
    const current: number = names.indexOf(this.provinceSel);
    const selected: number = current >= 0 ? current : 0;
    this.getUIContext().showTextPickerDialog({
      range: names,
      selected: selected,
      onAccept: (value: TextPickerResult) => {
        const index: number = typeof value.index === 'number' ? value.index : selected;
        const name: string = index >= 0 && index < names.length ? names[index] : names[selected];
        this.provinceSel = name;
        this.citySel = '';
        this.openCityPicker(name);
      }
    });
  }

  private openCityPicker(provinceName: string): void {
    const province = regionProvinceOf(provinceName);
    if (province === null) {
      return;
    }
    const names: string[] = province.cities;
    const current: number = names.indexOf(this.citySel);
    const selected: number = current >= 0 ? current : 0;
    this.getUIContext().showTextPickerDialog({
      range: names,
      selected: selected,
      onAccept: (value: TextPickerResult) => {
        const index: number = typeof value.index === 'number' ? value.index : selected;
        this.citySel = index >= 0 && index < names.length ? names[index] : names[selected];
      }
    });
  }

  private regionText(): string {
    if (this.provinceSel.length === 0) {
      return tr('未设置');
    }
    if (this.citySel.length === 0) {
      return this.provinceSel;
    }
    return `${this.provinceSel} ${this.citySel}`;
  }

  /** 保存修改：本机校验+审核 → 本机整份落盘（含头像）→ 在线再推服务器（91）；
   *  个性化服务开启时把个人空间信息写一份进用户信息（93，AI 上下文「本人用户资料」） */
  private async handleSave(): Promise<void> {
    if (this.saving) {
      return;
    }
    const signature: string = this.signInput.trim();
    if (signature.length > 100) {
      this.getUIContext().getPromptAction().showToast({ message: tr('个性签名最长 100 字') });
      return;
    }
    if (signature.length > 0 && !Backend.textPassesModeration(signature)) {
      this.getUIContext().getPromptAction().showToast({ message: tr('个性签名未通过智能审核 ✍️') });
      return;
    }
    this.saving = true;
    const account: string = appStore.getAccount();
    const pending: Uint8Array | null | undefined = this.pendingAvatarBytes;
    let avatarOp: string = 'keep';
    let avatarBase64: string = '';
    if (pending !== undefined) {
      if (pending === null) {
        avatarOp = 'remove';
      } else {
        const helper: util.Base64Helper = new util.Base64Helper();
        avatarBase64 = helper.encodeToStringSync(pending);
        avatarOp = 'update';
      }
    }
    const record: ProfileRecord = new ProfileRecord(account, this.genderSel, this.birthdaySel,
      signature, this.provinceSel, this.citySel, this.savedAvatarUri.length > 0, '');
    Backend.saveProfileRecord(record, pending);
    this.pendingAvatarBytes = undefined;
    if (this.previewAvatar !== undefined) {
      this.previewAvatar.release();
      this.previewAvatar = undefined;
    }
    this.savedAvatarUri = Backend.profileAvatarUri(account);
    AppStorage.setOrCreate('profileStamp', Date.now());
    if (!appStore.serverOnline) {
      this.saving = false;
      this.getUIContext().getPromptAction().showToast({ message: tr('个人空间已保存 ✨') });
      return;
    }
    const fields: Record<string, Object> = {
      'gender': this.genderSel,
      'birthday': this.birthdaySel,
      'signature': signature,
      'province': this.provinceSel,
      'city': this.citySel
    };
    const outcome: MessageOutcome = await ServerGateway.updateProfile(fields, avatarOp, avatarBase64);
    this.saving = false;
    if (!outcome.ok) {
      this.getUIContext().getPromptAction().showToast({
        message: trf('已保存到本机，服务器暂未同步：{0}', outcome.message)
      });
      return;
    }
    // 个性化服务开启时，把个人空间信息写一份进用户信息；关闭时用户信息保持为空
    // （开关关闭时已清空），此处不同步；同步失败不打扰保存主流程
    if (Backend.isPersonalizationEnabled()) {
      await ServerGateway.syncUserInfoPut(fields);
    }
    this.getUIContext().getPromptAction().showToast({ message: tr('个人空间已保存 ✨') });
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
          Text(tr('个人空间'))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .layoutWeight(1)
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 12, bottom: 8 })

        Scroll() {
          Column({ space: 16 }) {
            Column({ space: 10 }) {
              if (this.previewAvatar !== undefined) {
                Image(this.previewAvatar)
                  .width(88)
                  .height(88)
                  .borderRadius(44)
                  .objectFit(ImageFit.Cover)
              } else if (this.savedAvatarUri.length > 0) {
                Image(this.savedAvatarUri)
                  .width(88)
                  .height(88)
                  .borderRadius(44)
                  .objectFit(ImageFit.Cover)
              } else {
                Image($r('app.media.penguin'))
                  .width(88)
                  .height(88)
                  .borderRadius(44)
                  .objectFit(ImageFit.Contain)
              }

              Text(this.userName)
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor($r('app.color.text_primary'))
              if (this.serverUserId > 0) {
                Text(`UID：${uidText(this.serverUserId)}`)
                  .fontSize(Theme.fontCaption)
                  .fontColor($r('app.color.text_tertiary'))
              }

              Text(tr('点击更换头像'))
                .fontSize(Theme.fontCaption)
                .fontColor($r('app.color.text_secondary'))
            }
            .width('100%')
            .padding({ top: 22, bottom: 20 })
            .alignItems(HorizontalAlign.Center)
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(Theme.radiusCard)
            .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
            .onClick(() => {
              this.openAvatarSheet();
            })

            Column() {
              Row({ space: 12 }) {
                Text(tr('账号名'))
                  .fontSize(Theme.fontBody)
                  .fontColor($r('app.color.text_primary'))
                  .width(72)
                Text(this.userName)
                  .fontSize(Theme.fontBody)
                  .fontColor($r('app.color.text_primary'))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                  .textAlign(TextAlign.End)
                Text('›')
                  .fontSize(18)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .onClick(() => {
                this.openRenameDialog();
              })

              Divider()
                .color($r('app.color.divider'))
                .margin({ left: 16, right: 16 })

              Row({ space: 12 }) {
                Text(tr('性别'))
                  .fontSize(Theme.fontBody)
                  .fontColor($r('app.color.text_primary'))
                  .width(72)
                Text(this.genderSel.length > 0 ? tr(this.genderSel) : tr('未设置'))
                  .fontSize(Theme.fontBody)
                  .fontColor(this.genderSel.length > 0 ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
                  .layoutWeight(1)
                  .textAlign(TextAlign.End)
                Text('›')
                  .fontSize(18)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .onClick(() => {
                this.openGenderSheet();
              })

              Divider()
                .color($r('app.color.divider'))
                .margin({ left: 16, right: 16 })

              Row({ space: 12 }) {
                Text(tr('生日'))
                  .fontSize(Theme.fontBody)
                  .fontColor($r('app.color.text_primary'))
                  .width(72)
                Text(this.birthdaySel.length > 0 ? this.birthdaySel : tr('未设置'))
                  .fontSize(Theme.fontBody)
                  .fontColor(this.birthdaySel.length > 0 ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
                  .layoutWeight(1)
                  .textAlign(TextAlign.End)
                Text('›')
                  .fontSize(18)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .onClick(() => {
                this.openBirthdayPicker();
              })

              Divider()
                .color($r('app.color.divider'))
                .margin({ left: 16, right: 16 })

              Row({ space: 12 }) {
                Text(tr('地区'))
                  .fontSize(Theme.fontBody)
                  .fontColor($r('app.color.text_primary'))
                  .width(72)
                Text(this.regionText())
                  .fontSize(Theme.fontBody)
                  .fontColor(this.provinceSel.length > 0 ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
                  .layoutWeight(1)
                  .textAlign(TextAlign.End)
                Text('›')
                  .fontSize(18)
                  .fontColor($r('app.color.text_tertiary'))
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 14 })
              .onClick(() => {
                this.openProvincePicker();
              })

              Divider()
                .color($r('app.color.divider'))
                .margin({ left: 16, right: 16 })

              Column({ space: 10 }) {
                Text(tr('个性签名'))
                  .fontSize(Theme.fontBody)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                TextArea({ placeholder: tr('一句话介绍自己…'), text: this.signInput })
                  .fontSize(Theme.fontBody)
                  .fontColor($r('app.color.text_primary'))
                  .placeholderColor($r('app.color.text_tertiary'))
                  .backgroundColor($r('app.color.input_bg'))
                  .borderRadius(Theme.radiusInput)
                  .constraintSize({ minHeight: 76 })
                  .maxLength(100)
                  .padding(12)
                  .width('100%')
                  .onChange((value: string) => {
                    this.signInput = value;
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 14, bottom: 16 })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .backgroundColor($r('app.color.bg_card'))
            .borderRadius(Theme.radiusCard)
            .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })

            Column() {
              Text(this.saving ? tr('保存中…') : tr('保存修改'))
                .fontSize(Theme.fontBody)
                .fontWeight(FontWeight.Bold)
                .fontColor(Color.White)
            }
            .width('100%')
            .height(48)
            .justifyContent(FlexAlign.Center)
            .linearGradient({
              angle: 135,
              colors: [[Theme.brand(), 0.0], [Theme.brandDeep(), 1.0]]
            })
            .borderRadius(Theme.radiusBtn)
            .opacity(this.saving ? 0.6 : 1.0)
            .onClick(() => {
              this.handleSave();
            })

            Text(tr('账号名即昵称；资料同时保存到本机与服务器'))
              .fontSize(Theme.fontCaption)
              .fontColor($r('app.color.text_tertiary'))
              .textAlign(TextAlign.Center)
              .width('100%')
          }
          .width('100%')
          .padding({ left: Theme.spaceXl, right: Theme.spaceXl, top: 12 })
        }
        .layoutWeight(1)
        .width('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.bg_page'))

      // 头像选择弹窗：按钮竖排、整宽居中、带按钮框；backdrop 点击关闭
      if (this.avatarSheetVisible) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0, 0, 0, 0.45)')
          .onClick(() => {
            this.avatarSheetVisible = false;
          })

        Column({ space: 12 }) {
          Text(tr('更换头像'))
            .fontSize(Theme.fontCardTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .textAlign(TextAlign.Center)

          this.sheetBtn(tr('上传照片'), 'primary', (): void => {
            this.avatarSheetVisible = false;
            this.pickPhoto();
          })
          this.sheetBtn(tr('恢复默认头像'), 'option', (): void => {
            this.removeAvatar();
          })
          this.sheetBtn(tr('取消'), 'cancel', (): void => {
            this.avatarSheetVisible = false;
          })
        }
        .width('72%')
        .padding(20)
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(Theme.radiusModal)
        .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
        .onClick(() => {
        })
      }

      // 性别选择弹窗：当前选中项品牌描边高亮
      if (this.genderSheetVisible) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0, 0, 0, 0.45)')
          .onClick(() => {
            this.genderSheetVisible = false;
          })

        Column({ space: 12 }) {
          Text(tr('选择性别'))
            .fontSize(Theme.fontCardTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')
            .textAlign(TextAlign.Center)

          this.sheetBtn(tr('男'), this.genderSel === '男' ? 'primary' : 'option', (): void => {
            this.genderSel = '男';
            this.genderSheetVisible = false;
          })
          this.sheetBtn(tr('女'), this.genderSel === '女' ? 'primary' : 'option', (): void => {
            this.genderSel = '女';
            this.genderSheetVisible = false;
          })
          this.sheetBtn(tr('不公开'), this.genderSel === '不公开' ? 'primary' : 'option', (): void => {
            this.genderSel = '不公开';
            this.genderSheetVisible = false;
          })
          this.sheetBtn(tr('取消'), 'cancel', (): void => {
            this.genderSheetVisible = false;
          })
        }
        .width('72%')
        .padding(20)
        .backgroundColor($r('app.color.bg_card'))
        .borderRadius(Theme.radiusModal)
        .shadow({ radius: 16, color: $r('app.color.shadow_soft'), offsetX: 0, offsetY: 6 })
        .onClick(() => {
        })
      }

      // 修改账号名弹窗（82）：backdrop 点击关闭；卡片上的点击不会冒泡（ArkUI onClick 不冒泡），再补一层空 onClick 兜底
      if (this.renameVisible) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0, 0, 0, 0.45)')
          .onClick(() => {
            if (!this.renameBusy) {
              this.renameVisible = false;
            }
          })

        Column({ space: 16 }) {
          Text(tr('修改账号名'))
            .fontSize(Theme.fontCardTitle)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
            .width('100%')

          Text(tr('改名后相关卡片与记录中的名称都会同步更新'))
            .fontSize(Theme.fontCaption)
            .fontColor($r('app.color.text_secondary'))
            .width('100%')

          TextInput({ placeholder: tr('新账号名'), text: this.renameInput })
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
              if (!this.renameBusy) {
                this.renameVisible = false;
              }
            })

            Column() {
              Text(this.renameBusy ? tr('提交中…') : tr('确认'))
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
  }

  /** 弹窗选项按钮：primary=品牌描边主操作/选中项；option=浅灰填充；cancel=浅灰填充次要文字。
   *  整宽、高 44、圆角按钮框、文字居中，竖排排布（space 12） */
  @Builder
  private sheetBtn(label: string, style: string, onTap: () => void) {
    Column() {
      Text(label)
        .fontSize(Theme.fontBody)
        .fontWeight(FontWeight.Bold)
        .fontColor(style === 'cancel' ? $r('app.color.text_secondary')
          : (style === 'primary' ? Theme.brandDeep() : $r('app.color.text_primary')))
    }
    .width('100%')
    .height(44)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(style === 'primary' ? Color.Transparent : $r('app.color.chip_bg'))
    .border({ width: style === 'primary' ? 1.5 : 0, color: Theme.brand() })
    .borderRadius(Theme.radiusBtn)
    .onClick(() => {
      onTap();
    })
  }
}
