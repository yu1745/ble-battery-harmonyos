/**
 * 主页面 — BLE BMS 电量监控。
 * 移植自 yu1745/ble-battery (Web Bluetooth 版) 的界面与功能:
 *  电量/电压/电流/功率/循环/SOH/容量/温度/15串电芯/状态位/原始数据。
 */
import { access } from '@kit.ConnectivityKit';
import { BatteryMonitor, MonitorStatus } from '../monitor/BatteryMonitor';
import { DiscoveredDevice } from '../ble/BleManager';
import { BmsData, BitFlag } from '../ble/BmsTypes';
import { BatterySnapshot, emptySnapshot } from '../model/BatterySnapshot';
import { Store, HistoryRecord } from '../data/Store';

const DOMAIN: number = 0xB100;
const TAG: string = 'IndexPage';
const ACCENT = '#1C64F2';

interface CellChip {
  index: number;
  mv: number;
  isMin: boolean;
  isMax: boolean;
  isWarn: boolean;
}

@Entry
@Component
struct Index {
  @State snap: BatterySnapshot = emptySnapshot();
  @State status: MonitorStatus = new MonitorStatus();
  @State devices: DiscoveredDevice[] = [];
  @State history: HistoryRecord[] = [];
  @State lastBms: BmsData | null = null;
  @State cells: CellChip[] = [];
  @State activeProtections: string[] = [];
  @State activeFaults: string[] = [];
  @State activeWarns: string[] = [];
  @State balancingCells: number[] = [];
  @State showRaw: boolean = false;
  @State rawHex: string = '';
  @State btOn: boolean = true;
  @State monitorOn: boolean = false;
  @State cellWarnMv: number = 30;
  @State autoReconnect: boolean = true;
  @State selectedId: string = '';
  private settingsLoaded: boolean = false;
  private timerId: number = -1;
  private monitor: BatteryMonitor = BatteryMonitor.getInstance();

  aboutToAppear(): void {
    const ctx = this.monitor.getContext();
    if (ctx !== null) {
      this.cellWarnMv = Store.getCellWarnThreshold(ctx);
      this.autoReconnect = Store.getAutoReconnect(ctx);
      this.history = Store.getHistory(ctx).slice(-10).reverse();
    }
    this.monitorOn = this.monitor.getStatus().running;
    this.refreshStates();
    this.timerId = setInterval((): void => {
      this.refreshStates();
    }, 1000);
  }

  aboutToDisappear(): void {
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
  }

  private refreshStates(): void {
    this.snap = this.monitor.getSnapshot();
    this.status = this.monitor.getStatus();
    this.devices = this.monitor.getDevices();
    this.lastBms = this.monitor.getLastBms();
    this.selectedId = this.monitor.getSelectedDeviceId();
    this.btOn = access.getState() === access.BluetoothState.STATE_ON;
    this.monitorOn = this.status.running;

    // 监控启动后 context 可用, 补读设置与历史
    const ctx = this.monitor.getContext();
    if (ctx !== null && !this.settingsLoaded) {
      this.settingsLoaded = true;
      this.cellWarnMv = Store.getCellWarnThreshold(ctx);
      this.autoReconnect = Store.getAutoReconnect(ctx);
    }

    // 电芯列表
    const chips: CellChip[] = [];
    const bms = this.lastBms;
    if (bms !== null && bms.cellDetail.length > 0) {
      for (let i = 0; i < bms.cellDetail.length; i++) {
        const c = bms.cellDetail[i];
        const chip: CellChip = {
          index: c.index,
          mv: c.voltage,
          isMin: i === bms.minCellIndex,
          isMax: i === bms.maxCellIndex,
          isWarn: false
        };
        chips.push(chip);
      }
      // 压差告警: 相对最高 ≥ 阈值
      let maxMv = 0;
      for (let i = 0; i < chips.length; i++) {
        if (chips[i].mv > maxMv) {
          maxMv = chips[i].mv;
        }
      }
      for (let i = 0; i < chips.length; i++) {
        chips[i].isWarn = (maxMv - chips[i].mv) >= this.cellWarnMv;
      }
      this.cells = chips;

      const bal: number[] = [];
      for (let i = 0; i < bms.balancing.length; i++) {
        if (bms.balancing[i]) {
          bal.push(i + 1);
        }
      }
      this.balancingCells = bal;
      this.activeProtections = this.activeNames(bms.protections);
      this.activeFaults = this.activeNames(bms.faults);
      this.activeWarns = this.activeNames(bms.warns);
      this.rawHex = bms.rawHex;
    } else if (this.snap.rawHex !== '') {
      this.rawHex = this.snap.rawHex;
    }

    if (ctx !== null) {
      this.history = Store.getHistory(ctx).slice(-10).reverse();
    }
  }

  private activeNames(flags: BitFlag[]): string[] {
    const out: string[] = [];
    for (let i = 0; i < flags.length; i++) {
      if (flags[i].active && !flags[i].name.startsWith('RSVD')) {
        out.push(flags[i].name);
      }
    }
    return out;
  }

  private socColor(): string {
    const soc = this.snap.soc;
    if (this.snap.updatedAt === 0) {
      return '#9AA0A6';
    }
    if (soc <= 20) {
      return '#E8564A';
    }
    if (soc <= 50) {
      return '#F5B940';
    }
    return '#4FC47F';
  }

  private fmtTime(ts: number): string {
    if (ts <= 0) {
      return '--';
    }
    const d = new Date(ts);
    const mm = String(d.getMonth() + 1).padStart(2, '0');
    const dd = String(d.getDate()).padStart(2, '0');
    const hh = String(d.getHours()).padStart(2, '0');
    const mi = String(d.getMinutes()).padStart(2, '0');
    return `${mm}-${dd} ${hh}:${mi}`;
  }

  private ageText(ts: number): string {
    if (ts <= 0) {
      return '暂无数据';
    }
    const sec = Math.floor((Date.now() - ts) / 1000);
    if (sec < 60) {
      return `${sec}秒前更新`;
    }
    if (sec < 3600) {
      return `${Math.floor(sec / 60)}分钟前更新`;
    }
    if (sec < 86400) {
      return `${Math.floor(sec / 3600)}小时前更新`;
    }
    return `${Math.floor(sec / 86400)}天前更新`;
  }

  private async toggleMonitor(on: boolean): Promise<void> {
    const ctx = this.monitor.getContext();
    if (ctx === null) {
      return;
    }
    Store.setMonitorEnabled(ctx, on);
    if (on) {
      await this.monitor.start(ctx);
    } else {
      await this.monitor.stop();
    }
    this.monitorOn = on;
  }

  private setWarnThreshold(mv: number): void {
    this.cellWarnMv = mv;
    const ctx = this.monitor.getContext();
    if (ctx !== null) {
      Store.setCellWarnThreshold(ctx, mv);
    }
  }

  private setAutoReconnect(on: boolean): void {
    this.autoReconnect = on;
    const ctx = this.monitor.getContext();
    if (ctx !== null) {
      Store.setAutoReconnect(ctx, on);
    }
  }

  @Builder
  SectionTitle(title: string) {
    Text(title)
      .fontSize(15)
      .fontWeight(FontWeight.Bold)
      .margin({ top: 14, bottom: 8 })
  }

  @Builder
  StatCell(title: string, value: string) {
    Column({ space: 3 }) {
      Text(value === '' ? '--' : value)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.snap.updatedAt > 0 ? $r('sys.color.font_primary') : '#9AA0A6')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(title)
        .fontSize(11)
        .fontColor($r('sys.color.font_tertiary'))
    }
    .alignItems(HorizontalAlign.Center)
    .layoutWeight(1)
    .padding(8)
  }

  build() {
    Column() {
      // 标题栏
      Row({ space: 8 }) {
        Text('BLE 电池管家')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .layoutWeight(1)
        Circle({ width: 8, height: 8 })
          .fill(this.status.connected ? '#4FC47F' : (this.status.scanning ? '#F5B940' : '#9AA0A6'))
        Text(this.status.connected ? '已连接' : (this.status.scanning ? '扫描中' : '空闲'))
          .fontSize(12)
          .fontColor($r('sys.color.font_secondary'))
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 12, bottom: 4 })

      if (!this.btOn) {
        Text('蓝牙未开启, 请到控制中心打开蓝牙')
          .fontSize(12)
          .fontColor('#E8564A')
          .width('100%')
          .padding({ left: 16, right: 16 })
      }

      Scroll() {
        Column() {
          // ── 电量主卡片 ──
          Column({ space: 10 }) {
            Row({ space: 4 }) {
              Text(this.snap.name !== '' ? this.snap.name : '未选择设备')
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .layoutWeight(1)
                .maxLines(1)
              if (this.status.locked) {
                Text('电量已锁定')
                  .fontSize(11)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#9AA0A6')
                  .borderRadius(8)
                  .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              } else if (this.status.connected) {
                Text('实时')
                  .fontSize(11)
                  .fontColor('#FFFFFF')
                  .backgroundColor('#4FC47F')
                  .borderRadius(8)
                  .padding({ left: 8, right: 8, top: 2, bottom: 2 })
              }
            }
            .width('100%')

            Stack({ alignContent: Alignment.Center }) {
              Progress({ value: Math.min(Math.max(Math.round(this.snap.soc), 0), 100), total: 100, type: ProgressType.Ring })
                .color(this.socColor())
                .style({ strokeWidth: 12 })
                .width(150)
                .height(150)

              Column({ space: 2 }) {
                Row({ space: 2 }) {
                  Text(this.snap.updatedAt > 0 ? `${Math.round(this.snap.soc)}` : '--')
                    .fontSize(44)
                    .fontWeight(FontWeight.Bold)
                  Text('%')
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .margin({ bottom: 8 })
                }
                .alignItems(VerticalAlign.Bottom)

                Text(`${this.ageText(this.snap.updatedAt)}`)
                  .fontSize(11)
                  .fontColor($r('sys.color.font_tertiary'))
              }
            }
            .width(150)
            .height(150)
            .alignSelf(ItemAlign.Center)

            Row({ space: 8 }) {
              Text(this.snap.voltage > 0 ? `${this.snap.voltage.toFixed(2)} V` : '-- V')
                .fontSize(18)
                .fontWeight(FontWeight.Medium)
              if (this.snap.full) {
                Text(`${this.snap.current >= 0 ? '+' : ''}${this.snap.current.toFixed(1)} A`)
                  .fontSize(14)
                  .fontColor($r('sys.color.font_secondary'))
                Text(`${this.snap.power.toFixed(0)} W`)
                  .fontSize(14)
                  .fontColor($r('sys.color.font_secondary'))
              }
              if (this.snap.chargeState === 1) {
                Text('⚡ 充电中').fontSize(13).fontColor('#4FC47F')
              } else if (this.snap.chargeState === 2) {
                Text('放电中').fontSize(13).fontColor('#F5B940')
              }
            }
            .justifyContent(FlexAlign.Center)

            if (this.snap.sn !== '') {
              Text(`SN: ${this.snap.sn}`)
                .fontSize(11)
                .fontColor($r('sys.color.font_tertiary'))
            }
          }
          .width('100%')
          .padding(16)
          .borderRadius(16)
          .backgroundColor($r('sys.color.background_primary'))

          // ── 状态行 ──
          Row({ space: 8 }) {
            Text(this.status.statusText)
              .fontSize(12)
              .fontColor($r('sys.color.font_secondary'))
              .layoutWeight(1)
            Button(this.monitorOn ? '停止监控' : '启动监控')
              .fontSize(12)
              .height(30)
              .backgroundColor(this.monitorOn ? '#9AA0A6' : ACCENT)
              .onClick((): void => {
                this.toggleMonitor(!this.monitorOn);
              })
            Button('立即刷新')
              .fontSize(12)
              .height(30)
              .backgroundColor(ACCENT)
              .onClick((): void => {
                this.monitor.requestRefresh();
              })
          }
          .width('100%')
          .margin({ top: 10 })

          // ── 统计 ──
          this.SectionTitle('概览')
          Column() {
            Row() {
              this.StatCell('循环次数', this.snap.full ? `${this.snap.cycles}` : '')
              this.StatCell('SOH', this.snap.full ? `${this.snap.soh.toFixed(0)}%` : '')
              this.StatCell('剩余容量', this.snap.full ? `${this.snap.capRemain.toFixed(1)}Ah` : '')
            }
            Row() {
              this.StatCell('满充容量', this.snap.full ? `${this.snap.capFull.toFixed(1)}Ah` : '')
              this.StatCell('温度范围', this.snap.full ? `${this.snap.tempMin.toFixed(0)}~${this.snap.tempMax.toFixed(0)}°C` : '')
              this.StatCell('电芯数', this.snap.full ? `${this.snap.cellCount}串` : '')
            }
          }
          .width('100%')
          .padding(6)
          .borderRadius(12)
          .backgroundColor($r('sys.color.background_primary'))

          // ── 电芯 ──
          if (this.cells.length > 0) {
            this.SectionTitle(`电芯电压 (${this.cells.length}串, 告警阈值≥${this.cellWarnMv}mV压差)`)
            Column() {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.cells, (c: CellChip) => {
                  Column({ space: 2 }) {
                    Text(`#${c.index}`)
                      .fontSize(10)
                      .fontColor($r('sys.color.font_tertiary'))
                    Text(`${(c.mv / 1000).toFixed(3)}`)
                      .fontSize(12)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(c.isWarn ? '#E8564A' : $r('sys.color.font_primary'))
                    Row({ space: 2 }) {
                      if (c.isMin) {
                        Text('低').fontSize(9).fontColor('#F5B940')
                      }
                      if (c.isMax) {
                        Text('高').fontSize(9).fontColor(ACCENT)
                      }
                    }
                    .height(12)
                  }
                  .width('19%')
                  .margin(2)
                  .padding(4)
                  .borderRadius(8)
                  .backgroundColor(c.isWarn ? '#33E8564A' : $r('sys.color.background_primary'))
                }, (c: CellChip) => `${c.index}-${c.mv}-${c.isWarn}`)
              }
              .width('100%')
              if (this.balancingCells.length > 0) {
                Text(`均衡中: 第 ${this.balancingCells.join(', ')} 节`)
                  .fontSize(11)
                  .fontColor('#4FC47F')
                  .margin({ top: 6 })
              }
            }
            .width('100%')
            .padding(10)
            .borderRadius(12)
            .backgroundColor($r('sys.color.background_primary'))
          }

          // ── 告警/状态位 ──
          if (this.activeFaults.length > 0 || this.activeProtections.length > 0 || this.activeWarns.length > 0) {
            this.SectionTitle('告警')
            Column({ space: 6 }) {
              if (this.activeFaults.length > 0) {
                Text(`故障: ${this.activeFaults.join('、')}`)
                  .fontSize(12)
                  .fontColor('#E8564A')
              }
              if (this.activeProtections.length > 0) {
                Text(`保护: ${this.activeProtections.join('、')}`)
                  .fontSize(12)
                  .fontColor('#F5B940')
              }
              if (this.activeWarns.length > 0) {
                Text(`警告: ${this.activeWarns.join('、')}`)
                  .fontSize(12)
                  .fontColor('#F5B940')
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding(10)
            .borderRadius(12)
            .backgroundColor($r('sys.color.background_primary'))
          }

          // ── 设备列表 ──
          this.SectionTitle(`附近的电池设备 (${this.devices.length})`)
          Column({ space: 6 }) {
            if (this.devices.length === 0) {
              Text('正在扫描名称以 FD 开头的电池设备…')
                .fontSize(12)
                .fontColor($r('sys.color.font_tertiary'))
                .padding(8)
            }
            ForEach(this.devices, (d: DiscoveredDevice) => {
              Row({ space: 8 }) {
                Column({ space: 2 }) {
                  Text(d.name)
                    .fontSize(14)
                    .fontWeight(FontWeight.Medium)
                  if (d.adv !== null) {
                    Text(`${d.adv.voltage.toFixed(1)}V · ${d.adv.soc.toFixed(0)}% · SN:${d.adv.sn}`)
                      .fontSize(11)
                      .fontColor($r('sys.color.font_tertiary'))
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Text(`${d.rssi}dBm`)
                  .fontSize(11)
                  .fontColor($r('sys.color.font_tertiary'))

                Button(d.deviceId === this.selectedId ? '已选择' : '选择')
                  .fontSize(12)
                  .height(28)
                  .backgroundColor(d.deviceId === this.selectedId ? '#4FC47F' : ACCENT)
                  .onClick((): void => {
                    this.monitor.selectDevice(d.deviceId, d.name);
                  })
              }
              .width('100%')
              .padding(10)
              .borderRadius(10)
              .backgroundColor($r('sys.color.background_primary'))
            }, (d: DiscoveredDevice) => `${d.deviceId}-${d.rssi}`)
            Button('清除选定设备')
              .fontSize(12)
              .height(30)
              .backgroundColor('#9AA0A6')
              .onClick((): void => {
                this.monitor.forgetDevice();
              })
          }
          .width('100%')

          // ── 设置 ──
          this.SectionTitle('设置')
          Column({ space: 10 }) {
            Row() {
              Text('压差告警阈值').fontSize(13).layoutWeight(1)
              Text(`${this.cellWarnMv}mV`).fontSize(13).fontColor(ACCENT)
            }
            .width('100%')
            Slider({ value: this.cellWarnMv, min: 5, max: 80, step: 1 })
              .onChange((value: number): void => {
                this.setWarnThreshold(Math.round(value));
              })

            Row() {
              Text('断联后自动重连').fontSize(13).layoutWeight(1)
              Toggle({ type: ToggleType.Switch, isOn: this.autoReconnect })
                .onChange((on: boolean): void => {
                  this.setAutoReconnect(on);
                })
            }
            .width('100%')

            Text('设备离开信号范围后, 电量将锁定为最后数值, 卡片不会显示离线。')
              .fontSize(11)
              .fontColor($r('sys.color.font_tertiary'))
          }
          .width('100%')
          .padding(10)
          .borderRadius(12)
          .backgroundColor($r('sys.color.background_primary'))

          // ── 历史 ──
          if (this.history.length > 0) {
            this.SectionTitle('最近记录')
            Column({ space: 4 }) {
              ForEach(this.history, (h: HistoryRecord) => {
                Row() {
                  Text(this.fmtTime(h.time))
                    .fontSize(12)
                    .fontColor($r('sys.color.font_secondary'))
                    .layoutWeight(1)
                  Text(`${Math.round(h.soc)}%`)
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                  Text(`${h.voltage.toFixed(2)}V`)
                    .fontSize(12)
                    .fontColor($r('sys.color.font_secondary'))
                    .margin({ left: 10 })
                    .width(70)
                    .textAlign(TextAlign.End)
                }
                .width('100%')
              }, (h: HistoryRecord) => `${h.time}`)
            }
            .width('100%')
            .padding(10)
            .borderRadius(12)
            .backgroundColor($r('sys.color.background_primary'))
          }

          // ── 原始数据 ──
          this.SectionTitle('原始数据')
          Column({ space: 6 }) {
            Button(this.showRaw ? '隐藏 124 字节寄存器 HEX' : '显示 124 字节寄存器 HEX')
              .fontSize(12)
              .height(30)
              .backgroundColor('#9AA0A6')
              .onClick((): void => {
                this.showRaw = !this.showRaw;
              })
            if (this.showRaw) {
              Text(this.rawHex === '' ? '暂无数据' : this.rawHex)
                .fontSize(10)
                .fontFamily('monospace')
                .fontColor($r('sys.color.font_secondary'))
                .width('100%')
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(10)
          .borderRadius(12)
          .backgroundColor($r('sys.color.background_primary'))

          Text('协议: 迪子电量 (FD 前缀 BMS) · 广播解析 + F403 寄存器读取 · 移植自 yu1745/ble-battery')
            .fontSize(10)
            .fontColor($r('sys.color.font_tertiary'))
            .margin({ top: 12, bottom: 30 })
            .textAlign(TextAlign.Center)
            .width('100%')
        }
        .padding({ left: 12, right: 12 })
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Auto)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('sys.color.background_secondary'))
  }
}
