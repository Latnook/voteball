FROM python:3.12-slim
WORKDIR /app
ENV PYTHONUNBUFFERED=1
RUN useradd --create-home --uid 1000 appuser
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py db.py queries.py gunicorn.conf.py migrate.py schema.sql seed.sql .
USER appuser
CMD ["gunicorn", "--config", "gunicorn.conf.py", "app:app"]
