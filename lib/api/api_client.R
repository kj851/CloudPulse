# CloudPulse API client
# Drop-in replacement for direct data function calls.
# Source this instead of aws.r / azure.r / GCP.r / mock.r / forecast.r / kubernetes.r
# when running with the plumber backend.

library(httr)
library(jsonlite)

# Configuration
.api_base <- function() {
  base <- Sys.getenv("CLOUDPULSE_API_URL", unset = "http://127.0.0.1:8000")
  gsub("/$", "", base)
}

.api_key <- function() {
  Sys.getenv("CLOUDPULSE_API_KEY", unset = "")
}

# Core request helper
# All client calls go through here — centralises auth, error handling,
# timeout, and JSON parsing.
.api_get <- function(path, query = list()) {
  url <- paste0(.api_base(), path)
  key <- .api_key()

  headers <- if (nzchar(key)) {
    httr::add_headers("X-API-Key" = key)
  } else {
    httr::add_headers()
  }

  response <- tryCatch(
    httr::GET(url, headers, query = query, httr::timeout(15L)),
    error = function(e) {
      stop("API connection failed: is the plumber server running at ",
           .api_base(), "?")
    }
  )

  code <- httr::status_code(response)
  body <- httr::content(response, "text", encoding = "UTF-8")

  if (code == 401L) stop("API: unauthorized. Check CLOUDPULSE_API_KEY.")
  if (code == 404L) stop("API: endpoint not found: ", path)
  if (code >= 400L) {
    err <- tryCatch(jsonlite::fromJSON(body)$error, error = function(e) body)
    stop("API error (", code, "): ", err)
  }

  tryCatch(
    jsonlite::fromJSON(body, simplifyDataFrame = TRUE),
    error = function(e) stop("API: failed to parse response from ", path)
  )
}

# Cloud metadata
get_mock_metadata <- function(provider) {
  .api_get("/metadata", list(provider = provider, mock = "true"))
}

aws_rds_instances_metadata <- function() {
  .api_get("/metadata", list(provider = "AWS", mock = "false"))
}

azure_db_instances_metadata <- function() {
  .api_get("/metadata", list(provider = "Azure", mock = "false"))
}

gcp_db_instances_metadata <- function() {
  .api_get("/metadata", list(provider = "GCP", mock = "false"))
}

# Instance lists
get_mock_instances <- function(provider) {
  .api_get("/instances", list(provider = provider, mock = "true"))
}

# Usage
get_mock_usage <- function(provider, instance_id) {
  .api_get("/usage", list(
    provider = provider,
    instance = instance_id,
    mock     = "true"
  ))
}

aws_rds_instance_usage <- function(instance_id) {
  .api_get("/usage", list(
    provider = "AWS",
    instance = instance_id,
    mock     = "false"
  ))
}

azure_db_instance_usage <- function(instance_id) {
  .api_get("/usage", list(
    provider = "Azure",
    instance = instance_id,
    mock     = "false"
  ))
}

gcp_db_instance_usage <- function(instance_id) {
  .api_get("/usage", list(
    provider = "GCP",
    instance = instance_id,
    mock     = "false"
  ))
}

# Cost
get_mock_cost <- function(start_date, end_date) {
  .api_get("/cost", list(
    provider = "mock",
    start    = start_date,
    end      = end_date,
    mock     = "true"
  ))
}

aws_rds_cost_by_instance <- function(start_date, end_date) {
  .api_get("/cost", list(
    provider = "AWS",
    start    = start_date,
    end      = end_date,
    mock     = "false"
  ))
}

azure_db_cost_by_instance <- function(start_date, end_date) {
  .api_get("/cost", list(
    provider = "Azure",
    start    = start_date,
    end      = end_date,
    mock     = "false"
  ))
}

gcp_db_cost_by_instance <- function(start_date, end_date) {
  .api_get("/cost", list(
    provider = "GCP",
    start    = start_date,
    end      = end_date,
    mock     = "false"
  ))
}

# Forecasting
# Returns list with $forecast, $anomalies, $metrics, $method, $error
train_forecast_usage <- function(
  usage_df,
  periods  = 7L,
  method   = "auto_arima",
  ...
) {
  # usage_df is already loaded — pass provider/instance context via attributes
  # For API mode, re-fetch usage from API and forecast server-side
  provider <- attr(usage_df, "provider") %||% "mock"
  instance <- attr(usage_df, "instance") %||% ""
  use_mock <- attr(usage_df, "mock")     %||% TRUE

  .api_get("/forecast", list(
    provider = provider,
    instance = instance,
    periods  = as.character(periods),
    method   = method,
    mock     = if (isTRUE(use_mock)) "true" else "false"
  ))
}

# Kubernetes
get_mock_k8s_clusters <- function() {
  .api_get("/k8s/clusters", list(mock = "true"))
}

get_mock_k8s_nodes <- function(cluster_name) {
  .api_get("/k8s/nodes", list(cluster = cluster_name, mock = "true"))
}

get_mock_k8s_pods <- function(cluster_name, namespace = "") {
  .api_get("/k8s/pods", list(
    cluster   = cluster_name,
    namespace = namespace,
    mock      = "true"
  ))
}

get_mock_k8s_deployments <- function(cluster_name) {
  .api_get("/k8s/deployments", list(cluster = cluster_name, mock = "true"))
}

get_mock_k8s_events <- function(cluster_name) {
  .api_get("/k8s/events", list(cluster = cluster_name, mock = "true"))
}

get_mock_k8s_metrics <- function(cluster_name) {
  .api_get("/k8s/metrics", list(cluster = cluster_name, mock = "true"))
}

get_mock_k8s_namespaces <- function(cluster_name) {
  .api_get("/k8s/namespaces", list(cluster = cluster_name, mock = "true"))
}
