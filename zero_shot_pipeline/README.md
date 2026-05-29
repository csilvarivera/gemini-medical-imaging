# 🧬 Zero-Shot WSI Histology Pipeline

This directory contains the fully codified, automated, and serverless Zero-Shot Whole Slide Image (WSI) Histology Pipeline. 

The pipeline automatically triggers when a pathology Whole Slide Image (`.svs`) and its corresponding metadata (`.json`) are uploaded to Google Cloud Storage. It extracts biological targets using MedGemma, processes and tiles the massive image using Open-Source ViT Models (Virchow or H-optimus-0) and MedSigLip, indexes the embeddings in Vertex AI Vector Search, and generates a pathology report.

---

## 🏗 Architecture Overview

```mermaid
graph TD
    User([Scanner / User]) -->|Uploads WSI & JSON| GCS[Google Cloud Storage]
    GCS -->|Eventarc Trigger| CF[Cloud Function]
    
    subgraph Cloud Function (Local Execution)
        CF -->|1. Extract Metadata| MedGemma[MedGemma Endpoint]
        CF -->|2. Process WSI| LocalVit[HF Model (Virchow/H-optimus-0)]
        CF -->|Vision Segment Mask| MedSigLip[MedSigLip Endpoint]
        CF -->|Save Tiles & Masks| GCS_Out[GCS Outputs]
        CF -->|Index Embeddings| VS[Vertex Vector Search]
        CF -->|Log Metadata| BQ[(BigQuery)]
        CF -->|3. Generate Report| Report[docx summary report]
        Report -->|Uploads Word Doc| GCS_Out
    end
```

1. **`terraform/`**: Infrastructure-as-Code to provision GCS buckets, BigQuery tables, Vertex AI Vector Search endpoints, Service Accounts, and Eventarc triggers.
2. **`docker/`**: Contains standard environment specs for image processing tools.
3. **`pipeline/`**: Legacy Vertex AI Pipeline components (`components.py`) and compilation script (`compile_pipeline.py`).
4. **`cloud_function/`**: An event-driven, serverless Cloud Function that intercepts GCS uploads, waits for matching paired inputs, executes pathology models locally on CPU, communicates with Vertex endpoints, indexes tiles, logs to BigQuery, and outputs final summary reports.

---

## 🚀 Deployment Walkthrough

Follow these steps in order to deploy the pipeline from scratch.

### Prerequisites
* You must have the `gcloud` CLI installed and authenticated.
* You must have `terraform` installed.
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

### Step 2: Deploy the Automation Trigger (Cloud Function)
Because the Cloud Function runs the PyTorch embedding extraction, image tiling, and report generation directly within its own execution context, it must be allocated sufficient memory and execution time. We configure the function with **16GB RAM, 4 CPUs, and a 30-minute timeout**.

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
    --service-account="<YOUR_SERVICE_ACCOUNT_EMAIL>" \
    --memory=16Gi \
    --cpu=4 \
    --timeout=1800s \
    --set-env-vars="PROJECT_ID=<YOUR_PROJECT_ID>,REGION=us-central1,BUCKET_NAME=<YOUR_WSI_BUCKET_NAME>,MEDGEMMA_ID=<YOUR_MEDGEMMA_ID>,MEDSIGLIP_ID=<YOUR_MEDSIGLIP_ID>,VECTOR_INDEX_ENDPOINT_ID=<YOUR_VECTOR_ENDPOINT_ID>,VECTOR_INDEX_ID=<YOUR_VECTOR_INDEX_ID>,HF_TOKEN_SECRET=huggingface-token"
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
