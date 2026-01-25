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

### 3a) Configure Lightweight Access Tokens

**Option 1: Simple Toggle** ✅ **Recommended for targeting specific clients**

- Navigate to `Clients` → `frontend` → `Advanced` tab.
- Set `Always Use Lightweight Access Token` to **ON**.
- This applies to all token requests for this client.
- **Use this when:** You want only specific clients (like `frontend`) to receive lightweight tokens.

**Option 2: Client Policy Executor** (for realm-wide policies)

- Uses Client Policies to enforce lightweight tokens across multiple clients based on conditions.
- **Use this when:** You want to apply the same policy to many clients at once (e.g., all public clients in the realm).
- ⚠️ **Warning:** Due to a bug in Keycloak 26, the `client-access-type` condition doesn't work for token requests, making it difficult to target specific client types. See Known Issues section below.
- See detailed setup in section 3b below.

### 3b) Client Policy Executor Setup (Advanced)

This approach uses Keycloak 26's Client Policies to conditionally enforce lightweight tokens based on client attributes or requested scopes.

#### Step 1: Create a Client Profile

1. Navigate to `Realm Settings` → `Client Policies` tab → `Profiles` sub-tab.
2. Click `Create client profile` and name it (e.g., `lightweight-token-profile`).
3. Click on the profile name → `Executors` tab.
4. Click `Add executor` and select the **`use-lightweight-access-token`** executor.
   - This executor produces opaque/lightweight access tokens instead of full JWTs.
   - Note: In some Keycloak versions, this may appear as `limit-claims` or similar.
5. Save the profile.

#### Step 2: Create a Client Policy

1. Go to `Client Policies` → `Policies` sub-tab.
2. Click `Create client policy` and name it (e.g., `lightweight-token-policy`).
3. Add **Conditions** to define when this policy applies:

   **Working Conditions:**
   - ✅ **`any-client`**: Applies to all clients (realm-wide enforcement).
   - ✅ **`grant-type`**: Apply based on grant types (e.g., `authorization_code`, `password`).
     - ⚠️ Note: This applies to ALL clients using those grant types, not just specific clients.

   **Broken Conditions (Keycloak 26 Bug):**
   - ❌ **`client-access-type`** (public/confidential/bearer-only): Does NOT work for token request events.
     - Even if you set this to `public`, it will not trigger during token requests.
     - See Known Issues section below for details and workarounds.

4. In the **Profiles** section of the policy, select the profile you created in Step 1 (`lightweight-token-profile`).
5. Enable the policy and save.

#### Step 3: Verify Client Settings

1. For the executor to work with conditional logic:
   - Ensure `Always Use Lightweight Access Token` toggle under `Clients` → `[Your Client]` → `Advanced` is set to **OFF**.
   - If this toggle is ON, the lightweight token is forced regardless of your policy conditions.

#### Why use Client Policies?

- **Realm-wide enforcement**: Apply the same lightweight token policy to all clients at once using `any-client` condition.
- **Grant-type based**: Enforce lightweight tokens for specific grant types (e.g., only `authorization_code` flow).
- **Not recommended** for targeting specific individual clients due to the `client-access-type` bug - use the Simple Toggle (Option 1) instead.

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

## Known Issues

### Keycloak 26: `client-access-type` Condition Bug

The `client-access-type` condition in Client Policies **does not work** for token request events, even though the source code suggests it should.

- ❌ Setting `client-access-type` to `public` does NOT apply policies during token requests
- ✅ Workaround: Use the simple toggle (Section 3a, Option 1) for specific clients
- ✅ Alternative: Use `any-client` or `grant-type` conditions for realm-wide policies

**GitHub Issue:** [#45740](https://github.com/keycloak/keycloak/issues/45740)

See `KEYCLOAK_BUG_REPORT.md` for full details and steps to reproduce.

## Notes

- Later we can export/import this realm as JSON to avoid manual clicks.
- Tighten redirect URIs and web origins before productionizing.
