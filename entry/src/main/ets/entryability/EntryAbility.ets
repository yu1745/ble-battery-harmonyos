/**
 * 应用入口: 申请蓝牙权限 → 启动后台监控服务。
 */
import { UIAbility, Want, abilityAccessCtrl, Permissions } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import type AbilityConstant from '@ohos.app.ability.AbilityConstant';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BatteryMonitor } from '../monitor/BatteryMonitor';
import { Store } from '../data/Store';

const DOMAIN: number = 0xB100;
const TAG: string = 'EntryAbility';

const PERMISSIONS: Array<Permissions> = ['ohos.permission.ACCESS_BLUETOOTH'];

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'onDestroy');
    // 注意: 用户划掉应用后长时任务会被系统取消, 卡片显示最后锁定的电量。
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code !== 0) {
        hilog.error(DOMAIN, TAG, 'loadContent failed %{public}d', err.code);
        return;
      }
      this.bootstrap();
    });
  }

  onWindowStageDestroy(): void {
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'onForeground');
    BatteryMonitor.getInstance().setForeground(true);
    BatteryMonitor.getInstance().setLowLatency(true);
    BatteryMonitor.getInstance().requestRefresh();
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'onBackground');
    BatteryMonitor.getInstance().setForeground(false);
    BatteryMonitor.getInstance().setLowLatency(false);
  }

  private async bootstrap(): Promise<void> {
    const monitor = BatteryMonitor.getInstance();
    const granted = await this.ensurePermission();
    if (!granted) {
      hilog.warn(DOMAIN, TAG, 'bluetooth permission not granted');
      return;
    }
    if (Store.getMonitorEnabled(this.context)) {
      await monitor.start(this.context);
    }
  }

  private async ensurePermission(): Promise<boolean> {
    try {
      const atManager = abilityAccessCtrl.createAtManager();
      const result = await atManager.requestPermissionsFromUser(this.context, PERMISSIONS);
      for (let i = 0; i < result.authResults.length; i++) {
        if (result.authResults[i] !== 0) {
          return false;
        }
      }
      return true;
    } catch (e) {
      const be = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'requestPermissions err %{public}d %{public}s', be.code, be.message);
      return false;
    }
  }
}
