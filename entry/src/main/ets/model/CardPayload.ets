/**
 * 卡片数据构建 — BatteryMonitor 与 EntryFormAbility 共用。
 * 仅含 string/number 基础类型 (formBindingData 要求)。
 *
 * 时间显示规则:
 *   <1 分钟   → "刚刚更新"
 *   <1 小时   → "N分钟前更新"
 *   <24 小时  → "N小时M分钟前更新"
 *   ≥24 小时  → 不显示时间, disconnected=1, 卡片显示"断联"
 */
import { BatterySnapshot, emptySnapshot } from './BatterySnapshot';

export class CardPayload {
  /** 无数据时的空载荷 (卡片仍可渲染骨架) */
  static empty(): Record<string, Object> {
    return CardPayload.build(emptySnapshot());
  }

  static build(snap: BatterySnapshot | null): Record<string, Object> {
    const s: BatterySnapshot = snap !== null ? snap : emptySnapshot();
    const now = Date.now();
    const locked = s.updatedAt > 0 && (now - s.updatedAt) > 10 * 60 * 1000;
    const socRounded = Math.round(s.soc);

    // 相对时间
    let updatedAtText = '尚未连接';
    let disconnected = 0;
    if (s.updatedAt > 0) {
      const ageMs = now - s.updatedAt;
      const minTotal = Math.floor(ageMs / 60000);
      if (ageMs >= 24 * 60 * 60 * 1000) {
        disconnected = 1;
        updatedAtText = '';
      } else if (minTotal < 1) {
        updatedAtText = '刚刚更新';
      } else if (minTotal < 60) {
        updatedAtText = `${minTotal}分钟前更新`;
      } else {
        const h = Math.floor(minTotal / 60);
        const m = minTotal % 60;
        updatedAtText = m > 0 ? `${h}小时${m}分钟前更新` : `${h}小时前更新`;
      }
    }

    let stateText = '—';
    if (s.chargeState === 1) {
      stateText = '充电中';
    } else if (s.chargeState === 2) {
      stateText = '放电中';
    } else if (s.updatedAt > 0) {
      stateText = '静置';
    }
    const payload: Record<string, Object> = {
      'soc': socRounded,
      'socText': s.updatedAt > 0 ? `${socRounded}` : '--',
      'voltageText': s.voltage > 0 ? `${s.voltage.toFixed(2)}V` : '--',
      'currentText': s.full ? `${s.current >= 0 ? '+' : ''}${s.current.toFixed(1)}A` : '',
      'name': s.name !== '' ? s.name : 'FD…',
      'sn': s.sn,
      'stateText': stateText,
      'updatedAtText': updatedAtText,
      'disconnected': disconnected,
      'locked': locked ? 1 : 0,
      'cycles': s.cycles,
      'tempText': s.full ? `${s.tempMin.toFixed(0)}~${s.tempMax.toFixed(0)}°C` : '',
      'cellText': s.full && s.cellCount > 0 ?
        `${(s.cellMinMv / 1000).toFixed(3)}~${(s.cellMaxMv / 1000).toFixed(3)}V` : '',
      'capacityText': s.full && s.capFull > 0 ? `${s.capRemain.toFixed(1)}/${s.capFull.toFixed(1)}Ah` : ''
    };
    return payload;
  }
}
