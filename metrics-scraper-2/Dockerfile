# Build with 
# docker buildx build --platform linux/amd64,linux/arm64 -t [aws_account].dkr.ecr.us-east-1.amazonaws.com/metrics-scraper:latest --push .

FROM python:3.12-slim

# --- Runtime OS deps only (keep it slim) ---
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      tzdata \
      tini \
    && rm -rf /var/lib/apt/lists/*

# --- App directory ---
WORKDIR /app

# --- Environment for containerized Python ---
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1

# Optional: OCI labels (edit as you wish)
LABEL org.opencontainers.image.title="metrics-scraper" \
      org.opencontainers.image.description="K8s metrics scraper that pages via PagerDuty" \
      org.opencontainers.image.source="..."

# --- Non-root user ---
ARG UID=10001
ARG GID=10001
RUN groupadd -g $GID appuser && useradd -m -u $UID -g $GID -s /usr/sbin/nologin appuser

# --- Python deps ---
# If you have a requirements.txt, we’ll use it.
# Otherwise we install the minimal set needed by the script.
COPY requirements.txt* /tmp/
RUN set -eux; \
    python -m pip install --upgrade pip; \
    if [ -f /tmp/requirements.txt ]; then \
        pip install -r /tmp/requirements.txt; \
    else \
        pip install "kubernetes>=30.0.0" "requests>=2.31.0"; \
    fi; \
    rm -rf /root/.cache

# --- App code ---
COPY metrics_scraper.py /app/metrics_scraper.py

# --- Drop privileges & lock down FS by default ---
USER appuser
# NOTE: If you set readOnlyRootFilesystem: true in the Pod spec,
# ensure any needed write paths are mounted (usually none for this script).

# --- Use tini as init for clean signal handling ---
ENTRYPOINT ["/usr/bin/tini", "--"]

# --- Run the scraper (CronJob will start the Pod, run once, then exit) ---
CMD ["python", "/app/metrics_scraper.py"]
