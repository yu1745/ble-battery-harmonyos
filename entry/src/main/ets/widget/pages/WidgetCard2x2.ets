/**
 * 2x2 电量卡片 — 模拟随身设备电量样式。
 * 数据来自 FormBindingData (最后已知快照, 断联时锁定显示, 永不显示离线)。
 */
@Entry
@Component
struct WidgetCard2x2 {
  @LocalStorageProp('socText') socText: string = '--';
  @LocalStorageProp('voltageText') voltageText: string = '--';
  @LocalStorageProp('name') name: string = 'FD…';
  @LocalStorageProp('stateText') stateText: string = '—';
  @LocalStorageProp('updatedAtText') updatedAtText: string = '--';
  @LocalStorageProp('locked') locked: number = 0;

  private socColor(): string {
    if (this.socText === '--') {
      return '#9AA0A6';
    }
    const soc = Number(this.socText);
    if (soc <= 20) {
      return '#E8564A';
    }
    if (soc <= 50) {
      return '#F5B940';
    }
    return '#4FC47F';
  }

  private fillWidth(): string {
    if (this.socText === '--') {
      return '0%';
    }
    const pct = Math.min(Math.max(Number(this.socText), 4), 100);
    return `${pct}%`;
  }

  build() {
    Column({ space: 6 }) {
      Row({ space: 4 }) {
        Text(this.name)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.locked === 1) {
          Text('锁定')
            .fontSize(9)
            .fontColor('#FFFFFF')
            .backgroundColor('#9AA0A6')
            .borderRadius(4)
            .padding({ left: 3, right: 3, top: 1, bottom: 1 })
        }
      }
      .width('100%')

      Row({ space: 6 }) {
        // 电池图形: 外框 + 左对齐填充 + 右侧正极头
        Stack({ alignContent: Alignment.Start }) {
          Column()
            .width('100%')
            .height('100%')
            .border({ width: 3, color: this.socColor() })
            .borderRadius(10)
          Column()
            .width(this.fillWidth())
            .height('100%')
            .backgroundColor(this.socColor())
            .borderRadius(7)
            .margin(2)
        }
        .width('44%')
        .height('52%')

        Column()
          .width(5)
          .height('26%')
          .backgroundColor(this.socColor())
          .borderRadius(2)

        Column({ space: 2 }) {
          Row() {
            Text(this.socText)
              .fontSize(32)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.socColor())
            Text('%')
              .fontSize(14)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.socColor())
              .margin({ left: 1, bottom: 5 })
          }
          .alignItems(VerticalAlign.Bottom)

          Text(this.voltageText)
            .fontSize(12)
            .fontColor($r('sys.color.font_secondary'))
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.End)
      }
      .width('100%')
      .layoutWeight(1)

      Row() {
        Text(this.updatedAtText === '--' ? '尚未连接' : `${this.updatedAtText} 更新`)
          .fontSize(11)
          .fontColor($r('sys.color.font_tertiary'))
          .maxLines(1)
          .layoutWeight(1)
        if (this.stateText !== '—') {
          Text(this.stateText)
            .fontSize(11)
            .fontColor($r('sys.color.font_tertiary'))
        }
      }
      .width('100%')
    }
    .padding(12)
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_primary'))
    .onClick(() => {
      postCardAction(this, {
        'action': 'router',
        'abilityName': 'EntryAbility',
        'params': {}
      });
    })
  }
}
