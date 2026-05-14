# Ops Knowledge Base 執行與部署

## 本地開發 (Local Development)

### 快速啟動網頁預覽
如果你想在本地端查看網頁效果，請在專案根目錄執行：

```bash
make web
```

執行後，你可以透過瀏覽器存取：
👉 **[http://localhost:5678](http://localhost:5678)**

---

## 專案結構
- `docs/`: 存放 Markdown 原始檔。
  - `ceph/`: Ceph 相關維運與故障排除。
  - `k8s/`: Kubernetes 相關維運。
  - `kubevirt/`: KubeVirt 虛擬化相關。
- `mkdocs.yml`: 網站設定檔。

## 自動部署 (CI/CD)
本專案已配置 GitHub Actions。當你將變更推送到 `main` 分支時，GitHub Pages 會自動更新。

### 手動推送變更
```bash
git add .
git commit -m "你的更新訊息"
git push origin main
```
