variable "project_id" {
  description = "The GCP Project ID"
  type        = string
  default     = "gsk-cmc-hackathon"
}

variable "region" {
  description = "The GCP region to deploy resources to"
  type        = string
  default     = "us-central1"
}

variable "wsi_bucket_name" {
  description = "Name of the GCS bucket for WSI data"
  type        = string
  default     = "gsk-cmc-hackathon-wsi-data"
}

variable "bq_dataset_id" {
  description = "BigQuery dataset ID"
  type        = string
  default     = "pathology_db"
}

variable "medgemma_id" {
  description = "Vertex AI Endpoint ID for MedGemma"
  type        = string
  default     = "YOUR_MEDGEMMA_ID"
}

variable "pathfoundation_id" {
  description = "Vertex AI Endpoint ID for PathFoundation"
  type        = string
  default     = "YOUR_PATHFOUNDATION_ID"
}

variable "medsiglip_id" {
  description = "Vertex AI Endpoint ID for MedSigLip"
  type        = string
  default     = "YOUR_MEDSIGLIP_ID"
}
