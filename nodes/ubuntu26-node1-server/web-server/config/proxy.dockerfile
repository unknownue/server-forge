# Lightweight Anthropic↔OpenAI API translation proxy
# Image: ~150MB (python:3.12-slim + aiohttp)
#
# Build:
#   docker build -f nodes/ubuntu26-node1-server/game-server/config/proxy.dockerfile \
#       -t server-forge/anthropic-proxy:latest .
#
# Run standalone:
#   docker run --rm --network host \
#       -e BACKEND_8000=http://localhost:8000/v1 \
#       -e BACKEND_8001=http://localhost:8001/v1 \
#       -e BACKEND_8002=http://localhost:8002/v1 \
#       server-forge/anthropic-proxy:latest

FROM python:3.12-slim

RUN pip install --no-cache-dir aiohttp

COPY nodes/ubuntu26-node1-server/game-server/serve/anthropic-proxy.py /app/proxy.py

EXPOSE 8090
ENV PROXY_PORT=8090

ENTRYPOINT ["python", "/app/proxy.py"]
