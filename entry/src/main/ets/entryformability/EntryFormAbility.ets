/**
 * 卡片 FormExtensionAbility:
 *  - onAddForm: 记录 formId, 返回当前(锁定的)快照数据
 *  - onUpdateForm: 定时刷新 (30min) — 从持久化快照渲染, 永不清空
 *  - onFormEvent: 卡片上的"刷新"按钮 → 回写最新快照 (若监控进程在线, 其会推送实时数据)
 */
import { FormExtensionAbility, formBindingData, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Store } from '../data/Store';
import { CardPayload } from '../model/CardPayload';

const DOMAIN: number = 0xB100;
const TAG: string = 'EntryFormAbility';

export default class EntryFormAbility extends FormExtensionAbility {
  onAddForm(want: Want): formBindingData.FormBindingData {
    hilog.info(DOMAIN, TAG, 'onAddForm');
    const params: Record<string, Object> | undefined = want.parameters;
    let formId = '';
    if (params !== undefined && params !== null) {
      const v = params['ohos.extra.param.key.form_identity'];
      if (v !== undefined && v !== null) {
        formId = String(v);
      }
    }
    if (formId !== '') {
      Store.addFormId(this.context, formId);
    }
    return formBindingData.createFormBindingData(CardPayload.build(Store.loadSnapshot(this.context)));
  }

  onUpdateForm(formId: string): void {
    // 定时刷新: 用持久化快照渲染 (断联时即为锁定的最后电量, 永不显示离线)
    const data = formBindingData.createFormBindingData(CardPayload.build(Store.loadSnapshot(this.context)));
    formProvider.updateForm(formId, data).then<void>(() => {
      return;
    }).catch((e: Error) => {
      hilog.warn(DOMAIN, TAG, 'onUpdateForm err %{public}s', e.message);
    });
  }

  onRemoveForm(formId: string): void {
    hilog.info(DOMAIN, TAG, 'onRemoveForm %{public}s', formId);
    Store.removeFormId(this.context, formId);
  }

  onFormEvent(formId: string, message: string): void {
    hilog.info(DOMAIN, TAG, 'onFormEvent %{public}s %{public}s', formId, message);
    const data = formBindingData.createFormBindingData(CardPayload.build(Store.loadSnapshot(this.context)));
    formProvider.updateForm(formId, data).then<void>(() => {
      return;
    }).catch((e: Error) => {
    });
  }
}
