resource "google_storage_bucket" "wsi_data_bucket" {
  name                        = var.wsi_bucket_name
  location                    = var.region
  force_destroy               = false
  uniform_bucket_level_access = true

  # Ensure Eventarc can trigger from this bucket
  depends_on = [google_project_service.required_apis]
}

# Creates the virtual directory for inputs
resource "google_storage_bucket_object" "inputs_folder" {
  name    = "inputs/"
  content = "Placeholder for directory"
  bucket  = google_storage_bucket.wsi_data_bucket.name
}

# Creates the virtual directory for outputs
resource "google_storage_bucket_object" "outputs_folder" {
  name    = "outputs/"
  content = "Placeholder for directory"
  bucket  = google_storage_bucket.wsi_data_bucket.name
}

# Bucket for pipeline templates
resource "google_storage_bucket_object" "templates_folder" {
  name    = "templates/"
  content = "Placeholder for directory"
  bucket  = google_storage_bucket.wsi_data_bucket.name
}
