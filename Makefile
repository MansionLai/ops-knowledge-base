.PHONY: help install web

help:
	@echo "Usage:"
	@echo "  make install    - 安裝 Python 依賴環境"
	@echo "  make web        - 在本地啟動 MkDocs 預覽伺服器 (Port 5678)"

install:
	pip install -r requirements.txt

web:
	@echo "啟動本地預覽伺服器於 http://localhost:5678 ..."
	mkdocs serve -a localhost:5678
