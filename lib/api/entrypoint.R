# CloudPulse API — entrypoint
# Run from project root: Rscript api/entrypoint.R

library(plumber)

# Configuration
HOST <- Sys.getenv("CLOUDPULSE_API_HOST", unset = "127.0.0.1")
PORT <- as.integer(Sys.getenv("CLOUDPULSE_API_PORT", unset = "8000"))

if (!nzchar(Sys.getenv("CLOUDPULSE_API_KEY"))) {
  message(
    "[CloudPulse API] Warning: CLOUDPULSE_API_KEY is not set.\n",
    "  Set it before starting in production:\n",
    "  Sys.setenv(CLOUDPULSE_API_KEY = 'your-secret-key')\n",
    "  Running without authentication (dev mode)."
  )
}

# Build and start the API server
api <- plumber::plumb(file.path("api", "plumber.R"))

api$setDocs(TRUE)   # Swagger UI at http://host:port/__docs__/

api$registerHooks(list(
  preroute = function(data, req, res) {
    cat(sprintf(
      "[%s] %s %s\n",
      format(Sys.time(), "%H:%M:%S"),
      req$REQUEST_METHOD,
      req$PATH_INFO
    ))
  }
))

message(sprintf(
  "[CloudPulse API] Starting on http://%s:%d\n  Docs: http://%s:%d/__docs__/",
  HOST, PORT, HOST, PORT
))

api$run(host = HOST, port = PORT)
