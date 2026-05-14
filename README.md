# Ops Knowledge Base 執行與部署

## 本地開發 (Local Development)

### 快速啟動網頁預覽
本專案使用 Python 虛擬環境隔離。請在專案根目錄執行：

```bash
make web
```

**這項指令會自動完成以下動作：**
1. 建立 `.venv` 虛擬環境 (如果不存在)。
2. 安裝所有必要的依賴包。
3. 啟動 MkDocs 伺服器。

執行後，你可以透過瀏覽器存取：
👉 **[http://localhost:5678](http://localhost:5678)**

---

## 常用指令
- `make install`: 僅建立環境並安裝依賴。
- `make web`: 啟動本地預覽（包含自動安裝）。
- `make clean`: 刪除 `.venv` 虛擬環境。

## 專案結構
- `docs/`: 存放 Markdown 原始檔。
- `mkdocs.yml`: 網站設定檔。

## 自動部署 (CI/CD)
本專案已配置 GitHub Actions。當你將變更推送到 `main` 分支時，GitHub Pages 會自動更新。
