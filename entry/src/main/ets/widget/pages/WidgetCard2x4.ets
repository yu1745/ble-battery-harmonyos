/**
 * 2x4 电量卡片 — 电量 + 电压/电流 + 电芯/温度/循环信息。
 */
@Entry
@Component
struct WidgetCard2x4 {
  @LocalStorageProp('socText') socText: string = '--';
  @LocalStorageProp('voltageText') voltageText: string = '--';
  @LocalStorageProp('currentText') currentText: string = '';
  @LocalStorageProp('name') name: string = 'FD…';
  @LocalStorageProp('stateText') stateText: string = '—';
  @LocalStorageProp('updatedAtText') updatedAtText: string = '--';
  @LocalStorageProp('disconnected') disconnected: number = 0;
  @LocalStorageProp('locked') locked: number = 0;
  @LocalStorageProp('cycles') cycles: number = 0;
  @LocalStorageProp('tempText') tempText: string = '';
  @LocalStorageProp('cellText') cellText: string = '';
  @LocalStorageProp('capacityText') capacityText: string = '';

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

  @Builder
  InfoCell(title: string, value: string) {
    Column({ space: 2 }) {
      Text(title)
        .fontSize(10)
        .fontColor($r('sys.color.font_tertiary'))
      Text(value === '' ? '--' : value)
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('sys.color.font_primary'))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 4 }) {
        Text(this.name)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.stateText !== '—') {
          Text(this.stateText)
            .fontSize(10)
            .fontColor(this.stateText === '充电中' ? '#4FC47F' : (this.stateText === '放电中' ? '#F5B940' : $r('sys.color.font_tertiary')))
            .backgroundColor($r('sys.color.comp_background_tertiary'))
            .borderRadius(6)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
        }
        if (this.disconnected === 1) {
          Text('断联')
            .fontSize(10)
            .fontColor('#FFFFFF')
            .backgroundColor('#E8564A')
            .borderRadius(6)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
        } else if (this.locked === 1) {
          Text('锁定')
            .fontSize(10)
            .fontColor('#FFFFFF')
            .backgroundColor('#9AA0A6')
            .borderRadius(6)
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
        }
      }
      .width('100%')

      Row({ space: 10 }) {
        // 左侧: 电池图形 + 百分比
        Column({ space: 6 }) {
          Stack({ alignContent: Alignment.Start }) {
            Column()
              .width('100%')
              .height('100%')
              .border({ width: 3, color: this.socColor() })
              .borderRadius(8)
            Column()
              .width(this.fillWidth())
              .height('100%')
              .backgroundColor(this.socColor())
              .borderRadius(5)
              .margin(2)
          }
          .width('100%')
          .height(20)

          Row({ space: 2 }) {
            Text(this.socText)
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.socColor())
            Text('%')
              .fontSize(12)
              .fontColor(this.socColor())
              .margin({ bottom: 4 })
          }
          .alignItems(VerticalAlign.Bottom)
        }
        .width(92)

        // 右侧: 关键信息
        Row() {
          Column({ space: 4 }) {
            Text(this.voltageText)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
            if (this.currentText !== '') {
              Text(this.currentText)
                .fontSize(12)
                .fontColor($r('sys.color.font_secondary'))
            }
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Column({ space: 4 }) {
            Text(this.disconnected === 1 ? '断联' :
              (this.updatedAtText === '--' || this.updatedAtText === '尚未连接' ? '尚未连接' : this.updatedAtText))
              .fontSize(11)
              .fontColor(this.disconnected === 1 ? '#E8564A' : $r('sys.color.font_tertiary'))
            if (this.capacityText !== '') {
              Text(this.capacityText)
                .fontSize(11)
                .fontColor($r('sys.color.font_secondary'))
            }
          }
          .alignItems(HorizontalAlign.End)
        }
        .layoutWeight(1)
      }
      .width('100%')

      Divider()
        .strokeWidth(1)
        .color($r('sys.color.comp_divider'))
        .opacity(0.6)

      Row({ space: 4 }) {
        this.InfoCell('电芯', this.cellText)
        this.InfoCell('温度', this.tempText)
        this.InfoCell('循环', this.cycles > 0 ? `${this.cycles}次` : '--')
      }
      .width('100%')
    }
    .padding(14)
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
