# Forecasting functions for CloudPulse FinOps Dashboard
# This module provides functions to prepare time series data, find anomalies,
# and generate forecasts using Prophet, ARIMA, and Exponential Smoothing.
# Copyright (c) 2026, Keaton Szantho

library(dplyr)

yhat <- NULL
yhat_lower <- NULL
yhat_upper <- NULL
trend <- NULL
ds <- NULL
y <- NULL
is_anomaly <- NULL
library(dplyr)

# validate periods argument everywhere
.validate_periods <- function(periods, min_val = 1L, max_val = 365L) {
  periods <- suppressWarnings(as.integer(periods))
  if (is.na(periods) || periods < min_val || periods > max_val)
    stop(sprintf(
      "periods must be an integer between %d and %d.",
      min_val, max_val
    ))
  periods
}

# PATCH: validate column names before using get()
# VULNERABILITY FIXED: original used get(timestamp_col) and get(value_col)
# with caller-supplied strings — could reference arbitrary R objects in scope.
.validate_col <- function(df, col_name, context = "column") {
  col_name <- trimws(col_name %||% "")
  if (!nzchar(col_name) ||
        !grepl("^[a-zA-Z][a-zA-Z0-9_\\.]{0,63}$", col_name, perl = TRUE))
    stop(sprintf("Invalid %s name: '%s'.", context, col_name))
  if (!col_name %in% colnames(df))
    stop(sprintf("Column '%s' not found in data frame.", col_name))
  col_name
}

`%||%` <- function(a, b) if (!is.null(a)) a else b

prepare_time_series <- function(df, timestamp_col = "timestamp",
                                value_col = "cpu_avg",
                                frequency = "day", min_observations = 14L) {
  if (is.null(df) || !is.data.frame(df) || nrow(df) < min_observations)
    return(list(
      success = FALSE, data = data.frame(),
      error = "Insufficient data"
    ))

  timestamp_col <- .validate_col(df, timestamp_col, "timestamp")
  value_col <- .validate_col(df, value_col,     "value")

  tryCatch({
    prepared <- df |>
      dplyr::mutate(date = as.Date(.data[[timestamp_col]])) |>
      dplyr::group_by(date) |>
      dplyr::summarise(
        y     = mean(.data[[value_col]], na.rm = TRUE),
        min   = min(.data[[value_col]], na.rm = TRUE),
        max   = max(.data[[value_col]], na.rm = TRUE),
        sd    = sd(.data[[value_col]], na.rm = TRUE),
        count = n(),
        .groups = "drop"
      ) |>
      dplyr::arrange(date) |>
      dplyr::filter(!is.na(y))

    # PATCH: clamp y values to [0, 100] for CPU metrics
    prepared$y   <- pmax(0, pmin(100, prepared$y))
    prepared$min <- pmax(0, pmin(100, prepared$min))
    prepared$max <- pmax(0, pmin(100, prepared$max))

    if (nrow(prepared) < min_observations)
      return(list(success = FALSE, data = prepared,
                  error = "Insufficient clean data after aggregation"))

    list(success = TRUE, data = prepared, error = NULL)
  }, error = function(e) {
    list(success = FALSE, data = data.frame(),
         error = "Data preparation failed. Check input format.")
  })
}

# VULNERABILITY FIXED: original function was named detect_anomalies, which
# shadows the detect_anomalies parameter in train_forecast_usage — calling
# detect_anomalies(daily) inside the function called itself recursively if
# detect_anomalies=TRUE was passed.
find_anomalies <- function(ts_data, threshold = 1.5) {
  threshold <- max(0.5, min(5.0, as.numeric(threshold %||% 1.5)))
  if (!is.data.frame(ts_data) || nrow(ts_data) < 5L) return(data.frame())

  Q1    <- quantile(ts_data$y, 0.25, na.rm = TRUE)
  Q3    <- quantile(ts_data$y, 0.75, na.rm = TRUE)
  IQR   <- Q3 - Q1
  lower <- Q1 - threshold * IQR
  upper <- Q3 + threshold * IQR

  ts_data |>
    dplyr::mutate(
      is_anomaly   = y < lower | y > upper,
      anomaly_type = dplyr::case_when(
        y < lower ~ "low",
        y > upper ~ "high",
        TRUE      ~ NA_character_
      )
    ) |>
    dplyr::filter(is_anomaly)
}

calculate_metrics <- function(
    actual, predicted, metric = c("rmse", "mae", "mape")) {
  metric <- match.arg(metric, several.ok = TRUE)
  # PATCH: validate inputs are numeric vectors of same length
  if (!is.numeric(actual) || !is.numeric(predicted))
    stop("actual and predicted must be numeric vectors.")
  if (length(actual) != length(predicted))
    stop("actual and predicted must have the same length.")

  results <- list()
  if ("rmse" %in% metric)
    results$rmse <- sqrt(mean((actual - predicted)^2, na.rm = TRUE))
  if ("mae"  %in% metric)
    results$mae  <- mean(abs(actual - predicted), na.rm = TRUE)
  if ("mape" %in% metric) {
    nonzero <- actual != 0
    results$mape <- if (any(nonzero))
      mean(abs((
                actual[nonzero] - predicted[nonzero]) / actual[nonzero]),
      na.rm = TRUE
      ) * 100
    else NA_real_
  }
  results
}

forecast_prophet <- function(daily_data, periods = 7L) {
  periods <- .validate_periods(periods)
  if (!requireNamespace("prophet", quietly = TRUE))
    return(list(
      success = FALSE, data = data.frame(),
      error = "prophet package not available"
    ))

  tryCatch({
    dfp <- daily_data |>
      dplyr::rename(ds = date, y = y) |>
      dplyr::select(ds, y)
    m <- prophet::prophet(dfp, yearly.seasonality = FALSE,
                          weekly.seasonality = TRUE,
                          daily.seasonality  = FALSE,
                          interval.width     = 0.95)
    future <- prophet::make_future_dataframe(m, periods = periods, freq = "day")
    fc <- prophet::predict(m, future)

    fc_res <- fc |>
      dplyr::filter(ds > max(dfp$ds)) |>
      dplyr::transmute(
        date  = as.Date(ds),
        yhat  = pmax(0, pmin(100, yhat)),
        lower = pmax(0, pmin(100, yhat_lower)),
        upper = pmax(0, pmin(100, yhat_upper)),
        trend = trend
      )
    list(success = TRUE, data = fc_res, model = m, error = NULL)
  }, error = function(e) {
    list(success = FALSE, data = data.frame(), model = NULL,
         error = "Prophet forecasting failed.")
  })
}

forecast_arima <- function(daily_data, periods = 7L) {
  periods <- .validate_periods(periods)
  if (!requireNamespace("forecast", quietly = TRUE))
    return(list(
      success = FALSE, data = data.frame(),
      error = "forecast package not available"
    ))

  tryCatch({
    ts_series <- stats::ts(daily_data$y, frequency = 7L)
    fit       <- forecast::auto.arima(
      ts_series, stepwise = TRUE, approximation = FALSE
    )
    fc        <- forecast::forecast(fit, h = periods, level = c(80L, 95L))

    last_date <- max(daily_data$date)
    dates     <- seq(last_date + 1L, by = "day", length.out = periods)

    forecast_df <- data.frame(
      date     = as.Date(dates),
      yhat     = pmax(0, pmin(100, as.numeric(fc$mean))),
      lower80  = pmax(0, as.numeric(fc$lower[, 1])),
      upper80  = pmin(100, as.numeric(fc$upper[, 1])),
      lower95  = pmax(0, as.numeric(fc$lower[, 2])),
      upper95  = pmin(100, as.numeric(fc$upper[, 2])),
      stringsAsFactors = FALSE
    )
    list(success = TRUE, data = forecast_df, model = fit, error = NULL)
  }, error = function(e) {
    list(success = FALSE, data = data.frame(), model = NULL,
         error = "ARIMA forecasting failed.")
  })
}
 
forecast_exp_smoothing <- function(daily_data, periods = 7L) {
  periods <- .validate_periods(periods)
  if (!requireNamespace("forecast", quietly = TRUE))
    return(list(success = FALSE, data = data.frame(),
      error = "forecast package not available"
  ))

  tryCatch({
    fit  <- forecast::ets(stats::ts(daily_data$y, frequency = 7L))
    fc   <- forecast::forecast(fit, h = periods, level = c(80L, 95L))

    last_date <- max(daily_data$date)
    dates     <- seq(last_date + 1L, by = "day", length.out = periods)

    forecast_df <- data.frame(
      date    = as.Date(dates),
      yhat    = pmax(0, pmin(100, as.numeric(fc$mean))),
      lower80 = pmax(0, as.numeric(fc$lower[, 1])),
      upper80 = pmin(100, as.numeric(fc$upper[, 1])),
      lower95 = pmax(0, as.numeric(fc$lower[, 2])),
      upper95 = pmin(100, as.numeric(fc$upper[, 2])),
      stringsAsFactors = FALSE
    )
    list(success = TRUE, data = forecast_df, model = fit, error = NULL)
  }, error = function(e) {
    list(success = FALSE, data = data.frame(), model = NULL,
         error = "ETS forecasting failed.")
  })
}
 
ensemble_forecast <- function(daily_data, periods = 7L,
                              methods = c("arima","prophet","ets")) {
  periods   <- .validate_periods(periods)
  forecasts <- list()
 
  for (method in methods) {
    result <- switch(method,
      "arima"   = forecast_arima(daily_data, periods),
      "prophet" = forecast_prophet(daily_data, periods),
      "ets"     = forecast_exp_smoothing(daily_data, periods),
      list(success = FALSE, data = data.frame())
    )
    if (result$success) forecasts[[method]] <- result$data$yhat
  }
  if (length(forecasts) == 0)
    return(list(
      success = FALSE, data = data.frame(),
      error = "No forecast methods succeeded"
    ))

  ensemble_mean <- rowMeans(do.call(cbind, forecasts), na.rm = TRUE)
  last_date     <- max(daily_data$date)
  dates         <- seq(last_date + 1L, by = "day", length.out = periods)
  list(
    success = TRUE,
    data = data.frame(date = as.Date(dates),
                      yhat = pmax(0, pmin(100, ensemble_mean)),
                      methods_used = length(forecasts),
                      stringsAsFactors = FALSE),
    individual_forecasts = forecasts,
    error                = NULL
  )
}

train_forecast_usage <- function(usage_df, periods = 7L,
                                 method = c("auto_arima",
                                   "prophet",
                                   "ensemble"
                                 ),
                                 timestamp_col  = "timestamp",
                                 value_col      = "cpu_avg",
                                 detect_anomalies = TRUE,
                                 return_metrics   = TRUE) {
  method  <- match.arg(method)
  periods <- .validate_periods(periods)

  prep_result <- prepare_time_series(
    usage_df, timestamp_col,
    value_col, min_observations = 5L
  )
  if (!prep_result$success)
    return(list(original = data.frame(), forecast = data.frame(),
                anomalies = data.frame(),
                metrics = NULL, error = prep_result$error))

  daily <- prep_result$data

  anomalies <- if (isTRUE(detect_anomalies))
    find_anomalies(daily) else data.frame()
  fc_result <- switch(method,
    "prophet"    = forecast_prophet(daily, periods),
    "auto_arima" = forecast_arima(daily, periods),
    "ensemble"   = ensemble_forecast(daily, periods),
    list(success = FALSE, data = data.frame(), error = "Unknown method")
  )

  if (!fc_result$success)
    return(list(original = daily, forecast = data.frame(),
                anomalies = anomalies, metrics = NULL, error = fc_result$error))

  metrics <- NULL
  if (return_metrics && !is.null(fc_result$model)) {
    tryCatch({
      fitted_vals <- as.numeric(fc_result$model$fitted)
      if (length(fitted_vals) > 0)
        metrics <- calculate_metrics(
          daily$y, fitted_vals,
          metric = c("rmse", "mae", "mape")
        )
    }, error = function(e) NULL)
  }

  list(original  = daily,
       forecast  = fc_result$data,
       anomalies = anomalies,
       metrics   = metrics,
       error     = NULL,
       method    = method)
}
