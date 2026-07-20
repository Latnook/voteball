FROM python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1
RUN useradd --create-home --uid 1000 appuser
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY worker.py db.py rollups.py alerts.py snapshots.py heartbeat.py .
USER appuser
CMD ["python", "worker.py"]
