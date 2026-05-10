# For testing
get_mock_instances <- function(provider) {
  if (provider == "AWS") {
    c("aws-db-1", "aws-db-2")
  } else if (provider == "Azure") {
    c("azure-db-1", "azure-db-2")
  } else {
    c("gcp-db-1", "gcp-db-2")
  }
}

get_mock_metadata <- function(provider) {
  if (provider == "AWS") {
    data.frame(
      identifier = c("aws-db-1", "aws-db-2"),
      class = c("db.t3.medium", "db.t3.large"),
      engine = c("postgres", "postgres"),
      status = c("available", "stopped"),
      storage_gb = c(20, 50),
      multi_az = c(FALSE, TRUE),
      creation_time = Sys.time() - c(100000, 200000),
      endpoint = c("aws-db-1.example", "aws-db-2.example"),
      port = c(5432, 5432),
      stringsAsFactors = FALSE
    )
  } else if (provider == "Azure") {
    data.frame(
      name = c("azure-db-1", "azure-db-2"),
      location = c("eastus", "westeurope"),
      sku_name = c("GP_Gen5_2", "GP_Gen5_4"),
      sku_tier = c("GeneralPurpose", "GeneralPurpose"),
      storage_mb = c(51200, 102400),
      version = c("12", "13"),
      state = c("Ready", "Stopped"),
      fully_qualified_domain_name = c("azure-db-1.database.windows.net", "azure-db-2.database.windows.net"),
      stringsAsFactors = FALSE
    )
  } else {
    data.frame(
      name = c("gcp-db-1", "gcp-db-2"),
      database_version = c("POSTGRES_13", "POSTGRES_14"),
      region = c("us-central1", "europe-west1"),
      tier = c("db-custom-1-3840", "db-custom-2-7680"),
      data_disk_size_gb = c(20, 50),
      state = c("RUNNABLE", "SUSPENDED"),
      connection_name = c("project:region:gcp-db-1", "project:region:gcp-db-2"),
      stringsAsFactors = FALSE
    )
  }
}

get_mock_usage <- function(provider, instance_id) {
  # 7 daily points
  ts <- seq(Sys.time() - 6 * 86400, Sys.time(), by = "1 day")
  cpu_avg <- round(runif(length(ts), 5, 45), 1)
  cpu_max <- pmin(100, cpu_avg + round(runif(length(ts), 1, 30), 1))
  data.frame(timestamp = as.POSIXct(ts), cpu_avg = cpu_avg, cpu_max = cpu_max, stringsAsFactors = FALSE)
}

get_mock_cost <- function(start_date, end_date) {
  instances <- c("instance-A", "instance-B", "instance-C")
  data.frame(
    start = start_date,
    end = end_date,
    instance_id = instances,
    cost = round(runif(length(instances), 10, 200), 2),
    unit = rep("USD", length(instances)),
    stringsAsFactors = FALSE
  )
}
