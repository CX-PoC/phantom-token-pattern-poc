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
- Access Token Format: set to **Opaque** if you want opaque tokens; otherwise leave JWT.
- Redirect URIs: add `http://localhost:8080/*` for quick testing.
- Web origins: `*` (relax for now).
- Save.

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
