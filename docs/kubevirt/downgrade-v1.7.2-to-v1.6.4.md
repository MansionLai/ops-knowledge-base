# KubeVirt Downgrade Issues (v1.7.2 -> v1.6.4)

## 問題描述
將 KubeVirt 從 **v1.7.2** 降級至 **v1.6.4** 後，在 v1.7.2 時期創立的 VM 會出現管理異常。

## 異常現象
1. **關機行為**: 使用 `virtctl` (v1.6.4) 可以順利將 VM 關機。
2. **VMI 殘留**: 關機後，`VirtualMachineInstance` (VMI) 不會自動消失，而是維持在 `Succeeded` 狀態。
3. **啟動失敗**: 無法透過 `virtctl start` 重新啟動該 VM。

## 環境資訊
- **KubeVirt 原始版本**: v1.7.2
- **KubeVirt 降級後版本**: v1.6.4
- **virtctl 工具版本**: v1.6.4

## 潛在原因分析
這可能是因為 v1.7.2 引入了新的 API 欄位或 Finalizer 邏輯，在降級到 v1.6.4 後，舊版本的控制器無法正確處理或清理這些由新版本產生的資源標記。
