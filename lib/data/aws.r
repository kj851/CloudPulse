# AWS data access and processing functions for Shiny app
# with security validation and error handling
# S3, RDS, CloudWatch, Cost Explorer. Connect to RDS,
# retrieve metadata, usage, and cost data.
# Author: Keaton Szantho

library(shiny)
library(DBI)
library(RPostgres)
library(aws.s3)
# do not fail the whole script if paws service packages are missing
if (requireNamespace("paws.rds", quietly = TRUE)) {
  library(paws.rds)
} else {
  message("paws.rds not available. aws_rds_* functions will return informative errors or empty results.")
}
if (requireNamespace("paws.cloudwatch", quietly = TRUE)) {
  library(paws.cloudwatch)
} else {
  message("paws.cloudwatch not available. aws_rds_instance_usage will return informative results.")
}
if (requireNamespace("paws.cost_explorer", quietly = TRUE)) {
  library(paws.cost_explorer)
} else {
  message("paws.cost_explorer not available. aws_rds_cost_by_instance will return informative results.")
}
library(keyring)

aws_creds <- function() {
  creds <- list(
    aws_access_key_id = key_get(service = "aws", username = "access_key_id"),
    aws_secret_access_key = key_get(service = "aws", username = "secret_access_key"),
    aws_region = Sys.getenv("AWS_REGION", "us-east-1"),
    rds_host = key_get(service = "rds", username = "host"),
    rds_port = tryCatch(as.integer(key_get(service = "rds", username = "port")),
      error = function(e) 5432
    ),
    rds_dbname = key_get(service = "rds", username = "dbname"),
    rds_user = key_get(service = "rds", username = "user"),
    rds_password = key_get(service = "rds", username = "password")
  )

  # Check if any required credentials are missing
  required_aws <- c("aws_access_key_id", "aws_secret_access_key")
  missing_aws <- required_aws[sapply(creds[required_aws], function(x) is.null(x) || x == "")]
  if (length(missing_aws) > 0) {
    stop("Missing required AWS credentials: ", paste(missing_aws, collapse = ", "))
  }

  required_rds <- c("rds_host", "rds_dbname", "rds_user", "rds_password")
  missing_rds <- required_rds[sapply(creds[required_rds], function(x) is.null(x) || x == "")]
  if (length(missing_rds) > 0) {
    stop("Missing required RDS credentials: ", paste(missing_rds, collapse = ", "))
  }

  creds
}

aws_rds_conn <- function(creds = aws_creds()) {
  dbConnect(
    RPostgres::Postgres(),
    host = creds$rds_host,
    port = creds$rds_port,
    dbname = creds$rds_dbname,
    user = creds$rds_user,
    password = creds$rds_password
  )
}

aws_rds_query <- function(sql, creds = aws_creds()) {
  conn <- aws_rds_conn(creds)
  on.exit(dbDisconnect(conn), add = TRUE)
  dbGetQuery(conn, sql)
}

aws_s3_read_csv <- function(bucket, object, ...) {
  raw_data <- aws.s3::get_object(object = object, bucket = bucket)
  if (!is.raw(raw_data)) stop("Failed to read S3 object")
  read.csv(text = rawToChar(raw_data), ...)
}

aws_data_server <- function(id, sql) {
  moduleServer(id, function(input, output, session) {
    data <- reactive({
      aws_rds_query(sql)
    })
    data
  })
}

# Provide guarded metadata function
if (requireNamespace("paws.rds", quietly = TRUE)) {
  aws_rds_instances_metadata <- function(creds = aws_creds()) {
    rds <- paws.rds::rds(config = list(region = creds$aws_region))
    instances <- rds$describe_db_instances()
    metadata <- do.call(rbind, lapply(instances$DBInstances, function(inst) {
      data.frame(
        identifier = inst$DBInstanceIdentifier,
        class = inst$DBInstanceClass,
        engine = inst$Engine,
        status = inst$DBInstanceStatus,
        storage_gb = inst$AllocatedStorage,
        multi_az = inst$MultiAZ,
        creation_time = as.POSIXct(inst$InstanceCreateTime),
        endpoint = inst$Endpoint$Address,
        port = inst$Endpoint$Port,
        stringsAsFactors = FALSE
      )
    }))
    metadata
  }
} else {
  aws_rds_instances_metadata <- function(...) {
    data.frame(
      Error = "paws.rds not installed; install via CRAN or GitHub (paws-r/paws.rds) or upgrade R.",
      stringsAsFactors = FALSE
    )
  }
}

if (requireNamespace("paws.cloudwatch", quietly = TRUE)) {
  aws_rds_instance_usage <- function(instance_id, creds = aws_creds()) {
    cw <- paws.cloudwatch::cloudwatch(config = list(region = creds$aws_region))
    metrics <- cw$get_metric_statistics(
      Namespace = "AWS/RDS",
      MetricName = "CPUUtilization",
      Dimensions = list(list(Name = "DBInstanceIdentifier", Value = instance_id)),
      StartTime = Sys.time() - 7 * 86400,
      EndTime = Sys.time(),
      Period = 3600,
      Statistics = list("Average", "Maximum")
    )
    usage <- data.frame(
      timestamp = sapply(metrics$Datapoints, function(dp) as.POSIXct(dp$Timestamp)),
      cpu_avg = sapply(metrics$Datapoints, function(dp) dp$Average),
      cpu_max = sapply(metrics$Datapoints, function(dp) dp$Maximum),
      stringsAsFactors = FALSE
    )
    usage <- usage[order(usage$timestamp), ]
    usage
  }
} else {
  aws_rds_instance_usage <- function(instance_id, ...) {
    data.frame(
      timestamp = as.POSIXct(character(0)),
      cpu_avg = numeric(0),
      cpu_max = numeric(0),
      note = paste0("paws.cloudwatch not installed; cannot fetch usage for instance ", instance_id),
      stringsAsFactors = FALSE
    )
  }
}

if (requireNamespace("paws.cost_explorer", quietly = TRUE)) {
  aws_rds_cost_by_instance <- function(start_date, end_date, creds = aws_creds()) {
    ce <- paws.cost_explorer::cost_explorer(config = list(region = creds$aws_region))
    cost <- ce$get_cost_and_usage(
      TimePeriod = list(Start = start_date, End = end_date),
      Granularity = "MONTHLY",
      Metrics = list("BlendedCost"),
      GroupBy = list(list(Type = "DIMENSION", Key = "RESOURCE_ID")),
      Filter = list(Dimensions = list(Key = "SERVICE", Values = list("Amazon Relational Database Service")))
    )
    results <- do.call(rbind, lapply(cost$ResultsByTime, function(rt) {
      groups <- rt$Groups
      if (length(groups) == 0) {
        return(NULL)
      }
      do.call(rbind, lapply(groups, function(g) {
        resource_arn <- g$Keys[[1]]
        instance_id <- sub(".*:db:", "", resource_arn)
        data.frame(
          start = rt$TimePeriod$Start,
          end = rt$TimePeriod$End,
          instance_id = instance_id,
          cost = as.numeric(g$Metrics$BlendedCost$Amount),
          unit = g$Metrics$BlendedCost$Unit,
          stringsAsFactors = FALSE
        )
      }))
    }))
    results
  }
} else {
  aws_rds_cost_by_instance <- function(start_date, end_date, ...) {
    data.frame(
      start = start_date,
      end = end_date,
      instance_id = character(0),
      cost = numeric(0),
      unit = character(0),
      note = "paws.cost_explorer not installed; cost data unavailable",
      stringsAsFactors = FALSE
    )
  }
}
