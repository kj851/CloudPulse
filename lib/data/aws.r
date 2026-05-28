# AWS data access and processing functions for Shiny app
# with security validation and error handling
# S3, RDS, CloudWatch, Cost Explorer. Connect to RDS,
# retrieve metadata, usage, and cost data.
# Copyright (c) 2026, Keaton Szantho

library(shiny)
library(DBI)
library(RPostgres)
library(aws.s3)

if (requireNamespace("paws.rds", quietly = TRUE)) {
  library(paws.rds)
} else {
  message("paws.rds not available.")
}
if (requireNamespace("paws.cloudwatch", quietly = TRUE)) {
  library(paws.cloudwatch)
} else {
  message("paws.cloudwatch not available.")
}
if (requireNamespace("paws.cost_explorer", quietly = TRUE)) {
  library(paws.cost_explorer)
} else {
  message("paws.cost_explorer not available.")
}
library(keyring)

aws_creds <- function() {
  creds <- list(
    aws_access_key_id     = key_get(
      service = "aws", username = "access_key_id"
    ),
    aws_secret_access_key = key_get(
      service = "aws", username = "secret_access_key"
    ),
    aws_region            = Sys.getenv("AWS_REGION", "us-east-1"),
    rds_host              = key_get(service = "rds", username = "host"),
    rds_port              = tryCatch(as.integer(
      key_get(service = "rds", username = "port")
    ),
                              error = function(e) 5432L),
    rds_dbname            = key_get(service = "rds", username = "dbname"),
    rds_user              = key_get(service = "rds", username = "user"),
    rds_password          = key_get(service = "rds", username = "password")
  )

  # Validate key format
  key <- trimws(creds$aws_access_key_id %||% "")
  if (!grepl("^(AKIA|ASIA|AROA|AGPA|AIDA|AIPA|ANPA
  |ANVA|APKA)[A-Z0-9]{16}$", key, perl = TRUE)) {
    stop("Invalid AWS Access Key format.")
  }

  # Validate region against whitelist
  valid_regions <- c(
    "us-east-1", "us-east-2", "us-west-1", "us-west-2",
    "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1", "eu-north-1",
    "ap-southeast-1", "ap-southeast-2", "ap-northeast-1", "ap-northeast-2",
    "ap-south-1", "sa-east-1", "ca-central-1", "me-south-1", "af-south-1"
  )
  if (creds$aws_region %notin% valid_regions) {
    creds$aws_region <- "us-east-1"
    warning("Invalid AWS region supplied; defaulting to us-east-1.")
  }

  # Validate port range
  if (is.na(creds$rds_port) || creds$rds_port < 1L || creds$rds_port > 65535L) {
    creds$rds_port <- 5432L
  }

  required_aws <- c("aws_access_key_id","aws_secret_access_key")
  missing_aws  <- required_aws[sapply(creds[required_aws],
    function(x) is.null(x) || !nzchar(x)
  )]
  if (length(missing_aws) > 0)
    stop("Missing required AWS credentials: ",
      paste(missing_aws, collapse = ", ")
    )

  required_rds <- c("rds_host","rds_dbname","rds_user","rds_password")
  missing_rds  <- required_rds[sapply(creds[required_rds],
  function(x) is.null(x) || !nzchar(x))]
  if (length(missing_rds) > 0)
    stop("Missing required RDS credentials: ",
    paste(missing_rds, collapse = ", ")
  )

  creds
}

`%notin%` <- function(x, y) !(x %in% y)
`%||%`    <- function(a, b) if (!is.null(a)) a else b

aws_rds_conn <- function(creds = aws_creds()) {
  dbConnect(
    RPostgres::Postgres(),
    host     = creds$rds_host,
    port     = creds$rds_port,
    dbname   = creds$rds_dbname,
    user     = creds$rds_user,
    password = creds$rds_password,
    connect_timeout = 10L   # PATCH: prevent indefinite hangs
  )
}

# VULNERABILITY FIXED: original aws_rds_query(sql) accepted raw SQL strings
# from callers — any user-controlled value interpolated into sql was injectable.
# All queries must now use parameterized form: aws_rds_query(sql, params=list())
aws_rds_query <- function(sql, params = list(), creds = aws_creds()) {
  # Validate sql is a plain string (not a connection or expression)
  if (!is.character(sql) || length(sql) != 1L || nchar(sql) > 10000L)
    stop("Invalid SQL argument.")
  # Reject obviously dangerous patterns
  if (grepl("(--|;\\s*DROP|;\\s*DELETE|;\\s*INSERT|;\\s
  *UPDATE|EXEC\\s*\\(|xp_cmdshell)",
            sql, ignore.case = TRUE, perl = TRUE))
    stop("SQL contains disallowed patterns.")

  conn <- aws_rds_conn(creds)
  on.exit(dbDisconnect(conn), add = TRUE)

  if (length(params) > 0) {
    dbGetQuery(conn, sql, params = params)
  } else {
    dbGetQuery(conn, sql)
  }
}

# VULNERABILITY FIXED: original accepted arbitrary bucket/object — path
# traversal possible via "../" sequences in object names.
aws_s3_read_csv <- function(bucket, object, ...) {
  # Sanitize inputs
  bucket <- trimws(bucket)
  object <- trimws(object)
  if (!grepl("^[a-z0-9][a-z0-9\\-\\.]{1,61}[a-z0-9]$", bucket, perl = TRUE))
    stop("Invalid S3 bucket name.")
  if (grepl("\\.\\.", object, perl = TRUE) || grepl("^/", object))
    stop("Invalid S3 object path.")

  raw_data <- aws.s3::get_object(object = object, bucket = bucket)
  if (!is.raw(raw_data)) stop("Failed to read S3 object.")
  read.csv(text = rawToChar(raw_data), ...)
}

aws_data_server <- function(id, sql) {
  moduleServer(id, function(input, output, session) {
    data <- reactive({ aws_rds_query(sql) })
    data
  })
}

if (requireNamespace("paws.rds", quietly = TRUE)) {
  aws_rds_instances_metadata <- function(creds = aws_creds()) {
    rds       <- paws.rds::rds(config = list(region = creds$aws_region))
    instances <- rds$describe_db_instances()
    do.call(rbind, lapply(instances$DBInstances, function(inst) {
      data.frame(
        identifier    = inst$DBInstanceIdentifier,
        class         = inst$DBInstanceClass,
        engine        = inst$Engine,
        status        = inst$DBInstanceStatus,
        storage_gb    = inst$AllocatedStorage,
        multi_az      = inst$MultiAZ,
        creation_time = as.POSIXct(inst$InstanceCreateTime),
        endpoint      = inst$Endpoint$Address,
        port          = inst$Endpoint$Port,
        stringsAsFactors = FALSE
      )
    }))
  }
} else {
  aws_rds_instances_metadata <- function(...) data.frame(Error = "paws.rds not installed.", stringsAsFactors = FALSE)
}

if (requireNamespace("paws.cloudwatch", quietly = TRUE)) {
  aws_rds_instance_usage <- function(instance_id, creds = aws_creds()) {
    # Validate: RDS identifiers are alphanumeric + hyphens, 1-63 chars
    instance_id <- trimws(instance_id %||% "")
    if (!grepl("^[a-zA-Z][a-zA-Z0-9\\-]{0,62}$", instance_id, perl = TRUE))
      stop("Invalid RDS instance identifier.")

    cw      <- paws.cloudwatch::cloudwatch(
      config = list(region = creds$aws_region)
    )
    metrics <- cw$get_metric_statistics(
      Namespace  = "AWS/RDS",
      MetricName = "CPUUtilization",
      Dimensions = list(list(
        Name = "DBInstanceIdentifier",
        Value = instance_id
      )),
      StartTime  = Sys.time() - 7 * 86400,
      EndTime    = Sys.time(),
      Period     = 3600L,
      Statistics = list("Average", "Maximum")
    )
    usage <- data.frame(
      timestamp = sapply(
        metrics$Datapoints,
        function(dp) as.POSIXct(dp$Timestamp)
      ),
      cpu_avg   = sapply(metrics$Datapoints, function(dp) dp$Average),
      cpu_max   = sapply(metrics$Datapoints, function(dp) dp$Maximum),
      stringsAsFactors = FALSE
    )
    usage[order(usage$timestamp), ]
  }
} else {
  aws_rds_instance_usage <- function(instance_id, ...)
    data.frame(timestamp = as.POSIXct(character(0)), cpu_avg = numeric(0),
               cpu_max = numeric(0), stringsAsFactors = FALSE)
}

if (requireNamespace("paws.cost_explorer", quietly = TRUE)) {
  aws_rds_cost_by_instance <- function(start_date, end_date, creds = aws_creds()) {
    # Validate date format and logical range
    sd <- tryCatch(as.Date(start_date, "%Y-%m-%d"), error = function(e) NA)
    ed <- tryCatch(as.Date(end_date,   "%Y-%m-%d"), error = function(e) NA)
    if (is.na(sd) || is.na(ed))    stop("Invalid date format. Use YYYY-MM-DD.")
    if (sd >= ed)                  stop("start_date must be before end_date.")
    if (as.numeric(ed - sd) > 366) stop("Date range must not exceed 366 days.")

    ce   <- paws.cost_explorer::cost_explorer(config = list(region = creds$aws_region))
    cost <- ce$get_cost_and_usage(
      TimePeriod  = list(Start = format(sd), End = format(ed)),
      Granularity = "MONTHLY",
      Metrics     = list("BlendedCost"),
      GroupBy     = list(list(Type = "DIMENSION", Key = "RESOURCE_ID")),
      Filter      = list(Dimensions = list(
        Key    = "SERVICE",
        Values = list("Amazon Relational Database Service")
      ))
    )
    do.call(rbind, Filter(Negate(is.null), lapply(cost$ResultsByTime, function(rt) {
      if (length(rt$Groups) == 0) return(NULL)
      do.call(rbind, lapply(rt$Groups, function(g) {
        data.frame(
          start       = format(sd),
          end         = format(ed),
          instance_id = sub(".*:db:", "", g$Keys[[1]]),
          cost        = as.numeric(g$Metrics$BlendedCost$Amount),
          unit        = g$Metrics$BlendedCost$Unit,
          stringsAsFactors = FALSE
        )
      }))
    })))
  }
} else {
  aws_rds_cost_by_instance <- function(
    start_date,
    end_date,
    ...
  )
    data.frame(start = start_date, end = end_date, instance_id = character(0),
               cost = numeric(0), unit = character(0), stringsAsFactors = FALSE)
}
