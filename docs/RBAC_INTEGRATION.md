# CloudPulse RBAC Integration Guide
# Quick reference for integrating RBAC into existing codebase
# Author: Keaton Szantho | Date: 2026-06-04

## Files Created

The RBAC system adds these new files:

```
lib/
  ├── rbac.R              # Core RBAC system with roles & permissions
  ├── auth.R              # User authentication & password management
  └── login_ui.R          # Login UI and session management

api/
  ├── rbac_middleware.R   # API authentication & authorization middleware
  └── rbac_endpoints.R    # Example endpoints with RBAC integration

setup/
  └── rbac_schema.sql     # SQLite database schema for users & roles

docs/
  └── RBAC_SETUP.md       # Comprehensive setup documentation
```

## Integration Checklist

### Step 1: Initialize Database

```R
# In R console or setup script
library(RSQLite)
library(DBI)

db_path <- "cloudpulse_users.db"
schema <- readLines("setup/rbac_schema.sql")
schema_text <- paste(schema, collapse = "\n")

conn <- dbConnect(SQLite(), db_path)
dbExecute(conn, schema_text)
dbDisconnect(conn)
```

### Step 2: Update FInOpsApp.R

Add these lines at the beginning of the app:

```R
# ══════════════════════════════════════════════════════════════════════════════
# RBAC SYSTEM
# ══════════════════════════════════════════════════════════════════════════════

# Load RBAC modules
source("lib/rbac.R")
source("lib/auth.R")
source("lib/login_ui.R")

# Database path (use actual database in production)
RBAC_DB_PATH <- NULL  # NULL = demo users; set to "cloudpulse_users.db" for production
```

Then in the server function, add authentication setup:

```R
server <- function(input, output, session) {
  
  # ════════════════════════════════════════════════════════════════════════════
  # AUTHENTICATION STATE
  # ════════════════════════════════════════════════════════════════════════════
  
  user_authenticated     <- reactiveVal(FALSE)
  current_user_data      <- reactiveVal(NULL)
  login_attempts_rv      <- reactiveVal(0L)
  last_attempt_time_rv   <- reactiveVal(NULL)
  last_activity_time     <- reactiveVal(Sys.time())
  
  # Session timeout (1 hour)
  session_timer <- reactiveTimer(60000)
  
  observe({
    session_timer()
    if (user_authenticated()) {
      idle <- as.numeric(difftime(Sys.time(), last_activity_time(), units = "secs"))
      if (idle > session_timeout) {
        user_authenticated(FALSE)
        current_user_data(NULL)
        showNotification("Session expired due to inactivity.", type = "warning", duration = 8)
      }
    }
  })
  
  observe({
    reactiveValuesToList(input)
    if (user_authenticated()) last_activity_time(Sys.time())
  })
  
  # ════════════════════════════════════════════════════════════════════════════
  # LOGIN SERVER LOGIC
  # ════════════════════════════════════════════════════════════════════════════
  
  setup_login_server(
    input, output, session,
    user_authenticated,
    current_user_data,
    login_attempts_rv,
    last_attempt_time_rv
  )
  
  # ════════════════════════════════════════════════════════════════════════════
  # MAIN UI ROUTING (authenticated vs. login)
  # ════════════════════════════════════════════════════════════════════════════
  
  output$main_ui <- renderUI({
    if (user_authenticated()) {
      # User is authenticated - show dashboard with RBAC controls
      tagList(
        user_info_header(current_user_data()),
        authenticated_dashboard_ui(current_user_data())
      )
    } else {
      # User not authenticated - show login page
      login_ui()
    }
  })
  
  # ════════════════════════════════════════════════════════════════════════════
  # ROLE-BASED OPERATIONS (enforce permissions on actions)
  # ════════════════════════════════════════════════════════════════════════════
  
  # Example: Only allow users with 'cost:export' permission to export data
  observeEvent(input$export_costs_button, {
    req(user_authenticated())
    
    if (!has_permission(current_user_data()$role, "cost:export")) {
      showNotification("You don't have permission to export cost data.", 
        type = "error", duration = 5)
      return()
    }
    
    # Proceed with export
    # ... export code ...
  })
  
  # Example: Only allow admins to manage users
  observeEvent(input$create_user_button, {
    req(user_authenticated())
    
    if (!has_permission(current_user_data()$role, "user:create")) {
      showNotification("Only administrators can create users.", 
        type = "error", duration = 5)
      return()
    }
    
    # Proceed with user creation
    # ... user creation code ...
  })
  
  # ... rest of existing server code ...
}
```

### Step 3: Create Role-Based Dashboard UI

Replace or update the `dashboard_ui()` function:

```R
authenticated_dashboard_ui <- function(user_data) {
  req(user_data)
  
  # Get visibility settings for this role
  ui_vis <- get_ui_visibility(user_data$role)
  
  navbarPage(
    title = "CloudPulse",
    id = "main_nav",
    
    # Dashboard (visible to all)
    nav_panel(
      "Dashboard",
      dashboardPageUI()
    ),
    
    # Multi-Cloud (visible to users with cost/cloud visibility)
    if (ui_vis$show_multicloud) {
      nav_panel(
        "Multi-Cloud",
        multicloudPageUI(user_data)
      )
    },
    
    # Kubernetes (visible to users with cluster access)
    if (ui_vis$show_k8s) {
      nav_panel(
        "Kubernetes",
        k8sPageUI(user_data)
      )
    },
    
    # Reports (visible to users with report generation)
    if (ui_vis$show_reports) {
      nav_panel(
        "Reports",
        reportsPageUI(user_data)
      )
    },
    
    # User Management (admin only)
    if (ui_vis$show_users && ui_vis$can_manage_users) {
      nav_panel(
        "Users",
        usersManagementPageUI(user_data)
      )
    },
    
    # Settings (admin only)
    if (ui_vis$show_settings) {
      nav_panel(
        "Settings",
        settingsPageUI(user_data)
      )
    },
    
    # Audit Log (admin only)
    if (ui_vis$show_audit) {
      nav_panel(
        "Audit",
        auditPageUI(user_data)
      )
    }
  )
}
```

### Step 4: Update API (plumber.R)

Add RBAC to the beginning of your plumber file:

```R
# ══════════════════════════════════════════════════════════════════════════════
# RBAC SYSTEM
# ══════════════════════════════════════════════════════════════════════════════

source("lib/rbac.R")
source("lib/auth.R")
source("api/rbac_middleware.R")

# Load example RBAC endpoints
source("api/rbac_endpoints.R")

# Create Plumber router
pr <- plumber::plumb("api/plumber.R")

# ══════════════════════════════════════════════════════════════════════════════
# RBAC FILTER - Apply to all routes
# ══════════════════════════════════════════════════════════════════════════════

#* @filter rbac
function(req, res) {
  setup_rbac_filter(req, res)
}

# ══════════════════════════════════════════════════════════════════════════════
# EXAMPLE: Update existing endpoints with RBAC
# ══════════════════════════════════════════════════════════════════════════════

# Example: Update the /cost endpoint to check permissions
#* Get cost data with RBAC
#* @param provider AWS | Azure | GCP | mock
#* @get /cost
function(req, res, provider = "mock") {
  
  # Check user has permission to view costs
  if (!has_permission(req$user$role, "cost:view_all") &&
      !has_permission(req$user$role, "cost:view_own")) {
    res$status <- 403
    log_api_action(req$user$user_id, "VIEW_COST", "cost", provider, "failure")
    return(list(error = "Insufficient permissions to view cost data."))
  }
  
  # Log the action
  log_api_action(req$user$user_id, "VIEW_COST", "cost", provider, "success")
  
  # Return cost data (existing implementation)
  get_mock_cost(provider)
}

# ... apply similar pattern to other endpoints ...
```

### Step 5: Test with Demo Users

Start your app and test each role:

```
Username: admin
Password: admin_password
Role: Administrator
Expected: Full access to all features

Username: analyst
Password: analyst_password
Role: FinOps Analyst
Expected: Cost analysis and reports visible, no user management

Username: devops
Password: devops_password
Role: DevOps Engineer
Expected: Kubernetes management visible, limited cost visibility

Username: viewer
Password: viewer_password
Role: Viewer
Expected: Read-only access to assigned resources
```

## Key Functions Reference

### Checking Permissions in Shiny App

```R
# In observeEvent or reactive context:

# Check single permission
if (!has_permission(current_user_data()$role, "cost:view_all")) {
  showNotification("Insufficient permissions", type = "error")
  return()
}

# Check if user can see a UI element
ui_vis <- get_ui_visibility(current_user_data()$role)
if (ui_vis$show_users) {
  # Show users management UI
}

# Get user's display name and role
user_data <- current_user_data()
cat(user_data$display_name, "is a", get_role_display_name(user_data$role))
```

### Checking Permissions in API

```R
# In Plumber endpoint:

# Check single permission
if (!has_permission(req$user$role, "cost:view_all")) {
  res$status <- 403
  return(list(error = "Insufficient permissions"))
}

# Check multiple permissions
if (!has_any_permission(req$user$role, c("cost:view_all", "cost:view_own"))) {
  res$status <- 403
  return(list(error = "Insufficient permissions"))
}

# Log user action
log_api_action(req$user$user_id, "VIEW_DATA", "resource", "id", "success")
```

## Security Considerations

1. **Demo Users**: Change demo user passwords before production deployment
2. **Database**: Use a real SQLite database in production (set `RBAC_DB_PATH`)
3. **HTTPS**: Always use HTTPS for API endpoints in production
4. **API Keys**: Set `CLOUDPULSE_API_KEY` environment variable in production
5. **Session Timeout**: Currently 1 hour, adjustable via `session_timeout` constant
6. **Password Requirements**: Minimum 8 characters, enforced on creation

## Common Issues

### Issue: Demo users not working
**Solution**: Ensure `db_path = NULL` in `authenticate_user()` calls

### Issue: Permission check failing
**Solution**: Verify role name matches exactly (case-sensitive):
- `"admin"`
- `"finops_analyst"`
- `"devops_engineer"`
- `"viewer"`

### Issue: UI elements showing when they shouldn't
**Solution**: Ensure UI rendering checks are wrapped in conditional:
```R
if (ui_visibility$show_multicloud) {
  nav_panel("Multi-Cloud", ...)
}
```

### Issue: API returning 403 Forbidden
**Solution**: Check that:
1. User is authenticated (token/API key valid)
2. Endpoint is in allowed list for role
3. Permission check in endpoint handler passes

## Production Deployment

1. Create actual SQLite database: `cloudpulse_users.db`
2. Update `RBAC_DB_PATH` to point to database
3. Create production admin user via `create_user()` function
4. Change all demo user passwords or delete them
5. Enable HTTPS for all communications
6. Set environment variables:
   - `CLOUDPULSE_API_KEY=<strong_random_key>`
   - `CLOUDPULSE_DB_PATH=<path_to_database>`
7. Test all role-based access thoroughly
8. Set up regular database backups
9. Configure audit log review process

## Additional Resources

- Full documentation: [docs/RBAC_SETUP.md](../docs/RBAC_SETUP.md)
- RBAC module: [lib/rbac.R](../lib/rbac.R)
- Auth module: [lib/auth.R](../lib/auth.R)
- API examples: [api/rbac_endpoints.R](../api/rbac_endpoints.R)
