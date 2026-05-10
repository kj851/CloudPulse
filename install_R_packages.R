#!/usr/bin/env Rscript
# This script must be run with Rscript, not with 'bash'.
# example:
#   sudo Rscript install_R_packages.R

options(repos = c(CRAN = "https://cloud.r-project.org"), timeout = 600)

pkgs <- c(
  # core app packages
  "shiny","plotly","dplyr","DT","ggridges","ggplot2","bslib", # nolint
  # language server for editor/IDE
  "languageserver",
  # forecasting
  "forecast", "prophet", "future",
  # forecast (ARIMA) required; prophet optional if you want Meta Prophet
  # AWS & specific paws service packages (install only required services)
  "aws.s3",
  # Azure
  "AzureRMR","AzureAuth","AzureStor",
  # GCP
  "googleAuthR","googleCloudStorageR","bigrquery","httr","jsonlite",
  # DB and auth
  "DBI","RPostgres","keyring"
)

# Packages to skip because they are known 
# to pull many deps or hang in some environments
skip_pkgs <- c("paws", "paws.analytics")

failed_log <- "/tmp/install_R_failed.txt"
if (file.exists(failed_log)) file.remove(failed_log)

install_if_missing <- function(pkg, retries = 2) {
  if (pkg %in% skip_pkgs) {
    message("Skipping meta/problematic package: ", pkg)
    return(invisible(FALSE))
  }
  if (!requireNamespace(pkg, quietly = TRUE)) {
    message("Installing ", pkg, " ...")
    for (i in seq_len(retries)) {
      tryCatch({
        install.packages(pkg, dependencies = TRUE, 
                         Ncpus = max(1, parallel::detectCores() - 1))
        if (requireNamespace(pkg, quietly = TRUE)) {
          message("Installed ", pkg)
          return(invisible(TRUE))
        }
      }, error = function(e) {
        message(sprintf("Attempt %d failed for 
        %s: %s", i, pkg, conditionMessage(e)))
      })
      Sys.sleep(2) # brief pause between retries
    }
    msg <- sprintf("%s\tFAILED\n", pkg)
    cat(msg, file = failed_log, append = TRUE)
    message("Failed to install ", pkg, ". See ", failed_log)
    return(invisible(FALSE))
  } else {
    message(pkg, " already installed")
    return(invisible(TRUE))
  }
}

for (p in pkgs) install_if_missing(p)

# Try fallback for failed paws.* packages using remotes::install_github
if (file.exists(failed_log)) {
  failed <- trimws(gsub("\\tFAILED.*", "", readLines(failed_log)))
  # ensure remotes available
  if (!requireNamespace("remotes", quietly = TRUE)) {
    message("Installing 'remotes' to enable GitHub installs...")
    tryCatch(install.packages("remotes", dependencies = TRUE),
             error = function(e) message("remotes install failed: ", conditionMessage(e)))
  }
  # prefer explicit per-package GitHub repos for the known failing packages
  gh_targets <- c(
    "paws.rds" = "paws-r/paws.rds",
    "paws.cloudwatch" = "paws-r/paws.cloudwatch",
    "paws.cost_explorer" = "paws-r/paws.cost_explorer"
  )
  for (pkg in intersect(failed, names(gh_targets))) {
    repo <- gh_targets[[pkg]]
    if (!requireNamespace(pkg, quietly = TRUE)) {
      message("Attempting GitHub install for ", pkg, " from ", repo)
      tryCatch({
        remotes::install_github(repo, dependencies = TRUE, upgrade = 
                                  "never", INSTALL_opts = c("--no-multiarch"))
        if (requireNamespace(pkg, quietly = TRUE)) {
          message("Installed ", pkg, " from GitHub (", repo, ")")
        } else {
          message("GitHub install attempted but package not 
          available after install: ", pkg)
        }
      }, error = function(e) {
        message("Failed to install ",pkg, " from GitHub: ", conditionMessage(e))
      })
    } else {
      message(pkg, " is already available after initial install attempt")
    }
  }

  # If any paws.* still missing, also try installing the paws meta-package 
  # from GitHub as a last resort
  remaining_paws <- grep("^paws\\.", failed, value = TRUE)
  if (length(remaining_paws) > 0) {
    message("Attempting a GitHub install of 
    the paws meta-package (may pull many subpackages).")
    tryCatch({
      remotes::install_github("paws-r/paws", dependencies = TRUE, upgrade = 
                                "never", INSTALL_opts = c("--no-multiarch"))
    }, error = function(e) {
      message("paws meta-package GitHub install failed: ", conditionMessage(e))
    })
  }
}

message("R package installation script finished. Inspect messages above and ",
        failed_log, " for failures.")
message("If service packages still fail, check your R version 
        (R --version) and consider upgrading R, then re-run this script.")
message("If you need to install skipped packages (e.g. 'paws'), 
        run the install command manually and monitor logs:")
message("  sudo Rscript -e \"install.packages('paws', 
        repos='https://cloud.r-project.org')\"")
