# CloudPulse Plumber API
# Exposes REST endpoints for all cloud data, K8s health, and forecasting.
# Run via: Rscript api/entrypoint.R
# Author: Keaton Szantho

library(plumber)
library(jsonlite)
library(httr)

# Source data modules relative to project root
source("lib/data/aws.r")
source("lib/data/azure.r")
source("lib/data/GCP.r")
source("lib/data/mock.r")
source("lib/data/forecast.r")
source("lib/data/kubernetes.r")

# ── API key authentication filter ─────────────────────────────────────────────
# Set env var CLOUDPULSE_API_KEY before starting the server.
# Clients must send header:  X-API-Key: <key>
#* @filter auth
function(req, res) {
  expected_key <- Sys.getenv("CLOUDPULSE_API_KEY", unset = "")
  # Skip auth on health check and docs
  if (grepl("^/health$|^/__docs__|^/openapi", req$PATH_INFO)) {
    plumber::forward()
    return()
  }
  if (!nzchar(expected_key)) {
    # No key configured — warn but allow (dev mode)
    message("[API] Warning: CLOUDPULSE_API_KEY not set. Auth disabled.")
    plumber::forward()
    return()
  }
  provided_key <- req$HTTP_X_API_KEY %||% ""
  if (!identical(provided_key, expected_key)) {
    res$status <- 401L
    return(list(error = "Unauthorized. Provide a valid X-API-Key header."))
  }
  plumber::forward()
}

`%||%` <- function(a, b) if (!is.null(a) && nzchar(a)) a else b

# Input validation helpers
.valid_provider <- function(x) {
  x <- trimws(x %||% "")
  if (x %in% c("AWS","Azure","GCP","mock")) return(x)
  stop("provider must be one of: AWS, Azure, GCP, mock")
}

.valid_date <- function(x, label = "date") {
  d <- tryCatch(as.Date(x, "%Y-%m-%d"), error = function(e) NA)
  if (is.na(d)) stop(label, " must be YYYY-MM-DD")
  d
}

.valid_instance <- function(x) {
  x <- trimws(x %||% "")
  if (!grepl("^[a-zA-Z0-9][a-zA-Z0-9\\-_\\.]{0,62}$", x, perl = TRUE))
    stop("Invalid instance identifier.")
  x
}

.valid_cluster <- function(x) {
  x <- trimws(x %||% "")
  if (!grepl("^[a-z0-9][a-z0-9\\-\\.]{0,62}$", x, perl = TRUE))
    stop("Invalid cluster name.")
  x
}

.error_response <- function(e, res, code = 400L) {
  res$status <- code
  list(error = conditionMessage(e))
}

# ══════════════════════════════════════════════════════════════════════════════
# HEALTH
# ══════════════════════════════════════════════════════════════════════════════

#* Health check
#* @get /health
#* @tag System
function() {
  list(
    status    = "ok",
    version   = "1.0.0",
    timestamp = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ")
  )
}

# ══════════════════════════════════════════════════════════════════════════════
# CLOUD METADATA
# ══════════════════════════════════════════════════════════════════════════════

#* List instances / databases for a provider
#* @param provider AWS | Azure | GCP | mock
#* @param mock Use mock data (true/false)
#* @get /metadata
#* @tag Cloud
function(provider = "mock", mock = "true", res) {
  tryCatch({
    use_mock <- identical(trimws(mock), "true") || provider == "mock"
    p        <- if (use_mock) "mock" else .valid_provider(provider)
    df <- if (use_mock) {
      get_mock_metadata(if (p == "mock") "AWS" else p)
    } else {
      if (p == "AWS")        aws_rds_instances_metadata()
      else if (p == "Azure") azure_db_instances_metadata()
      else                   gcp_db_instances_metadata()
    }
    jsonlite::toJSON(df, auto_unbox = TRUE, na = "null")
  }, error = function(e) .error_response(e, res))
}

#* Get instance list (names only) for a provider
#* @param provider AWS | Azure | GCP | mock
#* @param mock Use mock data (true/false)
#* @get /instances
#* @tag Cloud
function(provider = "AWS", mock = "true", res) {
  tryCatch({
    use_mock <- identical(trimws(mock), "true")
    p        <- if (use_mock) "AWS" else .valid_provider(provider)
    instances <- if (use_mock) {
      get_mock_instances(p)
    } else {
      if (p == "AWS")        aws_rds_instances_metadata()$identifier
      else if (p == "Azure") azure_db_instances_metadata()$name
      else                   gcp_db_instances_metadata()$name
    }
    jsonlite::toJSON(instances, auto_unbox = TRUE)
  }, error = function(e) .error_response(e, res))
}

# ══════════════════════════════════════════════════════════════════════════════
# USAGE
# ══════════════════════════════════════════════════════════════════════════════

#* Get CPU usage for an instance
#* @param provider AWS | Azure | GCP | mock
#* @param instance Instance identifier
#* @param mock Use mock data (true/false)
#* @get /usage
#* @tag Cloud
function(provider = "AWS", instance = "", mock = "true", res) {
  tryCatch({
    use_mock  <- identical(trimws(mock), "true")
    p         <- if (use_mock) provider else .valid_provider(provider)
    inst      <- if (!nzchar(instance)) "" else .valid_instance(instance)
    df <- if (use_mock) {
      get_mock_usage(p, inst)
    } else {
      if (p == "AWS")        aws_rds_instance_usage(inst)
      else if (p == "Azure") azure_db_instance_usage(inst)
      else                   gcp_db_instance_usage(inst)
    }
    jsonlite::toJSON(df, auto_unbox = TRUE, na = "null")
  }, error = function(e) .error_response(e, res))
}

# ══════════════════════════════════════════════════════════════════════════════
# COST
# ══════════════════════════════════════════════════════════════════════════════

#* Get cost data for a provider
#* @param provider AWS | Azure | GCP | mock
#* @param start Start date (YYYY-MM-DD)
#* @param end End date (YYYY-MM-DD)
#* @param mock Use mock data (true/false)
#* @get /cost
#* @tag Cloud
function(
  provider = "AWS",
  start    = format(Sys.Date()-30, "%Y-%m-%d"),
  end      = format(Sys.Date(),    "%Y-%m-%d"),
  mock     = "true",
  res
) {
  tryCatch({
    use_mock <- identical(trimws(mock), "true")
    p        <- if (use_mock) provider else .valid_provider(provider)
    sd       <- .valid_date(start, "start")
    ed       <- .valid_date(end,   "end")
    if (sd >= ed) stop("start must be before end.")
    if (as.numeric(ed - sd) > 366) stop("Date range exceeds 366 days.")
    df <- if (use_mock) {
      get_mock_cost(format(sd), format(ed))
    } else {
      s <- format(sd); e <- format(ed)
      if (p == "AWS")        aws_rds_cost_by_instance(s, e)
      else if (p == "Azure") azure_db_cost_by_instance(s, e)
      else                   gcp_db_cost_by_instance(s, e)
    }
    jsonlite::toJSON(df, auto_unbox = TRUE, na = "null")
  }, error = function(e) .error_response(e, res))
}

# ══════════════════════════════════════════════════════════════════════════════
# FORECAST
# ══════════════════════════════════════════════════════════════════════════════

#* Forecast CPU usage
#* @param provider AWS | Azure | GCP | mock
#* @param instance Instance identifier
#* @param periods Forecast horizon in days (1-90)
#* @param method auto_arima | prophet | ensemble
#* @param mock Use mock data (true/false)
#* @get /forecast
#* @tag Analytics
function(
  provider = "AWS",
  instance = "",
  periods  = "7",
  method   = "auto_arima",
  mock     = "true",
  res
) {
  tryCatch({
    use_mock <- identical(trimws(mock), "true")
    p        <- if (use_mock) provider else .valid_provider(provider)
    inst     <- if (!nzchar(instance)) "" else .valid_instance(instance)
    n        <- suppressWarnings(as.integer(periods))
    if (is.na(n) || n < 1L || n > 90L)
      stop("periods must be between 1 and 90.")
    if (!method %in% c("auto_arima","prophet","ensemble"))
      stop("method must be auto_arima, prophet, or ensemble.")

    usage_df <- if (use_mock) {
      get_mock_usage(p, inst)
    } else {
      if (p == "AWS")        aws_rds_instance_usage(inst)
      else if (p == "Azure") azure_db_instance_usage(inst)
      else                   gcp_db_instance_usage(inst)
    }
    result <- train_forecast_usage(usage_df, periods = n, method = method)
    jsonlite::toJSON(
      list(
        forecast  = result$forecast,
        anomalies = result$anomalies,
        metrics   = result$metrics,
        method    = result$method,
        error     = result$error
      ),
      auto_unbox = TRUE, na = "null"
    )
  }, error = function(e) .error_response(e, res))
}

# ══════════════════════════════════════════════════════════════════════════════
# KUBERNETES
# ══════════════════════════════════════════════════════════════════════════════

#* List all K8s clusters
#* @param mock Use mock data (true/false)
#* @get /k8s/clusters
#* @tag Kubernetes
function(mock = "true", res) {
  tryCatch({
    clusters <- get_mock_k8s_clusters()
    jsonlite::toJSON(clusters, auto_unbox = TRUE)
  }, error = function(e) .error_response(e, res))
}

#* Get nodes for a cluster
#* @param cluster Cluster name
#* @param mock Use mock data (true/false)
#* @get /k8s/nodes
#* @tag Kubernetes
function(cluster = "", mock = "true", res) {
  tryCatch({
    cl <- .valid_cluster(cluster)
    df <- get_mock_k8s_nodes(cl)
    jsonlite::toJSON(df, auto_unbox = TRUE, na = "null")
  }, error = function(e) .error_response(e, res))
}

#* Get pods for a cluster
#* @param cluster Cluster name
#* @param namespace Namespace filter (empty = all)
#* @param mock Use mock data (true/false)
#* @get /k8s/pods
#* @tag Kubernetes
function(cluster = "", namespace = "", mock = "true", res) {
  tryCatch({
    cl <- .valid_cluster(cluster)
    df <- get_mock_k8s_pods(cl, namespace)
    jsonlite::toJSON(df, auto_unbox = TRUE, na = "null")
  }, error = function(e) .error_response(e, res))
}

#* Get deployments for a cluster
#* @param cluster Cluster name
#* @param mock Use mock data (true/false)
#* @get /k8s/deployments
#* @tag Kubernetes
function(cluster = "", mock = "true", res) {
  tryCatch({
    cl <- .valid_cluster(cluster)
    df <- get_mock_k8s_deployments(cl)
    jsonlite::toJSON(df, auto_unbox = TRUE, na = "null")
  }, error = function(e) .error_response(e, res))
}

#* Get events for a cluster
#* @param cluster Cluster name
#* @param mock Use mock data (true/false)
#* @get /k8s/events
#* @tag Kubernetes
function(cluster = "", mock = "true", res) {
  tryCatch({
    cl <- .valid_cluster(cluster)
    df <- get_mock_k8s_events(cl)
    jsonlite::toJSON(df, auto_unbox = TRUE, na = "null")
  }, error = function(e) .error_response(e, res))
}

#* Get metrics for a cluster
#* @param cluster Cluster name
#* @param mock Use mock data (true/false)
#* @get /k8s/metrics
#* @tag Kubernetes
function(cluster = "", mock = "true", res) {
  tryCatch({
    cl <- .valid_cluster(cluster)
    df <- get_mock_k8s_metrics(cl)
    jsonlite::toJSON(df, auto_unbox = TRUE, na = "null")
  }, error = function(e) .error_response(e, res))
}

#* Get namespaces for a cluster
#* @param cluster Cluster name
#* @param mock Use mock data (true/false)
#* @get /k8s/namespaces
#* @tag Kubernetes
function(cluster = "", mock = "true", res) {
  tryCatch({
    cl <- .valid_cluster(cluster)
    df <- get_mock_k8s_namespaces(cl)
    jsonlite::toJSON(df, auto_unbox = TRUE, na = "null")
  }, error = function(e) .error_response(e, res))
}
