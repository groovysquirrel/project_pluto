# OpenWebUI Authentication Troubleshooting Guide

## Issue Summary
OpenWebUI authentication with AWS Cognito via oauth2-proxy was working for existing users but failing for new users with error: "You do not have permission to access this resource."

## Authentication Architecture Evolution

### Task Definition 10 (Original - ALB Direct)
**Architecture:** Single container, ALB Cognito authentication
```
WEBUI_AUTH=true
WEBUI_AUTH_TRUSTED_EMAIL_HEADER=x-amzn-oidc-identity
ENABLE_SIGNUP=false
ENABLE_LOGIN_FORM=false
```
- Used ALB's built-in `x-amzn-oidc-*` headers
- Direct Cognito integration at ALB layer

### Task Definition 15-25 (First oauth2-proxy)
**Architecture:** Added oauth2-proxy sidecar container
```
WEBUI_AUTH_TRUSTED_EMAIL_HEADER=X-Forwarded-Email
WEBUI_AUTH_TRUSTED_NAME_HEADER=X-Forwarded-User
ENABLE_OAUTH_SIGNUP=true  # ⚠️ Problematic
```
- oauth2-proxy handles authentication
- No `WEBUI_AUTH` set (using OpenWebUI defaults)

### Task Definition 30 (OpenWebUI Native OAuth - Experiment)
**Architecture:** Removed oauth2-proxy, direct OpenWebUI → Cognito
```
OAUTH_CLIENT_ID=...
OAUTH_PROVIDER_NAME=Cognito
OAUTH_SCOPES=openid email profile
ENABLE_OAUTH_SIGNUP=true
```
- OpenWebUI's built-in OAuth support
- Direct integration with Cognito

### Task Definition 35-43 (Stable Working Configuration) ✅
**Architecture:** oauth2-proxy sidecar with simplified config

**TD 35:** Initial simplified version
```
WEBUI_AUTH_TRUSTED_EMAIL_HEADER=X-Forwarded-Email
WEBUI_AUTH_TRUSTED_NAME_HEADER=X-Forwarded-User
ENABLE_SIGNUP=true
DEFAULT_USER_ROLE=user
# Note: No WEBUI_AUTH set
# Note: No signout redirect yet
```

**TD 40-43:** **THE GOLDEN CONFIGURATION** (4 stable versions)
```
WEBUI_AUTH_TRUSTED_EMAIL_HEADER=X-Forwarded-Email
WEBUI_AUTH_TRUSTED_NAME_HEADER=X-Forwarded-User
WEBUI_AUTH_SIGNOUT_REDIRECT_URL=/oauth2/sign_out?rd=https%3A%2F%2Fauth.pluto.patternsatscale.com%2Flogout%3Fclient_id%3D77n2g266last0jim5h1c0qjckn%26logout_uri%3Dhttps%253A%252F%252Fpluto.patternsatscale.com
ENABLE_SIGNUP=true
DEFAULT_USER_ROLE=user
# Note: STILL no WEBUI_AUTH set - this is critical!
```

**Why this worked:**
- `WEBUI_AUTH` not set → OpenWebUI uses default behavior
- Trusted headers configured for oauth2-proxy
- Signout redirect properly configured for Cognito logout
- Simple, minimal configuration

### Task Definition 44-45 (Troubleshooting Attempts)
**Architecture:** Experimentation with explicit auth settings
```
WEBUI_AUTH=true  # ⚠️ First time explicitly setting this
WEBUI_AUTH_TRUSTED_EMAIL_HEADER=X-Forwarded-Email
WEBUI_AUTH_TRUSTED_NAME_HEADER=X-Forwarded-User
WEBUI_AUTH_SIGNOUT_REDIRECT_URL=...
ENABLE_SIGNUP=true
ENABLE_LOGIN_FORM=true        # TD 45
ENABLE_OAUTH_SIGNUP=false     # TD 45
```
- Attempts to fix something by explicitly setting WEBUI_AUTH
- Added extra configuration variables

### Task Definition 51 (Breaking Change) ❌
**Architecture:** Explicitly disabled auth
```
WEBUI_AUTH=false  # ❌ BREAKS EVERYTHING
WEBUI_AUTH_TRUSTED_EMAIL_HEADER=X-Forwarded-Email
WEBUI_AUTH_TRUSTED_NAME_HEADER=X-Forwarded-User
ENABLE_SIGNUP=true
# Note: Missing WEBUI_AUTH_SIGNOUT_REDIRECT_URL
```

**Why this broke:**
- Setting `WEBUI_AUTH=false` explicitly disables authentication logic needed for trusted headers
- Missing signout redirect URL
- Existing users could log in (already in DB), new users couldn't be created

## Key Learnings

### Critical Finding: WEBUI_AUTH Behavior
The `WEBUI_AUTH` environment variable behaves differently depending on how it's set:

1. **NOT SET (undefined)** ✅
   - OpenWebUI uses default authentication behavior
   - Trusted headers work correctly for auto-login
   - New users are auto-created from headers
   - **This is the correct approach for oauth2-proxy integration**

2. **WEBUI_AUTH=false** ❌
   - Explicitly disables authentication components
   - Breaks trusted header user auto-creation
   - Existing users can still authenticate but new users fail
   - **Do not use this setting with oauth2-proxy**

3. **WEBUI_AUTH=true** ⚠️
   - Enables full authentication system
   - May require additional settings (LOGIN_FORM, OAUTH_SIGNUP)
   - More complex configuration
   - Can work but requires careful configuration

### Critical Finding: oauth2-proxy Settings That BREAK Everything

**NEVER ADD THESE SETTINGS** - they will break authentication:

1. **OAUTH2_PROXY_PREFER_EMAIL_TO_USER=true** ❌❌❌
   - This is the "rapid hole" that breaks everything
   - Causes authentication to fail for both new and existing users
   - This is how configuration drift happened in TD 15-25
   - **DO NOT ADD THIS SETTING UNDER ANY CIRCUMSTANCES**

2. **OAUTH2_PROXY_SET_AUTHORIZATION_HEADER=true** ❌
   - Overwrites OpenWebUI's internal JWT Authorization headers
   - Breaks authenticated API calls after initial sign-in
   - Keep this unset or explicitly false

3. **OAUTH2_PROXY_OIDC_EMAIL_CLAIM** ❌
   - Unnecessary when email is already in standard claims
   - Adds complexity without benefit
   - Don't add unless proven necessary

4. **CORS_ALLOW_ORIGIN** ❌❌❌
   - **CRITICAL:** Breaks streaming responses from LiteLLM
   - Causes "Unexpected token 'd', "data: {"id"..." errors
   - Streaming uses SSE (Server-Sent Events) format which conflicts with CORS restrictions
   - OpenWebUI's default CORS handling works correctly without explicit setting
   - **DO NOT SET THIS VARIABLE** - let OpenWebUI handle CORS automatically

**The Golden Rule:**
Start with TD 40 config and only add settings that are PROVEN to work. Don't add "might help" settings - they usually break things. Configuration drift happens when we keep adding settings trying to fix problems.

### oauth2-proxy Header Configuration
oauth2-proxy sends different headers based on mode:

**Direct Proxy Mode (our setup):**
```
OAUTH2_PROXY_PASS_USER_HEADERS=true
```
Sends: `X-Forwarded-Email`, `X-Forwarded-User`

**Nginx Auth Mode:**
```
OAUTH2_PROXY_SET_XAUTHREQUEST=true
```
Sends: `X-Auth-Request-Email`, `X-Auth-Request-User`

**Critical:** Don't confuse these! We use direct proxy mode.

### Working Configuration Pattern

**OpenWebUI Container:**
```yaml
environment:
  # DO NOT set WEBUI_AUTH - let it use defaults
  WEBUI_AUTH_TRUSTED_EMAIL_HEADER: "X-Forwarded-Email"
  WEBUI_AUTH_TRUSTED_NAME_HEADER: "X-Forwarded-User"
  WEBUI_AUTH_SIGNOUT_REDIRECT_URL: "/oauth2/sign_out?rd=https%3A%2F%2Fauth.pluto.patternsatscale.com%2Flogout%3Fclient_id%3D77n2g266last0jim5h1c0qjckn%26logout_uri%3Dhttps%253A%252F%252Fpluto.patternsatscale.com"
  ENABLE_SIGNUP: "true"
  DEFAULT_USER_ROLE: "user"
```

**oauth2-proxy Container:**
```yaml
environment:
  OAUTH2_PROXY_PASS_USER_HEADERS: "true"
  OAUTH2_PROXY_USER_ID_CLAIM: "email"
  OAUTH2_PROXY_PREFER_EMAIL_TO_USER: "true"
  # NOT SET: OAUTH2_PROXY_SET_XAUTHREQUEST (we're in direct mode)
```

## Troubleshooting Steps

### 1. Check CloudWatch Logs
```bash
# Get current task ID
TASK_ID=$(aws ecs list-tasks --cluster pluto-cluster --service-name pluto-openwebui --desired-status RUNNING --query 'taskArns[0]' --output text | cut -d'/' -f3)

# Check OpenWebUI logs
aws logs tail /pluto/ecs --since 5m --filter-pattern "openwebui" --format short

# Check oauth2-proxy logs
aws logs tail /pluto/ecs --since 5m --filter-pattern "oauth2-proxy" --format short
```

### 2. Compare Task Definitions
```bash
# Check what's in the working configuration (TD 40)
aws ecs describe-task-definition --task-definition pluto-openwebui:40 \
  --query 'taskDefinition.containerDefinitions[?name==`openwebui`].environment' \
  --output json | jq -r '.[0][] | select(.name | contains("AUTH") or contains("SIGNUP"))'

# Check current configuration
aws ecs describe-task-definition --task-definition pluto-openwebui \
  --query 'taskDefinition.containerDefinitions[?name==`openwebui`].environment' \
  --output json | jq -r '.[0][] | select(.name | contains("AUTH") or contains("SIGNUP"))'
```

### 3. Verify oauth2-proxy Headers
Check that oauth2-proxy is configured for direct proxy mode:
```bash
aws ecs describe-task-definition --task-definition pluto-openwebui \
  --query 'taskDefinition.containerDefinitions[?name==`oauth2-proxy`].environment' \
  --output json | jq -r '.[0][] | select(.name | contains("PASS") or contains("XAUTH") or contains("HEADER"))'
```

Should show:
- `OAUTH2_PROXY_PASS_USER_HEADERS=true` ✅
- Should NOT have `OAUTH2_PROXY_SET_XAUTHREQUEST` or it should be false

### 4. Check for Stuck Deployments
```bash
aws ecs describe-services --cluster pluto-cluster --services pluto-openwebui \
  --query 'services[0].deployments' --output json | jq
```

If multiple deployments are stuck:
```bash
aws ecs update-service --cluster pluto-cluster --service pluto-openwebui --force-new-deployment
```

### 5. Force Fresh Task Restart
```bash
# Stop current task
TASK_ARN=$(aws ecs list-tasks --cluster pluto-cluster --service-name pluto-openwebui --desired-status RUNNING --query 'taskArns[0]' --output text)
aws ecs stop-task --cluster pluto-cluster --task $TASK_ARN --reason "Forcing fresh restart"

# ECS will automatically start a new task
```

## Common Issues

### Issue: "You do not have permission to access this resource"
**Symptoms:**
- Existing users can log in
- New users see permission error
- Users don't appear in OpenWebUI database

**Causes:**
1. `WEBUI_AUTH=false` explicitly set (breaks auto-creation)
2. Wrong header names (X-Auth-Request-* instead of X-Forwarded-*)
3. `ENABLE_SIGNUP=false`
4. oauth2-proxy not passing headers correctly

**Solution:**
1. Remove `WEBUI_AUTH` environment variable entirely
2. Verify headers are `X-Forwarded-Email` and `X-Forwarded-User`
3. Ensure `ENABLE_SIGNUP=true`
4. Check oauth2-proxy has `PASS_USER_HEADERS=true`

### Issue: "Your provider has not provided a trusted header"
**Symptoms:**
- Error message about trusted header
- Even existing users can't log in

**Causes:**
1. Wrong header names configured
2. oauth2-proxy not sending headers
3. Header names don't match oauth2-proxy configuration

**Solution:**
1. Verify header names match oauth2-proxy mode (X-Forwarded-* for direct proxy)
2. Check oauth2-proxy is running and authenticating requests
3. Review oauth2-proxy logs for authentication flow

### Issue: Deployment Stuck
**Symptoms:**
- New task definition not deploying
- Multiple deployments shown as "IN_PROGRESS"
- No tasks running for new deployment

**Causes:**
- Multiple rapid deployments triggered
- ECS service in confused state

**Solution:**
```bash
aws ecs update-service --cluster pluto-cluster --service pluto-openwebui --force-new-deployment
```

## References

### Task Definition History Summary
- **TD 10:** ALB Cognito direct (`x-amzn-oidc-identity`)
- **TD 15-25:** First oauth2-proxy implementation
- **TD 30:** OpenWebUI native OAuth (experiment)
- **TD 35:** Simplified oauth2-proxy (no WEBUI_AUTH)
- **TD 40-43:** GOLDEN CONFIG (added signout redirect, 4 stable versions)
- **TD 44-45:** Troubleshooting with `WEBUI_AUTH=true`
- **TD 51:** BREAKING CHANGE (`WEBUI_AUTH=false`)
- **TD 55:** Attempt to revert (still broken)
- **TD 56:** Final revert to TD 40-43 pattern

### OpenWebUI Documentation
- GitHub Issue #16193: WEBUI_AUTH=false breaks user auto-creation
- Trusted header authentication requires WEBUI_AUTH to be unset or true

### oauth2-proxy Documentation
- PASS_USER_HEADERS: https://oauth2-proxy.github.io/oauth2-proxy/configuration/overview/
- Direct proxy mode vs Nginx auth mode

## Full Clean Deployment

If all else fails, teardown and redeploy:

```bash
# Teardown
./pluto.sh teardown aws

# Verify ecs.tf has correct configuration (TD 40-43 pattern)
# - No WEBUI_AUTH variable
# - Has WEBUI_AUTH_SIGNOUT_REDIRECT_URL
# - Has X-Forwarded-Email and X-Forwarded-User headers
# - ENABLE_SIGNUP=true

# Redeploy
./pluto.sh deploy aws
```

## Last Resort: Database Check

If authentication still fails after proper configuration, check OpenWebUI database:

```bash
# Connect to RDS
# Check users table
SELECT id, email, name, role, created_at FROM user;

# If new users appear in the table but still can't access, might be a permissions issue
# Check auth table for session issues
```

## Lambda-Based User Creation (The Real Solution)

### Problem
Trusted header user auto-creation (`ENABLE_SIGNUP=true` with `X-Forwarded-*` headers) was unreliable and difficult to configure correctly with oauth2-proxy.

### Solution Architecture
Instead of relying on OpenWebUI's trusted header auto-creation, we use AWS Lambda to orchestrate user creation:

**Flow:**
1. User signs up with Google → Cognito
2. Cognito PostConfirmation trigger → Lambda
3. Lambda calls OpenWebUI API (`/api/v1/auths/signup`) to create user
4. User accesses OpenWebUI → oauth2-proxy authenticates → OpenWebUI recognizes existing user ✅

**Advantages:**
- Clean separation of concerns
- More control over user creation (role, metadata, etc.)
- Avoids oauth2-proxy configuration complexity
- Proper error handling and logging
- Works reliably without fighting oauth2-proxy quirks

### Implementation

**Lambda Function:** `/aws/lambda/cognito_postconfirm/handler.py`
- Triggers on `PostConfirmation_ConfirmSignUp`
- Extracts email and name from Cognito user attributes
- Calls `POST /api/v1/auths/signup` with user details
- Generates random password (user never uses it - authenticates via SSO)
- Also invites user to n8n

**Terraform Configuration:** `/aws/terraform/cognito.tf`
```terraform
resource "aws_lambda_function" "cognito_postconfirm" {
  environment {
    variables = {
      OPENWEBUI_URL      = "https://${local.service_hosts.openwebui}"
      N8N_URL            = "https://n8n.${local.domain_root}"
      N8N_API_KEY_SECRET = aws_secretsmanager_secret.n8n_api_key.name
    }
  }
}

# Connect to Cognito
resource "aws_cognito_user_pool" "pluto" {
  lambda_config {
    post_confirmation = aws_lambda_function.cognito_postconfirm.arn
  }
}
```

**Critical: Skip Auth for Signup Endpoint**

oauth2-proxy must allow unauthenticated access to the signup endpoint for Lambda to work:

```terraform
# In OpenWebUI oauth2-proxy container (ecs.tf)
{ name = "OAUTH2_PROXY_SKIP_AUTH_ROUTES", value = "^/api/v1/auths/signup$" }
```

Without this setting, oauth2-proxy returns `302 Redirect` to Cognito login, and the Lambda can't complete the signup API call.

### Debugging Lambda

```bash
# Check if Lambda exists and is deployed
aws lambda list-functions --query 'Functions[?contains(FunctionName, `pluto-cognito-postconfirm`)]'

# View recent logs
aws logs tail /aws/lambda/pluto-cognito-postconfirm --since 1h --format short

# Check for errors
aws logs tail /aws/lambda/pluto-cognito-postconfirm --since 24h | grep -i error
```

**Common Errors:**

1. **"Expecting value: line 1 column 1 (char 0)"**
   - Lambda is getting empty/non-JSON response from OpenWebUI API
   - Usually means oauth2-proxy is redirecting (302) instead of allowing access
   - **Fix:** Add `OAUTH2_PROXY_SKIP_AUTH_ROUTES` to oauth2-proxy config

2. **"404 not found" for n8n invitation**
   - n8n API endpoint doesn't exist or n8n not deployed
   - Non-blocking - user creation in OpenWebUI still succeeds

3. **Lambda not triggering**
   - Check Cognito trigger is configured: `aws cognito-idp describe-user-pool --user-pool-id <id>`
   - Verify Lambda has permission to be invoked by Cognito

### Future Improvement: SQS Queue for Resilience

**Current Limitation:**
The Lambda makes a synchronous call to OpenWebUI API. If OpenWebUI is restarting, scaling, or experiencing issues during signup, user creation fails silently. There's no retry mechanism.

**Improved Architecture with SQS:**

```
┌─────────────┐     ┌────────────┐     ┌──────────────┐     ┌────────────┐     ┌──────────────┐
│   Cognito   │────▶│   Lambda   │────▶│  SQS Queue   │────▶│  Worker    │────▶│  OpenWebUI   │
│PostConfirm  │     │ (producer) │     │              │     │  Lambda    │     │     API      │
└─────────────┘     └────────────┘     └──────────────┘     └────────────┘     └──────────────┘
                           │                                        │
                           │                                        │ (Retries up to 5x)
                           ▼                                        ▼
                  Returns immediately                      Dead Letter Queue
                  (doesn't block signup)                   (failed creations)
```

**Benefits:**
- User signup completes even if OpenWebUI is temporarily down ✅
- Automatic retries with exponential backoff (5 attempts before DLQ) ✅
- Dead letter queue for failed creations → CloudWatch alarm → manual intervention ✅
- Decouples Cognito availability from OpenWebUI availability ✅
- Messages retained for 4 days (won't lose signup requests during extended outage) ✅
- Can batch process multiple users efficiently ✅

**Implementation Steps (after validating current solution):**

1. Create `aws/terraform/sqs.tf` with:
   - Main queue: `pluto-user-provisioning` (4-day retention, 60s visibility timeout)
   - Dead letter queue: `pluto-user-provisioning-dlq` (14-day retention)
   - Redrive policy: 5 max retries before DLQ

2. Update `cognito_postconfirm` Lambda:
   - Instead of direct API call, send message to SQS queue
   - Message format: `{"email": "user@example.com", "name": "User Name"}`
   - Add SQS SendMessage IAM permission

3. Create worker Lambda: `user_provisioning_worker`
   - Event source: SQS queue (batch size: 1)
   - Same logic as current Lambda (call OpenWebUI API)
   - If API call fails, raise exception → message returns to queue
   - After 5 failures → message moves to DLQ

4. Monitoring:
   - CloudWatch alarm on DLQ message count > 0
   - Alert via SNS/email when user creation permanently fails

5. Manual intervention for DLQ:
   - Review failed messages in DLQ
   - Fix underlying issue (OpenWebUI bug, network, etc.)
   - Manually reprocess messages or re-invite users

**When to Implement:**
After confirming the simple synchronous approach works reliably for normal operations. SQS adds operational complexity but provides resilience for edge cases (deployments, outages, scaling events).

---

## FINAL WORKING SOLUTION (January 30, 2026) 🎉

### The Problem: GUID Usernames

After extensive debugging, we discovered users were being created with Cognito `sub` (GUID) as their display name instead of their actual name or email. This caused authentication failures for users with real names in the database.

**Symptoms:**
- Users with `name = GUID` (e.g., `ec6df508-40e1-70e3...`) could authenticate ✅
- Users with `name = "Real Name"` could NOT authenticate ❌
- Database showed all users had `username = NULL`

**Root Cause:** oauth2-proxy bug #3165

oauth2-proxy v7.6.0 and v7.14.2 both have a bug where the `OAUTH2_PROXY_USER_ID_CLAIM` setting is ignored. Even when set to `"email"`, oauth2-proxy sends the Cognito `sub` claim (GUID) in the `X-Forwarded-User` header instead of the email address.

**Discovery Process:**
1. Tested with `USER_ID_CLAIM = "email"` - still got GUIDs
2. Upgraded from v7.6.0 to v7.14.2 - bug persists
3. Created new test user - confirmed `name` field in database contained GUID
4. Researched and found [oauth2-proxy issue #3165](https://github.com/oauth2-proxy/oauth2-proxy/issues/3165)

### The Workaround (CURRENT SOLUTION)

Use `X-Forwarded-Email` for BOTH the email and name headers:

**OpenWebUI Configuration (ecs.tf):**
```terraform
{ name = "WEBUI_AUTH_TRUSTED_EMAIL_HEADER", value = "X-Forwarded-Email" },
{ name = "WEBUI_AUTH_TRUSTED_NAME_HEADER", value = "X-Forwarded-Email" },
```

**Why this works:**
- `X-Forwarded-Email` reliably contains the user's email address
- OpenWebUI uses the NAME header value for both authentication matching AND display name
- Since both are set to email, authentication works consistently
- Users see their email as display name (acceptable - they can change it manually)

**oauth2-proxy Configuration:**
```terraform
image = "quay.io/oauth2-proxy/oauth2-proxy:v7.14.2"
environment:
  OAUTH2_PROXY_USER_ID_CLAIM: "email"  # Still set (for future bug fix)
  OAUTH2_PROXY_PASS_USER_HEADERS: "true"
  OAUTH2_PROXY_SET_XAUTHREQUEST: "true"
```

**OpenWebUI Configuration:**
```terraform
WEBUI_AUTH: "true"
WEBUI_AUTH_TRUSTED_HEADER: "true"
WEBUI_AUTH_TYPE: "trusted-header"
SCIM_ENABLED: "true"

# Auto-creation disabled - not needed with trusted headers
# ENABLE_SIGNUP: commented out
# ENABLE_LOGIN_FORM: commented out
# ENABLE_OAUTH_SIGNUP: commented out
# DEFAULT_USER_ROLE: commented out
```

**Cognito PostConfirmation Lambda:** Disabled (trusted header auto-creation works reliably)

### Testing Results

**Task Definition 81+ (January 30, 2026):**
- oauth2-proxy v7.14.2
- Workaround active (X-Forwarded-Email for both headers)
- Cognito PostConfirmation Lambda disabled
- Auto-creation via trusted headers: ✅ WORKS
- Authentication for all users: ✅ WORKS
- Display name shows email: ✅ Acceptable (users can change)

**Database Results:**
```sql
SELECT id, email, name, username FROM "user" ORDER BY created_at DESC LIMIT 1;
```
```
id                                   | email                     | name                      | username
-------------------------------------|---------------------------|---------------------------|---------
3c494aee-5c64-46ee-85cd-92086b225d21 | test@example.com          | test@example.com          | NULL
```

### Key Learnings

1. **oauth2-proxy USER_ID_CLAIM bug is real and persists through v7.14.2**
   - Setting `USER_ID_CLAIM` to "email" does not work
   - `X-Forwarded-User` always contains the `sub` (GUID) claim
   - Workaround: Use `X-Forwarded-Email` for name header instead

2. **OpenWebUI uses NAME header for two purposes:**
   - Authentication matching (finding user in database)
   - Display name (what shows in UI)
   - This dual purpose caused the GUID display issue

3. **username field in database is always NULL with trusted headers**
   - OpenWebUI doesn't populate this field during auto-creation
   - Authentication relies on the `name` field instead

4. **Trusted header auto-creation is reliable when configured correctly**
   - No need for Lambda-based user provisioning
   - No need for SCIM API calls
   - Simpler architecture, fewer moving parts

5. **ENABLE_SIGNUP and related settings should be disabled**
   - Causes confusion and dual-creation paths
   - Trusted header auth handles everything automatically
   - Cleaner configuration

### Future Improvements

1. **Monitor oauth2-proxy bug #3165** for fix
   - Once fixed, can revert to using `X-Forwarded-User` with real names
   - Users would see their actual names instead of email addresses

2. **Consider alpha config format for oauth2-proxy**
   - Use `injectRequestHeaders` to directly map email claim to X-Forwarded-User
   - More complex but guaranteed to work
   - Requires YAML config file instead of environment variables

3. **Add user profile completion flow**
   - Prompt new users to update their display name
   - Provides better UX than showing email as name

---

**Date:** 2026-01-30
**Last Tested Working Config:** Task Definition 81+ (oauth2-proxy v7.14.2 + workaround)
**Current Status:** Trusted header auto-creation ✅ | All authentication working ✅ | Display shows email (workaround active)
