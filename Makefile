PORT ?= 9090
HUB_DIR := nodes/ubuntu26-node1-server/service-hub

.PHONY: service-hub service-hub-stop

## service-hub: Start the local service management gateway
service-hub:
	@command -v uv >/dev/null 2>&1 || { echo "ERROR: 'uv' not found. Install: curl -LsSf https://astral.sh/uv/install.sh | sh" >&2; exit 1; }
	@echo "[$(shell date +%H:%M:%S)] Service Hub — port $(PORT)"
	@echo "  API docs: http://localhost:$(PORT)/docs"
	@cd $(HUB_DIR) && PYTHONPATH=src exec uv run uvicorn service_hub.server:app --host 0.0.0.0 --port $(PORT) --log-level info

## service-hub-stop: Stop the service management gateway
service-hub-stop:
	@echo "Stopping Service Hub..."
	@pkill -f "uvicorn service_hub.server" 2>/dev/null || true
	@echo "Service Hub stopped."
