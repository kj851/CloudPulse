# RBAC Implementation Guide for CloudPulse
# Complete instructions for integrating Role-Based Access Control
# Author: Keaton Szantho | Date: 2026-06-04

## Overview

The CloudPulse RBAC system provides enterprise-grade role-based access control with four roles:

- **Admin**: Full platform access, user management, cloud account configuration
- **FinOps Analyst**: Cost analysis and reporting, read-only infrastructure access
- **DevOps Engineer**: Kubernetes management, alerts, infrastructure metrics
- **Viewer**: Read-only access to assigned resources

## Architecture

### Components

1. **lib/rbac.R** - Role definitions and permission checking functions
2. **lib/auth.R** - User authentication and password management
3. **lib/login_ui.R** - Login UI and session management
4. **api/rbac_middleware.R** - API authentication and authorization middleware
5. **setup/rbac_schema.sql** - Database schema for users and roles

## Integration Steps

### 1. Initialize the Database

```R
# In R console or setup script
library(RSQLite)
library(DBI)

# Create the database
db_path <- "cloudpulse_users.db"

# Read and execute the schema
schema <- readLines("setup/rbac_schema.sql")
schema_text <- paste(schema, collapse = "\n")

# Execute schema
conn <- dbConnect(SQLite(), db_path)
dbExecute(conn, schema_text)
dbDisconnect(conn)

# Database is now ready with default admin user
```

### 2. Update Shiny App (FInOpsApp.R)

Add these sources at the top of the server function:

```R
# Load RBAC modules
source("lib/rbac.R")
source("lib/auth.R")
source("lib/login_ui.R")

server <- function(input, output, session) {
  # RBAC reactive values
  user_authenticated     <- reactiveVal(FALSE)
  current_user_data      <- reactiveVal(NULL)
  login_attempts_rv      <- reactiveVal(0L)
  last_attempt_time_rv   <- reactiveVal(NULL)
  
  # Setup login server logic
  setup_login_server(
    input, output, session,
    user_authenticated,
    current_user_data,
    login_attempts_rv,
    last_attempt_time_rv
  )
  
  # Existing server code...
}
```

Update the main UI output to show login page:

```R
output$main_ui <- renderUI({
  if (user_authenticated()) {
    # Show dashboard with RBAC controls
    tagList(
      user_info_header(current_user_data()),
      dashboard_ui(current_user_data())
    )
  } else {
    # Show login page
    login_ui()
  }
})
```

### 3. Add Role-Based UI Controls

Update dashboard_ui() to respect permissions:

```R
dashboard_ui <- function(user_data) {
  ui_visibility <- get_ui_visibility(user_data$role)
  
  navbarPage(
    # Navigation items based on role
    if (ui_visibility$show_dashboard) {
      nav_panel("Dashboard", dashboardUI())
    },
    if (ui_visibility$show_multicloud) {
      nav_panel("Multi-Cloud", multicloudUI())
    },
    if (ui_visibility$show_k8s) {
      nav_panel("Kubernetes", k8sUI())
    },
    if (ui_visibility$show_reports) {
      nav_panel("Reports", reportsUI())
    },
    if (ui_visibility$show_users && ui_visibility$can_manage_users) {
      nav_panel("Users", usersManagementUI())
    },
    if (ui_visibility$show_settings) {
      nav_panel("Settings", settingsUI())
    }
  )
}
```

### 4. Update Plumber API (api/plumber.R)

Add RBAC middleware and update endpoints:

```R
# Load RBAC modules
source("lib/rbac.R")
source("api/rbac_middleware.R")

# Create Plumber instance
pr <- plumber::plumb("api/plumber.R")

# Add RBAC filter to all endpoints
#* @filter rbac
function(req, res) {
  setup_rbac_filter(req, res)
}

# Example endpoint with permission checking
#* Get cost data
#* @param provider AWS | Azure | GCP | mock
#* @get /cost
function(req, res, provider = "mock") {
  # Check permission
  if (!check_permission_or_error(req, res, "cost:view_all")) {
    if (!check_permission_or_error(req, res, "cost:view_own")) {
      res$status <- 403
      return(list(error = "Insufficient permissions."))
    }
  }
  
  # Log the action
  log_api_action(req$user$user_id, "VIEW_COST", "cost", provider, "success")
  
  # Return cost data
  get_mock_cost(provider)
}
```

## Default Demo Users

The system comes with four demo users for testing:

| Username | Password | Role | Email |
|----------|----------|------|-------|
| admin | admin_password | Admin | admin@cloudpulse.local |
| analyst | analyst_password | FinOps Analyst | analyst@cloudpulse.local |
| devops | devops_password | DevOps Engineer | devops@cloudpulse.local |
| viewer | viewer_password | Viewer | viewer@cloudpulse.local |

**IMPORTANT**: Change these demo user passwords before deploying to production!

## Permission System

### Permission Strings

Permissions follow the format: `resource:action`

Examples:
- `cost:view_all` - View all cost data
- `cost:view_own` - View only own cost data
- `user:create` - Create new users
- `cluster:manage` - Manage Kubernetes clusters
- `alert:manage` - Manage alerts

### Permission Checking

```R
# Check single permission
has_permission("admin", "cost:view_all")  # TRUE
has_permission("viewer", "cost:view_all") # FALSE

# Check multiple permissions (any)
has_any_permission("admin", c("cost:view_all", "cost:view_own"))  # TRUE

# Check multiple permissions (all)
has_all_permissions("admin", c("cost:view_all", "user:create"))  # TRUE

# Get UI visibility
ui_vis <- get_ui_visibility("finops_analyst")
ui_vis$show_multicloud  # TRUE
ui_vis$can_manage_users # FALSE
```

## User Management

### Creating New Users (Admin Only)

```R
# In Shiny server code
create_user(
  username = "john.smith",
  password = "initial_password_123",
  email = "john.smith@example.com",
  role = "finops_analyst",
  display_name = "John Smith",
  db_path = "cloudpulse_users.db"
)
```

### Authenticating Users

```R
# In Shiny app
result <- authenticate_user("john.smith", "password", db_path = "cloudpulse_users.db")

if (result$success) {
  user_authenticated(TRUE)
  current_user_data(result)
} else {
  # Show error
  showNotification(result$error, type = "error")
}
```

## API Authorization

### Bearer Token Authentication

```bash
# Request with JWT token
curl -H "Authorization: Bearer <token>" \
  http://localhost:8000/cost?provider=AWS
```

### API Key Authentication

```bash
# Request with API key
curl -H "X-API-Key: <api_key>" \
  http://localhost:8000/cost?provider=AWS
```

### Permission-Based Endpoint Filtering

The API automatically restricts endpoints based on user role:

```
Admin Role:
  /metadata, /instances, /usage, /cost, /forecast
  /k8s/* (all K8s endpoints)
  /users, /roles, /settings, /audit

FinOps Analyst Role:
  /metadata, /usage, /cost, /forecast
  /k8s/clusters (read-only)

DevOps Engineer Role:
  /k8s/* (full access)
  /metadata, /usage
  /alerts, /alerts/*

Viewer Role:
  /k8s/clusters (read-only)
```

## Audit Logging

All API actions are logged for compliance:

```R
log_api_action(
  user_id = "john.smith",
  action = "VIEW_COST",
  resource_type = "cost",
  resource_id = "AWS_account_123",
  status = "success",
  details = list(provider = "AWS", start_date = "2026-01-01")
)
```

View audit logs:
```R
# Query audit log (from database)
audit_logs <- dbGetQuery(conn, 
  "SELECT * FROM audit_log WHERE user_id = ? ORDER BY timestamp DESC",
  params = list("john.smith")
)
```

## Security Best Practices

1. **Password Management**
   - Minimum 8 characters
   - Use PBKDF2 hashing with SHA256
   - Store salt separately
   - Force password change on first login (optional)

2. **Session Management**
   - Auto-logout after 1 hour of inactivity
   - Limit login attempts (5 attempts, 20-minute lockout)
   - Invalidate sessions on logout

3. **API Security**
   - Require authentication on all protected endpoints
   - Validate all inputs
   - Log all API actions
   - Use HTTPS in production

4. **Database Security**
   - Use strong credentials
   - Enable encryption at rest
   - Regular backups
   - Limit database access

## Troubleshooting

### Demo Users Not Working

```R
# Test authentication
result <- authenticate_user("admin", "admin_password", db_path = NULL)
# If successful, result$success == TRUE
```

### Users Can't Access Features

1. Check role: `get_user_role("username")`
2. Check permission: `has_permission("role", "permission")`
3. Check UI visibility: `get_ui_visibility("role")`

### API Returns 403 Forbidden

1. Check user token/API key
2. Verify endpoint is in allowed list: `is_endpoint_allowed("role", "/endpoint")`
3. Check permission: `has_permission("role", "required_permission")`

## Production Deployment

Before deploying to production:

1. ✅ Set `db_path` parameter in all functions to use actual database
2. ✅ Remove demo user credentials or change them
3. ✅ Enable proper JWT or OAuth authentication
4. ✅ Set `CLOUDPULSE_API_KEY` environment variable
5. ✅ Enable HTTPS for all communications
6. ✅ Configure database backups
7. ✅ Set up audit log rotation
8. ✅ Test role-based access thoroughly

## API Reference

### RBAC Functions

```R
# Role management
get_user_role(user_id, role_cache)
get_role_display_name(role_name)
get_role_permissions(role_name)
list_all_roles()
is_valid_role(role_name)

# Permission checking
has_permission(user_role, permission, resource_owner, current_user)
has_any_permission(user_role, permissions)
has_all_permissions(user_role, permissions)

# UI controls
get_ui_visibility(user_role)
get_allowed_endpoints(user_role)
is_endpoint_allowed(user_role, endpoint)

# Authorization helpers
can_view_costs(user_role, account_owner, user_id)
can_manage_users(user_role)
can_view_k8s(user_role, cluster_owner, user_id)
can_manage_alerts(user_role)
```

### Authentication Functions

```R
# User authentication
authenticate_user(username, password, db_path)
hash_password(password, salt)
verify_password(password, stored_hash, salt)

# User management
create_user(username, password, email, role, display_name, db_path)
get_user_info(user_id, db_path)
list_users(db_path)
```

## Next Steps

1. Initialize the database with `setup/rbac_schema.sql`
2. Source RBAC modules in your main app
3. Add login UI to the Shiny app
4. Update endpoints to check permissions
5. Test with demo users
6. Create real users and roles as needed
7. Configure production database
8. Deploy with proper security settings

For more information, see the individual module documentation in each R file.
