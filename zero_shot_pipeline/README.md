# 🧬 Zero-Shot WSI Histology Pipeline

This directory contains the fully codified, automated, and serverless Zero-Shot Whole Slide Image (WSI) Histology Pipeline. 

The pipeline automatically triggers when a pathology Whole Slide Image (`.svs`) and its corresponding metadata (`.json`) are uploaded to Google Cloud Storage. It extracts biological targets using MedGemma, processes and tiles the massive image using Open-Source ViT Models (Virchow or H-optimus-0) and MedSigLip, indexes the embeddings in Vertex AI Vector Search, and generates a pathology report.

---

## 🏗 Architecture Overview

```mermaid
graph TD
    User([Scanner / User]) -->|Uploads WSI & JSON| GCS[Google Cloud Storage]
    GCS -->|Eventarc Trigger| CF[Cloud Function]
    CF -->|Submits Job| KFP[Vertex AI Pipeline]
    
    subgraph Vertex AI Pipeline
        KFP_Ext[1. Extract Metadata] -->|MedGemma Prompting| KFP_Proc[2. Process WSI]
        KFP_Proc -->|Tile Extraction & Embedding| PF[HF Model (Virchow/H-optimus-0)]
        KFP_Proc -->|Mask Generation| MS[MedSigLip Model]
        KFP_Proc -->|Save Tiles & Masks| GCS_Out[GCS Outputs]
        KFP_Proc -->|Index Embeddings| VS[Vertex Vector Search]
        KFP_Proc -->|Log Metadata| BQ[(BigQuery)]
        KFP_Proc --> KFP_Rep[3. Generate Report]
        KFP_Rep -->|Uploads Word Doc| GCS_Out
    end
```

1. **`terraform/`**: Infrastructure-as-Code to provision GCS buckets, BigQuery tables, Vertex AI Vector Search endpoints, Service Accounts, and Eventarc triggers.
2. **`docker/`**: A custom Kubeflow (KFP) container environment that pre-installs complex C-libraries like `openslide-tools` alongside Python dependencies.
3. **`pipeline/`**: Modularized Vertex AI Pipeline components (`components.py`) and a compilation script (`compile_pipeline.py`) that generates the execution graph.
4. **`cloud_function/`**: An event-driven Cloud Function that intercepts GCS uploads, deduplicates them, waits for both the image and metadata files to be present, and dynamically submits the pipeline job to Vertex AI.

---

## 🚀 Deployment Walkthrough

Follow these steps in order to deploy the pipeline from scratch.

### Prerequisites
* You must have the `gcloud` CLI installed and authenticated.
* You must have `terraform` installed.
* You must have Docker installed.
* Ensure you are operating within your target GCP Project (e.g. `<YOUR_PROJECT_ID>`).

### Step 1: Deploy Infrastructure (Terraform)
This step provisions the buckets, databases, vector search endpoints, and service accounts.

```bash
cd terraform

# Initialize terraform plugins
terraform init

# Review the infrastructure plan
terraform plan

# Apply the infrastructure (type 'yes' when prompted)
terraform apply
```

> **Note:** Vertex AI Vector Search Endpoints can take up to 30-45 minutes to provision entirely. Please be patient during the `terraform apply` step.

### Step 2: Build & Push the Pipeline Container
Kubeflow requires a base image to execute the Python components. We use Artifact Registry to host this image.

```bash
cd ../docker

# Replace with your actual Artifact Registry path!
export IMAGE_URI="us-central1-docker.pkg.dev/<YOUR_PROJECT_ID>/<YOUR_REPO>/kfp-base:latest"

# Build the image locally
docker build -t $IMAGE_URI .

# Push the image to Google Cloud
docker push $IMAGE_URI
```

> **Critical:** After pushing, you **must** update the `BASE_IMAGE` variable at the top of `pipeline/components.py` with your exact `$IMAGE_URI`.

### Step 3: Compile the Vertex AI Pipeline
This step converts your Python component code into a JSON execution graph and uploads it to GCS so the Cloud Function can trigger it later.

```bash
cd ../pipeline

# Install compilation requirements
pip install -r requirements.txt

# Compile the pipeline and upload to GCS templates/ directory
python compile_pipeline.py
```
*You should see a success message indicating `wsi_pipeline.json` was uploaded.*

### Step 4: Deploy the Automation Trigger (Cloud Function)
The Terraform in Step 1 handles the Eventarc setup, but you might prefer or need to deploy the Cloud Function source directly via `gcloud` if you make rapid iterations to the trigger logic.

```bash
cd ../cloud_function

gcloud functions deploy trigger-wsi-pipeline \
    --gen2 \
    --runtime=python310 \
    --region=us-central1 \
    --source=. \
    --entry-point=trigger_pipeline \
    --trigger-event-filters="type=google.cloud.storage.object.v1.finalized" \
    --trigger-event-filters="bucket=<YOUR_WSI_BUCKET_NAME>" \
    --service-account="<YOUR_SERVICE_ACCOUNT_EMAIL>"
```

---

## 🧪 Testing the Pipeline

Once deployed, the pipeline runs entirely headlessly. You test it by mimicking a lab scanner uploading files to GCS.

### 1. Prepare your Test Files
You need an SVS image and a JSON metadata file with **matching base names**.
* `sample_123.svs`
* `sample_123_metadata.json`

### 2. Upload to the Inputs Bucket
Upload both files to the `inputs/` directory of your provisioned bucket.

```bash
# Upload the WSI
gsutil cp sample_123.svs gs://<YOUR_WSI_BUCKET_NAME>/inputs/

# Upload the Metadata
gsutil cp sample_123_metadata.json gs://<YOUR_WSI_BUCKET_NAME>/inputs/
```

### 3. Monitor the Execution
1. The Cloud Function will intercept the uploads. It will wait until **both** files are present before firing.
2. Go to the **Google Cloud Console -> Vertex AI -> Pipelines**.
3. You will see a new pipeline run named `auto-wsi-pipeline-<run_id>` executing.
4. You can click on the pipeline graph to watch the components execute in real-time:
   * **Extract Metadata**: Calls MedGemma to identify targets.
   * **Process WSI**: Tiles the image, calls the requested HF Model and MedSigLip, and indexes to Vector Search.
   * **Generate Report**: Creates a `.docx` summary.

### 4. Verify the Outputs
Once the pipeline finishes, check your outputs:
* **Storage**: `gs://<YOUR_WSI_BUCKET_NAME>/outputs/<run_id>/` (Contains your masks and the generated `.docx` report).
* **BigQuery**: Check the `pathology_db.tile_metadata` table for the newly inserted row logs.
* **Vector Search**: The embeddings for the tiles are now searchable in your Vertex AI Index.
