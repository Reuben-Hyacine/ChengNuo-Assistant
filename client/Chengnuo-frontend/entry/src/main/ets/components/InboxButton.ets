/**
 * 收件箱入口按钮：铃铛 + 未读角标
 */
@Component
export struct InboxButton {
  @StorageProp('inboxUnread') unread: number = 3;

  build() {
    Stack({ alignContent: Alignment.TopEnd }) {
      Image($r('app.media.icon_notice'))
        .width(38)
        .height(38)
      if (this.unread > 0) {
        Text(this.unread > 9 ? '9+' : `${this.unread}`)
          .fontSize(9)
          .fontColor(Color.White)
          .fontWeight(FontWeight.Bold)
          .textAlign(TextAlign.Center)
          .height(16)
          .constraintSize({ minWidth: 16 })
          .padding({ left: 4, right: 4 })
          .backgroundColor($r('app.color.badge_red'))
          .borderRadius(8)
          .translate({ x: 6, y: -4 })
      }
    }
    .padding(4)
    .onClick(() => {
      this.getUIContext().getRouter().pushUrl({ url: 'pages/InboxPage' });
    })
  }
}
