FROM python:3.10-slim

# Install system dependencies for OpenSlide and other image processing
RUN apt-get update && apt-get install -y \
    openslide-tools \
    libopenslide0 \
    libgl1-mesa-glx \
    && rm -rf /var/lib/apt/lists/*

# Install python libraries required by the KFP components
RUN pip install --no-cache-dir \
    openslide-python \
    google-cloud-aiplatform \
    google-cloud-storage \
    google-cloud-bigquery \
    tifffile \
    python-docx \
    numpy \
    Pillow \
    kfp \
    torch \
    torchvision \
    timm \
    huggingface-hub \
    google-cloud-secret-manager
