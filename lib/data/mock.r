# Mock data functions for CloudPulse FinOps Dashboard
# Patched: input validation, bounded random generation,
# no user-controlled values passed to data frames unsanitized.
# Copyright (c) 2026, Keaton Szantho

`%||%` <- function(a, b) if (!is.null(a)) a else b

# VULNERABILITY FIXED: original accepted any string as provider and used it
# directly in data frames — could inject arbitrary strings into the UI.
.valid_provider <- function(provider) {
  provider <- trimws(provider %||% "")
  if (provider %notin% c("AWS", "Azure", "GCP")) {
    warning("Unknown provider '", provider, "'; defaulting to AWS.")
    return("AWS")
  }
  provider
}

`%notin%` <- function(x, y) !(x %in% y)

get_mock_instances <- function(provider) {
  provider <- .valid_provider(provider)
  switch(provider,
    AWS   = c("aws-db-1",   "aws-db-2"),
    Azure = c("azure-db-1", "azure-db-2"),
    GCP   = c("gcp-db-1",   "gcp-db-2")
  )
}

get_mock_metadata <- function(provider) {
  provider <- .valid_provider(provider)
  switch(provider,
    AWS = data.frame(
      identifier    = c("aws-db-1", "aws-db-2"),
      class         = c("db.t3.medium", "db.t3.large"),
      engine        = c("postgres", "postgres"),
      status        = c("available", "stopped"),
      storage_gb    = c(20L, 50L),
      multi_az      = c(FALSE, TRUE),
      creation_time = Sys.time() - c(100000, 200000),
      endpoint      = c("aws-db-1.example", "aws-db-2.example"),
      port          = c(5432L, 5432L),
      stringsAsFactors = FALSE
    ),
    Azure = data.frame(
      name                        = c("azure-db-1", "azure-db-2"),
      location                    = c("eastus", "westeurope"),
      sku_name                    = c("GP_Gen5_2", "GP_Gen5_4"),
      sku_tier                    = c("GeneralPurpose", "GeneralPurpose"),
      storage_mb                  = c(51200L, 102400L),
      version                     = c("12", "13"),
      state                       = c("Ready", "Stopped"),
      fully_qualified_domain_name = c("azure-db-1.database.windows.net",
                                      "azure-db-2.database.windows.net"),
      stringsAsFactors = FALSE
    ),
    GCP = data.frame(
      name = c("gcp-db-1", "gcp-db-2"),
      database_version  = c("POSTGRES_13", "POSTGRES_14"),
      region = c("us-central1", "europe-west1"),
      tier = c("db-custom-1-3840", "db-custom-2-7680"),
      data_disk_size_gb = c(20L, 50L),
      state = c("RUNNABLE", "SUSPENDED"),
      connection_name = c("project:region:gcp-db-1", "project:region:gcp-db-2"),
      stringsAsFactors = FALSE
    )
  )
}

# PATCH: instance_id validation + bounded random values
# VULNERABILITY FIXED: original accepted arbitrary instance_id and used it
# in the returned data frame directly; random values were unbounded.
get_mock_usage <- function(provider, instance_id) {
  provider    <- .valid_provider(provider)
  instance_id <- trimws(instance_id %||% "")
  # Validate instance_id against known mock values
  valid_ids <- c("aws-db-1",
    "aws-db-2",
    "azure-db-1",
    "azure-db-2",
    "gcp-db-1",
    "gcp-db-2", ""
  )
  if (instance_id %notin% valid_ids) {
    warning("Unknown instance_id '", instance_id, "'; using mock data.")
  }

  set.seed(NULL)  # ensure fresh randomness each call
  ts <- seq(Sys.time() - 29 * 86400, Sys.time(), by = "1 day")
  n <- length(ts)
  # PATCH: clamp values to realistic CPU range [0, 100]
  cpu_avg <- pmax(0, pmin(100, round(runif(n, 5, 45), 1)))
  cpu_max <- pmax(cpu_avg, pmin(100, cpu_avg + round(runif(n, 1, 30), 1)))

  data.frame(
    timestamp = as.POSIXct(ts),
    cpu_avg   = cpu_avg,
    cpu_max   = cpu_max,
    stringsAsFactors = FALSE
  )
}

# VULNERABILITY FIXED: original passed start_date/end_date directly into the
# data frame without format or range validation.
get_mock_cost <- function(start_date, end_date) {
  sd <- tryCatch(as.Date(start_date, "%Y-%m-%d"), error = function(e) NA)
  ed <- tryCatch(as.Date(end_date,   "%Y-%m-%d"), error = function(e) NA)
  if (is.na(sd) || is.na(ed))    stop("Invalid date format. Use YYYY-MM-DD.")
  if (sd >= ed)                  stop("start_date must be before end_date.")
  if (as.numeric(ed - sd) > 366) stop("Date range must not exceed 366 days.")

  instances <- c("instance-A", "instance-B", "instance-C")
  data.frame(
    start       = format(sd),
    end         = format(ed),
    instance_id = instances,
    cost        = round(runif(length(instances), 10, 200), 2),
    unit        = rep("USD", length(instances)),
    stringsAsFactors = FALSE
  )
}
