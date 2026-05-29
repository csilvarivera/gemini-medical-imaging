# Zip the Cloud Function source code
data "archive_file" "function_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../cloud_function"
  output_path = "${path.module}/function_source.zip"
}

# Upload the zip to GCS
resource "google_storage_bucket_object" "function_source" {
  name   = "function-source-${data.archive_file.function_zip.output_md5}.zip"
  bucket = google_storage_bucket.wsi_data_bucket.name
  source = data.archive_file.function_zip.output_path
}

# Define the 2nd Gen Cloud Function
resource "google_cloudfunctions2_function" "trigger_wsi_pipeline" {
  name        = "trigger-wsi-pipeline"
  location    = var.region
  description = "Triggers the WSI Kubeflow Pipeline when files are uploaded to GCS"
  project     = var.project_id

  build_config {
    runtime     = "python310"
    entry_point = "trigger_pipeline"
    source {
      storage_source {
        bucket = google_storage_bucket.wsi_data_bucket.name
        object = google_storage_bucket_object.function_source.name
      }
    }
  }

  service_config {
    max_instance_count = 1
    available_memory   = "16Gi"
    cpu                = "4"
    timeout_seconds    = 1800
    service_account_email = google_service_account.pipeline_sa.email
    environment_variables = {
      PROJECT_ID               = var.project_id
      REGION                   = var.region
      BUCKET_NAME              = google_storage_bucket.wsi_data_bucket.name
      MEDGEMMA_ID              = var.medgemma_id
      MEDSIGLIP_ID             = var.medsiglip_id
      VECTOR_INDEX_ENDPOINT_ID = google_vertex_ai_index_endpoint.histology_vector_endpoint.id
      VECTOR_INDEX_ID          = google_vertex_ai_index.histology_index.id
      HF_TOKEN_SECRET          = "huggingface-token"
    }
  }

  event_trigger {
    trigger_region = var.region
    event_type     = "google.cloud.storage.object.v1.finalized"
    retry_policy   = "RETRY_POLICY_DO_NOT_RETRY"
    service_account_email = google_service_account.pipeline_sa.email
    event_filters {
      attribute = "bucket"
      value     = google_storage_bucket.wsi_data_bucket.name
    }
  }

  depends_on = [
    google_project_iam_member.sa_eventarc_receiver,
    google_project_iam_member.sa_run_invoker,
    google_project_iam_member.gcs_pubsub_publisher
  ]
}
