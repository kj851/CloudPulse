# CloudPulse RBAC - Quick Reference Card

## Demo User Credentials

### Admin (Full Access)
```
Username: admin
Password: admin_password
```
**See**: All 5 tabs + Developer settings

### FinOps Analyst (Cost/Cloud)
```
Username: analyst  
Password: analyst_password
```
**See**: Dashboard, Multi-Cloud, Reports

### DevOps Engineer (K8s)
```
Username: devops
Password: devops_password
```
**See**: Dashboard, Kubernetes

### Viewer (Read-Only)
```
Username: viewer
Password: viewer_password
```
**See**: Dashboard only

---

## First-Time Features to Try

### 1. Login Page
- Beautiful gradient background
- Demo credentials displayed
- Form validation on submit

### 2. Role-Based Navigation
- Click as admin → see 5 tabs
- Click as analyst → see 3 tabs
- Click as devops → see 2 tabs
- Click as viewer → see 1 tab

### 3. User Info Header
- Top-right corner shows username
- Shows current role
- Click "Logout" to exit

### 4. Multi-Cloud Tab (Admin/Analyst Only)
- See cloud provider configuration form
- Fields for AWS, Azure, GCP
- Mock data option for testing

### 5. Session Management
- Auto-logout after 1 hour
- Notification warns before logout
- Login again to continue

### 6. Rate Limiting Security
- Try 5 wrong passwords
- On 5th attempt: 20-min lockout
- Intentional security feature

---

## Key File Location

### Core RBAC System
```
lib/
  ├── rbac.R          ← Roles & permissions definitions
  ├── auth.R          ← Authentication & password hashing  
  ├── login_ui.R      ← Login page UI
  └── FInOpsApp.R     ← Main app
```

### Documentation
```
docs/
  ├── TESTING_GUIDE.md          ← Testing procedures (Start here!)
  ├── RBAC_QUICK_START.md       ← 5-min walkthrough
  ├── RBAC_SETUP.md             ← Complete setup guide
  ├── FINOPSAPP_INTEGRATION.md  ← What changed
  └── 4 other guides...
```

---

## Testing Checklist

- [ ] App runs without errors
- [ ] Login page displays
- [ ] Admin login succeeds
- [ ] See all 5 tabs as admin
- [ ] View Multi-Cloud tab
- [ ] See user info in top-right
- [ ] Click logout works
- [ ] Analyst login shows 3 tabs
- [ ] DevOps login shows 2 tabs
- [ ] Viewer login shows 1 tab
- [ ] Wrong password shows error
- [ ] Session timeout works

---

## What to Verify

### Navigation
✓ Tabs show/hide based on role  
✓ User info in top-right  
✓ Logout button present  
✓ Dashboard always visible  

### Authentication  
✓ Login with correct credentials works  
✓ Login with wrong password fails  
✓ Rate limiting after 5 attempts  
✓ Remember last user (optional)

### Features  
✓ Admin sees all features  
✓ Analyst sees cost/cloud features  
✓ DevOps sees K8s features  
✓ Viewer sees read-only data  

---

## Important Defaults

| Setting | Default | For Production |
|---------|---------|-----------------|
| Database | NULL (demo mode) | `/path/to/rbac.db` |
| Session Timeout | 3600 sec (1 hr) | Adjust as needed |
| Rate Limit | 5 attempts, 20 min | Adjust as needed |
| Password Hash | PBKDF2-SHA256 | ✓ Already secure |

---

## Common Tasks

### Test a Different Role
1. Click Logout
2. Login with different username
3. Observe tab changes

### Check Cloud Config Form
1. Login as admin or analyst
2. Click "Multi-Cloud" tab
3. See credential entry form

### Test Rate Limiting
1. Try login with wrong password
2. Repeat 5 times
3. See lockout message
4. Wait 20 minutes (or edit code to reduce)

### Check User Header
1. Look top-right corner
2. Click to see options
3. View user role badge
4. Click logout

---

## Troubleshooting

### App won't start
```
Check: All RBAC modules exist in lib/
  - rbac.R
  - auth.R  
  - login_ui.R
```

### Login fails
```
Check: Exact username/password match
  admin / admin_password
  analyst / analyst_password
  devops / devops_password
  viewer / viewer_password
```

### Can't see all tabs
```
Check: Logged in as admin?
  Other roles have fewer tabs (expected!)
  Admin has 5 tabs
  Analyst has 3 tabs
  DevOps has 2 tabs
  Viewer has 1 tab
```

### No cloud provider form
```
Check: On Multi-Cloud tab?
  Only shows for Admin/Analyst
  Check if Viewer (no tab)
```

---
