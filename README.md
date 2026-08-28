# BLE 电池管家 (HarmonyOS NEXT 版)

[yu1745/ble-battery](https://github.com/yu1745/ble-battery)(Web Bluetooth 版 "BYD BLE BMS")的 **鸿蒙 HarmonyOS NEXT 原生移植版**。

扫描名称以 `FD` 开头的 BLE 电池(迪子电量协议 / 15 串磷酸铁锂 BMS),解析广播数据并通过 Nordic UART 透传 F403 命令读取完整 BMS 寄存器,展示电量、电压、电流、功率、循环次数、SOH、容量、温度、15 串电芯电压与 128 个状态位;同时提供**服务卡片**(2x2 / 2x4),可添加到桌面与负一屏卡片专区,断联后**锁定显示最后已知电量,永不显示离线**。

- 目标平台:HarmonyOS NEXT(Compatible SDK `5.1.0(18)` / API 18,Stage 模型,ArkTS)
- 协议文档见 [docs/BMS寄存器映射.md](docs/BMS寄存器映射.md)
- 负一屏接口调研与"电量锁定"设计见 [docs/负一屏电量接口分析.md](docs/负一屏电量接口分析.md)

## 功能对照(与 Web 版)

| Web 版功能 | 鸿蒙版 |
|---|---|
| Web Bluetooth 选择 FD 设备 | 后台自动扫描 `FD*` 广播 + 设备列表手动选择 |
| 广播解析 SN/电压/电量(免连接) | ✅ 同协议(含 GYE0/BYDM 变体),卡片实时刷新主要靠它 |
| F403 读 124 字节寄存器(分块 60→4 降级重试、CRC16-Modbus 校验) | ✅ 完整移植 |
| 电量/电压/电流/功率/循环/SOH/容量/温度/15 串电芯/128 状态位/原始 HEX | ✅ 全部保留,电芯压差告警阈值可调 |
| 5s 轮询 | ✅(连接时),另有广播流式更新 |
| —(Web 版没有) | 服务卡片(2x2/2x4)、长时任务后台监控、断联电量锁定、历史记录、自动重连 |

## 工程结构

```
entry/src/main/ets/
├── ble/
│   ├── Crc16.ets          # CRC16-Modbus + F403 命令生成 (移植自 src/ble.ts)
│   ├── BmsTypes.ets       # BmsData / AdvParsed 等类型
│   ├── BmsParser.ets      # 124 字节寄存器解析 + 128 状态位字典 (FACE72B3.parse 移植)
│   ├── AdvParser.ets      # 原始 ADV 报文解析 + manufacturer data → SN/V/SoC
│   └── BleManager.ets     # createBleScanner 扫描 + GattClientDevice 会话 + 串行命令队列
├── model/
│   ├── BatterySnapshot.ets# 持久化"最后已知"快照 (锁定数据源)
│   └── CardPayload.ets    # 卡片数据构建
├── data/Store.ets         # preferences 持久化 (快照/设备/卡片formId/设置/历史)
├── monitor/
│   └── BatteryMonitor.ets # 长时任务(bluetoothInteraction) + 扫描/连接/轮询状态机 + 卡片推送
├── entryability/EntryAbility.ets      # 权限申请 + 启动监控 + 前后台扫描占空比切换
├── entryformability/EntryFormAbility.ets # 卡片生命周期 (添加/定时/事件刷新)
├── pages/Index.ets        # 主界面 (完整监控详情)
└── widget/pages/          # 2x2 / 2x4 卡片
```

## 在 Linux 命令行构建(本仓库验证过的流程)

1. 下载 Command Line Tools(HuaweiCloud 公共仓库,免登录):

```bash
curl -LO https://repo.huaweicloud.com/harmonyos/ohpm/5.1.0/commandline-tools-linux-x64-5.1.0.840.zip
unzip commandline-tools-linux-x64-5.1.0.840.zip -d ~/harmonyos
# sha256: 1dcefa4741dc289277560b2802040e0c45b433898d8db453d711d5376e0478f1
```

2. 构建(Hvigor 5.18.5 已通过 `hvigor/hvigor-config.json5` 的 `file:` 依赖指向本地):

```bash
./build.sh            # = hvigorw --no-daemon assembleHap
# 产物: entry/build/default/outputs/default/entry-default-unsigned.hap
```

## 签名与安装(需华为开发者账号)

HarmonyOS NEXT 不允许安装未签名 HAP,签名证书必须经 AGC(AppGallery Connect)签发,无法纯本地完成:

1. 用 DevEco Studio(Windows/macOS)打开本工程,登录华为账号 → File ▸ Project Structure ▸ Signing Configs ▸ 勾选 Automatically generate signature(调试证书会绑定设备 UDID);
2. 或者在 AGC 下载 `.p12/.cer/.p7b` 后填入 `build-profile.json5` 的 `signingConfigs`,再命令行 `hvigorw assembleHap`;
3. 安装:`hdc install entry-default-signed.hap`。

## 权限与后台行为

- `ohos.permission.ACCESS_BLUETOOTH`(user_grant):BLE 扫描/连接;
- `ohos.permission.KEEP_BACKGROUND_RUNNING` + `backgroundModes: ["bluetoothInteraction"]`:长时任务,后台持续扫描/连接并实时更新卡片;
- 平台限制:从最近任务划掉应用会取消长时任务,卡片转为显示**锁定的最后电量**(30 分钟兜底重绘),再次打开应用即恢复实时。

## 添加卡片到负一屏

桌面长按空白 → 服务卡片 / 负一屏"卡片"专区"+"→ 选择"BLE电池管家"卡片(2x2 或 2x4)。卡片样式与信息密度对齐系统"随身设备电量"卡片;负一屏卡片专区对常驻应用卡片的支持见 [docs/负一屏电量接口分析.md](docs/负一屏电量接口分析.md)。

## License

MIT(协议解析移植自 [yu1745/ble-battery](https://github.com/yu1745/ble-battery))
