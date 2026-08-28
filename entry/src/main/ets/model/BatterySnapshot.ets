/**
 * 电量快照 — 持久化的"最后已知数据"。
 * 断联后 UI 与卡片继续展示该快照 (电量锁住, 永不显示离线)。
 */
import { AdvParsed, BmsData } from '../ble/BmsTypes';

export interface BatterySnapshot {
  deviceId: string;
  name: string;
  sn: string;
  soc: number; // %
  voltage: number; // V
  current: number; // A
  power: number; // W
  cycles: number;
  soh: number; // %
  capRemain: number; // Ah
  capFull: number; // Ah
  cellCount: number;
  tempMin: number;
  tempMax: number;
  cellTemp: number;
  envTemp: number;
  mosTemp: number;
  cellMinMv: number;
  cellMinIdx: number;
  cellMaxMv: number;
  cellMaxIdx: number;
  chargeState: number; // 0=静置 1=充电 2=放电
  updatedAt: number; // epoch ms
  full: boolean; // 是否来自完整 BMS 读取
  rawHex: string;
}

export function emptySnapshot(): BatterySnapshot {
  return {
    deviceId: '', name: '', sn: '',
    soc: 0, voltage: 0, current: 0, power: 0,
    cycles: 0, soh: 0, capRemain: 0, capFull: 0, cellCount: 0,
    tempMin: 0, tempMax: 0, cellTemp: 0, envTemp: 0, mosTemp: 0,
    cellMinMv: 0, cellMinIdx: 0, cellMaxMv: 0, cellMaxIdx: 0,
    chargeState: 0,
    updatedAt: 0,
    full: false,
    rawHex: ''
  };
}

export function snapshotToJson(s: BatterySnapshot): string {
  return JSON.stringify(s);
}

export function snapshotFromJson(text: string): BatterySnapshot | null {
  try {
    const o = JSON.parse(text) as Record<string, Object>;
    const s = emptySnapshot();
    if (o['deviceId'] !== undefined && o['deviceId'] !== null) {
      s.deviceId = o['deviceId'] as string;
    }
    if (o['name'] !== undefined && o['name'] !== null) {
      s.name = o['name'] as string;
    }
    if (o['sn'] !== undefined && o['sn'] !== null) {
      s.sn = o['sn'] as string;
    }
    s.soc = Number(o['soc'] ?? 0);
    s.voltage = Number(o['voltage'] ?? 0);
    s.current = Number(o['current'] ?? 0);
    s.power = Number(o['power'] ?? 0);
    s.cycles = Number(o['cycles'] ?? 0);
    s.soh = Number(o['soh'] ?? 0);
    s.capRemain = Number(o['capRemain'] ?? 0);
    s.capFull = Number(o['capFull'] ?? 0);
    s.cellCount = Number(o['cellCount'] ?? 0);
    s.tempMin = Number(o['tempMin'] ?? 0);
    s.tempMax = Number(o['tempMax'] ?? 0);
    s.cellTemp = Number(o['cellTemp'] ?? 0);
    s.envTemp = Number(o['envTemp'] ?? 0);
    s.mosTemp = Number(o['mosTemp'] ?? 0);
    s.cellMinMv = Number(o['cellMinMv'] ?? 0);
    s.cellMinIdx = Number(o['cellMinIdx'] ?? 0);
    s.cellMaxMv = Number(o['cellMaxMv'] ?? 0);
    s.cellMaxIdx = Number(o['cellMaxIdx'] ?? 0);
    s.chargeState = Number(o['chargeState'] ?? 0);
    s.updatedAt = Number(o['updatedAt'] ?? 0);
    s.full = (Number(o['full'] ?? 0)) === 1;
    if (o['rawHex'] !== undefined && o['rawHex'] !== null) {
      s.rawHex = o['rawHex'] as string;
    }
    return s;
  } catch (e) {
    return null;
  }
}

/** 从完整 BMS 读取构建快照 */
export function fromBmsData(deviceId: string, name: string, sn: string, b: BmsData): BatterySnapshot {
  const s = emptySnapshot();
  s.deviceId = deviceId;
  s.name = name;
  s.sn = sn;
  s.soc = Math.round(b.soc * 10) / 10;
  s.voltage = b.voltage;
  s.current = b.avgCurrent;
  s.power = b.power;
  s.cycles = b.cycles;
  s.soh = b.soh;
  s.capRemain = b.capRemain;
  s.capFull = b.capFull;
  s.cellCount = b.cellCount;
  s.tempMin = b.tempMin;
  s.tempMax = b.tempMax;
  s.cellTemp = b.cellTemp;
  s.envTemp = b.envTemp;
  s.mosTemp = b.mosTemp;
  s.cellMinMv = b.cellVoltages.length > 0 ? b.cellVoltages[b.minCellIndex] : 0;
  s.cellMinIdx = b.cellVoltages.length > 0 ? b.minCellIndex + 1 : 0;
  s.cellMaxMv = b.cellVoltages.length > 0 ? b.cellVoltages[b.maxCellIndex] : 0;
  s.cellMaxIdx = b.cellVoltages.length > 0 ? b.maxCellIndex + 1 : 0;
  s.chargeState = b.chargeState;
  s.updatedAt = Date.now();
  s.full = true;
  s.rawHex = b.rawHex;
  return s;
}

/** 从广播数据更新快照 (轻量字段) */
export function updateFromAdv(s: BatterySnapshot, adv: AdvParsed): void {
  s.soc = Math.round(adv.soc * 10) / 10;
  s.voltage = adv.voltage;
  s.sn = adv.sn;
  s.updatedAt = Date.now();
}
