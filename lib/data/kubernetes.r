# Supports EKS (AWS), AKS (Azure), GKE (GCP), and generic kubeconfig.
# Patched: input validation, safe API errors, no raw kubectl injection.
# Copyright (c) 2026, Keaton Szantho

library(httr)
library(jsonlite)

`%||%` <- function(a, b) if (!is.null(a)) a else b

# Validation for Kubernetes resource names
# (e.g. namespaces) to prevent injection.
.valid_k8s_name <- function(x) {
  x <- trimws(x %||% "")
  if (!grepl(
    "^[a-z0-9][a-z0-9\\-\\.]{0,251}[a-z0-9]$", x, perl = TRUE
  ) && !grepl("^[a-z0-9]$", x, perl = TRUE)) return("")
  x
}

.safe_k8s_error <- function(e, context = "Kubernetes") {
  msg <- conditionMessage(e)
  if (grepl("401|unauthorized", msg, ignore.case = TRUE))
    return(paste(context, ": authentication failed. Check your kubeconfig."))
  if (grepl("403|forbidden",   msg, ignore.case = TRUE))
    return(paste(context, ": permission denied."))
  if (grepl("404|not found",   msg, ignore.case = TRUE))
    return(paste(context, ": resource not found."))
  if (grepl("connection|timeout|refused|network", msg, ignore.case = TRUE))
    return(paste(context, ": connection failed. Is the cluster reachable?"))
  paste(context, ": request failed.")
}

# API client
# Builds an authenticated httr request against the K8s API server.
# Supports token-based auth (EKS/GKE/AKS service accounts) and
# kubeconfig client-cert auth.
k8s_api <- function(path, cluster_config, method = "GET", body = NULL) {
  base_url <- trimws(cluster_config$server %||% "")
  if (!grepl("^https?://", base_url)) stop("Invalid cluster server URL.")

  # Sanitize path — allow only alphanumeric, /, -, _, .
  path <- trimws(path)
  if (!grepl("^[a-zA-Z0-9/\\-_\\.\\?=&%]+$", path, perl = TRUE))
    stop("Invalid API path.")

  url     <- paste0(base_url, path)
  headers <- httr::add_headers(
    "Accept"       = "application/json",
    "Content-Type" = "application/json"
  )

  # Auth: bearer token (EKS/GKE/AKS) or skip for mock
  config <- httr::config()
  if (!is.null(cluster_config$token) && nzchar(cluster_config$token)) {
    headers <- httr::add_headers(
      "Authorization" = paste("Bearer", cluster_config$token),
      "Accept"        = "application/json"
    )
  }
  if (isTRUE(cluster_config$skip_tls)) {
    config <- httr::config(ssl_verifypeer = FALSE)
  }

  response <- switch(method,
    "GET"  = httr::GET( url, headers, config, httr::timeout(15L)),
    "POST" = httr::POST(url, headers, config, httr::timeout(15L),
                        body = jsonlite::toJSON(body, auto_unbox = TRUE),
                        encode = "raw"),
    stop("Unsupported HTTP method: ", method)
  )

  code <- httr::status_code(response)
  if (code == 401L) stop("Kubernetes: authentication failed.")
  if (code == 403L) stop("Kubernetes: permission denied.")
  if (code == 404L) stop("Kubernetes: resource not found.")
  if (code >= 400L) stop("Kubernetes: API error (HTTP ", code, ").")

  jsonlite::fromJSON(
    httr::content(response, "text", encoding = "UTF-8"),
    simplifyVector = FALSE
  )
}

# Mock data generators for testing without a real cluster.
# This produces realistic but random data based on the
# `cluster name (to get consistent results per cluster).
get_mock_k8s_clusters <- function() {
  list(
    list(name = "prod-eks-us-east-1",  provider = "AWS",   status = "Healthy",
         version = "1.29", nodes = 8L,  region = "us-east-1"),
    list(name = "staging-aks-eastus",   provider = "Azure", status = "Healthy",
         version = "1.28", nodes = 4L,  region = "eastus"),
    list(name = "dev-gke-us-central1",  provider = "GCP",   status = "Warning",
         version = "1.27", nodes = 3L,  region = "us-central1"),
    list(name = "qa-eks-us-west-2",     provider = "AWS",   status = "Healthy",
         version = "1.29", nodes = 2L,  region = "us-west-2")
  )
}

get_mock_k8s_nodes <- function(cluster_name) {
  set.seed(nchar(cluster_name))
  n <- sample(3:8, 1)
  data.frame(
    name       = paste0("node-", seq_len(n)),
    status     = sample(c(
      "Ready", "Ready", "Ready", "NotReady"
    ), n, replace = TRUE),
    roles      = sample(c(
      "control-plane", "worker", "worker", "worker"
    ), n, replace = TRUE),
    age        = paste0(sample(5:120, n, replace = TRUE), "d"),
    version    = rep("v1.29.0", n),
    cpu_pct    = round(runif(n, 10, 80), 1),
    mem_pct    = round(runif(n, 20, 85), 1),
    pods       = sample(5:40, n, replace = TRUE),
    stringsAsFactors = FALSE
  )
}

get_mock_k8s_pods <- function(cluster_name, namespace = "all") {
  set.seed(nchar(cluster_name) + nchar(namespace))
  n <- sample(10:30, 1)
  statuses <- c(
    "Running", "Running", "Running", "Running",
    "Pending", "CrashLoopBackOff", "Completed"
)
  data.frame(
    name       = paste0(sample(c(
      "api", "worker", "cache", "db", "ingress"
    ), n, replace=TRUE),
    "-", replicate(n, paste0(
      sample(c(0:9, letters[1:6]), 5,
             replace = TRUE), collapse = ""
    ))),
    namespace  = sample(c(
      "default","kube-system","monitoring","prod"
    ), n, replace=TRUE),
    status     = sample(
      statuses, n, replace = TRUE,
      prob = c(.6, .6, .6, .6, .1, .05, .1)
    ),
    ready      = paste0(
      sample(1:3, n, replace = TRUE), "/",
      sample(1:3, n, replace = TRUE)
    ),
    restarts   = sample(0:20, n, replace = TRUE),
    age        = paste0(sample(1:60, n, replace = TRUE), "h"),
    node       = paste0("node-", sample(1:5, n, replace = TRUE)),
    cpu_req    = paste0(sample(10:500, n, replace = TRUE), "m"),
    mem_req    = paste0(sample(64:1024, n, replace = TRUE), "Mi"),
    stringsAsFactors = FALSE
  )
}

get_mock_k8s_deployments <- function(cluster_name) {
  set.seed(nchar(cluster_name) * 2)
  n <- sample(5:12, 1)
  data.frame(
    name       = paste0(sample(c(
      "api", "frontend", "backend", "worker", "scheduler", "proxy"
    ), n, replace = TRUE),
    "-", seq_len(n)),
    namespace  = sample(c("default", "prod", "staging"), n, replace = TRUE),
    ready      = paste0(sample(
        1:5, n, replace = TRUE
    ), "/", sample(3:5, n, replace = TRUE)),
    up_to_date = sample(1:5, n, replace = TRUE),
    available  = sample(1:5, n, replace = TRUE),
    age        = paste0(sample(1:90, n, replace = TRUE), "d"),
    stringsAsFactors = FALSE
  )
}

get_mock_k8s_events <- function(cluster_name) {
  set.seed(nchar(cluster_name) * 3)
  n <- 10L
  types    <- c("Normal", "Warning", "Warning", "Normal")
  reasons  <- c(
    "Scheduled", "Pulled", "Started", "BackOff",
    "OOMKilled", "NodeNotReady", "Killing"
)
  msgs     <- c("Successfully assigned pod to node",
                "Container image pulled successfully",
                "Started container",
                "Back-off restarting failed container",
                "OOM killed container",
                "Node not ready",
                "Stopping container")
  data.frame(
    type      = sample(types,   n, replace=TRUE),
    reason    = sample(reasons, n, replace=TRUE),
    object    = paste0(
                       "pod/", paste0(replicate(n, paste0(
                         sample(letters, 6, replace = TRUE), collapse = ""
                       )),
                       "-xyz")),
    namespace = sample(c("default","prod","kube-system"), n, replace = TRUE),
    message   = sample(msgs,    n, replace = TRUE),
    age       = paste0(sample(1:60, n, replace = TRUE), "m"),
    stringsAsFactors = FALSE
  )
}

get_mock_k8s_namespaces <- function(cluster_name) {
  data.frame(
    name = c(
      "default", "kube-system", "kube-public",
      "monitoring", "prod", "staging", "dev"
    ),
    status = c(
      "Active", "Active", "Active", "Active",
      "Active", "Active", "Terminating"
    ),
    age = c(
      "120d", "120d", "120d", "45d", "90d", "60d", "5d"
    ),
    stringsAsFactors = FALSE
  )
}

get_mock_k8s_metrics <- function(cluster_name) {
  set.seed(nchar(cluster_name) + 99)
  ts <- seq(Sys.time() - 3600, Sys.time(), by = "5 min")
  n  <- length(ts)
  data.frame(
    timestamp   = ts,
    cpu_pct     = pmax(0, pmin(100, cumsum(c(30, diff(runif(n-1, -5, 5)))))),
    mem_pct     = pmax(0, pmin(100, cumsum(c(45, diff(runif(n-1, -3, 3)))))),
    pod_count   = sample(15:35, n, replace=TRUE),
    error_rate  = pmax(0, runif(n, 0, 3)),
    stringsAsFactors = FALSE
  )
}

# Real K8s API functions (used when not mocking)
k8s_get_nodes <- function(cluster_config) {
  raw <- k8s_api("/api/v1/nodes", cluster_config)
  items <- raw$items %||% list()
  if (length(items) == 0) return(data.frame())
  do.call(rbind, lapply(items, function(node) {
    conditions <- node$status$conditions %||% list()
    ready_cond <- Filter(function(c) c$type == "Ready", conditions)
    status     <- if (
                      length(ready_cond) > 0 && 
                        ready_cond[[1]]$status == "True") "Ready"
    else "NotReady"
    alloc      <- node$status$allocatable %||% list()
    data.frame(
      name    = node$metadata$name %||% "",
      status  = status,
      roles   = paste(names(Filter(function(v) grepl("node-role", v),
                              node$metadata$labels %||% list())), collapse=","),
      version = node$status$nodeInfo$kubeletVersion %||% "",
      cpu     = alloc$cpu %||% "",
      memory  = alloc$memory %||% "",
      stringsAsFactors = FALSE
    )
  }))
}

k8s_get_pods <- function(cluster_config, namespace = "") {
  path <- if (nzchar(namespace)) {
    ns <- .valid_k8s_name(namespace)
    if (!nzchar(ns)) stop("Invalid namespace name.")
    paste0("/api/v1/namespaces/", ns, "/pods")
  } else "/api/v1/pods"
  raw   <- k8s_api(path, cluster_config)
  items <- raw$items %||% list()
  if (length(items) == 0) return(data.frame())
  do.call(rbind, lapply(items, function(pod) {
    cs <- pod$status$containerStatuses %||% list()
    data.frame(
      name      = pod$metadata$name %||% "",
      namespace = pod$metadata$namespace %||% "",
      status    = pod$status$phase %||% "Unknown",
      ready     = paste0(sum(
        sapply(cs, function(c) isTRUE(c$ready))
      ), "/", length(cs)),
      restarts  = sum(sapply(cs, function(c) c$restartCount %||% 0L)),
      node      = pod$spec$nodeName %||% "",
      age       = "",
      stringsAsFactors = FALSE
    )
  }))
}

k8s_get_deployments <- function(cluster_config, namespace = "") {
  path <- if (nzchar(namespace)) {
    ns <- .valid_k8s_name(namespace)
    if (!nzchar(ns)) stop("Invalid namespace name.")
    paste0("/apis/apps/v1/namespaces/", ns, "/deployments")
  } else "/apis/apps/v1/deployments"
  raw   <- k8s_api(path, cluster_config)
  items <- raw$items %||% list()
  if (length(items) == 0) return(data.frame())
  do.call(rbind, lapply(items, function(d) {
    spec   <- d$spec %||% list()
    status <- d$status %||% list()
    data.frame(
      name       = d$metadata$name %||% "",
      namespace  = d$metadata$namespace %||% "",
      ready      = paste0(
        status$readyReplicas %||% 0L, "/", spec$replicas %||% 0L
      ),
      up_to_date = status$updatedReplicas %||% 0L,
      available  = status$availableReplicas %||% 0L,
      stringsAsFactors = FALSE
    )
  }))
}

k8s_get_events <- function(cluster_config, namespace = "") {
  path <- if (nzchar(namespace)) {
    ns <- .valid_k8s_name(namespace)
    if (!nzchar(ns)) stop("Invalid namespace name.")
    paste0("/api/v1/namespaces/", ns, "/events")
  } else "/api/v1/events"
  raw   <- k8s_api(path, cluster_config)
  items <- raw$items %||% list()
  if (length(items) == 0) return(data.frame())
  events <- do.call(rbind, lapply(items, function(e) {
    data.frame(
      type      = e$type %||% "",
      reason    = e$reason %||% "",
      object    = paste0(e$involvedObject$kind, "/", e$involvedObject$name),
      namespace = e$metadata$namespace %||% "",
      message   = substr(e$message %||% "", 1L, 120L),
      count     = e$count %||% 1L,
      stringsAsFactors = FALSE
    )
  }))
  # Show warnings first
  events[order(events$type == "Warning", decreasing = TRUE), ]
}

k8s_get_namespaces <- function(cluster_config) {
  raw   <- k8s_api("/api/v1/namespaces", cluster_config)
  items <- raw$items %||% list()
  if (length(items) == 0) return(data.frame())
  do.call(rbind, lapply(items, function(ns) {
    data.frame(
      name   = ns$metadata$name %||% "",
      status = ns$status$phase %||% "Unknown",
      stringsAsFactors = FALSE
    )
  }))
}