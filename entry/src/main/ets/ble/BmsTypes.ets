/**
 * BMS 数据类型定义。
 * 移植自 yu1745/ble-battery src/ble.ts
 */

export interface AdvParsed {
  name: string;
  sn: string;
  voltage: number;
  soc: number;
}

export interface BitFlag {
  name: string;
  active: boolean;
}

export interface CellVoltage {
  index: number;
  voltage: number; // mV
  voltageV: number; // V
}

export interface TemperatureReading {
  index: number;
  temperature: number; // °C
}

export interface BmsData {
  // 基础
  voltage: number; // V
  avgCurrent: number; // A
  current: number; // A
  soc: number; // %
  soh: number; // %
  cycles: number;
  cellCount: number;
  timestamp: number; // ms
  capRemain: number; // Ah
  capFull: number; // Ah

  // 温度
  tempMax: number; // °C
  tempMin: number; // °C
  cellTemp: number; // °C
  envTemp: number; // °C
  mosTemp: number; // °C
  temperatures: TemperatureReading[];

  // 电芯
  cellVoltages: number[]; // mV[]
  cellDetail: CellVoltage[];
  maxCellVoltage: number; // V
  minCellVoltage: number; // V
  maxCellIndex: number;
  minCellIndex: number;
  voltageDiff: number; // V

  // 功率与状态
  power: number; // W
  isCharging: boolean;
  isDischarging: boolean;
  chargeState: number; // 0=静置 1=充电 2=放电
  chargeMosOn: boolean;
  dischargeMosOn: boolean;

  // 均衡
  balanceMask: number;
  balancing: boolean[];

  // 状态位
  controls: BitFlag[];
  protections: BitFlag[];
  faults: BitFlag[];
  warns: BitFlag[];
  states: BitFlag[];

  // 原始
  flags: string;
  rawHex: string;
}
