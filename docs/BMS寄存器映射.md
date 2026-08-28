# BMS 寄存器映射文档

## 设备识别

### 如何区分电池 BLE 设备与其他蓝牙设备

扫描到 BLE 设备时，通过以下特征组合可以确认是否为该型号电池：

| 特征 | 判断依据 |
|------|---------|
| **设备名** | 以 `FD` 开头（实测例：`FDA90705`） |
| **广播数据** | Manufacturer Data 前段为 ASCII 可打印字符（序列号），末尾 4-6 字节为电压和电量的二进制值 |
| **连接后 Service** | 暴露 Nordic UART Service (`6E400001-B5A3-F393-E0A9-E50E24DCCA9E`) |
| **响应 F403 命令** | 发送 `F40310003C` + CRC 后，返回 60 字节数据的设备才是目标电池 |

**筛选流程：**

```
扫描 → 设备名以 FD 开头？
  ├─ 否 → 跳过（其他设备）
  └─ 是 → 解析 manufacturer_data：
       ├─ 能解析出 ASCII 序列号 + 电压 + 电量 → 确认是电池
       └─ 数据不足（如仅 4 字节）→ 忽略（残留广播包）
```

### 微信小程序的过滤方式

微信小程序通过 **三层过滤** 识别电池设备：

**第一层 — ecBLE.js 广播回调：**
```javascript
if (name != null && name.startsWith("FD")) {
    // 解析 advertisData 中的 SN/电压/电量
}
```

**第二层 — bluetooth/index.vue 列表显示：**
```javascript
if (!device.name || !device.name.startsWith("FD")) {
    return; // 不加入列表
}
```

**第三层 — 连接后调服务端 API 做关联校验：**
```javascript
getCorrelationList({ wxId }).then(res => {
    res.data.filter(e => e.batteryName == deviceName); // 匹配已关联设备
})
```

核心规则就是一条：**设备名以 `FD` 开头**。

### 第三方客户端推荐判断逻辑

无法调微信服务器 API，因此采用自包含的多层判断：

#### 快速筛选（广播扫描时，无需连接）

| 条件 | 说明 |
|------|------|
| ① 名称以 `FD` 开头 | 第一道过滤 |
| ② Manufacturer data 非空且长度 ≥ 4 | 排除残留广播包 |
| ③ 前 N 个字节为 ASCII 可见字符 | 确认包含 SN 文本 |
| ④ 末尾字节能解析出合理电压和电量 | 确认是电池数据 |

```python
def is_battery_candidate(device, adv_data) -> bool:
    """广播扫描时的快速筛选"""
    if not device.name or not device.name.startswith("FD"):
        return False
    if not adv_data.manufacturer_data:
        return False
    raw = next(iter(adv_data.manufacturer_data.values()))
    if len(raw) < 6:
        return False
    ascii_len = sum(1 for b in raw if 0x20 <= b <= 0x7E)
    if ascii_len < 4:
        return False
    return True
```

#### 可靠确认（需连接）

```python
async def confirm_is_battery(address: str) -> bool:
    """连接后确认设备是否为电池"""
    client = BleakClient(address)
    await client.connect()
    try:
        # ① 检查 Nordic UART Service
        has_uart = any(
            s.uuid.upper() == "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
            for s in client.services
        )
        if not has_uart:
            return False
        # ② 发送 F403 命令并验证响应
        cmd = make_f403_command(0x1000, 4)
        resp = await send_command(client, cmd)
        if not resp or not resp.startswith("F403"):
            return False
        # ③ 解析出电压并验证合理性
        data = bytes.fromhex(resp[6:-4])
        if len(data) < 4:
            return False
        voltage = struct.unpack_from("<H", data, 2)[0] * 0.01
        return 20 < voltage < 60  # 锂电池合理范围
    except Exception:
        return False
    finally:
        await client.disconnect()
```

#### 推荐方案

两步就够了，不需要额外确认：

```
广播扫描 → FD 前缀 + 有 manufacturer data → 加入列表
   ↓ 用户选择
连接 → F403 读 BMS → 能返回 124 字节 → 确认是电池 → 开始轮询
```

#### 判断依据的特异度

| 检测项 | 误报率 | 说明 |
|--------|--------|------|
| 名称 `FD` 前缀 | 中 | 可能有其他设备也用此前缀 |
| + UART Service UUID | 低 | Nordic NUS 服务常见于串口透传设备 |
| + F403 命令正确响应 | **极低** | 这是电池 BMS 特有的 Modbus 类协议 |
| + 解析出 15 串电芯电压 | **唯一性** | 非电池设备不可能有该数据 |

### 实测设备

| 项目 | 内容 |
|------|------|
| 设备名 | FDA90705 |
| MAC 地址 | XX:XX:XX:XX:XX:XX |
| 电池类型 | 15 串磷酸铁锂 (LiFePO4) |
| 额定电压 | 48V (15 × 3.2V) |
| 满电电压 | ≈51.1V (15 × 3.41V) |
| 通信方式 | BLE UART (Nordic UART Service) |
| Service UUID | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` |
| Write Char | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` |
| Notify Char | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` |

## 通信协议

### 命令格式

读取 BMS 寄存器使用 F403 命令（ASCII hex 文本传输）：

```
F403 <addr_high> <addr_low> <byte_count> <CRC16>
```

- 命令以 ASCII hex 文本形式通过 BLE 发送（设备的 Nordic UART 固件解析 hex 文本）
- 响应也是 ASCII hex 文本，格式相同
- CRC16: Modbus CRC-16 (多项式 0xA001, 初始 0xFFFF, 小端序)

### 读取参数

| 参数 | 值 |
|------|-----|
| 起始地址 | 0x1000 |
| 读取长度 | 124 bytes |
| 分块大小 | 60 bytes |
| 响应超时 | 3 秒 |
| 轮询间隔 | 5 秒 |

## 完整通信流程

### 1. 广播扫描 → 解析 advertisData

无需连接。从 BLE 广播包的 manufacturer data 中直接读取：

```
raw = manufacturer_data[company_id]

① 找 SN 末尾: 从 raw[0] 开始遍历，直到遇到非 ASCII 可见字符 (0x20-0x7E)
② SN = raw[0:sn_end] → 字节转 ASCII
③ V  = raw[sn_end:sn_end+2] → LE 16-bit × 0.01
④ SoC = raw[sn_end+2:sn_end+4] → LE 16-bit × 0.1
```

示例：`raw = 31373733394232...` → SN=`XXXXXXXXXXXXXXXXX`, V=`0x13F7`=51.11V, SoC=`0x03E8`=100.0%

### 2. 连接 → 发现服务

```python
client = BleakClient(address)
await client.connect()

# 查找 Nordic UART Service
for service in client.services:
    if service.uuid.upper() == "6E400001-B5A3-F393-E0A9-E50E24DCCA9E":
        for char in service.characteristics:
            if char.uuid.upper() == "6E400002-B5A3-F393-E0A9-E50E24DCCA9E":
                write_char = char   # 写特征值
            if "notify" in char.properties:
                notify_char = char  # 通知特征值

# (Android) 设置 MTU = 247
try:
    await client.set_mtu(247)
except:
    pass
```

### 3. 发送命令与接收响应 (核心细节)

**数据格式**：所有命令和响应都以 **ASCII hex 文本** 形式传输，非二进制。

```python
# ── 发送 ──
# 命令字符串 "F40310003C9445" 的每个字符作为 ASCII 字节发送
data = cmd_string.encode("ascii")
await client.write_gatt_char(write_char.uuid, bytearray(data), response=False)

# ── 接收 ──
# 设备响应的原始字节是 ASCII 字符，需解码为字符串
def notify_handler(sender, data: bytearray):
    text = bytes(data).decode("ascii", errors="replace")
    # text = "F4031000<hex_payload><CRC>"
    self.response_text = text
    self.response_event.set()
```

### 4. F403 命令生成与 CRC 校验

```python
def crc16_modbus(data: bytes) -> int:
    """Modbus CRC-16: 多项式 0xA001, 初始 0xFFFF"""
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 1:
                crc = (crc >> 1) ^ 0xA001
            else:
                crc >>= 1
    return crc

def crc16_hex_str(data: bytes) -> str:
    """返回小端序 CRC hex 字符串 (4字符, 大写)"""
    val = crc16_modbus(data)
    swapped = ((val & 0xFF) << 8) | ((val >> 8) & 0xFF)
    return f"{swapped:04X}"

def make_f403_command(address: int, byte_count: int) -> str:
    """
    生成 F403 命令.

    命令格式: F403 <addr_high> <addr_low> <byte_count> <CRC16>
    CRC 计算范围: F4 03 addr_high addr_low byte_count (5字节)
    """
    addr_bytes = bytes([address >> 8 & 0xFF, address & 0xFF])
    payload = bytes([0xF4, 0x03]) + addr_bytes + bytes([byte_count])
    crc = crc16_hex_str(payload)
    addr_str = addr_bytes.hex().upper()
    return f"F403{addr_str}{byte_count:02X}{crc}"

# 示例: 从 0x1000 读 60 字节
cmd = make_f403_command(0x1000, 60)  # → "F40310003C9445"
```

CRC 验证（收到响应后）：

```python
# 响应格式: "F403<addr_2chars><payload_hex><CRC_4chars>"
# resp = "F4031000<data...><CRC>"
verify_bytes = bytes.fromhex(resp[:-4])      # 去掉 CRC 的剩余字节
expected_crc = crc16_hex_str(verify_bytes)   # 重新计算 CRC
received_crc = resp[-4:]                     # 设备返回的 CRC
if expected_crc != received_crc:
    raise ValueError(f"CRC 校验失败: 期望 {expected_crc}, 收到 {received_crc}")

# 提取有效数据 (去掉 F403 + addr = 6 hex chars, 去掉 CRC = 4 hex chars)
payload_hex = resp[6:-4]
raw_bytes = bytes.fromhex(payload_hex)
```

### 5. 批量读取 (btSendTap 等效算法)

BMS 寄存器从 0x1000 开始，共 124 字节，分 3 块读取：

```python
total_bytes = 124
chunk_size = 60
accumulated_hex = ""
offset = 0
remaining = total_bytes

while remaining > 0:
    chunk = min(remaining, chunk_size)
    addr = 0x1000 + offset
    cmd = make_f403_command(addr, chunk)
    resp = await send_command(cmd)  # 发送+接收

    # 验证 CRC
    validate_crc(resp)

    # 提取 payload 并累积
    payload_hex = resp[6:-4]
    accumulated_hex += payload_hex

    offset += chunk
    remaining -= chunk

# accumulated_hex = 248 hex chars = 124 bytes
raw_data = bytes.fromhex(accumulated_hex)

# ── 原版微信将 raw_data.hex() 发往服务器 API ──
# POST /bicyclebusi/bicyclebusi/management/selectNowInfo
# Body: { deviceId: blueSn, item: accumulated_hex }
# 服务器返回 [{id, value}, ...] 格式的结果
```

### 6. 轮询循环

```python
while True:
    raw = await read_bms_data()
    parse_bms_data(raw)
    await asyncio.sleep(5)  # 5 秒轮询间隔
```

### 7. 参数与公式速查

| 字段 | 偏移 | 取值方式 | 单位 |
|------|------|---------|------|
| 电压 | 22 | `unpack('<H', raw[22:24])[0] × 0.01` | V |
| SoC | 48 | `unpack('<H', raw[48:50])[0] × 0.1` | % |
| 循环次数 | 60 | `unpack('<H', raw[60:62])[0]` | 次 |
| 温度 Min | 116 | `unpack('<H', raw[116:118])[0] × 0.1` | °C |
| 温度 Max | 118 | `unpack('<H', raw[118:120])[0] × 0.1` | °C |
| 单节电压 | 68 + i×2 | `unpack('<H', raw[68+i*2:70+i*2])[0]` | mV (i=0..14) |
| 满充容量 | 52 | `unpack('<H', raw[52:54])[0]` | 待确认 |
| 剩余容量 | 56 | `unpack('<H', raw[56:58])[0]` | 待确认 |

## 数据来源

- **广播数据 (advertisData)**：无需连接，快速获取，但可能非实时。从 BLE 广播包的 manufacturer data 中解析。
- **连接后读取 (F403 命令)**：需要建立 BLE 连接，读取 BMS 内部寄存器，获取最新数据。

### 广播数据格式

设备名以 `FD` 开头。Manufacturer Data 结构：

```
ASCII SN (不定长) + Voltage (2B LE) + SoC (2B LE) [+ 0x00 终止符]
```

示例：`XXXXXXXXXXXXXXXXX` (17 chars SN) + `F713` (0x13F7 LE = 5111 → 51.11V) + `E803` (0x03E8 LE = 1000 → 100.0%)

## 寄存器映射 (BMS 0x1000, 124 bytes)

> ⚠️ **注意**：原始数据通过 HTTP API `/bicyclebusi/bicyclebusi/management/selectNowInfo` 发往服务器解析。本地映射为反向推断，部分字段待验证。

### 已确认字段

| 偏移 | 长度 | 字段 | 格式 | 示例值 | 说明 |
|------|------|------|------|--------|------|
| 48-49 | 2B | SoC (电量百分比) | LE 16-bit × 0.1 | `0x03E8` = 1000 → 100.0% | |
| 52-53 | 2B | 满充容量 | LE 16-bit | `0x5DC0` = 24000 | 单位待确认 |
| 56-57 | 2B | 剩余容量 | LE 16-bit | `0x5DC0` = 24000 | 与满充容量相等时表示满电 |
| 60-61 | 2B | 循环次数 | LE 16-bit | `0x0003` = 3 | |
| 68-97 | 30B | 电芯电压 × 15 串 | LE 16-bit mV | `0x0D4D` = 3405 → 3.405V | 共 15 节 |
| 116-117 | 2B | 温度 Min | LE 16-bit × 0.1 | `0x00F0` = 240 → 24.0°C | |
| 118-119 | 2B | 温度 Max | LE 16-bit × 0.1 | `0x00F0` = 240 → 24.0°C | |

### 推测字段

| 偏移 | 长度 | 字段 | 格式 | 示例值 | 可信度 |
|------|------|------|------|--------|--------|
| 0-3 | 4B | Flags / 状态字 | 位域 | `0x030C0000` | ⚠️ 中 |
| 22-23 | 2B | 电池组电压 (冗余) | LE 16-bit × 0.01 | `0x13F6` = 5110 → 51.10V | ✅ 高 (与广播值匹配) |
| 6-7 | 2B | 未知 | LE 16-bit | `0x1000` = 4096 | ❓ |
| 16 | 1B | 递增计数器 | 8-bit | `0x2E` → `0xB9` (递增) | ❓ |
| 62-63 | 2B | 未知 | LE 16-bit | `0x0F00` = 3840 | ❓ |
| 42-43 | 2B | 未知 | LE 16-bit | `0x6315` = 25365 | ❓ |

### 未确定字段偏移

以下偏移的 16-bit LE 值均为零（电流可能在其中）：

`2-5, 8-11, 14-15, 26-27, 29-31, 39, 41, 44-45, 54-55, 58-59, 64-67, 98-115`

## 完整原始数据示例

```hex
030C 0000 0000 1000 0000 0000 0400 0000
FB7F 116A F613 0000 F0FF 0000 F000 0000
0401 540D 4D0D 0600 0700 6315 0000 400B
E803 E803 C05D 0000 C05D 0000 0300 000F
0000 0000 4C0D 4E0D 4F0D 4C0D 4D0D 500D
540D 4E0D 4F0D 500D 4F0D 4D0D 4F0D 510D
4D0D 0000 0000 0000 0000 0000 0000 0000
0000 00F0 00F0 0000 0000 00
```

### 按字段标注

```
偏移  0         4         8         C        10        14        18
     ┌────────┬────────┬────────┬────────┬────────┬────────┬────────┐
0x00 │ 03 0C  │ 00 00  │ 00 00  │ 10 00  │ 00 00  │ 00 00  │ 04 00  │
     │ Flags  │        │        │        │        │        │        │
     ├────────┼────────┼────────┼────────┼────────┼────────┼────────┤
0x06 │ 00 00  │ 2E 7E  │ 11 6A  │ F6 13  │ 00 00  │ F0 FF  │ 00 00  │
     │        │ counter│        │ Voltage│        │ cycle? │        │
     ├────────┼────────┼────────┼────────┼────────┼────────┼────────┤
0x0C │ F0 00  │ 00 00  │ 04 01  │ 54 0D  │ 4C 0D  │ 06 00  │ 07 00  │
     │        │        │        │        │        │        │        │
     ├────────┼────────┼────────┼────────┼────────┼────────┼────────┤
0x12 │ 63 15  │ 00 00  │ 40 0B  │ E8 03  │ E8 03  │ C0 5D  │ 00 00  │
     │        │        │        │ SoC    │ SoC×2  │CapFull │        │
     ├────────┼────────┼────────┼────────┼────────┼────────┼────────┤
0x18 │ C0 5D  │ 00 00  │ 03 00  │ 00 0F  │ 00 00  │ 00 00  │ 4C 0D  │
     │CapRem  │        │Cycles  │        │        │        │Cell[1] │
     ├────────┼────────┼────────┼────────┼────────┼────────┼────────┤
0x1E │ 4E 0D  │ 4F 0D  │ 4C 0D  │ 4D 0D  │ 50 0D  │ 54 0D  │ 4E 0D  │
     │Cell[2] │Cell[3] │Cell[4] │Cell[5] │Cell[6] │Cell[7] │Cell[8] │
     ├────────┼────────┼────────┼────────┼────────┼────────┼────────┤
0x24 │ 4F 0D  │ 50 0D  │ 4F 0D  │ 4D 0D  │ 4F 0D  │ 51 0D  │ 4D 0D  │
     │Cell[9] │Cell[10]│Cell[11]│Cell[12]│Cell[13]│Cell[14]│Cell[15]│
     ├────────┼────────┼────────┼────────┼────────┼────────┼────────┤
0x2A │ 00 00  │ ...    │ ...    │ ...    │ ...    │ ...    │ ...    │
     │(zeros) │        │        │        │        │        │        │
     ├────────┼────────┼────────┼────────┼────────┼────────┼────────┤
0x3C │ 00 F0  │ 00 F0  │ 00 00  │ 00 00  │ 00     │
     │Temp Min│Temp Max│        │        │        │
     └────────┴────────┴────────┴────────┴────────┘
```

> 注：每格 = 2 bytes，偏移量为相对于 124 字节缓冲区的偏移（不是绝对寄存器地址）。
> 绝对地址 = 0x1000 + 偏移。

## Python 读取脚本

脚本位置：`<本地脚本路径>`

### 功能

1. **广播扫描** — 无需连接，解析 advertisData 获取 SN/电压/电量
2. **连接读取** — 通过 BLE UART 发送 F403 命令读取 BMS 寄存器
3. **轮询** — 每 5 秒自动刷新实时数据

### 使用方法

```bash
python <本地脚本路径>
```

### 数据解析函数

`parse_bms_data(raw)` 中实现了当前已知的偏移映射：

```python
voltage = struct.unpack_from("<H", raw, 22)[0] * 0.01       # 51.10V
soc = struct.unpack_from("<H", raw, 48)[0] * 0.1             # 100.0%
cycles = struct.unpack_from("<H", raw, 60)[0]                # 3
temp_min = struct.unpack_from("<H", raw, 116)[0] * 0.1       # 24°C
temp_max = struct.unpack_from("<H", raw, 118)[0] * 0.1       # 24°C

# Cell voltages at offset 68-97 (15 cells × 2 bytes LE)
for i in range(15):
    mv = struct.unpack_from("<H", raw, 68 + i * 2)[0]       # mV
```

## 待确认事项

- [ ] 电流字段的偏移（当前静态=0，需充电/放电时实测确定）
- [ ] Flags (0x030C0000) 各位的具体含义
- [ ] 容量单位（24000 = ? mAh / 0.1Ah）
- [ ] 计数器字段 (offset 16) 的用途
- [ ] 是否还有其他温度传感器
- [ ] 均衡状态指示位
