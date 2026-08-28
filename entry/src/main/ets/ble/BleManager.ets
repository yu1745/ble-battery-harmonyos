/**
 * BLE 扫描 + GATT 客户端 + F403 协议会话。
 * 移植自 yu1745/ble-battery src/ble.ts (BatteryConnection / scanDevices)
 * 目标 API: HarmonyOS NEXT 5.1.0 (API 18) @ohos.bluetooth.ble
 */
import { ble, constant } from '@kit.ConnectivityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { makeF403Command, crc16HexStr, hexToBytes } from './Crc16';
import { parseBmsData } from './BmsParser';
import { parseRawAdv, parseAdvData } from './AdvParser';
import { BmsData, AdvParsed } from './BmsTypes';

const DOMAIN: number = 0xB100;
const TAG: string = 'BleBms';

// Nordic UART Service (NUS)
const UART_SERVICE_UUID = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const WRITE_CHAR_UUID = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
const NOTIFY_CHAR_UUID = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';

export interface DiscoveredDevice {
  deviceId: string;
  name: string;
  rssi: number;
  adv: AdvParsed | null;
}

interface PendingCommand {
  buffer: string;
  expectedLen: number;
  resolve: (val: string) => void;
  reject: (err: Error) => void;
  timer: number;
  settled: boolean;
}

function delay(ms: number): Promise<void> {
  return new Promise<void>((resolve: (value: void | PromiseLike<void>) => void) => {
    setTimeout(() => {
      resolve();
    }, ms);
  });
}

/**
 * 单个 BLE 设备的 GATT 会话: 连接、F403 命令收发、124 字节分块读取。
 */
export class GattSession {
  private deviceId: string;
  private device: ble.GattClientDevice | null = null;
  private writeChar: ble.BLECharacteristic | null = null;
  private notifyChar: ble.BLECharacteristic | null = null;
  private notificationsStarted: boolean = false;
  private pending: PendingCommand | null = null;
  private queue: Promise<void> = Promise.resolve();
  private lastCmd: string = '';
  private lastRespText: string = '';
  private lastRespTs: number = 0;
  private txCnt: number = 0;
  public connected: boolean = false;

  constructor(deviceId: string) {
    this.deviceId = deviceId;
    this.lastRespText = '';
    this.lastRespTs = 0;
  }

  is_connected(): boolean {
    return this.connected;
  }

  get_deviceId(): string {
    return this.deviceId;
  }

  async connect(timeoutMs: number = 12000): Promise<void> {
    if (this.connected) {
      return;
    }
    const dev = ble.createGattClientDevice(this.deviceId);
    this.device = dev;

    await new Promise<void>((resolve, reject) => {
      let settled = false;
      const stateCb = (state: ble.BLEConnectionChangeState) => {
        if (settled || state.deviceId !== this.deviceId) {
          return;
        }
        hilog.info(DOMAIN, TAG, 'conn state %{public}d', state.state);
        if (state.state === constant.ProfileConnectionState.STATE_CONNECTED) {
          settled = true;
          clearTimeout(timer);
          this.connected = true;
          resolve();
        } else if (settled === false &&
          (state.state === constant.ProfileConnectionState.STATE_DISCONNECTED ||
            state.state === constant.ProfileConnectionState.STATE_DISCONNECTING)) {
          settled = true;
          clearTimeout(timer);
          reject(new Error('连接被断开'));
        }
      };
      const timer = setTimeout(() => {
        if (!settled) {
          settled = true;
          reject(new Error('连接超时'));
        }
      }, timeoutMs);

      try {
        dev.on('BLEConnectionStateChange', stateCb);
        dev.connect();
      } catch (e) {
        const be = e as BusinessError;
        hilog.error(DOMAIN, TAG, 'connect err %{public}d %{public}s', be.code, be.message);
        if (!settled) {
          settled = true;
          clearTimeout(timer);
          reject(new Error(`连接失败: ${be.message}`));
        }
      }
    });

    // 注意: 此处不主动请求 MTU — MTU 交换(getServices 前调用)在部分设备上会悬挂,
    // 导致后续所有 getServices 报 2900099 (参考华为开发者 FAQ); 协议响应分片到达, 默认 MTU 即可。

    // 断连事件
    dev.on('BLEConnectionStateChange', (state: ble.BLEConnectionChangeState) => {
      if (state.deviceId === this.deviceId &&
        (state.state === constant.ProfileConnectionState.STATE_DISCONNECTED ||
          state.state === constant.ProfileConnectionState.STATE_DISCONNECTING)) {
        this.connected = false;
        this.failPending(new Error('设备断开连接'));
      }
    });

    // 通知回调
    dev.on('BLECharacteristicChange', (charData: ble.BLECharacteristic) => {
      this.onNotify(charData);
    });

    // 服务发现 + 找 NUS 特征值 (部分固件连接后服务发现需延迟, 多试几次; 单次异常也继续重试)
    let services: Array<ble.GattService> = [];
    let found = false;
    let lastErr = '';
    for (let attempt = 0; attempt < 8 && !found; attempt++) {
      if (attempt > 0) {
        await delay(500);
      }
      try {
        services = await dev.getServices();
      } catch (e) {
        const be = e as BusinessError;
        lastErr = `${be.code}: ${be.message}`;
        hilog.warn(DOMAIN, TAG, 'getServices attempt %{public}d err %{public}s', attempt, lastErr);
        services = [];
        continue;
      }
      for (let i = 0; i < services.length; i++) {
        if (services[i].serviceUuid.toLowerCase() === UART_SERVICE_UUID) {
          found = true;
          break;
        }
      }
    }
    if (found) {
      const svc = services.find((s: ble.GattService): boolean =>
        s.serviceUuid.toLowerCase() === UART_SERVICE_UUID);
      if (svc === undefined) {
        throw new Error('未找到 Nordic UART Service');
      }
      for (let j = 0; j < svc.characteristics.length; j++) {
        const ch = svc.characteristics[j];
        const u = ch.characteristicUuid.toLowerCase();
        if (u === WRITE_CHAR_UUID) {
          this.writeChar = ch;
        } else if (u === NOTIFY_CHAR_UUID) {
          this.notifyChar = ch;
        }
      }
      found = this.writeChar !== null && this.notifyChar !== null;
    }
    if (!found || this.writeChar === null || this.notifyChar === null) {
      let dump = '';
      for (let i = 0; i < services.length; i++) {
        dump += services[i].serviceUuid + ' ';
      }
      hilog.error(DOMAIN, TAG, 'GATT services(%{public}d): %{public}s lastErr=%{public}s', services.length, dump, lastErr);
      if (services.length === 0 && lastErr !== '') {
        throw new Error(`服务发现失败(${lastErr})`);
      }
      throw new Error('未找到 Nordic UART Service');
    }

    // MTU = 247 已在服务发现前尝试过; 此处不再重复

    // 断连事件
    dev.on('BLEConnectionStateChange', (state: ble.BLEConnectionChangeState) => {
      if (state.deviceId === this.deviceId &&
        (state.state === constant.ProfileConnectionState.STATE_DISCONNECTED ||
          state.state === constant.ProfileConnectionState.STATE_DISCONNECTING)) {
        this.connected = false;
        this.failPending(new Error('设备断开连接'));
      }
    });

    // 通知回调
    dev.on('BLECharacteristicChange', (charData: ble.BLECharacteristic) => {
      this.onNotify(charData);
    });

    await dev.setCharacteristicChangeNotification(this.notifyChar, true);
    this.notificationsStarted = true;
    await delay(300);

    // MTU 247: 必须在服务发现之后请求 (与 getServices 并发会 2900099)。
    // 原版 Web BLE / bleak 均在 MTU 247 下工作: 单条通知可装下整个 F403 响应,
    // 避免 MTU 23 分片下固件双发响应的问题。
    try {
      dev.on('BLEMtuChange', (mtu: number) => {
        hilog.info(DOMAIN, TAG, 'MTU negotiated: %{public}d', mtu);
      });
      dev.setBLEMtuSize(247);
    } catch (e) {
      const be = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'setBLEMtuSize err %{public}d', be.code);
    }
  }

  disconnect(): void {
    this.failPending(new Error('本地断开'));
    this.connected = false;
    const dev = this.device;
    this.device = null;
    this.writeChar = null;
    this.notifyChar = null;
    this.notificationsStarted = false;
    if (dev !== null) {
      try {
        dev.disconnect();
      } catch (e) {
        const be = e as BusinessError;
        hilog.warn(DOMAIN, TAG, 'disconnect err %{public}d', be.code);
      }
      try {
        dev.off('BLEConnectionStateChange');
        dev.off('BLECharacteristicChange');
        dev.close();
      } catch (e) {
        const be = e as BusinessError;
        hilog.warn(DOMAIN, TAG, 'close err %{public}d', be.code);
      }
    }
  }

  private failPending(err: Error): void {
    if (this.pending !== null && !this.pending.settled) {
      clearTimeout(this.pending.timer);
      this.pending.settled = true;
      this.pending.reject(err);
    }
    this.pending = null;
  }

  private onNotify(charData: ble.BLECharacteristic): void {
    if (this.pending === null || this.pending.settled) {
      return;
    }
    const raw = new Uint8Array(charData.characteristicValue);
    let text = '';
    for (let i = 0; i < raw.length; i++) {
      // ASCII 解码, 非法字符替换
      text += raw[i] >= 0x20 && raw[i] <= 0x7e ? String.fromCharCode(raw[i]) : '?';
    }
    const p = this.pending;
    p.buffer += text;
    const idx = p.buffer.indexOf('F403');
    if (idx < 0) {
      return;
    }
    if (idx > 0) {
      p.buffer = p.buffer.slice(idx);
    }
    if (p.buffer.length < 6) {
      return;
    }
    const bc = parseInt(p.buffer.slice(4, 6), 16);
    if (isNaN(bc)) {
      return;
    }
    if (p.buffer.length < 10 + bc * 2) {
      return;
    }
    p.settled = true;
    clearTimeout(p.timer);
    const frame = p.buffer.slice(0, 10 + bc * 2);
    // 重复响应抑制: 设备偶发把同一响应连发两遍, 400ms 内完全相同的帧视为重复副本, 丢弃等待真实响应
    const now = Date.now();
    if (frame === this.lastRespText && now - this.lastRespTs < 400) {
      hilog.warn(DOMAIN, TAG, 'dup resp dropped');
      p.settled = false;
      p.buffer = '';
      // 重新挂超时, 等待真实响应 (超时后 reject 由外层处理)
      p.timer = setTimeout(() => {
        if (this.pending !== null && !this.pending.settled) {
          this.pending.settled = true;
          const buf = this.pending.buffer;
          this.pending = null;
          p.reject(new Error(`接收超时 buf=${buf}`));
        }
      }, 1000);
      return;
    }
    this.lastRespText = frame;
    this.lastRespTs = now;
    hilog.info(DOMAIN, TAG, 'tx#%{public}d cmd=%{public}s resp=%{public}s', this.txCnt, this.lastCmd, frame);
    p.resolve(frame);
    this.pending = null;
  }

  /** 发送一条命令并等待完整响应 (串行队列) */
  async sendCommand(cmd: string, timeoutMs: number = 1000): Promise<string> {
    if (this.writeChar === null || this.notifyChar === null || !this.connected) {
      return Promise.reject(new Error('未连接'));
    }
    const byteCount = parseInt(cmd.slice(8, 10), 16);
    const expectedLen = 10 + byteCount * 2;
    const run = (): Promise<string> => this.sendCommandNow(cmd, expectedLen, timeoutMs);
    const queued = this.queue.then(run, run);
    this.queue = queued.then((): void => {
    }, (): void => {
    });
    // 命令间限速, 给设备发送尾部通知留出时间
    await delay(120);
    return queued;
  }

  private sendCommandNow(cmd: string, expectedLen: number, timeoutMs: number): Promise<string> {
    const dev = this.device;
    if (dev === null || this.writeChar === null || this.notifyChar === null) {
      return Promise.reject(new Error('未连接'));
    }
    return new Promise<string>((resolve: (v: string) => void, reject: (e: Error) => void) => {
      if (this.pending !== null && !this.pending.settled) {
        clearTimeout(this.pending.timer);
        this.pending.settled = true;
        this.pending.reject(new Error('命令冲突'));
      }
      const timer = setTimeout(() => {
        if (this.pending !== null && !this.pending.settled) {
          this.pending.settled = true;
          const buf = this.pending.buffer;
          this.pending = null;
          reject(new Error(`接收超时 buf=${buf}`));
        }
      }, timeoutMs);

      this.pending = {
        buffer: '',
        expectedLen: expectedLen,
        resolve: resolve,
        reject: reject,
        timer: timer,
        settled: false
      };
      this.lastCmd = cmd;
      this.txCnt++; // 发送计数: 证明同一命令只写一次

      try {
        const cmdLen = cmd.length;
        const ab = new ArrayBuffer(cmdLen);
        const arr = new Uint8Array(ab);
        for (let i = 0; i < cmdLen; i++) {
          arr[i] = cmd.charCodeAt(i);
        }
        this.writeChar!.characteristicValue = ab;
        const useNoRsp = this.writeChar!.properties !== undefined &&
          this.writeChar!.properties !== null &&
          this.writeChar!.properties.writeNoResponse === true;
        const writeType = useNoRsp ? ble.GattWriteType.WRITE_NO_RESPONSE : ble.GattWriteType.WRITE;
        dev.writeCharacteristicValue(this.writeChar!, writeType).catch((we: BusinessError) => {
          clearTimeout(timer);
          if (this.pending !== null && !this.pending.settled) {
            this.pending.settled = true;
            this.pending = null;
          }
          reject(new Error(`写入失败: ${we.message}`));
        });
      } catch (e) {
        const be = e as BusinessError;
        clearTimeout(timer);
        if (this.pending !== null && !this.pending.settled) {
          this.pending.settled = true;
          this.pending = null;
        }
        reject(new Error(`写入失败: ${be.message}`));
      }
    });
  }

  /** 读取完整 124 字节 BMS 寄存器, 分块降级重试 */
  async readBmsData(): Promise<BmsData> {
    const chunkSizes: number[] = [60, 32, 20, 12, 4];
    let lastErrMsg: string = '';
    for (let c = 0; c < chunkSizes.length; c++) {
      try {
        const data: BmsData = await this.readBmsDataWithChunk(chunkSizes[c]);
        return data;
      } catch (e) {
        lastErrMsg = (e as Error).message;
        hilog.warn(DOMAIN, TAG, 'chunk %{public}d failed: %{public}s', chunkSizes[c], lastErrMsg);
        await delay(150);
      }
    }
    throw new Error(lastErrMsg !== '' ? lastErrMsg : '所有分块大小读取均失败');
  }

  private async readBmsDataWithChunk(chunkSize: number): Promise<BmsData> {
    const totalBytes = 124;
    let accumulatedHex = '';
    let offset = 0;
    let remaining = totalBytes;
    while (remaining > 0) {
      const chunk = Math.min(remaining, chunkSize);
      const addr = 0x1000 + offset;
      const cmd = makeF403Command(addr, chunk);
      const resp = await this.sendCommand(cmd);
      if (resp === '' || !resp.startsWith('F403')) {
        throw new Error(`无效响应: ${resp}`);
      }
      const verifyBytes = hexToBytes(resp.slice(0, resp.length - 4));
      const expectedCrc = crc16HexStr(verifyBytes);
      const receivedCrc = resp.slice(resp.length - 4);
      if (expectedCrc !== receivedCrc) {
        throw new Error(`CRC 校验失败: 期望 ${expectedCrc}, 收到 ${receivedCrc}`);
      }
      accumulatedHex += resp.slice(6, resp.length - 4);
      offset += chunk;
      remaining -= chunk;
    }
    const raw = hexToBytes(accumulatedHex);
    if (raw.length !== totalBytes) {
      throw new Error(`读取长度错误: ${raw.length}/${totalBytes}`);
    }
    return parseBmsData(raw);
  }
}

/**
 * BLE 扫描器: 过滤 FD 前缀设备并解析广播数据。
 */
export class BleScanner {
  private scanner: ble.BleScanner | null = null;
  private scanning: boolean = false;
  private devices: Map<string, DiscoveredDevice> = new Map();
  public onDevice: ((d: DiscoveredDevice) => void) | null = null;
  public lowLatency: boolean = true;
  private lastOkStrategy: number = -1;
  public lastError: string = '';

  isScanning(): boolean {
    return this.scanning;
  }

  /** 过滤策略逐个降级尝试: 新固件拒绝空数组, 只能带过滤条件 */
  private buildStrategies(): ble.ScanFilter[][] {
    const emptyFilter: ble.ScanFilter = {};
    const nusFilter: ble.ScanFilter = { serviceUuid: UART_SERVICE_UUID };
    const strategies: ble.ScanFilter[][] = [];
    if (this.lastOkStrategy >= 0 && this.lastOkStrategy < 3) {
      // 命中过的策略优先复用
      if (this.lastOkStrategy === 0) {
        strategies.push([], [emptyFilter], [nusFilter]);
      } else if (this.lastOkStrategy === 1) {
        strategies.push([emptyFilter], [], [nusFilter]);
      } else {
        strategies.push([nusFilter], [emptyFilter], []);
      }
    } else {
      strategies.push([], [emptyFilter], [nusFilter]);
    }
    return strategies;
  }

  async start(): Promise<void> {
    if (this.scanning) {
      return;
    }
    if (this.scanner === null) {
      this.scanner = ble.createBleScanner();
      this.scanner.on('BLEDeviceFind', (report: ble.ScanReport) => {
        this.onReport(report);
      });
    }
    const options: ble.ScanOptions = {
      interval: 0,
      dutyMode: this.lowLatency ? ble.ScanDuty.SCAN_MODE_LOW_LATENCY : ble.ScanDuty.SCAN_MODE_BALANCED,
      matchMode: ble.MatchMode.MATCH_MODE_AGGRESSIVE
    };
    const strategies = this.buildStrategies();
    let lastBe = '';
    for (let i = 0; i < strategies.length; i++) {
      try {
        await this.scanner.startScan(strategies[i], options);
        this.scanning = true;
        this.lastOkStrategy = i;
        hilog.info(DOMAIN, TAG, 'scan started (strategy %{public}d)', i);
        return;
      } catch (e) {
        const be = e as BusinessError;
        lastBe = `${be.code}: ${be.message}`;
        hilog.warn(DOMAIN, TAG, 'startScan strategy %{public}d err %{public}s', i, lastBe);
      }
    }
    this.lastError = lastBe;
    hilog.error(DOMAIN, TAG, 'startScan all strategies failed: %{public}s', lastBe);
    throw new Error(`启动扫描失败: ${lastBe}`);
  }

  async stop(): Promise<void> {
    if (this.scanner !== null && this.scanning) {
      try {
        await this.scanner.stopScan();
      } catch (e) {
        const be = e as BusinessError;
        hilog.warn(DOMAIN, TAG, 'stopScan err %{public}d', be.code);
      }
    }
    this.scanning = false;
  }

  getDevices(): DiscoveredDevice[] {
    const out: DiscoveredDevice[] = [];
    this.devices.forEach((d) => {
      out.push(d);
    });
    out.sort((a: DiscoveredDevice, b: DiscoveredDevice): number => b.rssi - a.rssi);
    return out;
  }

  private onReport(report: ble.ScanReport): void {
    const results: Array<ble.ScanResult> = report.scanResult;
    for (let i = 0; i < results.length; i++) {
      const r = results[i];
      let name = r.deviceName;
      const raw = new Uint8Array(r.data);
      const parsed = parseRawAdv(raw);
      if (!name.startsWith('FD') && parsed.localName.startsWith('FD')) {
        name = parsed.localName;
      }
      if (!name.startsWith('FD')) {
        continue;
      }
      const adv = parseAdvData(name, parsed.manufacturerData);
      const dev: DiscoveredDevice = {
        deviceId: r.deviceId,
        name: name,
        rssi: r.rssi,
        adv: adv
      };
      if (!this.devices.has(r.deviceId)) {
        hilog.info(DOMAIN, TAG, 'FD device: %{public}s rssi=%{public}d soc=%{public}s v=%{public}s',
          name, r.rssi, adv !== null ? adv.soc.toFixed(1) : '-', adv !== null ? adv.voltage.toFixed(2) : '-');
      }
      this.devices.set(r.deviceId, dev);
      if (this.onDevice !== null) {
        this.onDevice(dev);
      }
    }
  }
}
