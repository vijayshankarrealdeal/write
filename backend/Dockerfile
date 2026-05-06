FROM python:3.12-slim

WORKDIR /app

COPY backend/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
# spaCy ships its language models out-of-band (not via PyPI). Pull the
# small English model so /api/linguistic/tag has POS data without a
# first-request download. ~12 MB.
RUN python -m spacy download en_core_web_sm

COPY backend/ .

# --proxy-headers + --forwarded-allow-ips="*" make uvicorn respect the
# X-Forwarded-Proto header Caddy sends, so FastAPI generates https:// URLs
# (not http://) for redirects — avoids mixed-content blocking in browsers.
# `alembic upgrade head` runs on every container start so schema migrations
# ship with the code; `exec` hands PID 1 to uvicorn so SIGTERM propagates.
CMD ["sh", "-c", "alembic upgrade head && exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --proxy-headers --forwarded-allow-ips '*'"]
