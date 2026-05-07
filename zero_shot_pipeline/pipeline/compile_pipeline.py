import os
from kfp import dsl
from kfp.v2 import compiler
from google.cloud import storage

from components import extract_metadata_and_targets, process_wsi_and_index, generate_report

# Environment variables that would be provided during compilation
PROJECT_ID = os.environ.get("PROJECT_ID", "gsk-cmc-hackathon")
REGION = os.environ.get("REGION", "us-central1")
BUCKET_NAME = os.environ.get("BUCKET_NAME", f"{PROJECT_ID}-wsi-data")

MEDGEMMA_ID = os.environ.get("MEDGEMMA_ID", "YOUR_MEDGEMMA_ID")
HF_TOKEN_SECRET = os.environ.get("HF_TOKEN_SECRET", "huggingface-token")
MEDSIGLIP_ID = os.environ.get("MEDSIGLIP_ID", "YOUR_MEDSIGLIP_ID")

VECTOR_INDEX_ENDPOINT_ID = os.environ.get("VECTOR_INDEX_ENDPOINT_ID", "YOUR_VECTOR_ENDPOINT_ID")
VECTOR_INDEX_ID = os.environ.get("VECTOR_INDEX_ID", "YOUR_VECTOR_INDEX_ID")
BQ_TABLE = f"{PROJECT_ID}.pathology_db.tile_metadata"

@dsl.pipeline(name="zero-shot-wsi-pipeline")
def histology_pipeline(wsi_uri: str, metadata_uri: str, run_id: str, output_bucket: str, hf_model_id: str = "bioptimus/H-optimus-0"):
    
    step_1 = extract_metadata_and_targets(
        metadata_gcs_uri=metadata_uri, 
        medgemma_id=MEDGEMMA_ID, 
        project=PROJECT_ID, 
        region=REGION
    )
    
    # We must require a GPU instance for HF models
    step_2 = process_wsi_and_index(
        wsi_gcs_uri=wsi_uri, 
        metadata=step_1.output, 
        run_id=run_id,
        hf_model_id=hf_model_id,
        hf_token_secret=HF_TOKEN_SECRET,
        ms_id=MEDSIGLIP_ID, 
        v_end_id=VECTOR_INDEX_ENDPOINT_ID, 
        v_idx_id=VECTOR_INDEX_ID, 
        bq_table=BQ_TABLE, 
        project=PROJECT_ID, 
        region=REGION
    ).set_cpu_limit('16').set_memory_limit('64G').add_node_selector_constraint(
        'cloud.google.com/gke-accelerator', 'nvidia-l4'
    )
    
    step_3 = generate_report(
        run_id=run_id, 
        metadata=step_1.output, 
        tile_count=step_2.output, 
        output_bucket=output_bucket, 
        project=PROJECT_ID
    )

if __name__ == "__main__":
    output_file = "wsi_pipeline.json"
    print(f"Compiling pipeline to {output_file}...")
    compiler.Compiler().compile(pipeline_func=histology_pipeline, package_path=output_file)
    
    print("Uploading template to GCS...")
    try:
        storage_client = storage.Client(project=PROJECT_ID)
        storage_client.bucket(BUCKET_NAME).blob(f"templates/{output_file}").upload_from_filename(output_file)
        print(f"✅ Fully Dynamic Pipeline compiled and uploaded to gs://{BUCKET_NAME}/templates/{output_file}")
    except Exception as e:
        print(f"⚠️ Could not upload to GCS. Are you authenticated? Error: {e}")
