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
- Build the Basic auth header for Oathkeeper: `Authorization: Basic base64("oathkeeper-introspector:<CLIENT_SECRET>")`.
  - Replace this value in `oathkeeper/config.yaml` and `oathkeeper/rules.yaml`, then restart `oathkeeper` and `envoy`.

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

- Ensure Oathkeeper configs use the real Basic auth header, then:

  ```bash
  curl -X POST http://localhost:8080/graphql -H "Authorization: Bearer <ACCESS_TOKEN>" -H "Content-Type: application/json" -d "{\'query\': \'{ __typename }\'}" -v
  ```

  Envoy → Oathkeeper for ext_authz → Keycloak introspection → Oathkeeper issues phantom token → GraphQL Faker sees the internal token/headers.

## Notes

- Later we can export/import this realm as JSON to avoid manual clicks.
- Tighten redirect URIs and web origins before productionizing.
