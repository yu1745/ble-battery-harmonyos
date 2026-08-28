/**
 * 后台电量监控服务:
 *  - 长时任务 (bluetoothInteraction) 保持进程存活
 *  - 持续 BLE 扫描, 从广播解析 SN/电压/电量 (无需连接, ~1s 一条)
 *  - 尽力维持 GATT 连接并每 5s 读取完整 BMS 寄存器
 *  - 断联后"锁住"最后已知电量: 快照永不清空, 卡片永不显示离线
 *  - 通过 formProvider 更新所有已添加的卡片
 */
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { wantAgent, Context } from '@kit.AbilityKit';
import { formBindingData, formProvider } from '@kit.FormKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BleScanner, GattSession, DiscoveredDevice } from '../ble/BleManager';
import { Store } from '../data/Store';
import {
  BatterySnapshot, emptySnapshot, fromBmsData, updateFromAdv
} from '../model/BatterySnapshot';
import { CardPayload } from '../model/CardPayload';
import { BmsData } from '../ble/BmsTypes';

const DOMAIN: number = 0xB100;
const TAG: string = 'BleMonitor';

const POLL_INTERVAL_MS = 5000;        // 连接后的完整读取间隔
const RECONNECT_COOLDOWN_MS = 15000;  // 连接失败后的重试冷却
const CARD_UPDATE_MIN_MS = 1000;      // 卡片更新节流
const ADV_SAVE_MIN_MS = 30000;        // 广播数据落盘节流
const LOCK_AFTER_MS = 10 * 60 * 1000; // 超过此时长无新数据则视为"锁住"

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

export class MonitorStatus {
  running: boolean = false;
  scanning: boolean = false;
  connected: boolean = false;
  locked: boolean = false;
  statusText: string = '待启动';
  deviceCount: number = 0;
  rssi: number = -127;
}

export class BatteryMonitor {
  private static instance: BatteryMonitor | null = null;

  static getInstance(): BatteryMonitor {
    if (BatteryMonitor.instance === null) {
      BatteryMonitor.instance = new BatteryMonitor();
    }
    return BatteryMonitor.instance;
  }

  private context: Context | null = null;
  private scanner: BleScanner = new BleScanner();
  private session: GattSession | null = null;
  private snapshot: BatterySnapshot = emptySnapshot();
  private lastBms: BmsData | null = null;
  private selectedId: string = '';
  private selectedName: string = '';
  private status: MonitorStatus = new MonitorStatus();
  private running: boolean = false;
  private nextConnectTs: number = 0;
  private nextScanRetryTs: number = 0;
  private lastCardKey: string = '';
  private lastCardUpdateTs: number = 0;
  private lastAdvSaveTs: number = 0;
  private autoSelectDone: boolean = false;
  private userSelected: boolean = false;
  private blacklist: Set<string> = new Set<string>();

  getContext(): Context | null {
    return this.context;
  }

  getSnapshot(): BatterySnapshot {
    return this.snapshot;
  }

  getLastBms(): BmsData | null {
    return this.lastBms;
  }

  getSelectedDeviceId(): string {
    return this.selectedId;
  }

  getStatus(): MonitorStatus {
    const s = new MonitorStatus();
    s.running = this.status.running;
    s.scanning = this.scanner.isScanning();
    s.connected = this.session !== null && this.session.is_connected();
    s.locked = this.isLocked();
    s.statusText = this.status.statusText;
    s.deviceCount = this.scanner.getDevices().length;
    s.rssi = this.currentRssi;
    return s;
  }

  private currentRssi: number = -127;

  isLocked(): boolean {
    if (this.snapshot.updatedAt === 0) {
      return false;
    }
    return (Date.now() - this.snapshot.updatedAt) > LOCK_AFTER_MS;
  }

  getDevices(): DiscoveredDevice[] {
    return this.scanner.getDevices();
  }

  async start(context: Context): Promise<void> {
    if (this.running) {
      return;
    }
    this.context = context;
    this.snapshot = Store.loadSnapshot(context) ?? emptySnapshot();
    this.selectedId = Store.getSelectedDevice(context);
    this.selectedName = Store.getSelectedName(context);
    if (this.selectedId !== '') {
      this.autoSelectDone = true;
    }

    this.scanner.onDevice = (d: DiscoveredDevice): void => {
      this.onDevice(d);
    };

    this.running = true;
    this.status.running = true;
    this.status.statusText = '正在扫描…';

    // 长时任务 (需要 backgroundModes + KEEP_BACKGROUND_RUNNING)
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: 'com.yu1745.blebattery',
          abilityName: 'EntryAbility'
        }],
        operationType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        wantAgentFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(
        context, backgroundTaskManager.BackgroundMode.BLUETOOTH_INTERACTION, agent);
      hilog.info(DOMAIN, TAG, 'continuous task started');
    } catch (e) {
      const be = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'startBackgroundRunning err %{public}d %{public}s', be.code, be.message);
    }

    try {
      await this.scanner.start();
    } catch (e) {
      const be = e as BusinessError;
      this.status.statusText = `扫描失败: ${be.message}`;
    }

    this.mainLoop();
    this.updateCards(true);
  }

  async stop(): Promise<void> {
    this.running = false;
    this.status.running = false;
    this.status.statusText = '已停止';
    try {
      await this.scanner.stop();
    } catch (e) {
    }
    if (this.session !== null) {
      this.session.disconnect();
      this.session = null;
    }
    if (this.context !== null) {
      try {
        await backgroundTaskManager.stopBackgroundRunning(this.context);
      } catch (e) {
      }
    }
  }

  selectDevice(deviceId: string, name: string): void {
    this.selectedId = deviceId;
    this.selectedName = name;
    this.autoSelectDone = true;
    this.userSelected = true;
    if (this.context !== null) {
      Store.setSelectedDevice(this.context, deviceId, name);
    }
    if (this.session !== null) {
      const old = this.session;
      this.session = null;
      old.disconnect();
    }
    // 换设备: 旧电池的锁定数据必须清空, 避免张冠李戴
    this.snapshot = emptySnapshot();
    this.lastBms = null;
    if (this.context !== null) {
      Store.saveSnapshot(this.context, this.snapshot);
    }
    this.nextConnectTs = 0;
    this.status.statusText = `已选择 ${name}`;
    this.updateCards(true);
  }

  forgetDevice(): void {
    this.selectedId = '';
    this.selectedName = '';
    this.autoSelectDone = false;
    this.userSelected = false;
    if (this.context !== null) {
      Store.setSelectedDevice(this.context, '', '');
    }
    if (this.session !== null) {
      const old = this.session;
      this.session = null;
      old.disconnect();
    }
    this.status.statusText = '已清除设备';
  }

  /** 前台高速扫描 / 后台省电扫描 */
  async setLowLatency(on: boolean): Promise<void> {
    if (this.scanner.lowLatency === on) {
      return;
    }
    this.scanner.lowLatency = on;
    if (this.scanner.isScanning()) {
      await this.scanner.stop();
      try {
        await this.scanner.start();
      } catch (e) {
      }
    }
  }

  requestRefresh(): void {
    this.nextConnectTs = 0;
    this.updateCards(true);
  }

  // ────────────────────────────── 内部逻辑 ──────────────────────────────

  private onDevice(d: DiscoveredDevice): void {
    // 选定设备: 用户已选 → 按 deviceId; 未选且未自动选 → 首个设备自动选定
    let target = false;
    if (this.selectedId !== '') {
      target = d.deviceId === this.selectedId;
    } else if (this.selectedName !== '') {
      target = d.name === this.selectedName;
      if (target) {
        this.selectedId = d.deviceId;
        if (this.context !== null) {
          Store.setSelectedDevice(this.context, d.deviceId, d.name);
        }
      }
    } else if (!this.autoSelectDone && !this.blacklist.has(d.deviceId)) {
      target = true;
      this.selectedId = d.deviceId;
      this.selectedName = d.name;
      this.autoSelectDone = true;
      this.userSelected = false;
      if (this.context !== null) {
        Store.setSelectedDevice(this.context, d.deviceId, d.name);
      }
    }
    this.currentRssi = d.rssi;

    if (!target || d.adv === null) {
      return;
    }

    // 广播 → 快照轻量更新 (不覆盖完整读取的详细字段)
    const changed = Math.abs(this.snapshot.soc - d.adv.soc) > 0.05 ||
      Math.abs(this.snapshot.voltage - d.adv.voltage) > 0.005 ||
      this.snapshot.updatedAt === 0;
    const prevSn = this.snapshot.sn;
    updateFromAdv(this.snapshot, d.adv);
    if (prevSn !== '' && this.snapshot.name === '') {
      this.snapshot.name = d.name;
    }
    if (this.snapshot.name === '') {
      this.snapshot.name = d.name;
    }
    if (changed || Date.now() - this.lastAdvSaveTs > ADV_SAVE_MIN_MS) {
      if (this.context !== null) {
        Store.saveSnapshot(this.context, this.snapshot);
        this.lastAdvSaveTs = Date.now();
      }
    }
    this.updateCards(false);
  }

  private resolveTarget(): DiscoveredDevice | null {
    const devs = this.scanner.getDevices();
    if (this.selectedId !== '') {
      for (let i = 0; i < devs.length; i++) {
        if (devs[i].deviceId === this.selectedId) {
          return devs[i];
        }
      }
      return null;
    }
    if (this.selectedName !== '') {
      for (let i = 0; i < devs.length; i++) {
        if (devs[i].name === this.selectedName) {
          return devs[i];
        }
      }
    }
    return null;
  }

  private async mainLoop(): Promise<void> {
    while (this.running) {
      try {
        await this.tick();
      } catch (e) {
        const be = e as Error;
        hilog.error(DOMAIN, TAG, 'tick err %{public}s', be.message);
      }
      await delay(1000);
    }
  }

  private async tick(): Promise<void> {
    if (!this.scanner.isScanning()) {
      const now = Date.now();
      if (now < this.nextScanRetryTs) {
        return;
      }
      this.nextScanRetryTs = now + 10000; // 失败后 10s 再试, 不硬撞
      try {
        await this.scanner.start();
      } catch (e) {
        const be = e as Error;
        this.status.statusText = be.message;
        return;
      }
    }
    const target = this.resolveTarget();
    if (target === null) {
      if (this.status.statusText !== '正在扫描…') {
        this.status.statusText = '正在扫描…';
      }
      return;
    }
    if (this.session !== null && this.session.is_connected()) {
      return; // 轮询在 connectionLoop 内
    }
    if (!Store.getAutoReconnect(this.context!)) {
      return;
    }
    const now = Date.now();
    if (now < this.nextConnectTs) {
      return;
    }
    // 只有近期看到广播才尝试连接 (设备在附近)
    if (this.snapshot.updatedAt !== 0 && now - this.snapshot.updatedAt > 90000) {
      this.status.statusText = '信号丢失 · 电量已锁定';
      return;
    }
    if (this.blacklist.has(target.deviceId) && !this.userSelected) {
      return;
    }
    await this.connectAndPoll(target.deviceId, target.name);
  }

  private async connectAndPoll(deviceId: string, name: string): Promise<void> {
    this.status.statusText = `正在连接 ${name}…`;
    // 关键: 扫描与 GATT 服务发现并发会导致发现失败(2900099), 连接前先暂停扫描
    const wasScanning = this.scanner.isScanning();
    if (wasScanning) {
      await this.scanner.stop();
    }
    const session = new GattSession(deviceId);
    try {
      await session.connect(12000);
    } catch (e) {
      const be = e as Error;
      hilog.warn(DOMAIN, TAG, 'connect fail: %{public}s', be.message);
      session.disconnect();
      if (wasScanning && this.running) {
        try {
          await this.scanner.start();
        } catch (e2) {
        }
      }
      // 自动选择的设备若不含 NUS (不是目标电池), 拉黑并释放自动选择, 让下一个候选进来
      if (!this.userSelected && be.message.includes('Nordic UART')) {
        this.blacklist.add(deviceId);
        this.selectedId = '';
        this.selectedName = '';
        this.autoSelectDone = false;
        if (this.context !== null) {
          Store.setSelectedDevice(this.context, '', '');
        }
        hilog.warn(DOMAIN, TAG, 'blacklist %{public}s', deviceId);
      }
      this.nextConnectTs = Date.now() + RECONNECT_COOLDOWN_MS;
      if (this.running) {
        this.status.statusText = '连接失败 · 将自动重试';
      }
      return;
    }
    this.session = session;
    this.status.statusText = '已连接';
    this.updateCards(true);

    let failCount = 0;
    while (this.running && session.is_connected()) {
      try {
        const bms = await session.readBmsData();
        this.lastBms = bms;
        const snap = fromBmsData(deviceId, name, this.snapshot.sn, bms);
        const prevSoc = this.snapshot.soc;
        const keepSn = this.snapshot.sn;
        this.snapshot = snap;
        if (keepSn !== '') {
          snap.sn = keepSn;
        }
        if (this.context !== null) {
          Store.saveSnapshot(this.context, snap);
          Store.appendHistory(this.context, snap);
        }
        if (Math.abs(prevSoc - snap.soc) > 0.05) {
          this.status.statusText = '已连接';
        }
        failCount = 0;
        this.updateCards(true);
        await delay(POLL_INTERVAL_MS);
      } catch (e) {
        const be = e as Error;
        failCount++;
        hilog.warn(DOMAIN, TAG, 'read fail x%{public}d: %{public}s', failCount, be.message);
        if (!session.is_connected() || failCount >= 6) {
          break;
        }
        await delay(2000);
      }
    }

    if (this.session === session) {
      this.session = null;
    }
    session.disconnect();
    if (this.running && wasScanning) {
      try {
        await this.scanner.start();
      } catch (e) {
      }
    }
    this.nextConnectTs = Date.now() + RECONNECT_COOLDOWN_MS;
    if (this.running) {
      this.status.statusText = '连接断开 · 电量已锁定';
      this.updateCards(true);
    }
  }

  // ────────────────────────────── 卡片更新 ──────────────────────────────

  buildCardPayload(): Record<string, Object> {
    return CardPayload.build(this.snapshot);
  }

  updateCards(force: boolean): void {
    if (this.context === null) {
      return;
    }
    const now = Date.now();
    if (!force && now - this.lastCardUpdateTs < CARD_UPDATE_MIN_MS) {
      return;
    }
    const payload = this.buildCardPayload();
    const key = JSON.stringify(payload) + String(this.isLocked());
    if (!force && key === this.lastCardKey) {
      return;
    }
    this.lastCardKey = key;
    this.lastCardUpdateTs = now;

    const ids = Store.getFormIds(this.context);
    for (let i = 0; i < ids.length; i++) {
      const formId = ids[i];
      const data = formBindingData.createFormBindingData(payload);
      formProvider.updateForm(formId, data).then<void>(() => {
        return;
      }).catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'updateForm %{public}s err %{public}d', formId, e.code);
      });
    }
  }
}
