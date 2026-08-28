/**
 * 持久化存储 — 基于 @ohos.data.preferences。
 * 保存: 最后电量快照 / 选定设备 / 卡片 formId 列表 / 设置 / 历史记录。
 */
import { preferences } from '@kit.ArkData';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Context } from '@kit.AbilityKit';
import { BatterySnapshot, snapshotToJson, snapshotFromJson } from '../model/BatterySnapshot';

const DOMAIN: number = 0xB100;
const TAG: string = 'BleStore';
const PREF_NAME = 'blebms';

const K_SNAPSHOT = 'snapshot';
const K_SELECTED_ID = 'selectedId';
const K_SELECTED_NAME = 'selectedName';
const K_FORM_IDS = 'formIds';
const K_CELL_WARN = 'cellWarnThresholdMv';
const K_AUTO_RECONNECT = 'autoReconnect';
const K_HISTORY = 'history';
const K_MONITOR_ENABLED = 'monitorEnabled';

export class HistoryRecord {
  time: number = 0;
  soc: number = 0;
  voltage: number = 0;
}

function getPref(context: Context): preferences.Preferences {
  // 使用 ApplicationContext 保证 UIAbility 与 FormExtensionAbility 两个进程访问同一份偏好文件
  return preferences.getPreferencesSync(context.getApplicationContext(), { name: PREF_NAME });
}

export class Store {
  static loadSnapshot(context: Context): BatterySnapshot | null {
    try {
      const p = getPref(context);
      const text = p.getSync(K_SNAPSHOT, '') as string;
      if (text === '') {
        return null;
      }
      return snapshotFromJson(text);
    } catch (e) {
      return null;
    }
  }

  static saveSnapshot(context: Context, snap: BatterySnapshot): void {
    try {
      const p = getPref(context);
      p.putSync(K_SNAPSHOT, snapshotToJson(snap));
      p.flush();
    } catch (e) {
      const be = e as Error;
      hilog.error(DOMAIN, TAG, 'saveSnapshot err %{public}s', be.message);
    }
  }

  static getSelectedDevice(context: Context): string {
    try {
      const p = getPref(context);
      return p.getSync(K_SELECTED_ID, '') as string;
    } catch (e) {
      return '';
    }
  }

  static getSelectedName(context: Context): string {
    try {
      const p = getPref(context);
      return p.getSync(K_SELECTED_NAME, '') as string;
    } catch (e) {
      return '';
    }
  }

  static setSelectedDevice(context: Context, deviceId: string, name: string): void {
    try {
      const p = getPref(context);
      p.putSync(K_SELECTED_ID, deviceId);
      p.putSync(K_SELECTED_NAME, name);
      p.flush();
    } catch (e) {
    }
  }

  static getFormIds(context: Context): string[] {
    try {
      const p = getPref(context);
      const v = p.getSync(K_FORM_IDS, '');
      if (v === '') {
        return [];
      }
      return (v as string).split(',');
    } catch (e) {
      return [];
    }
  }

  static addFormId(context: Context, formId: string): void {
    try {
      const ids = Store.getFormIds(context);
      if (ids.indexOf(formId) < 0) {
        ids.push(formId);
        const p = getPref(context);
        p.putSync(K_FORM_IDS, ids.join(','));
        p.flush();
      }
    } catch (e) {
    }
  }

  static removeFormId(context: Context, formId: string): void {
    try {
      const ids = Store.getFormIds(context);
      const idx = ids.indexOf(formId);
      if (idx >= 0) {
        ids.splice(idx, 1);
        const p = getPref(context);
        p.putSync(K_FORM_IDS, ids.join(','));
        p.flush();
      }
    } catch (e) {
    }
  }

  static getCellWarnThreshold(context: Context): number {
    try {
      const p = getPref(context);
      return p.getSync(K_CELL_WARN, 30) as number;
    } catch (e) {
      return 30;
    }
  }

  static setCellWarnThreshold(context: Context, mv: number): void {
    try {
      const p = getPref(context);
      p.putSync(K_CELL_WARN, mv);
      p.flush();
    } catch (e) {
    }
  }

  static getAutoReconnect(context: Context): boolean {
    try {
      const p = getPref(context);
      return (p.getSync(K_AUTO_RECONNECT, 1) as number) === 1;
    } catch (e) {
      return true;
    }
  }

  static setAutoReconnect(context: Context, on: boolean): void {
    try {
      const p = getPref(context);
      p.putSync(K_AUTO_RECONNECT, on ? 1 : 0);
      p.flush();
    } catch (e) {
    }
  }

  static getMonitorEnabled(context: Context): boolean {
    try {
      const p = getPref(context);
      return (p.getSync(K_MONITOR_ENABLED, 1) as number) === 1;
    } catch (e) {
      return true;
    }
  }

  static setMonitorEnabled(context: Context, on: boolean): void {
    try {
      const p = getPref(context);
      p.putSync(K_MONITOR_ENABLED, on ? 1 : 0);
      p.flush();
    } catch (e) {
    }
  }

  static getHistory(context: Context): HistoryRecord[] {
    try {
      const p = getPref(context);
      const v = p.getSync(K_HISTORY, '[]') as string;
      const arr = JSON.parse(v) as Array<Record<string, Object>>;
      const out: HistoryRecord[] = [];
      for (let i = 0; i < arr.length; i++) {
        const r = new HistoryRecord();
        r.time = Number(arr[i]['t'] ?? 0);
        r.soc = Number(arr[i]['s'] ?? 0);
        r.voltage = Number(arr[i]['v'] ?? 0);
        out.push(r);
      }
      return out;
    } catch (e) {
      return [];
    }
  }

  /** 追加历史记录 (环形上限 200), soc 变化或距上一条 ≥60s 才记录 */
  static appendHistory(context: Context, snap: BatterySnapshot): void {
    try {
      const hist = Store.getHistory(context);
      const last = hist.length > 0 ? hist[hist.length - 1] : null;
      if (last !== null) {
        const sameSoc = Math.abs(last.soc - snap.soc) < 0.05;
        const fresh = snap.updatedAt - last.time < 60000;
        if (sameSoc && fresh) {
          return;
        }
      }
      const r = new HistoryRecord();
      r.time = snap.updatedAt;
      r.soc = snap.soc;
      r.voltage = snap.voltage;
      hist.push(r);
      while (hist.length > 200) {
        hist.shift();
      }
      const arr: Record<string, Object>[] = [];
      for (let i = 0; i < hist.length; i++) {
        const rec: Record<string, Object> = {
          't': hist[i].time,
          's': hist[i].soc,
          'v': hist[i].voltage
        };
        arr.push(rec);
      }
      const p = getPref(context);
      p.putSync(K_HISTORY, JSON.stringify(arr));
      p.flush();
    } catch (e) {
    }
  }
}
