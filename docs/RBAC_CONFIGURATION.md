# CloudPulse RBAC Configuration Reference
# Customize roles, permissions, and settings
# Author: Keaton Szantho

## Overview

This guide explains how to customize and configure the RBAC system for your specific needs.

## 1. Configuring Roles

### Modifying Existing Roles

Edit `lib/rbac.R` in the `RBAC_ROLES` list:

```R
RBAC_ROLES <- list(
  admin = list(
    display_name = "Administrator",
    permissions = c(
      # Add or remove permissions here
      "user:create", "user:read", "user:update", "user:delete",
      "cost:view_all",
      # ... more permissions
    ),
    description = "Full platform access..."
  ),
  # Other roles...
)
```

### Creating New Roles

Add to the `RBAC_ROLES` list:

```R
RBAC_ROLES <- list(
  # ... existing roles ...
  
  custom_role = list(
    display_name = "Custom Role Name",
    permissions = c(
      "cost:view_all",
      "report:generate",
      "k8s:view_nodes"
    ),
    description = "Description of what this role can do"
  )
)
```

Then update validation in functions:

```R
# In authenticate_user and other validation functions
if (!(role %in% c("admin", "finops_analyst", "devops_engineer", "viewer", "custom_role"))) {
  return(list(success = FALSE, error = "Invalid role."))
}
```

## 2. Configuring Permissions

### Adding New Permissions

1. Define the permission string in `lib/rbac.R`:
```R
# Add to relevant roles
admin = list(
  permissions = c(
    # ... existing permissions ...
    "new_resource:new_action"  # New permission
  )
)
```

2. Use in permission checks:
```R
has_permission(user_role, "new_resource:new_action")
```

3. Add endpoint check in `api/rbac_middleware.R`:
```R
# Update endpoint mapping
endpoint_mapping <- list(
  admin = c(
    "/endpoint/with/new/permission",
    # ... other endpoints
  )
)
```

### Permission Categories

Organize permissions by resource:

```
User:        user:create, user:read, user:update, user:delete
Cloud:       cloud:configure, cloud:list, cloud:delete
Cost:        cost:view_all, cost:view_own, cost:export
Kubernetes:  cluster:view_all, k8s:manage_alerts
Infrastructure: metric:view_infrastructure
Reporting:   report:generate, report:view_all
System:      system:settings, system:audit_log
```

## 3. Session Configuration

### Adjust Session Timeout

In `lib/FInOpsApp.R`:

```R
# Default: 1 hour (3600 seconds)
session_timeout <- 3600L  # Change to desired seconds

# Update the timer
session_timer <- reactiveTimer(60000)  # 60 seconds check interval
```

Example timeouts:
- `900L` = 15 minutes
- `1800L` = 30 minutes
- `3600L` = 1 hour (default)
- `7200L` = 2 hours

### Auto-Logout Configuration

```R
observe({
  session_timer()
  if (user_authenticated()) {
    idle <- as.numeric(difftime(Sys.time(), last_activity_time(), units = "secs"))
    
    if (idle > session_timeout) {
      # Customize auto-logout behavior
      user_authenticated(FALSE)
      showNotification("Your session has expired. Please log in again.",
        type = "warning", duration = 10)
    }
  }
})
```

## 4. Login Configuration

### Adjust Login Rate Limiting

In `lib/FInOpsApp.R`:

```R
# Default: 5 attempts
max_login_attempts <- 5L  # Change to desired number

# Default: 20 minutes (1200 seconds)
lockout_seconds <- 1200L  # Change to desired seconds

# Example: 3 attempts, 10-minute lockout
max_login_attempts <- 3L
lockout_seconds <- 600L
```

### Customize Login UI

Edit `lib/login_ui.R`:

```R
login_ui <- function() {
  # Customize colors
  div(
    style = "background: linear-gradient(135deg, #YOUR_COLOR_1 0%, #YOUR_COLOR_2 50%);",
    # ... rest of UI
  )
}

# Change demo credentials display
details(
  summary = "📋 Demo Credentials",
  # Customize demo user information shown
)
```

## 5. Password Policy Configuration

### Minimum Password Length

In `lib/auth.R`:

```R
create_user <- function(username, password, email, role, display_name = NULL, db_path = NULL) {
  # Default: 8 characters
  if (nchar(password) < 8) {  # Change to desired length
    return(list(success = FALSE, error = "Password must be at least 8 characters."))
  }
}
```

### Add Password Complexity Requirements

```R
validate_password <- function(password) {
  # Require at least one uppercase, one digit, one special char
  has_upper <- grepl("[A-Z]", password)
  has_lower <- grepl("[a-z]", password)
  has_digit <- grepl("[0-9]", password)
  has_special <- grepl("[!@#$%^&*]", password)
  
  if (!all(c(has_upper, has_lower, has_digit, has_special))) {
    return(list(
      success = FALSE,
      error = "Password must contain uppercase, lowercase, digit, and special character"
    ))
  }
  
  list(success = TRUE)
}
```

## 6. Database Configuration

### Change Database Location

In your main app file:

```R
# Default: NULL (demo users)
RBAC_DB_PATH <- "cloudpulse_users.db"  # Change to desired path

# Use in auth functions
authenticate_user(username, password, db_path = RBAC_DB_PATH)
```

### Custom Database Setup

```R
# Initialize custom database
initialize_rbac_db <- function(db_path) {
  library(RSQLite)
  library(DBI)
  
  schema <- readLines("setup/rbac_schema.sql")
  schema_text <- paste(schema, collapse = "\n")
  
  conn <- dbConnect(SQLite(), db_path)
  dbExecute(conn, schema_text)
  dbDisconnect(conn)
  
  message(sprintf("Database initialized at %s", db_path))
}

# Use it
initialize_rbac_db("my_cloudpulse.db")
```

## 7. API Configuration

### API Key Management

Set environment variable:

```bash
# In your shell or .Renviron
export CLOUDPULSE_API_KEY="your-random-strong-key-here"
```

Or in R:

```R
Sys.setenv(CLOUDPULSE_API_KEY = "your-random-strong-key-here")
```

### Customize API Authentication

In `api/rbac_middleware.R`:

```R
authenticate_api_request <- function(req, res) {
  # Add custom authentication logic
  
  # Example: Check for custom header
  custom_auth <- req$HTTP_X_CUSTOM_AUTH %||% ""
  
  if (nzchar(custom_auth)) {
    # Validate custom auth
    return(validate_custom_auth(custom_auth))
  }
  
  # Fall back to standard auth
  # ...
}
```

## 8. Audit Logging Configuration

### Custom Audit Log Path

```R
log_api_action <- function(user_id, action, resource_type, resource_id, 
                           status = "success", details = NULL, db_path = NULL) {
  
  # Custom logging to file
  log_file <- "logs/audit.log"
  
  log_entry <- sprintf(
    "[%s] User: %s | Action: %s | Resource: %s/%s | Status: %s\n",
    format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    user_id, action, resource_type, resource_id, status
  )
  
  cat(log_entry, file = log_file, append = TRUE)
}
```

### Audit Log Rotation

```R
rotate_audit_logs <- function(days = 30, max_files = 12) {
  log_dir <- "logs"
  log_files <- list.files(log_dir, pattern = "^audit.*\\.log$")
  
  for (file in log_files) {
    full_path <- file.path(log_dir, file)
    file_age <- as.numeric(Sys.time() - file.mtime(full_path), units = "days")
    
    if (file_age > days) {
      file.remove(full_path)
      message(sprintf("Removed old audit log: %s", file))
    }
  }
}

# Run daily
schedule::at("23:59", rotate_audit_logs())
```

## 9. Multi-Tenant Configuration

### Add Organization Support

Extend the user table:

```sql
-- Add to rbac_schema.sql
ALTER TABLE users ADD COLUMN organization_id INTEGER;
ALTER TABLE users ADD COLUMN department TEXT;

CREATE TABLE organizations (
  org_id INTEGER PRIMARY KEY,
  org_name TEXT NOT NULL,
  created_at TIMESTAMP
);
```

### Filter Data by Organization

```R
# In API endpoints
#* Get organization data
#* @get /org/<org_id>/cost
function(req, res, org_id) {
  
  # Check if user belongs to this organization
  if (!user_in_organization(req$user$user_id, org_id)) {
    res$status <- 403
    return(list(error = "Insufficient permissions"))
  }
  
  # Return organization-specific data
}
```

## 10. Custom Permission Groups

### Create Permission Aliases

In `lib/rbac.R`:

```R
# Define permission groups for easier assignment
PERMISSION_GROUPS <- list(
  analyst_basic = c("cost:view_all", "report:generate"),
  analyst_advanced = c("cost:view_all", "cost:export", "report:generate", "recommendation:view"),
  engineer_junior = c("cluster:view_all", "metric:view_infrastructure"),
  engineer_senior = c("cluster:view_all", "cluster:manage", "alert:manage")
)

# Use in role definitions
admin = list(
  permissions = PERMISSION_GROUPS$analyst_advanced,  # Use group
  # ... rest of role
)
```

## 11. Notification Configuration

### Customize Login Notifications

```R
setup_login_server <- function(...) {
  observeEvent(input$login_button, {
    # On success
    showNotification(
      sprintf("Welcome back, %s!", result$display_name),
      type = "message",
      duration = 10,  # Duration in seconds
      closeButton = TRUE
    )
    
    # On failure
    showNotification(
      "Login failed. Check your credentials.",
      type = "error",
      duration = 5
    )
  })
}
```

## 12. Testing Configuration

### Enable Debug Mode

```R
# Add to lib/rbac.R
DEBUG_MODE <- Sys.getenv("DEBUG", "false") == "true"

# Use in functions
if (DEBUG_MODE) {
  message(sprintf("Checking permission: %s for role: %s", permission, user_role))
}
```

Enable in tests:

```bash
DEBUG=true Rscript test_rbac.R
```

## Examples

### Example 1: Custom Role for Auditors

```R
# In lib/rbac.R
audit_role = list(
  display_name = "Auditor",
  permissions = c(
    "user:list",
    "cost:view_all",
    "metric:view_infrastructure",
    "system:audit_log"
  ),
  description = "Read-only access for compliance auditing"
)
```

### Example 2: Temporary Access Permission

```R
# Add expiring permission to database
user_cloud_access <- data.frame(
  user_id = 123,
  provider = "AWS",
  account_id = "123456789",
  access_level = "read",
  expires_at = format(Sys.time() + 86400*7, "%Y-%m-%d %H:%M:%S")  # 7 days
)

# Check if permission is expired
if (!is.na(expires_at) && Sys.time() > expires_at) {
  # Permission expired
}
```

### Example 3: Role-Specific API Endpoints

```R
# Only expose certain endpoints per role
get_allowed_endpoints <- function(user_role) {
  endpoints <- list(
    admin = c("/users", "/users/*", "/settings", "/audit"),
    finops_analyst = c("/cost", "/forecast", "/report"),
    devops_engineer = c("/k8s/clusters", "/k8s/pods", "/alerts"),
    viewer = c("/dashboard", "/report")
  )
  
  endpoints[[user_role]] %||% character(0)
}
```

## Performance Tuning

### Cache Role Permissions

```R
role_cache <- new.env()

get_role_with_cache <- function(user_id) {
  if (exists(user_id, envir = role_cache)) {
    return(get(user_id, envir = role_cache))
  }
  
  # Fetch from database
  role <- fetch_user_role(user_id)
  
  # Cache for 1 hour
  assign(user_id, role, envir = role_cache)
  
  role
}
```

### Optimize Permission Checks

```R
# Memoize permission checks
has_permission_cached <- function(user_role, permission) {
  cache_key <- paste0(user_role, ":", permission)
  
  if (exists(cache_key, envir = perm_cache)) {
    return(get(cache_key, envir = perm_cache))
  }
  
  result <- has_permission(user_role, permission)
  assign(cache_key, result, envir = perm_cache)
  
  result
}
```

## Troubleshooting Configuration

### Check Current Configuration

```R
# List all roles
list_all_roles()

# Get role details
get_role_permissions("admin")

# Test permission
has_permission("admin", "user:create")

# Check endpoints
is_endpoint_allowed("devops_engineer", "/k8s/clusters")
```

### Debug Configuration

```R
# Enable detailed logging
DEBUG_MODE <- TRUE

# Trace permission check
trace_permission <- function(user_role, permission) {
  role_data <- RBAC_ROLES[[user_role]]
  is_allowed <- permission %in% role_data$permissions
  
  cat(sprintf(
    "Role: %s | Permission: %s | Allowed: %s\n",
    user_role, permission, is_allowed
  ))
  
  is_allowed
}
```

---

**Remember**: After modifying RBAC configuration, test thoroughly with all affected roles!
