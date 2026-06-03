# KubeVirt Downgrade Issues (v1.7.2 -> v1.6.4)

## 問題描述
將 KubeVirt 從 **v1.7.2** 降級至 **v1.6.4** 後，在 v1.7.2 時期創立的 VM 會出現管理異常。

## 異常現象
1. **關機行為**: 使用 `virtctl` (v1.6.4) 可以順利將 VM 關機。
2. **VMI 殘留**: 關機後，`VirtualMachineInstance` (VMI) 不會自動消失，而是維持在 `Succeeded` 狀態（標記為 Deleting，但不會被刪除）。
3. **啟動失敗**: 無法透過 `virtctl start` 重新啟動該 VM，因為舊的 VMI 實例仍然存在。

## 核心原因分析：Finalizer 名稱不一致
經過分析 KubeVirt 原始碼，確認主因為 **Finalizer 命名規範變更** 導致的版本不相容：

*   **v1.7.x+**: 使用網域限定的 Finalizer 名稱 `kubevirt.io/foregroundDeleteVirtualMachine`。
*   **v1.6.x**: 使用舊版的 Finalizer 名稱 `foregroundDeleteVirtualMachine`。

### 故障鏈：
1. **遺留標記**：v1.7.2 創立的 VMI 帶有 `kubevirt.io/foregroundDeleteVirtualMachine` 標記。
2. **無法識別**：降級後的 v1.6.4 控制器只會尋找並嘗試移除 `foregroundDeleteVirtualMachine`。
3. **刪除卡死**：由於 API Server 偵測到 VMI 上仍有無人處理的 Finalizer (`kubevirt.io/...`)，因此拒絕從資料庫中物理刪除該資源，導致 VMI 永久殘留在 `Succeeded` 狀態。

## 解決方案

### 方法一：手動清理特定 VMI
使用 `kubectl patch` 直接移除受影響 VMI 的 finalizers：

```bash
kubectl patch vmi <VMI_NAME> --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'
```

### 方法二：批次清理所有殘留 VMI
使用以下指令找出所有處於 `Succeeded` 狀態但未消失的 VMI 並強制清理：

```bash
kubectl get vmi -A -o json | jq -r '.items[] | select(.status.phase=="Succeeded") | .metadata.namespace + "/" + .metadata.name' | xargs -I {} kubectl patch vmi {} --type=json -p='[{"op": "remove", "path": "/metadata/finalizers"}]'
```

## 建議與預防
*   **避免直接降級**：KubeVirt 官方並不保證降級的相容性。
*   **降級前處理**：若必須降級，請務必先將所有 VM 正常關機並確認 VMI 已消失，再進行 Operator 的版本回退。
