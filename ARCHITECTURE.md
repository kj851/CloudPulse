# CloudPulse RBAC - Architecture Diagram & Changes

## System Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      CloudPulse FinOpsApp                        │
│                    (lib/FInOpsApp.R)                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
                    ┌──────────────────┐
                    │  Authentication  │
                    │   State Check    │
                    └──────────────────┘
                      │              │
              Not Auth │              │ Authenticated
                      ▼              ▼
            ┌──────────────┐    ┌─────────────────────┐
            │  login_ui()  │    │  page_navbar()      │
            │              │    │  (Role-based tabs)  │
            │ Username/    │    │                     │
            │ Password     │    │ • Dashboard (all)   │
            │ Login Form   │    │ • Multi-Cloud *     │
            └──────────────┘    │ • Kubernetes *      │
                   │            │ • Reports *         │
                   │            │ • Developer *       │
                   ▼            │ (* = permission)    │
            ┌──────────────┐    └─────────────────────┘
            │ AUTHENTICATE │               │
            │   (auth.R)   │               ▼
            └──────────────┘      ┌──────────────────┐
                   │              │ get_ui_visibility│
                   │              │   (rbac.R)       │
                   ▼              └──────────────────┘
        ┌──────────────────────┐          │
        │ Check Credentials    │          ▼
        │ Against Database     │  ┌────────────────┐
        │ or Demo Users        │  │ Role Matched   │
        └──────────────────────┘  │ with UI Flags  │
                   │              └────────────────┘
                   ▼                      │
        ┌──────────────────────┐         │
        │ Success/Failure      │         ▼
        │ Set State:           │  ┌──────────────────┐
        │ • current_user_data()│  │ Nav Panel Items  │
        │ • user_authenticated()  │ Conditionally    │
        │ • Reset attempts     │  │ Rendered         │
        └──────────────────────┘  └──────────────────┘
                   │                     │
                   ▼                     ▼
            ┌─────────────┐         ┌─────────────┐
            │ User Logged │         │ Tab Access  │
            │ In - Can    │         │ Granted by  │
            │ Configure   │         │ Role        │
            │ Providers   │         └─────────────┘
            └─────────────┘
```

---

## Data Flow - User Authentication

```
1. User enters credentials on login_ui()
                │
                ▼
2. setup_login_server() intercepts input$login_submit
                │
                ▼
3. Call authenticate_user(username, password)
                │
                ▼
4. Check against:
   - SQLite database (if RBAC_DB_PATH set)
   - OR demo users (if RBAC_DB_PATH = NULL)
                │
        ┌───────┴───────┐
        │               │
        ▼               ▼
    ✓ Match         ✗ Mismatch
        │               │
        ▼               ▼
   Get user      Increment
   from DB       attempts
        │
        ├─► Check rate limit:
        │   - 5 attempts = lockout
        │
        ├─► Hash password:
        │   verify_password(input vs stored)
        │
        ├─► Get user role
        │
        ▼
5. Set Reactive State:
   - current_user_data() = user info
   - user_authenticated() = TRUE
   - reset login_attempts
                │
                ▼
6. Render main_ui output
   - page_navbar() with role-based tabs
                │
                ▼
7. User sees dashboard with accessible tabs
```

---

## Session Management Timeline

```
T=0min (User Login)
├─ user_authenticated(TRUE)
├─ current_user_data() = {id, username, email, role}
├─ last_activity_time() = Sys.time()
└─ Session token valid

T=30min
├─ session_timer fires every 60 sec
├─ Check: idle = Sys.time() - last_activity_time()
└─ idle < 3600s → Continue

T=59min
├─ User clicks a button
├─ observe({reactiveValuesToList(input)}) triggers
├─ last_activity_time() = Sys.time() (reset)
└─ Timer continues

T=60min (No Activity)
├─ session_timer fires
├─ idle = 3600+ seconds
├─ user_authenticated(FALSE)
├─ current_user_data(NULL)
├─ Notification: "Session expired"
└─ Redirect to login_ui()

T=60min+ (Activity)
├─ session_timer fires
├─ idle < 3600s (activity occurred)
├─ User continues working
└─ Session extends
```

---

## Role Permission Matrix

```
┌─────────────────────┬────────────┬──────────┬────────┬────────┐
│ Permission          │   Admin    │ Analyst  │ DevOps │ Viewer │
├─────────────────────┼────────────┼──────────┼────────┼────────┤
│ DASHBOARD ACCESS    │   ✓✓✓      │   ✓✓     │  ✓✓    │   ✓    │
│ (read)              │            │          │        │        │
├─────────────────────┼────────────┼──────────┼────────┼────────┤
│ MULTI-CLOUD         │   ✓✓✓      │   ✓✓     │        │        │
│ (cloud:*)           │            │          │        │        │
├─────────────────────┼────────────┼──────────┼────────┼────────┤
│ KUBERNETES          │   ✓✓✓      │          │  ✓✓    │        │
│ (cluster:*)         │            │          │        │        │
├─────────────────────┼────────────┼──────────┼────────┼────────┤
│ REPORTS             │   ✓✓✓      │   ✓✓     │        │        │
│ (report:*)          │            │          │        │        │
├─────────────────────┼────────────┼──────────┼────────┼────────┤
│ DEVELOPER           │   ✓✓✓      │          │        │        │
│ (system:*)          │            │          │        │        │
├─────────────────────┼────────────┼──────────┼────────┼────────┤
│ USER MANAGEMENT     │   ✓✓✓      │          │        │        │
│ (user:*)            │            │          │        │        │
└─────────────────────┴────────────┴──────────┴────────┴────────┘

Legend: ✓✓✓ = Full | ✓✓ = Modified | ✓ = Limited | (blank) = None
```

## File Structure

```
CloudPulse/
├── lib/
│   ├── FInOpsApp.R              ← MAIN APP
│   ├── rbac.R                   
│   ├── auth.R                   
│   ├── login_ui.R               
│   ├── (existing modules)
│   └── www/
│       └── styles.css
│
├── api/
│   ├── plumber.R                ← (existing)
│   ├── rbac_middleware.R        
│   ├── rbac_endpoints.R         
│   └── (existing endpoints)
│
├── setup/
│   ├── rbac_schema.sql          
│   └── (existing setup files)

---

## Permission Categories (in lib/rbac.R)

```R
RBAC_PERMISSIONS <- list(
  "user" = c(
    "user:create",
    "user:read",
    "user:update",
    "user:delete"
  ),
  "cloud" = c(
    "cloud:connect",
    "cloud:configure",
    "cloud:read",
    "cloud:delete"
  ),
  "cost" = c(
    "cost:view",
    "cost:export",
    "cost:analyze",
    "cost:forecast"
  ),
  "cluster" = c(
    "cluster:view_all",
    "cluster:view_own",
    "cluster:create",
    "cluster:configure"
  ),
  "k8s" = c(
    "k8s:view",
    "k8s:manage",
    "k8s:admin"
  ),
  "metric" = c(
    "metric:view",
    "metric:export"
  ),
  "report" = c(
    "report:view",
    "report:generate",
    "report:export"
  ),
  "system" = c(
    "system:read",
    "system:configure",
    "system:admin"
  )
)
```

---

## Database Schema (setup/rbac_schema.sql)

```
┌─────────────────────────────────────────────────────────────┐
│                    SQLite Database                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌──────────────────┐      ┌──────────────────────┐         │
│  │ users            │      │ user_sessions        │         │
│  ├──────────────────┤      ├──────────────────────┤         │
│  │ user_id (PK)     │      │ session_id (PK)      │         │
│  │ username (UQ)    │      │ user_id (FK)         │         │
│  │ email            │      │ token                │         │
│  │ password_hash    │      │ ip_address           │         │
│  │ password_salt    │      │ created_at           │         │
│  │ role             │      │ expires_at           │         │
│  │ created_at       │      │ active               │         │
│  │ last_login       │      └──────────────────────┘         │
│  │ active           │                 ▲                     │
│  └──────────────────┘                 │ (user_id)           │
│         │                              │                    │
│         ├─────────────────────────────┤                     │
│         │ (role)        │              │                    │
│         │               │              │                    │
│         ▼               ▼              ▼                    │
│   ┌──────────┐  ┌─────────────────┐  ┌──────────────────┐   │
│   │ roles    │  │ audit_log       │  │ user_cloud_access│   │
│   ├──────────┤  ├─────────────────┤  ├──────────────────┤   │
│   │ role_id  │  │ id (PK)         │  │ id (PK)          │   │
│   │ name (UQ)│  │ user_id (FK)    │  │ user_id (FK)     │   │
│   │ perms    │  │ action          │  │ provider         │   │
│   │ desc     │  │ resource_type   │  │ account_id       │   │
│   └──────────┘  │ resource_id     │  │ access_level     │   │
│                 │ status          │  │ expires_at       │   │
│                 │ timestamp       │  └──────────────────┘   │
│                 └─────────────────┘                         │
│                                                             │
│  ┌──────────────────────┐  ┌──────────────────────┐         │
│  │ role_changes         │  │ user_cluster_access  │         │
│  ├──────────────────────┤  ├──────────────────────┤         │
│  │ id (PK)              │  │ id (PK)              │         │
│  │ user_id (FK)         │  │ user_id (FK)         │         │
│  │ old_role             │  │ cluster_name         │         │
│  │ new_role             │  │ access_level         │         │
│  │ changed_by           │  │ namespaces           │         │
│  │ reason               │  │ expires_at           │         │
│  │ changed_at           │  └──────────────────────┘         │
│  └──────────────────────┘                                   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Integration Checklist

### Ready for Testing
- [ ] Run app with demo users
- [ ] Test each role's features
- [ ] Verify session timeout
- [ ] Test rate limiting
- [ ] Test cloud provider configuration
- [ ] Check audit logging

### Optional (Future)
- [ ] Production database setup
- [ ] API integration in plumber.R
- [ ] Add permission checks to operations
- [ ] Create user management UI
- [ ] Set up TLS/HTTPS
- [ ] Configure LDAP/SSO
- [ ] Multi-factor authentication
- [ ] Audit dashboard

---
