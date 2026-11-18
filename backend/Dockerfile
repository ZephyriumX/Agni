# Agni-Pulse API image. Works locally (docker compose) and on cloud hosts that inject $PORT
# (Render, Railway, Fly.io, Cloud Run, Koyeb). Build context = repository root.
FROM python:3.11-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1 PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
COPY backend/requirements.txt .
RUN pip install -r requirements.txt
COPY backend/ /app/
COPY db/ /db/
RUN useradd --create-home --uid 10001 agni && chown -R agni /app
USER agni
EXPOSE 8000
# apply pending migrations, then serve. --proxy-headers: the real client IP (rate limits) behind the host's proxy.
CMD ["sh", "-c", "python migrate.py && exec uvicorn main:app --host 0.0.0.0 --port ${PORT:-8000} --proxy-headers --forwarded-allow-ips='*' --timeout-keep-alive 30"]
