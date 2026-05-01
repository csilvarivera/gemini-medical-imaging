resource "google_vertex_ai_index" "histology_index" {
  region       = var.region
  display_name = "histology_index"
  description  = "Semantic index for histology tile embeddings"
  
  metadata {
    contents_delta_uri = "gs://${google_storage_bucket.wsi_data_bucket.name}/empty_index/"
    config {
      dimensions = 768
      approximate_neighbors_count = 150
      distance_measure_type = "DOT_PRODUCT_DISTANCE"
      algorithm_config {
        tree_ah_config {
          leaf_node_embedding_count = 500
          leaf_nodes_to_search_percent = 7
        }
      }
    }
  }
  
  index_update_method = "STREAM_UPDATE"
  
  depends_on = [google_project_service.required_apis]
}

resource "google_vertex_ai_index_endpoint" "histology_vector_endpoint" {
  display_name = "histology_vector_endpoint"
  description  = "Endpoint for histology vector search"
  region       = var.region
  
  depends_on = [google_project_service.required_apis]
}

# The deployment of the index to the endpoint can sometimes take a long time and is tricky in terraform.
# We map it here but note it might time out depending on GCP's current provisioning speed.
resource "google_vertex_ai_index_endpoint_deployed_index" "histology_deployed_index" {
  index_endpoint = google_vertex_ai_index_endpoint.histology_vector_endpoint.id
  index          = google_vertex_ai_index.histology_index.id
  deployed_index_id = "histology_deployed_idx"
  
  dedicated_resources {
    machine_spec {
      machine_type = "e2-standard-2"
    }
    min_replica_count = 1
    max_replica_count = 1
  }
}
