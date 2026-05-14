VENV = .venv
PYTHON = $(VENV)/bin/python3
PIP = $(VENV)/bin/pip

.PHONY: help install web clean

help:
	@echo "Usage:"
	@echo "  make install    - 建立虛擬環境並安裝 Python 依賴"
	@echo "  make web        - 在本地啟動 MkDocs 預覽伺服器 (Port 5678)"
	@echo "  make clean      - 移除虛擬環境"

$(VENV)/bin/activate: requirements.txt
	@echo "正在建立虛擬環境..."
	python3 -m venv $(VENV)
	@echo "正在安裝依賴包..."
	$(PIP) install --upgrade pip
	$(PIP) install -r requirements.txt
	@touch $(VENV)/bin/activate

install: $(VENV)/bin/activate

web: install
	@echo "啟動本地預覽伺服器於 http://localhost:5678 ..."
	$(VENV)/bin/mkdocs serve -a localhost:5678

clean:
	rm -rf $(VENV)
