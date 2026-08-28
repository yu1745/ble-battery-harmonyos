/**
 * 广播数据解析 — 无需连接即可获取 SN / 电压 / 电量。
 * 移植自 yu1745/ble-battery src/ble.ts (parseAdvData)
 * HarmonyOS 版本额外提供原始 ADV 报文解析 (提取 manufacturer data)。
 */
import { AdvParsed } from './BmsTypes';

/** 提取的广播信息 */
export interface RawAdv {
  localName: string;
  manufacturerId: number;
  /** company id 之后的数据段 (与 Web BLE / Bleak 的 manufacturerData 值一致) */
  manufacturerData: Uint8Array | null;
}

/**
 * 解析 BLE 原始广播报文 (ScanResult.data)。
 * 结构: [len][type][data...] 重复, len 不含自身 1 字节。
 */
export function parseRawAdv(data: Uint8Array): RawAdv {
  let localName = '';
  let manufacturerId = -1;
  let manufacturerData: Uint8Array | null = null;
  let pos = 0;
  while (pos + 1 < data.length) {
    const len = data[pos];
    if (len < 1 || pos + 1 + len > data.length) {
      break;
    }
    const adType = data[pos + 1];
    const start = pos + 2;
    const end = pos + 1 + len;
    if (adType === 0x08 || adType === 0x09) {
      // shortened / complete local name
      let name = '';
      for (let i = start; i < end; i++) {
        if (data[i] >= 0x20 && data[i] <= 0x7e) {
          name += String.fromCharCode(data[i]);
        }
      }
      if (name.length > 0) {
        localName = name;
      }
    } else if (adType === 0xff && end - start >= 2) {
      manufacturerId = data[start] | (data[start + 1] << 8);
      const md = new Uint8Array(end - start - 2);
      for (let i = start + 2; i < end; i++) {
        md[i - start - 2] = data[i];
      }
      manufacturerData = md;
    }
    pos = end;
  }
  return { localName: localName, manufacturerId: manufacturerId, manufacturerData: manufacturerData };
}

const GYE0 = [71, 89, 69, 48]; // "GYE0"
const BYDM = [66, 89, 68, 77]; // "BYDM"

/**
 * 解析 manufacturer data → SN / 电压 / 电量。
 * 数据结构: ASCII SN + Voltage(2B LE ×0.01) + SoC(2B LE ×0.1)
 */
export function parseAdvData(name: string, advData: Uint8Array | null): AdvParsed | null {
  if (!name.startsWith('FD') || advData === null || advData.length < 6) {
    return null;
  }

  let snBytes: Uint8Array;
  let vOff = 0;
  let socOff = 0;

  const isGyemBydm =
    (advData[0] === GYE0[0] && advData[1] === GYE0[1]) ||
    (advData[0] === BYDM[0] && advData[1] === BYDM[1]);

  if (isGyemBydm && advData.length >= 24) {
    snBytes = advData.slice(0, 20);
    vOff = 20;
    socOff = 22;
  } else {
    let snEnd = 0;
    const limit = Math.min(advData.length, 20);
    while (snEnd < limit && advData[snEnd] >= 0x20 && advData[snEnd] <= 0x7e) {
      snEnd++;
    }
    if (snEnd > 0) {
      snBytes = advData.slice(0, snEnd);
    } else {
      snBytes = advData.slice(0, Math.min(advData.length, 17));
    }
    vOff = snEnd;
    socOff = snEnd + 2;
  }

  let sn = '';
  for (let i = 0; i < snBytes.length; i++) {
    if (snBytes[i] >= 0x20 && snBytes[i] <= 0x7e) {
      sn += String.fromCharCode(snBytes[i]);
    }
  }

  const le16 = (off: number): number => {
    if (off + 2 > advData.length) {
      return 0;
    }
    return (advData[off] | (advData[off + 1] << 8)) >>> 0;
  };

  const voltage = le16(vOff) * 0.01;
  const soc = le16(socOff) * 0.1;

  return { name: name, sn: sn.length > 0 ? sn : '-', voltage: voltage, soc: soc };
}
