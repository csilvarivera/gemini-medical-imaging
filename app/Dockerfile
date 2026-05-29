FROM python:3.10-slim

WORKDIR /app

# Install system dependencies required for openslide and other image processing libs
RUN apt-get update && apt-get install -y \
    openslide-tools \
    libopenslide0 \
    libgl1-mesa-glx \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8080

CMD ["streamlit", "run", "app.py", "--server.port=8080", "--server.address=0.0.0.0"]
