/**
 * 完整 124 字节 BMS 寄存器解析 (迪子电量 FACE72B3.parse 移植)
 * 来源: yu1745/ble-battery src/ble.ts
 */
import { BmsData, BitFlag, CellVoltage, TemperatureReading } from './BmsTypes';

// 位标签字典: 16 字节 @0..15, 每字节 8 位, 共 128 个状态位
const CONTROLS0: string[] = ['允许放电', '允许充电', '关闭SOC过低保护', '使用常规均衡', '开放充电', '开放放电', '禁熔保险丝', '启用LED'];
const CONTROLS1: string[] = ['禁用防拆故障', '关闭数据统计', '停止LOG', 'CAN主动发送', 'RSVD', 'RSVD', 'RSVD', 'RSVD'];
const CONTROLS2: string[] = ['强制关机', '4G模块强制断电', 'RS485透传', '4G模块串口透传', 'AFE调试', '强制休眠', 'RSVD', '强制均衡'];
const CONTROLS3: string[] = ['RSVD', 'RSVD', 'RSVD', 'RSVD', 'RSVD', 'RSVD', 'RSVD', 'RSVD'];
const PROTECTIONS0: string[] = ['电芯一级欠压', 'NTC开路', '电芯二级欠压', '二级电芯过压', '充电过流', '一级放电过流', '二级放电过流', '短路'];
const PROTECTIONS1: string[] = ['充电低温', '放电低温', '芯片内部低温', 'NTC短路', '充电高温', '放电高温', '芯片内部高温', 'FET高温'];
const PROTECTIONS2: string[] = ['温差', '一级电芯过压', '预充超时', '充电过流锁定', '满充锁定', '放电过流锁定', '短路锁定', '三级放电过流'];
const PROTECTIONS3: string[] = ['压差', '组过压', '组欠压', '一级充电过流', '二级充电过流', '环境温度过低', '环境温度过高', 'AFE通信失效'];
const FAULTS: string[] = ['电芯温度高', '电芯失效', '充电MOS故障', '放电MOS故障', '内包进水', '断线', 'RSVD', '电芯电压高'];
const WARNS1: string[] = ['放电高温', '充电高温', '放电低温', '充电低温', '环境高温', '环境低温', 'MOS高温', 'SOC过低'];
const WARNS2: string[] = ['放电过流', '外部进水', '电芯过压', '电芯欠压', 'AFE配置出错', '组过压', '组欠压', '一级充电过流'];
const WARNS3: string[] = ['热失控', 'RSVD', 'RSVD', 'RTC停止', '外部Flash失效', '片内Flash失效', '防拆故障', '压差告警'];
const STATES0: string[] = ['放电开关', '充电开关', '预放电', '预充电', '充电器状态', '负载状态', '防拆状态', 'APP合法状态'];
const STATES1: string[] = ['允许OTA', '在充电柜内', 'FLASH写授权', '4G模块供电状态', '4G模块与信息通信状态', '4G模块与WAKE_UP电压', 'RTC被设置', '预放电错误'];
const STATES2: string[] = ['允许回滚', 'OCV校准', '非法充电', '满充校准', 'SOC低压修正', 'SOC高压修正', 'RSVD', 'RSVD'];
const STATES3: string[] = ['RSVD', 'RSVD', 'RSVD', 'RSVD', 'RSVD', 'RSVD', 'RSVD', 'RSVD'];

interface StatusByteGroup {
  labels: string[];
  byte: number;
}

const STATUS_BYTE_MAP: StatusByteGroup[] = [
  { labels: CONTROLS0, byte: 0 }, { labels: CONTROLS1, byte: 1 },
  { labels: CONTROLS2, byte: 2 }, { labels: CONTROLS3, byte: 3 },
  { labels: PROTECTIONS0, byte: 4 }, { labels: PROTECTIONS1, byte: 5 },
  { labels: PROTECTIONS2, byte: 6 }, { labels: PROTECTIONS3, byte: 7 },
  { labels: FAULTS, byte: 8 }, { labels: WARNS1, byte: 9 },
  { labels: WARNS2, byte: 10 }, { labels: WARNS3, byte: 11 },
  { labels: STATES0, byte: 12 }, { labels: STATES1, byte: 13 },
  { labels: STATES2, byte: 14 }, { labels: STATES3, byte: 15 }
];

function decodeBits(byteVal: number, names: string[]): BitFlag[] {
  const out: BitFlag[] = [];
  for (let bit = 0; bit < names.length; bit++) {
    out.push({ name: names[bit], active: (byteVal & (1 << bit)) !== 0 });
  }
  return out;
}

export function parseBmsData(raw: Uint8Array): BmsData {
  const u16 = (o: number): number => ((raw[o] | (raw[o + 1] << 8)) >>> 0);
  const i16 = (o: number): number => {
    const v = u16(o);
    return (v & 0x8000) !== 0 ? v - 0x10000 : v;
  };
  const u32 = (o: number): number =>
    ((raw[o] | (raw[o + 1] << 8) | (raw[o + 2] << 16) | (raw[o + 3] << 24)) >>> 0);

  const voltage = u16(20) / 100;
  const avgCurrent = i16(24) / 100;
  const current = i16(26) / 100;
  const soc0 = u16(48) / 10;
  const soh = u16(50) / 10;
  const capRemain = u32(52) / 1000;
  const capFull = u32(56) / 1000;

  // SoC 兜底: 寄存器为 0 时用容量比反推
  let soc = soc0;
  if (soc0 === 0 && capFull > 0) {
    soc = (capRemain / capFull) * 100;
  }

  const cellCount = raw[63] || 0;
  const cellVoltages: number[] = [];
  const cellDetail: CellVoltage[] = [];
  for (let i = 0; i < cellCount && 68 + 2 * i + 1 < raw.length; i++) {
    const mv = u16(68 + 2 * i);
    cellVoltages.push(mv);
    cellDetail.push({ index: i + 1, voltage: mv, voltageV: mv / 1000 });
  }

  let maxCellIndex = 0;
  let minCellIndex = 0;
  for (let i = 1; i < cellVoltages.length; i++) {
    if (cellVoltages[i] > cellVoltages[maxCellIndex]) {
      maxCellIndex = i;
    }
    if (cellVoltages[i] < cellVoltages[minCellIndex]) {
      minCellIndex = i;
    }
  }
  const maxCellVoltage = cellVoltages.length > 0 ? cellDetail[maxCellIndex].voltageV : 0;
  const minCellVoltage = cellVoltages.length > 0 ? cellDetail[minCellIndex].voltageV : 0;
  const voltageDiff = u16(40) / 1000;

  // 温度: @116 起最多 4 路 int16, 后 2 路为 0 时跳过
  const temperatures: TemperatureReading[] = [];
  const tempSources: number[] = [];
  for (let q = 0; q < 4; q++) {
    const off = 116 + 2 * q;
    if (off + 1 >= raw.length) {
      break;
    }
    const t = i16(off) / 10;
    if (t <= -100 || t >= 100) {
      continue;
    }
    if (q >= 2 && t === 0) {
      continue;
    }
    temperatures.push({ index: q + 1, temperature: t });
    tempSources.push(t);
  }
  const cellTemp = i16(28) / 10;
  const envTemp = i16(30) / 10;
  const mosTemp = i16(32) / 10;
  const allTemps: number[] = [mosTemp, envTemp, cellTemp];
  for (let i = 0; i < tempSources.length; i++) {
    allTemps.push(tempSources[i]);
  }
  let tempMax = allTemps[0];
  let tempMin = allTemps[0];
  for (let i = 1; i < allTemps.length; i++) {
    if (allTemps[i] > tempMax) {
      tempMax = allTemps[i];
    }
    if (allTemps[i] < tempMin) {
      tempMin = allTemps[i];
    }
  }

  const balanceMask = u32(64);
  const balancing: boolean[] = [];
  for (let i = 0; i < cellVoltages.length; i++) {
    balancing.push((balanceMask & (1 << i)) !== 0);
  }

  const isCharging = avgCurrent > 0.05;
  const isDischarging = avgCurrent < -0.05;
  const chargeState = isCharging ? 1 : (isDischarging ? 2 : 0);
  const chargeMosOn = (raw[12] & 2) !== 0;
  const dischargeMosOn = (raw[12] & 1) !== 0;
  const power = Math.round(voltage * Math.abs(current) * 100) / 100;

  const flags: string[] = [];
  const groups: StatusByteGroup[] = STATUS_BYTE_MAP;
  let controls: BitFlag[] = [];
  let protections: BitFlag[] = [];
  let faults: BitFlag[] = [];
  let warns: BitFlag[] = [];
  let states: BitFlag[] = [];
  for (let g = 0; g < groups.length; g++) {
    const grp = groups[g];
    flags.push(grp.byte.toString(16));
    const bits = decodeBits(raw[grp.byte], grp.labels);
    if (grp.byte <= 3) {
      controls = controls.concat(bits);
    } else if (grp.byte <= 7) {
      protections = protections.concat(bits);
    } else if (grp.byte === 8) {
      faults = faults.concat(bits);
    } else if (grp.byte <= 11) {
      warns = warns.concat(bits);
    } else {
      states = states.concat(bits);
    }
  }

  let rawHex = '';
  for (let i = 0; i < raw.length; i++) {
    let h = raw[i].toString(16);
    if (h.length < 2) {
      h = '0' + h;
    }
    rawHex += h.toUpperCase();
  }

  return {
    voltage: voltage,
    avgCurrent: avgCurrent,
    current: current,
    soc: soc,
    soh: soh,
    cycles: u16(60),
    cellCount: cellCount,
    timestamp: 1000 * u32(16),
    capRemain: capRemain,
    capFull: capFull,
    tempMax: tempMax,
    tempMin: tempMin,
    cellTemp: cellTemp,
    envTemp: envTemp,
    mosTemp: mosTemp,
    temperatures: temperatures,
    cellVoltages: cellVoltages,
    cellDetail: cellDetail,
    maxCellVoltage: maxCellVoltage,
    minCellVoltage: minCellVoltage,
    maxCellIndex: maxCellIndex,
    minCellIndex: minCellIndex,
    voltageDiff: voltageDiff,
    power: power,
    isCharging: isCharging,
    isDischarging: isDischarging,
    chargeState: chargeState,
    chargeMosOn: chargeMosOn,
    dischargeMosOn: dischargeMosOn,
    balanceMask: balanceMask,
    balancing: balancing,
    controls: controls,
    protections: protections,
    faults: faults,
    warns: warns,
    states: states,
    flags: flags.join('').toUpperCase(),
    rawHex: rawHex
  };
}
