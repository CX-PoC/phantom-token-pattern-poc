# Keycloak Manual Setup (Realm `demo`)

Step-by-step to get Keycloak issuing tokens that Oathkeeper can introspect. Adjust names as needed.

## 1) Sign in

- Open `http://localhost:8081/` → log in with `admin / admin` (bootstrap creds).

## 2) Create realm

- Realm selector → `Create realm` → name `demo`.

## 3) Public client `frontend` (for your app/tests)

- Clients → `Create client`.
- Client ID: `frontend`.
- Capabilities: enable `Standard flow`; (optional for curl tests) enable `Direct access grants`.
- Client authentication: OFF (public client).
- Redirect URIs: add `http://localhost:8080/*` for quick testing.
- Web origins: `*` (relax for now).
- Save.

### 3a) Configure Lightweight Access Tokens (recommended approach)

**Option 1: Simple Toggle** (forces lightweight tokens always)

- In Advanced settings tab: set `Always Use Lightweight Access Token` to ON.
- This applies to all token requests for this client.

**Option 2: Client Policy Executor** (flexible, conditional enforcement)

- More flexible than the toggle - allows clients to request full tokens with a specific scope.
- See detailed setup in section 3b below.

### 3b) Client Policy Executor Setup (Advanced)

This approach uses Keycloak 26's Client Policies to conditionally enforce lightweight tokens based on client attributes or requested scopes.

#### Step 1: Create a Client Profile

1. Navigate to `Realm Settings` → `Client Policies` tab → `Profiles` sub-tab.
2. Click `Create client profile` and name it (e.g., `lightweight-token-profile`).
3. Click on the profile name → `Executors` tab.
4. Click `Add executor` and select the `limit-claims` executor (or similar executor for lightweight tokens in Keycloak 26).
   - This executor strips the access token of non-essential claims, making it lightweight.
5. Save the profile.

#### Step 2: Create a Client Policy

1. Go to `Client Policies` → `Policies` sub-tab.
2. Click `Create client policy`.
3. Add **Conditions** to define when this policy applies:
   - **Client ID**: Apply to specific client(s) like `frontend`.
   - **Client Attribute**: Apply to any client with a specific attribute.
   - **Requested Scope**: Apply only if a certain scope is NOT present (e.g., enable lightweight tokens unless `scope=full` is requested).
4. In the **Profiles** section of the policy, select the profile you created in Step 1 (`lightweight-token-profile`).
5. Save the policy.

#### Step 3: Verify Client Settings

1. For the executor to work with conditional logic:
   - Ensure `Always Use Lightweight Access Token` toggle under `Clients` → `[Your Client]` → `Advanced` is set to **OFF**.
   - If this toggle is ON, the lightweight token is forced regardless of your policy conditions.

#### Why use the Executor?

- Ideal for "happy middle ground" scenarios where clients use lightweight tokens by default to save bandwidth.
- Allows clients to request a "heavy" token (containing all roles and claims) only when they explicitly request a specific scope (e.g., `scope=full`).
- Provides flexibility without forcing all-or-nothing token formats.

## 4) Confidential introspection client `oathkeeper-introspector`

- Clients → `Create client`.
- Client ID: `oathkeeper-introspector`.
- Enable `Client authentication` = ON; `Service accounts roles` = ON.
- Save → Credentials tab: copy the `Client secret`.
- Service accounts tab → Assign role → realm-management → add `view-clients` (and optionally `view-users` / `view-realm` or `uma_protection` to avoid 403 on introspection).
- In `oathkeeper/config.yaml`, set:
  - `authenticators.oauth2_introspection.config.pre_authorization.client_id` = `oathkeeper-introspector`
  - `authenticators.oauth2_introspection.config.pre_authorization.client_secret` = `<CLIENT_SECRET>`
  - `authenticators.oauth2_introspection.config.pre_authorization.token_url` = `http://keycloak:8080/realms/demo/protocol/openid-connect/token`
  - `authenticators.oauth2_introspection.config.introspection_request_headers.accept` = `application/jwt`
- Oathkeeper will use the client credentials flow to get a bearer token, then call introspection with `Accept: application/jwt` to receive Keycloak’s full JWT.

## 5) Test user

- Users → Add user `alice`.
- Credentials tab → set password, disable “Temporary”.
- (Optional) Assign realm role `user` or custom roles if you want them forwarded.

## 6) Get a token (password grant for quick test)

- Ensure `frontend` has `Direct access grants` enabled.
- Request a token:

  ```bash
  curl -X POST http://localhost:8081/realms/demo/protocol/openid-connect/token -H "Content-Type: application/x-www-form-urlencoded" -d "grant_type=password&client_id=frontend&username=alice&password=pass"
  ```
  
- If `Access Token Format` is Opaque, `access_token` will be opaque; otherwise it is a JWT.

## 7) Call through Envoy (goes to graphql-faker)

- Ensure `oathkeeper/config.yaml` has the correct `pre_authorization` client credentials and `Accept: application/jwt`, then:

  ```bash
  curl -X POST http://localhost:8080/graphql -H "Authorization: Bearer <ACCESS_TOKEN>" -H "Content-Type: application/json" -d "{\'query\': \'{ __typename }\'}" -v
  ```

  Envoy → Oathkeeper for ext_authz → Keycloak introspection (`Accept: application/jwt`) → Oathkeeper rewrites `Authorization` with the Keycloak full JWT (short-lived phantom token) → GraphQL Faker sees the internal token/headers.

## Notes

- Later we can export/import this realm as JSON to avoid manual clicks.
- Tighten redirect URIs and web origins before productionizing.
