# Build with 
# docker buildx build --platform linux/amd64,linux/arm64 -t 708959940856.dkr.ecr.us-east-1.amazonaws.com/metrics-scraper:latest --push .
FROM python:3.12-slim

# Working directory
WORKDIR /app

# Installing dependencies
RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    python3-dev \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

# Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

COPY metrics_scraper.py .

# Setting some environment variables
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD python -c "import sys; sys.exit(0)"

# Run the application
CMD ["python", "metrics_scraper.py"]

