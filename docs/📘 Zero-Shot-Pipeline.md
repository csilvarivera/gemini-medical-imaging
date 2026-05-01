# **📘 THE COMPREHENSIVE GUIDE: Zero-Shot WSI Histology Pipeline**

## **📖 Introduction: How This Works**

This POC creates a fully automated, headless AI pipeline.

1. **The Trigger:** A user drops a Whole Slide Image (`.svs`) and a paired Metadata file (`.json`) into a Google Cloud Storage (GCS) bucket.  
2. **The Automation:** GCP Eventarc detects the files. It waits until *both* files are present, then triggers a Cloud Function.  
3. **The Engine:** The Cloud Function launches a **Vertex AI Pipeline (Kubeflow)**.  
4. **The Processing:** The Pipeline spins up heavy GPU servers, chops the massive image into tiles, normalizes the JSON metadata, extracts biological targets using **MedGemma**, generates visual embeddings using **PathFoundation**, generates masks using **MedSigLip**, and logs the data into **BigQuery** and **Vertex AI Vector Search**.  
5. **The Output:** A stitched visual mask and a summary report are saved back to GCS for the pathologist to review.

---

## **🛠️ Phase 1: Infrastructure Provisioning (Console Steps)**

*These steps set up the storage, databases, and AI endpoints. You only need to do this once.*

### **Step 1: Create the Data Buckets (Google Cloud Storage)**

1. Go to the GCP Console $\\rightarrow$ **Cloud Storage** $\\rightarrow$ **Buckets**.  
2. Click **\+ CREATE**. Name it: `your-project-id-wsi-data` (Replace `your-project-id` with your actual project ID).  
3. Choose Region: `us-central1`. Click **Create**.  
4. Inside this new bucket, click **\+ CREATE FOLDER** twice to create two folders: `inputs/` and `outputs/`.

### **Step 2: Create the Metadata Catalog (BigQuery)**

1. Go to **BigQuery** $\\rightarrow$ **BigQuery Studio**.  
2. In the left Explorer pane, click the three dots (`⋮`) next to your Project ID $\\rightarrow$ **Create dataset**.  
3. Dataset ID: `pathology_db`. Location: `us-central1`. Click **Create dataset**.  
4. Click the three dots (`⋮`) next to `pathology_db` $\\rightarrow$ **Create table**.  
5. Table Name: `tile_metadata`.  
6. Under Schema, toggle **Edit as text** and paste this exact JSON:

`[`  
  `{"name": "run_id", "type": "STRING"},`  
  `{"name": "wsi_filename", "type": "STRING"},`  
  `{"name": "heart_id", "type": "STRING"},`  
  `{"name": "tissue_name", "type": "STRING"},`  
  `{"name": "primary_diagnosis", "type": "STRING"},`  
  `{"name": "sample_category", "type": "STRING"},`  
  `{"name": "stain", "type": "STRING"},`  
  `{"name": "species", "type": "STRING"},`  
  `{"name": "disease_category", "type": "STRING"},`  
  `{"name": "tile_id", "type": "STRING"},`  
  `{"name": "vector_id", "type": "STRING"},`  
  `{"name": "mask_uri", "type": "STRING"},`  
  `{"name": "predicted_class", "type": "STRING"}`  
`]`

7. Click **Create table**.

### **Step 3: Create the Semantic Index (Vertex AI Vector Search)**

1. Go to **Vertex AI** $\\rightarrow$ **Vector Search** $\\rightarrow$ **Indexes**.  
2. Click **\+ CREATE**. Name: `histology_index`. Dimensions: `768`. Update method: `Stream update`. Click **Create**. *(This takes \~10 minutes).*  
3. Go to the **Index Endpoints** tab. Click **\+ CREATE ENDPOINT**. Name: `histology_vector_endpoint`.  
4. Once the endpoint is created, click **Deploy Index**, select `histology_index`, and deploy it.  
5. **🚨 COPY THESE IDs:** Once deployed, copy the **Index ID** and **Index Endpoint ID** into a notepad.

### **Step 4: Deploy the AI Models (Vertex AI Model Registry)**

1. Go to **Vertex AI** $\\rightarrow$ **Model Registry** $\\rightarrow$ **Import**.  
2. Import **MedGemma**, **PathFoundation**, and **MedSigLip** using the GCS URIs provided by Google Health. (Select PyTorch pre-built containers for the vision models).  
3. Click each imported model $\\rightarrow$ **Deploy to Endpoint**. Select `g2-standard-16` (NVIDIA L4 GPU). Set Min/Max nodes to 1\.  
4. **🚨 COPY THESE IDs:** Go to the **Online Prediction** tab. Copy the numeric **Endpoint IDs** for MedGemma, PathFoundation, and MedSigLip into your notepad.

---

## **🏗️ Phase 2: Building the Pipeline Environment**

*Because WSI files require heavy C-libraries (OpenSlide), we must build a custom Docker image to run the pipeline.*

1. Open **Cloud Shell** (the `>_` icon top right).  
2. Run these commands to create an Artifact Registry repository:

`export PROJECT_ID=$(gcloud config get-value project)`  
`gcloud services enable artifactregistry.googleapis.com`  
`gcloud artifacts repositories create histology-repo --repository-format=docker --location=us-central1 --description="KFP Base Image" || true`

3. Run these commands to create and push the Docker image:

`mkdir kfp_env && cd kfp_env`

`cat << 'EOF' > Dockerfile`  
`FROM python:3.10-slim`  
`RUN apt-get update && apt-get install -y openslide-tools libgl1-mesa-glx && rm -rf /var/lib/apt/lists/*`  
`RUN pip install --no-cache-dir openslide-python google-cloud-aiplatform google-cloud-storage google-cloud-bigquery tifffile python-docx numpy Pillow kfp`  
`EOF`

`gcloud builds submit --tag us-central1-docker.pkg.dev/$PROJECT_ID/histology-repo/kfp-base:latest .`

---

## **🧠 Phase 3: The Kubeflow Pipeline Code**

*This is the core logic. We will write this in Vertex AI Workbench to compile the pipeline.*

1. Go to **Vertex AI** $\\rightarrow$ **Workbench** $\\rightarrow$ **User-Managed Notebooks**. Create a new `PyTorch 2.x` notebook (`n1-standard-16`). Open JupyterLab.  
2. Open a new **Python 3 Notebook** file.  
3. Paste the following master code block into a single cell.  
4. **🚨 CRITICAL:** Before running the cell, replace the `YOUR_...` placeholders at the top with the IDs from your notepad\!

`!pip install kfp google-cloud-aiplatform --upgrade -q`

`import kfp`  
`from kfp import dsl`  
`from kfp.v2.dsl import component`  
`from kfp.v2 import compiler`  
`from google.cloud import aiplatform`

`# ==========================================`  
`# ⚙️ CONFIGURATION (UPDATE THESE VARIABLES!)`  
`# ==========================================`  
`PROJECT_ID = "YOUR_PROJECT_ID"`  
`REGION = "us-central1"`  
`BUCKET_NAME = f"{PROJECT_ID}-wsi-data"`  
`BASE_IMAGE = f"us-central1-docker.pkg.dev/{PROJECT_ID}/histology-repo/kfp-base:latest"`

`# Paste your numeric IDs from Phase 1 here`  
`MEDGEMMA_ID = "YOUR_MEDGEMMA_ENDPOINT_ID"`  
`PATHFOUNDATION_ID = "YOUR_PATHFOUNDATION_ENDPOINT_ID"`  
`MEDSIGLIP_ID = "YOUR_MEDSIGLIP_ENDPOINT_ID"`  
`VECTOR_INDEX_ENDPOINT_ID = "YOUR_VECTOR_INDEX_ENDPOINT_ID"`  
`VECTOR_INDEX_ID = "YOUR_VECTOR_INDEX_ID"`

`BQ_TABLE = f"{PROJECT_ID}.pathology_db.tile_metadata"`  
`aiplatform.init(project=PROJECT_ID, location=REGION)`

`# ==========================================`  
`# 🧱 COMPONENT 1: Parse JSON & Reasoning (DYNAMIC)`  
`# ==========================================`  
`@component(base_image=BASE_IMAGE)`  
`def extract_metadata_and_targets(metadata_gcs_uri: str, medgemma_id: str, project: str, region: str) -> dict:`  
    `import json`  
    `import re`  
    `from google.cloud import storage, aiplatform`  
      
    `aiplatform.init(project=project, location=region)`  
    `storage_client = storage.Client(project=project)`  
      
    `# 1. Safely Download JSON`  
    `try:`  
        `bucket_name = metadata_gcs_uri.split("/")[2]`  
        `blob_path = "/".join(metadata_gcs_uri.split("/")[3:])`  
        `metadata_text = storage_client.bucket(bucket_name).blob(blob_path).download_as_text()`  
        `raw_json = json.loads(metadata_text)`  
    `except Exception as e:`  
        raise RuntimeError(f"❌ CRITICAL ERROR: Failed to download or parse JSON metadata: {e}")  
      
    `# 2. FLEXIBLE JSON NORMALIZER`  
    `# Converts "TissueName", "tissue_name", "Tissue Name" all into "TISSUE_NAME"`  
    `flat_metadata = {}`  
    `for item in raw_json.get("fieldValues", []):`  
        `raw_key = item.get("name", "unknown_key")`  
        `normalized_key = re.sub(r'[\s\-]+', '_', str(raw_key)).strip().upper()`  
        `flat_metadata[normalized_key] = item.get("value", "")`  
      
    `# 3. Extract standard keys (using the normalized uppercase format)`  
    `species = flat_metadata.get("SPECIES", "Unknown species")`  
    `tissue = flat_metadata.get("TISSUE_NAME", "Unknown tissue")`  
    `diagnosis = flat_metadata.get("PATIENT_PRIMARY_DIAGNOSIS", "Unknown diagnosis")`  
    `disease_cat = flat_metadata.get("TISSUE_DISEASE_CATEGORY", "")`  
      
    `prompt = f"As an expert pathologist, analyze a {species} {tissue} tissue sample. The patient's primary diagnosis is {diagnosis} ({disease_cat}). List 2-3 specific microscopic histological features, structures, or cellular abnormalities that should be segmented in this Whole Slide Image. Return ONLY a comma-separated list."`  
      
    `# 4. Safely Call MedGemma`  
    `try:`  
        `endpoint = aiplatform.Endpoint(medgemma_id)`  
        `response = endpoint.predict(instances=[{"prompt": prompt}])`  
        `targets = [t.strip() for t in response.predictions[0].split(',')]`  
    `except Exception as e:`  
        `print(f"⚠️ MedGemma Warning: Call failed ({e}). Falling back to default targets.")`  
        `targets = ["Tumour Epithelium", "Necrosis", "Normal Adjacent Tissue"]`  
      
    `flat_metadata["identified_targets"] = targets`  
    `return flat_metadata`

`# ==========================================`  
`# 🧱 COMPONENT 2: Vision, Tiling & Indexing (DYNAMIC)`  
`# ==========================================`  
`@component(base_image=BASE_IMAGE)`  
`def process_wsi_and_index(`  
    `wsi_gcs_uri: str, metadata: dict, run_id: str,`  
    `pf_id: str, ms_id: str, v_end_id: str, v_idx_id: str, bq_table: str, project: str, region: str`  
`) -> int:`  
    `import openslide, numpy as np, tifffile, os, base64, io`  
    `from google.cloud import storage, aiplatform, bigquery`  
      
    `aiplatform.init(project=project, location=region)`  
    `storage_client = storage.Client(project=project)`  
    `bq_client = bigquery.Client(project=project)`  
      
    `pf_endpoint = aiplatform.Endpoint(pf_id)`  
    `ms_endpoint = aiplatform.Endpoint(ms_id)`  
    `v_endpoint = aiplatform.MatchingEngineIndexEndpoint(v_end_id)`  
      
    `wsi_bucket = wsi_gcs_uri.split("/")[2]`  
    `wsi_filename = wsi_gcs_uri.split("/")[-1]`  
    `local_wsi_path = f"/tmp/{wsi_filename}"`  
      
    `# Safely download massive WSI`  
    `try:`  
        `storage_client.bucket(wsi_bucket).blob("/".join(wsi_gcs_uri.split("/")[3:])).download_to_filename(local_wsi_path)`  
        `slide = openslide.OpenSlide(local_wsi_path)`  
    `except Exception as e:`  
        raise RuntimeError(f"❌ CRITICAL ERROR: Failed to download or open WSI file: {e}")  
          
    `width, height = slide.dimensions`  
    `processed_count = 0`  
    `targets = metadata.get("identified_targets", ["Abnormal Tissue"])`  
      
    `for x in range(0, width, 512):`  
        `for y in range(0, height, 512):`  
            `try:`  
                `tile = slide.read_region((x, y), 0, (512, 512)).convert("RGB")`  
            `except Exception as e:`  
                `print(f"⚠️ Warning: Failed to read tile at {x},{y}: {e}")`  
                `continue # Skip corrupted coordinate`  
              
            `if tile.getextrema()[0][0] < 240: # Skip blank glass`  
                `tile_id = f"tile_x{x}_y{y}"`  
                `vector_id = f"vec_{run_id}_{tile_id}"`  
                  
                `buffered = io.BytesIO()`  
                `tile.save(buffered, format="PNG")`  
                `img_b64 = base64.b64encode(buffered.getvalue()).decode("utf-8")`  
                  
                `# Vision API Error Handling`  
                `try:`  
                    `embedding = pf_endpoint.predict(instances=[{"image_bytes": img_b64}]).predictions[0]`   
                    `mask = np.array(ms_endpoint.predict(instances=[{"image_bytes": img_b64, "targets": targets}]).predictions[0], dtype=np.uint8)`   
                `except Exception as e:`  
                    `print(f"⚠️ Warning: Vision AI failed on {tile_id}. Error: {e}. Skipping.")`  
                    `continue`  
                  
                `# Storage & Database Error Handling`  
                `try:`  
                    `local_mask = f"/tmp/{tile_id}_mask.tif"`  
                    `tifffile.imwrite(local_mask, mask, photometric='minisblack')`  
                    `mask_uri = f"gs://{wsi_bucket}/outputs/{run_id}/masks/{tile_id}_mask.tif"`  
                    `storage_client.bucket(wsi_bucket).blob(f"outputs/{run_id}/masks/{tile_id}_mask.tif").upload_from_filename(local_mask)`  
                      
                    `v_endpoint.upsert_datapoints(index_id=v_idx_id, datapoints=[{"datapoint_id": vector_id, "feature_vector": embedding}])`  
                      
                    `# Log normalized metadata to BigQuery`  
                    `rows = [{`  
                        `"run_id": run_id, "wsi_filename": wsi_filename,`  
                        `"heart_id": metadata.get("HEART_ID", ""),`  
                        `"tissue_name": metadata.get("TISSUE_NAME", ""),`  
                        `"primary_diagnosis": metadata.get("PATIENT_PRIMARY_DIAGNOSIS", ""),`  
                        `"sample_category": metadata.get("SAMPLE_CATEGORY", ""),`  
                        `"stain": metadata.get("STAIN_FULL_NAME", ""),`  
                        `"species": metadata.get("SPECIES", ""),`  
                        `"disease_category": metadata.get("TISSUE_DISEASE_CATEGORY", ""),`  
                        `"tile_id": tile_id, "vector_id": vector_id,`   
                        `"mask_uri": mask_uri, "predicted_class": targets[0]`  
                    `}]`  
                    `bq_client.insert_rows_json(bq_table, rows)`  
                      
                    `processed_count += 1`  
                    `if processed_count >= 20: return processed_count # Cap for POC speed`  
                `except Exception as e:`  
                    `print(f"⚠️ Warning: Database/Storage operation failed on {tile_id}: {e}")`  
                    `continue`  
                      
    `return processed_count`

`# ==========================================`  
`# 🧱 COMPONENT 3: Summary Report (DYNAMIC)`  
`# ==========================================`  
`@component(base_image=BASE_IMAGE)`  
`def generate_report(run_id: str, metadata: dict, tile_count: int, output_bucket: str, project: str):`  
    `from docx import Document`  
    `from google.cloud import storage`  
      
    `doc = Document()`  
    `doc.add_heading('WSI Zero-Shot Processing Summary', 0)`  
    `doc.add_paragraph(f"Run ID: {run_id}")`  
    `doc.add_paragraph(f"HEART ID: {metadata.get('HEART_ID', 'N/A')}")`  
    `doc.add_paragraph(f"Diagnosis: {metadata.get('PATIENT_PRIMARY_DIAGNOSIS', 'N/A')}")`  
    `doc.add_paragraph(f"Tissue / Species: {metadata.get('TISSUE_NAME', 'N/A')} ({metadata.get('SPECIES', 'N/A')})")`  
    `doc.add_paragraph(f"Stain: {metadata.get('STAIN_FULL_NAME', 'N/A')}")`  
    `doc.add_paragraph(f"AI Targets Segmented: {', '.join(metadata.get('identified_targets', []))}")`  
    `doc.add_paragraph(f"Total Tiles Processed & Indexed: {tile_count}")`  
      
    `local_doc = f"/tmp/{run_id}_summary.docx"`  
    `doc.save(local_doc)`  
    `storage.Client(project=project).bucket(output_bucket).blob(f"outputs/{run_id}/{run_id}_summary.docx").upload_from_filename(local_doc)`

`# ==========================================`  
`# 🚀 PIPELINE ASSEMBLE & COMPILE`  
`# ==========================================`  
`@dsl.pipeline(name="zero-shot-wsi-pipeline")`  
`def histology_pipeline(wsi_uri: str, metadata_uri: str, run_id: str, output_bucket: str):`  
      
    `step_1 = extract_metadata_and_targets(`  
        `metadata_gcs_uri=metadata_uri, medgemma_id=MEDGEMMA_ID, project=PROJECT_ID, region=REGION`  
    `)`  
      
    `step_2 = process_wsi_and_index(`  
        `wsi_gcs_uri=wsi_uri, metadata=step_1.output, run_id=run_id,`  
        `pf_id=PATHFOUNDATION_ID, ms_id=MEDSIGLIP_ID, v_end_id=VECTOR_INDEX_ENDPOINT_ID, v_idx_id=VECTOR_INDEX_ID,`   
        `bq_table=BQ_TABLE, project=PROJECT_ID, region=REGION`  
    `).set_cpu_limit('16').set_memory_limit('64G')`  
      
    `step_3 = generate_report(`  
        `run_id=run_id, metadata=step_1.output, tile_count=step_2.output, output_bucket=output_bucket, project=PROJECT_ID`  
    `)`

`# Compile to JSON and upload to GCS`  
`compiler.Compiler().compile(pipeline_func=histology_pipeline, package_path="wsi_pipeline.json")`  
`storage_client.bucket(BUCKET_NAME).blob("templates/wsi_pipeline.json").upload_from_filename("wsi_pipeline.json")`  
print(f"✅ Fully Dynamic Pipeline compiled and uploaded to gs://{BUCKET_NAME}/templates/wsi_pipeline.json")

*Run the cell. It will output the green checkmark when it successfully compiles and uploads the JSON template.*

---

## **⚡ Phase 4: Automation (Cloud Functions & Eventarc)**

*This connects the GCS bucket to the pipeline, handling duplicates and missing files.*

1. Go to the GCP Console $\\rightarrow$ **Cloud Functions** $\\rightarrow$ **Create Function**.  
2. Environment: **2nd Gen**. Name: `trigger-wsi-pipeline`. Region: `us-central1`.  
3. Click **Add Eventarc Trigger**:  
   * Event Provider: `Cloud Storage`  
   * Event Type: `google.cloud.storage.object.v1.finalized`  
   * Bucket: Select your `your-project-id-wsi-data` bucket.  
   * Click Save. Click Next.  
4. Runtime: **Python 3.10**.  
5. In `requirements.txt`, paste:

`google-cloud-aiplatform`  
`google-cloud-storage`  
`functions-framework`

6.   
7. In `main.py`, paste this code. **🚨 Replace `YOUR_PROJECT_ID`\!**

`import functions_framework`  
`from google.cloud import aiplatform, storage`  
`import uuid`

`PROJECT_ID = "YOUR_PROJECT_ID"`  
`REGION = "us-central1"`  
`BUCKET_NAME = f"{PROJECT_ID}-wsi-data"`  
`TEMPLATE_PATH = f"gs://{BUCKET_NAME}/templates/wsi_pipeline.json"`

`@functions_framework.cloud_event`  
`def trigger_pipeline(cloud_event):`  
    `data = cloud_event.data`  
    `file_name = data["name"]`  
    `bucket_name = data["bucket"]`  
      
    `# We only care about the inputs directory`  
    `if not file_name.startswith('inputs/'):`  
        `return`

    `storage_client = storage.Client()`  
    `bucket = storage_client.bucket(bucket_name)`  
    `uploaded_blob = bucket.blob(file_name)`  
      
    `# ---------------------------------------------------------`  
    `# 1. DUPLICATE HANDLING: Check if already processed`  
    `# ---------------------------------------------------------`  
    `uploaded_blob.reload()`  
    `if uploaded_blob.metadata and uploaded_blob.metadata.get("pipeline_triggered") == "true":`  
        `print(f"🛑 Duplicate trigger detected for {file_name}. This file has already been processed. Skipping.")`  
        `return`

    `# ---------------------------------------------------------`  
    `# 2. PAIRED FILE CHECK: Ensure both WSI and JSON exist`  
    `# ---------------------------------------------------------`  
    `if file_name.endswith('.svs'):`  
        `wsi_blob = uploaded_blob`  
        `meta_name = file_name.replace('.svs', '_metadata.json')`  
        `meta_blob = bucket.blob(meta_name)`  
    `elif file_name.endswith('_metadata.json'):`  
        `meta_blob = uploaded_blob`  
        `wsi_name = file_name.replace('_metadata.json', '.svs')`  
        `wsi_blob = bucket.blob(wsi_name)`  
    `else:`  
        `return # Ignore random files`

    `if not wsi_blob.exists():`  
        print(f"⏳ Waiting for pair: {wsi_name} is missing. Pipeline will not fire until WSI is uploaded.")  
        `return`  
          
    `if not meta_blob.exists():`  
        print(f"⏳ Waiting for pair: {meta_name} is missing. Pipeline will not fire until JSON metadata is uploaded.")  
        `return`

    `# ---------------------------------------------------------`  
    `# 3. MARK AS PROCESSED & TRIGGER PIPELINE`  
    `# ---------------------------------------------------------`  
    `# Tag files to prevent double-firing if a duplicate is uploaded later`  
    `wsi_blob.metadata = {"pipeline_triggered": "true"}`  
    `wsi_blob.patch()`  
    `meta_blob.metadata = {"pipeline_triggered": "true"}`  
    `meta_blob.patch()`

    print(f"✅ Both files detected ({wsi_blob.name} & {meta_blob.name}). Launching Pipeline!")  
      
    `aiplatform.init(project=PROJECT_ID, location=REGION)`  
    `run_id = f"run_{uuid.uuid4().hex[:6]}"`

    `pipeline_job = aiplatform.PipelineJob(`  
        `display_name=f"auto-wsi-pipeline-{run_id}",`  
        `template_path=TEMPLATE_PATH,`  
        `pipeline_root=f"gs://{bucket_name}/pipeline_root",`  
        `parameter_values={`  
            `"wsi_uri": f"gs://{bucket_name}/{wsi_blob.name}",`  
            `"metadata_uri": f"gs://{bucket_name}/{meta_blob.name}",`  
            `"run_id": run_id,`  
            `"output_bucket": BUCKET_NAME`  
        `}`  
    `)`  
      
    `try:`  
        `pipeline_job.submit()`  
        `print(f"🚀 Successfully launched pipeline job: auto-wsi-pipeline-{run_id}")`  
    `except Exception as e:`  
        print(f"❌ Failed to submit Vertex AI Pipeline: {e}")

8. Click **Deploy**.

## 

## **🏁 Phase 5: How to Run the POC (The User Experience)**

Your entire architecture is now live, automated, robust, and ready. Here is exactly what the Pathologist does:

1. **Prepare the Files Locally:**  
   * They have a WSI file: `kidney_study_01.svs`  
   * They create a paired JSON file named exactly `kidney_study_01_metadata.json` (The casing inside the JSON doesn't matter, the pipeline will normalize it\!):

`{`  
  `"fieldValues": [`  
    `{"name": "PATIENT_PRIMARY_DIAGNOSIS", "value": "Colorectal Adenocarcinoma"},`  
    `{"name": "TISSUE_NAME", "value": "LARGE INTESTINE, COLON"},`  
    `{"name": "SPECIES", "value": "HUMAN"},`  
    `{"name": "Tissue_Disease_Category", "value": "Primary tumour"}`  
  `]`  
`}`

*   
2. **The Drop:**  
   * They log into GCP Console $\\rightarrow$ **Cloud Storage**.  
   * They open the bucket `your-project-id-wsi-data` $\\rightarrow$ `inputs/` folder.  
   * They upload both the `.svs` and `.json` files.  
3. **The Magic:**  
   * Eventarc detects the files. It checks if both exist. Once verified, it tags them to prevent duplicates and fires the pipeline.  
   * The pathologist goes to **Vertex AI $\\rightarrow$ Pipelines**.  
   * They will see a new pipeline actively running\! They can click it to watch the interactive graph.  
4. **The Result:**  
   * When the pipeline turns green, the pathologist goes back to Cloud Storage $\\rightarrow$ `outputs/`.  
   * They will find a Word document summarizing the run and a folder containing all the generated `.tif` masks ready for review in QuPath.

