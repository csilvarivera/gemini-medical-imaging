FROM python:3.10-slim

# 1. Install system dependencies for OpenSlide
RUN apt-get update && apt-get install -y \
    libgl1 \
    gcc \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 2. Install requirements
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# 3. Copy source code
COPY . .

# 4. Expose port (Cloud Run / GCF 2nd Gen listens on PORT)
EXPOSE 8080

# 5. Start the Cloud Function using the Google Functions Framework
CMD ["functions-framework", "--target=trigger_pipeline"]
