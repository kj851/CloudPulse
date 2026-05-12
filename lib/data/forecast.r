# Forecasting functions for CloudPulse FinOps Dashboard
# This module provides functions to prepare time series data, find anomalies,
# and generate forecasts using Prophet, ARIMA, and Exponential Smoothing.

library(dplyr)

prepare_time_series <- function(df, timestamp_col = "timestamp", value_col = "cpu_avg", 
                                frequency = "day", min_observations = 14) {
  if (is.null(df) || nrow(df) < min_observations) {
    return(list(success = FALSE, data = data.frame(), error = "Insufficient data"))
  }
  
  tryCatch({
    prepared <- df |>
      dplyr::mutate(date = as.Date(get(timestamp_col))) |>
      dplyr::group_by(date) |>
      dplyr::summarise(
        y = mean(get(value_col), na.rm = TRUE),
        min = min(get(value_col), na.rm = TRUE),
        max = max(get(value_col), na.rm = TRUE),
        sd = sd(get(value_col), na.rm = TRUE),
        count = n(),
        .groups = "drop"
      ) |>
      dplyr::arrange(date) |>
      dplyr::filter(!is.na(y))
    
    if (nrow(prepared) < min_observations) {
      return(list(success = FALSE, data = prepared, error = "Insufficient clean data after aggregation"))
    }
    
    list(success = TRUE, data = prepared, error = NULL)
  }, error = function(e) {
    list(success = FALSE, data = data.frame(), error = paste("Data preparation failed:", conditionMessage(e)))
  })
}

# Detect anomalies using IQR method
detect_anomalies <- function(ts_data, threshold = 1.5) {
  if (nrow(ts_data) < 5) return(data.frame())
  
  Q1 <- quantile(ts_data$y, 0.25, na.rm = TRUE)
  Q3 <- quantile(ts_data$y, 0.75, na.rm = TRUE)
  IQR <- Q3 - Q1
  lower_bound <- Q1 - threshold * IQR
  upper_bound <- Q3 + threshold * IQR
  
  ts_data |>
    dplyr::mutate(
      is_anomaly = y < lower_bound | y > upper_bound,
      anomaly_type = dplyr::case_when(
        y < lower_bound ~ "low",
        y > upper_bound ~ "high",
        TRUE ~ NA_character_
      )
    ) |>
    dplyr::filter(is_anomaly)
}

# Calculate forecast accuracy metrics
calculate_metrics <- function(actual, predicted, metric = c("rmse", "mae", "mape")) {
  metric <- match.arg(metric, several.ok = TRUE)
  results <- list()
  
  if ("rmse" %in% metric) {
    results$rmse <- sqrt(mean((actual - predicted) ^ 2, na.rm = TRUE))
  }
  if ("mae" %in% metric) {
    results$mae <- mean(abs(actual - predicted), na.rm = TRUE)
  }
  if ("mape" %in% metric) {
    results$mape <- mean(abs((actual - predicted) / actual), na.rm = TRUE) * 100
  }
  
  results
}

# Prophet forecasting with error handling
forecast_prophet <- function(daily_data, periods = 7) {
  if (!requireNamespace("prophet", quietly = TRUE)) {
    return(list(success = FALSE, data = data.frame(), error = "prophet package not available"))
  }
  
  tryCatch({
    dfp <- daily_data |> 
      dplyr::rename(ds = date, y = y) |>
      dplyr::select(ds, y)
    
    m <- prophet::prophet(
      dfp, 
      yearly.seasonality = FALSE, 
      weekly.seasonality = TRUE, 
      daily.seasonality = FALSE,
      interval.width = 0.95
    )
    
    future <- prophet::make_future_dataframe(m, periods = periods, freq = "day")
    fc <- prophet::predict(m, future)
    
    fc_res <- fc |>
      dplyr::filter(ds > max(dfp$ds)) |>
      dplyr::transmute(
        date = as.Date(ds),
        yhat = yhat,
        lower = yhat_lower,
        upper = yhat_upper,
        trend = trend
      )
    
    list(success = TRUE, data = fc_res, model = m, error = NULL)
  }, error = function(e) {
    list(success = FALSE, data = data.frame(), model = NULL, 
         error = paste("Prophet failed:", conditionMessage(e)))
  })
}

# ARIMA forecasting with auto model selection
forecast_arima <- function(daily_data, periods = 7) {
  if (!requireNamespace("forecast", quietly = TRUE)) {
    return(list(success = FALSE, data = data.frame(), error = "forecast package not available"))
  }
  
  tryCatch({
    ts_series <- stats::ts(daily_data$y, frequency = 7)
    fit <- forecast::auto.arima(ts_series, stepwise = TRUE, approximation = FALSE)
    fc <- forecast::forecast(fit, h = periods, level = c(80, 95))
    
    last_date <- max(daily_data$date)
    dates <- seq(last_date + 1, by = "day", length.out = periods)
    
    forecast_df <- data.frame(
      date = as.Date(dates),
      yhat = as.numeric(fc$mean),
      lower80 = as.numeric(fc$lower[, 1]),
      upper80 = as.numeric(fc$upper[, 1]),
      lower95 = as.numeric(fc$lower[, 2]),
      upper95 = as.numeric(fc$upper[, 2]),
      stringsAsFactors = FALSE
    )
    
    list(success = TRUE, data = forecast_df, model = fit, error = NULL)
  }, error = function(e) {
    list(success = FALSE, data = data.frame(), model = NULL,
         error = paste("ARIMA failed:", conditionMessage(e)))
  })
}

# Exponential smoothing
forecast_exp_smoothing <- function(daily_data, periods = 7) {
  if (!requireNamespace("forecast", quietly = TRUE)) {
    return(list(success = FALSE, data = data.frame(), error = "forecast package not available"))
  }
  
  tryCatch({
    fit <- forecast::ets(ts(daily_data$y, frequency = 7))
    fc <- forecast::forecast(fit, h = periods, level = c(80, 95))
    
    last_date <- max(daily_data$date)
    dates <- seq(last_date + 1, by = "day", length.out = periods)
    
    forecast_df <- data.frame(
      date = as.Date(dates),
      yhat = as.numeric(fc$mean),
      lower80 = as.numeric(fc$lower[, 1]),
      upper80 = as.numeric(fc$upper[, 1]),
      lower95 = as.numeric(fc$lower[, 2]),
      upper95 = as.numeric(fc$upper[, 2]),
      stringsAsFactors = FALSE
    )
    
    list(success = TRUE, data = forecast_df, model = fit, error = NULL)
  }, error = function(e) {
    list(success = FALSE, data = data.frame(), model = NULL,
         error = paste("ETS failed:", conditionMessage(e)))
  })
}

# Ensemble forecast combining multiple methods
ensemble_forecast <- function(daily_data, periods = 7, methods = c("arima", "prophet", "ets")) {
  forecasts <- list()
  weights <- list()
  
  for (method in methods) {
    result <- switch(method,
      "arima" = forecast_arima(daily_data, periods),
      "prophet" = forecast_prophet(daily_data, periods),
      "ets" = forecast_exp_smoothing(daily_data, periods),
      list(success = FALSE, data = data.frame())
    )
    
    if (result$success) {
      forecasts[[method]] <- result$data$yhat
    }
  }
  
  if (length(forecasts) == 0) {
    return(list(success = FALSE, data = data.frame(), error = "No methods succeeded"))
  }
  
  # Average ensemble
  ensemble_mean <- rowMeans(do.call(cbind, forecasts), na.rm = TRUE)
  
  last_date <- max(daily_data$date)
  dates <- seq(last_date + 1, by = "day", length.out = periods)
  
  ensemble_df <- data.frame(
    date = as.Date(dates),
    yhat = ensemble_mean,
    methods_used = length(forecasts),
    stringsAsFactors = FALSE
  )
  
  list(success = TRUE, data = ensemble_df, individual_forecasts = forecasts, error = NULL)
}

# Main comprehensive forecasting function
train_forecast_usage <- function(usage_df, periods = 7, method = c("auto_arima", "prophet", "ensemble"),
                                 timestamp_col = "timestamp", value_col = "cpu_avg",
                                 detect_anomalies = TRUE, return_metrics = TRUE) {
  method <- match.arg(method)
  
  # Prepare data
  prep_result <- prepare_time_series(usage_df, timestamp_col, value_col, min_observations = 8)
  if (!prep_result$success) {
    return(list(
      original = data.frame(),
      forecast = data.frame(),
      anomalies = data.frame(),
      metrics = NULL,
      error = prep_result$error
    ))
  }
  
  daily <- prep_result$data
  
  # Detect anomalies
  anomalies <- if (detect_anomalies) detect_anomalies(daily) else data.frame()
  
  # Generate forecast
  fc_result <- switch(method,
    "prophet" = forecast_prophet(daily, periods),
    "auto_arima" = forecast_arima(daily, periods),
    "ensemble" = ensemble_forecast(daily, periods),
    list(success = FALSE, data = data.frame(), error = "Unknown method")
  )
  
  if (!fc_result$success) {
    return(list(
      original = daily,
      forecast = data.frame(),
      anomalies = anomalies,
      metrics = NULL,
      error = fc_result$error
    ))
  }
  
  # Calculate metrics on training data if model available
  metrics <- NULL
  if (return_metrics && !is.null(fc_result$model)) {
    tryCatch({
      fitted_values <- as.numeric(fc_result$model$fitted)
      if (length(fitted_values) > 0) {
        metrics <- calculate_metrics(daily$y, fitted_values, metric = c("rmse", "mae", "mape"))
      }
    }, error = function(e) NULL)
  }
  
  list(
    original = daily,
    forecast = fc_result$data,
    anomalies = anomalies,
    metrics = metrics,
    error = NULL,
    method = method
  )
}
