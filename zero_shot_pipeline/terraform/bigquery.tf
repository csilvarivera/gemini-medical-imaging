resource "google_bigquery_dataset" "pathology_db" {
  dataset_id  = var.bq_dataset_id
  location    = var.region
  description = "Dataset containing WSI pathology metadata"
  project     = var.project_id
  
  depends_on = [google_project_service.required_apis]
}

resource "google_bigquery_table" "tile_metadata" {
  dataset_id = google_bigquery_dataset.pathology_db.dataset_id
  table_id   = "tile_metadata"
  project    = var.project_id

  schema = <<EOF
[
  {"name": "run_id", "type": "STRING"},
  {"name": "wsi_filename", "type": "STRING"},
  {"name": "heart_id", "type": "STRING"},
  {"name": "tissue_name", "type": "STRING"},
  {"name": "primary_diagnosis", "type": "STRING"},
  {"name": "sample_category", "type": "STRING"},
  {"name": "stain", "type": "STRING"},
  {"name": "species", "type": "STRING"},
  {"name": "disease_category", "type": "STRING"},
  {"name": "tile_id", "type": "STRING"},
  {"name": "vector_id", "type": "STRING"},
  {"name": "mask_uri", "type": "STRING"},
  {"name": "predicted_class", "type": "STRING"}
]
EOF
}
