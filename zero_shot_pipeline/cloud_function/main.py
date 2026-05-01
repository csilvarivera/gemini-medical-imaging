import functions_framework
import os
import uuid
from google.cloud import aiplatform, storage

PROJECT_ID = os.environ.get("PROJECT_ID", "gsk-cmc-hackathon")
REGION = os.environ.get("REGION", "us-central1")
BUCKET_NAME = os.environ.get("BUCKET_NAME", f"{PROJECT_ID}-wsi-data")
TEMPLATE_PATH = f"gs://{BUCKET_NAME}/templates/wsi_pipeline.json"

@functions_framework.cloud_event
def trigger_pipeline(cloud_event):
    data = cloud_event.data
    file_name = data["name"]
    bucket_name = data["bucket"]
    
    # We only care about the inputs directory
    if not file_name.startswith('inputs/'):
        return

    storage_client = storage.Client()
    bucket = storage_client.bucket(bucket_name)
    uploaded_blob = bucket.blob(file_name)
    
    # ---------------------------------------------------------
    # 1. DUPLICATE HANDLING: Check if already processed
    # ---------------------------------------------------------
    uploaded_blob.reload()
    if uploaded_blob.metadata and uploaded_blob.metadata.get("pipeline_triggered") == "true":
        print(f"🛑 Duplicate trigger detected for {file_name}. This file has already been processed. Skipping.")
        return

    # ---------------------------------------------------------
    # 2. PAIRED FILE CHECK: Ensure both WSI and JSON exist
    # ---------------------------------------------------------
    if file_name.endswith('.svs'):
        wsi_blob = uploaded_blob
        wsi_name = file_name
        meta_name = file_name.replace('.svs', '_metadata.json')
        meta_blob = bucket.blob(meta_name)
    elif file_name.endswith('_metadata.json'):
        meta_blob = uploaded_blob
        meta_name = file_name
        wsi_name = file_name.replace('_metadata.json', '.svs')
        wsi_blob = bucket.blob(wsi_name)
    else:
        return # Ignore random files

    if not wsi_blob.exists():
        print(f"⏳ Waiting for pair: {wsi_name} is missing. Pipeline will not fire until WSI is uploaded.")
        return
        
    if not meta_blob.exists():
        print(f"⏳ Waiting for pair: {meta_name} is missing. Pipeline will not fire until JSON metadata is uploaded.")
        return

    # ---------------------------------------------------------
    # 3. MARK AS PROCESSED & TRIGGER PIPELINE
    # ---------------------------------------------------------
    # Tag files to prevent double-firing if a duplicate is uploaded later
    wsi_blob.metadata = {"pipeline_triggered": "true"}
    wsi_blob.patch()
    meta_blob.metadata = {"pipeline_triggered": "true"}
    meta_blob.patch()

    print(f"✅ Both files detected ({wsi_blob.name} & {meta_blob.name}). Launching Pipeline!")
    
    aiplatform.init(project=PROJECT_ID, location=REGION)
    run_id = f"run_{uuid.uuid4().hex[:6]}"

    pipeline_job = aiplatform.PipelineJob(
        display_name=f"auto-wsi-pipeline-{run_id}",
        template_path=TEMPLATE_PATH,
        pipeline_root=f"gs://{bucket_name}/pipeline_root",
        parameter_values={
            "wsi_uri": f"gs://{bucket_name}/{wsi_blob.name}",
            "metadata_uri": f"gs://{bucket_name}/{meta_blob.name}",
            "run_id": run_id,
            "output_bucket": BUCKET_NAME
        }
    )
    
    try:
        pipeline_job.submit()
        print(f"🚀 Successfully launched pipeline job: auto-wsi-pipeline-{run_id}")
    except Exception as e:
        print(f"❌ Failed to submit Vertex AI Pipeline: {e}")
