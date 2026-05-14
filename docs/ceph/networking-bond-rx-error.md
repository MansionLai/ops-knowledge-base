# Ceph 節點 Bond 網卡 RX Error 診斷流程

## 1. 現象描述
伺服器發出 `cephnetworkreceiveerror` 告警，檢查發現 `bond0` 及其內部的 `eth0` RX Error 持續上升。

## 2. 診斷步驟 (SOP)

### Step 1: 確認 Bonding 狀態
確認目前哪張網卡是 Active，以及是否有備援。
```bash
cat /proc/net/bonding/bond0
```
*重點觀察：`Currently Active Slave` 與 `MII Status`。*

### Step 2: 判定錯誤類型 (關鍵)
利用 `ethtool -S` 查看具體報錯計數。
```bash
ethtool -S eth0 | grep -E "crc|fcs|align|symbol|error|drop|miss|fifo|overflow"
```

| 錯誤欄位 | 判定結果 | 建議處理 |
| :--- | :--- | :--- |
| `rx_crc_errors` / `rx_fcs_errors` | **物理層故障** | 更換網路線、SFP+ 模組、或更換交換機 Port。 |
| `rx_missed_errors` / `rx_fifo_errors` | **資源/效能瓶頸** | 調大 Ring Buffer (`ethtool -G`) 或檢查 CPU 中斷平衡。 |

### Step 3: 進階硬體檢查 (光纖)
如果是光纖連線，檢查收光功率：
```bash
ethtool -m eth0
```
*注意 `rx_power` 是否在正常區間。*

## 3. 處理方案

### 方案 A：邏輯切換流量 (安全)
如果你想暫時切換到 `eth1` 並觀察，可以強制切換 Active Slave：
```bash
# 強制切換
echo eth1 > /sys/class/net/bond0/bonding/active_slave

# 鎖定 primary 避免自動跳回
echo eth1 > /sys/class/net/bond0/bonding/primary
```

### 方案 B：隔離故障網卡 (徹底)
如果錯誤率極高，建議直接關閉該埠口以保護 Ceph 穩定性。
```bash
ip link set eth0 down
```

## 4. 參考資料
- [Linux Bonding Documentation](https://www.kernel.org/doc/Documentation/networking/bonding.txt)
- Ceph Troubleshooting Guides
