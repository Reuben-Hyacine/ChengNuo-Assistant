/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { postcardStore } from '../store/PostcardStore';
import { shopStore } from '../store/ShopStore';
import { petStore } from '../store/PetStore';
import { groupChatStore } from '../store/GroupChatStore';
import { langStore } from '../store/LangStore';
import { notificationPrefStore } from '../store/NotificationPrefStore';
import { weatherPrefStore } from '../store/WeatherPrefStore';
import { loginAccountsStore } from '../store/LoginAccountsStore';
import { themeStore } from '../store/ThemeStore';
import { birthdayStore } from '../store/BirthdayStore';
import { countdownStore } from '../store/CountdownStore';
import { initAgc } from '../net/EmailAuth';
import { Backend } from '@chengnuo/backend';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    // 注入上下文供明信片库读写 filesDir（按账号持久化）
    postcardStore.init(this.context);
    // 注入上下文供卡片小铺读写 filesDir（按账号、按周持久化）
    shopStore.init(this.context);
    // 注入上下文供宠物养成（名字/积分缓存/装饰）读写 filesDir（按账号持久化）
    petStore.init(this.context);
    // 注入上下文供群聊本地记录读写 filesDir（按账号持久化，服务器只做短期中转）
    groupChatStore.init(this.context);
    // 界面语言偏好（默认中文）注入 AppStorage，供各页 @StorageProp('appLang') 同步
    langStore.init(this.context);
    AppStorage.setOrCreate('appLang', langStore.load());
    // 主题色偏好（默认珊瑚橙 #FF7A59）注入 AppStorage，供 Theme.brand()/brandDeep()/brandSoft() 读取
    themeStore.init(this.context);
    AppStorage.setOrCreate('themeColor', themeStore.load());
    // 横幅通知开关（提醒设置页）：读盘镜像 AppStorage（默认全部开启）
    notificationPrefStore.init(this.context);
    // 天气城市偏好（日程页天气块）：读盘镜像 AppStorage（默认北京市 市辖区）
    weatherPrefStore.init(this.context);
    // 最近登录账号表（登录页邮箱框下拉）：注入上下文供 preferences 读写
    loginAccountsStore.init(this.context);
    // 生日祝福每天一次标记（主页生日祝福弹窗去重）：注入上下文供 preferences 读写
    birthdayStore.init(this.context);
    // 倒计时（类倒数日）本地库：注入上下文供按账号读写 filesDir（纯本机不联网）
    countdownStore.init(this.context);
    // 后端内置为本地库：初始化后端数据目录（filesDir/backend-data）与 boot-at
    Backend.init(this.context);
    // AGC（邮箱验证码）SDK 初始化：读取 rawfile 配置注入，失败不阻塞启动
    initAgc(this.context.getApplicationContext());
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    if (this.isFromReminderBanner(want)) {
      AppStorage.setOrCreate('reminderBannerOpen', true);
      hilog.info(DOMAIN, 'testTag', 'cold start from reminder banner');
    }
    if (this.isFromChatBanner(want)) {
      AppStorage.setOrCreate('chatBannerOpen', true);
      hilog.info(DOMAIN, 'testTag', 'cold start from chat banner');
    }
    this.applyLockCardWant(want);
  }

  /** 热启动：应用存活时点击提醒横幅/通知条目回到应用（置旗标，主框架 onPageShow 消费并切日程页） */
  onNewWant(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onNewWant');
    if (this.isFromReminderBanner(want)) {
      AppStorage.setOrCreate('reminderBannerOpen', true);
      hilog.info(DOMAIN, 'testTag', 'hot start from reminder banner');
    }
    if (this.isFromChatBanner(want)) {
      AppStorage.setOrCreate('chatBannerOpen', true);
      hilog.info(DOMAIN, 'testTag', 'hot start from chat banner');
    }
    this.applyLockCardWant(want);
  }

  /** 提醒通知点击拉起携带 parameters.from=reminderBanner */
  private isFromReminderBanner(want: Want): boolean {
    return this.wantFromIs(want, 'reminderBanner');
  }

  /** 好友聊天横幅点击拉起携带 parameters.from=chatBanner */
  private isFromChatBanner(want: Want): boolean {
    return this.wantFromIs(want, 'chatBanner');
  }

  private wantFromIs(want: Want, expected: string): boolean {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      return false;
    }
    const v: Object | undefined = params['from'];
    return typeof v === 'string' && v === expected;
  }

  /** 锁屏卡片 router 拉起携带 parameters.from=lockCard：把动作（open 进日程页 / checkin 自动打卡）
   *  存入 AppStorage（日程页消费执行）并置 reminderBannerOpen（主框架切到日程 tab） */
  private applyLockCardWant(want: Want): void {
    const params: Record<string, Object> | undefined = want.parameters;
    if (params === undefined) {
      return;
    }
    const v: Object | undefined = params['from'];
    if (typeof v !== 'string' || v !== 'lockCard') {
      return;
    }
    const actionObj: Object | undefined = params['action'];
    const cardIdObj: Object | undefined = params['cardId'];
    const dateObj: Object | undefined = params['date'];
    const action: Record<string, Object> = {
      'action': typeof actionObj === 'string' ? actionObj : 'open',
      'cardId': typeof cardIdObj === 'string' ? cardIdObj : '',
      'date': typeof dateObj === 'string' ? dateObj : ''
    };
    AppStorage.setOrCreate('lockCardAction', JSON.stringify(action));
    AppStorage.setOrCreate('reminderBannerOpen', true);
    hilog.info(DOMAIN, 'testTag', 'start from lock screen card');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, decide entry page, then set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');
    this.loadEntryPage(windowStage);
  }

  /**
   * 开屏动画：每次冷启动都播放（pages/Splash → 登录页）。
   * 杀后台后重新打开会重新走 onCreate → onWindowStageCreate → 再次播放；
   * 从后台恢复（进程存活）只走 onForeground，不会重复播放。
   * 加载期间系统启动页（startWindow）保持显示，视觉上无缝衔接。
   */
  private loadEntryPage(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Splash', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}