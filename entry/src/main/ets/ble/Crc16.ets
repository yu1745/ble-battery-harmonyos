/**
 * CRC16-Modbus (poly 0xA001, init 0xFFFF) 与 F403 命令生成。
 * 移植自 yu1745/ble-battery src/ble.ts
 */

export function crc16Modbus(data: Uint8Array): number {
  let crc = 0xffff;
  for (let i = 0; i < data.length; i++) {
    crc ^= data[i];
    for (let b = 0; b < 8; b++) {
      if ((crc & 1) !== 0) {
        crc = (crc >> 1) ^ 0xa001;
      } else {
        crc = crc >> 1;
      }
    }
  }
  return crc;
}

/** 返回小端序 CRC hex 字符串 (4字符, 大写) */
export function crc16HexStr(data: Uint8Array): string {
  const val = crc16Modbus(data);
  const swapped = ((val & 0xff) << 8) | ((val >> 8) & 0xff);
  let hex = swapped.toString(16);
  while (hex.length < 4) {
    hex = '0' + hex;
  }
  return hex.toUpperCase();
}

/**
 * 生成 F403 命令: F403 <addr_hi> <addr_lo> <byte_count> <CRC16>
 * CRC 计算范围: F4 03 addr_hi addr_lo byte_count
 */
export function makeF403Command(address: number, byteCount: number): string {
  const payload = new Uint8Array([
    0xf4, 0x03,
    (address >> 8) & 0xff,
    address & 0xff,
    byteCount & 0xff
  ]);
  const crc = crc16HexStr(payload);
  let hi = ((address >> 8) & 0xff).toString(16);
  let lo = (address & 0xff).toString(16);
  let bc = (byteCount & 0xff).toString(16);
  while (hi.length < 2) {
    hi = '0' + hi;
  }
  while (lo.length < 2) {
    lo = '0' + lo;
  }
  while (bc.length < 2) {
    bc = '0' + bc;
  }
  return 'F403' + hi.toUpperCase() + lo.toUpperCase() + bc.toUpperCase() + crc;
}

export function hexToBytes(hex: string): Uint8Array {
  const len = hex.length >> 1;
  const bytes = new Uint8Array(len);
  for (let i = 0; i < len; i++) {
    bytes[i] = parseInt(hex.substr(i * 2, 2), 16);
  }
  return bytes;
}

export function bytesToHex(bytes: Uint8Array): string {
  let s = '';
  for (let i = 0; i < bytes.length; i++) {
    let h = bytes[i].toString(16);
    if (h.length < 2) {
      h = '0' + h;
    }
    s += h.toUpperCase();
  }
  return s;
}
