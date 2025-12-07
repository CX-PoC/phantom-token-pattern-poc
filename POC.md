# Brainstorm

[SPA / Native App / bot with API key]
  |
 Envoy ---connect via ext_authz--- ory/oathkeeper -- idp (Keycloak)
  |
 Backend graphql API

# GPT 5.1 Answer

Below is a concrete way to realize your phantom-token gateway with Docker + Docker Compose, using:

- Envoy as edge/API gateway
- Envoy `ext_authz` → Ory Oathkeeper (Decision API)
- Oathkeeper → Keycloak (introspection)
- Oathkeeper mints an internal JWT and forwards that to the backend
- Backend = `graphql-faker` as your dummy GraphQL API

I’ll start with the target flow, then give you a suggested `docker-compose.yml`, followed by Envoy and Oathkeeper configs, and finally Keycloak setup notes.

---

## 1. Target Architecture & Request Flow

Logical diagram you proposed, expanded:

```text
Client (SPA / Native App / Bot)
  |
  | 1. Authenticate in Keycloak (OIDC)
  | 2. Receives opaque access token
  |
  | 3. Call protected API: Authorization: Bearer <opaque_access_token>
  v
[ Envoy (edge/API gateway) ]
  |
  | 4. Envoy calls Ory Oathkeeper via ext_authz (Decision API)
  v
[ Ory Oathkeeper ]
  |
  | 5. Introspects token with Keycloak (OAuth2 token introspection)
  | 6. If active, mints internal JWT (phantom token) with claims
  | 7. Returns decision + mutated headers (e.g. new Authorization header)
  v
[ Envoy forwards to backend ]
  |
  | 8. Backend receives request with internal JWT (or user headers)
  v
[ GraphQL Faker (backend) ]
```

**Phantom token aspect:**

- _External_ token to clients = opaque token from Keycloak, never directly accepted by your APIs.
- Gateway (Envoy + Oathkeeper) is the only component that:
  - understands that token
  - introspects it
  - mints an **internal JWT** (the “phantom token”)
- _Internal_ token seen by the backend = JWT minted by Oathkeeper.

This keeps your backend simple and decoupled from the IdP.

---

## 2. Containers & Responsibilities

We’ll use one Docker network, e.g. `mesh`, and four services:

1. **Keycloak**
   - IdP, issues opaque access tokens.
   - Exposes introspection endpoint to Oathkeeper.

2. **Ory Oathkeeper**
   - Runs in **decision mode** (no proxy).
   - Accepts `ext_authz` calls from Envoy.
   - Uses `oauth2_introspection` handler against Keycloak.
   - Uses `id_token` mutator (or `header` mutator as a simpler alternative) to produce the phantom token.

3. **Envoy**
   - Public edge API gateway (`localhost:8080`).
   - Forwards `/graphql` to backend.
   - Uses `ext_authz` HTTP filter to call Oathkeeper’s Decision API.

4. **GraphQL Faker**
   - Test GraphQL backend.
   - Doesn’t need to know anything about OAuth or Keycloak.

---

## 3. Docker Compose Skeleton

Here’s a **starting point** `docker-compose.yml` to glue everything together:

```yaml
version: "3.9"

services:
  keycloak:
    image: quay.io/keycloak/keycloak:25.0
    command: >
      start-dev
      --http-port=8080
      --hostname-strict=false
      --http-relative-path=/
    environment:
      KEYCLOAK_ADMIN: admin
      KEYCLOAK_ADMIN_PASSWORD: admin
    ports:
      - "8081:8080"   # Keycloak UI from host at http://localhost:8081
    networks:
      - mesh

  oathkeeper:
    image: oryd/oathkeeper:v0.40
    command: serve decision
    environment:
      # point to config and rules
      OATHKEEPER_CONFIG: /etc/oathkeeper/config.yaml
    volumes:
      - ./oathkeeper/config.yaml:/etc/oathkeeper/config.yaml:ro
      - ./oathkeeper/rules.yaml:/etc/oathkeeper/rules.yaml:ro
    ports:
      - "4456:4456"   # Decision API from host (optional)
    networks:
      - mesh

  envoy:
    image: envoyproxy/envoy:v1.30-latest
    command: ["envoy", "-c", "/etc/envoy/envoy.yaml", "--log-level", "info"]
    volumes:
      - ./envoy/envoy.yaml:/etc/envoy/envoy.yaml:ro
    ports:
      - "8080:8080"   # Public API gateway
    depends_on:
      - oathkeeper
      - graphql-faker
    networks:
      - mesh

  graphql-faker:
    image: apisguru/graphql-faker:latest
    command: ["--port", "9002", "--open=false"]
    ports:
      - "9002:9002"   # Optional to hit directly for debugging
    networks:
      - mesh

networks:
  mesh:
    driver: bridge
```

Notes:

- Network DNS names:
  - `keycloak:8080`
  - `oathkeeper:4456`
  - `graphql-faker:9002`
  - `envoy:8080`
- For real project you’d pin versions; above are examples.

---

## 4. Envoy Configuration (with ext_authz)

Key aspects of Envoy config:

- Define two clusters:
  - `ext_authz` → Oathkeeper Decision API
  - `graphql-backend` → GraphQL Faker
- Add HTTP filter `ext_authz` before `router`.
- Configure it to:
  - forward the `Authorization` header to Oathkeeper
  - accept mutated `Authorization` (the phantom token) and any user headers back.

Minimal `envoy/envoy.yaml` sketch:

```yaml
static_resources:
  listeners:
    - name: listener_http
      address:
        socket_address:
          address: 0.0.0.0
          port_value: 8080
      filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: ingress_http
                route_config:
                  name: local_route
                  virtual_hosts:
                    - name: backend
                      domains: ["*"]
                      routes:
                        - match:
                            prefix: "/graphql"
                          route:
                            cluster: graphql-backend
                http_filters:
                  # 1. External auth filter
                  - name: envoy.filters.http.ext_authz
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthz
                      transport_api_version: V3
                      with_request_body:
                        max_request_bytes: 8192
                        allow_partial_message: true
                      http_service:
                        server_uri:
                          uri: http://oathkeeper:4456
                          cluster: ext_authz
                          timeout: 0.25s
                        path_prefix: /decisions
                        authorization_request:
                          allowed_headers:
                            patterns:
                              - exact: authorization
                              - exact: x-request-id
                        authorization_response:
                          allowed_upstream_headers:
                            patterns:
                              # Let Oathkeeper replace the Authorization header with phantom token
                              - exact: authorization
                              # Optional additional context headers
                              - exact: x-user-id
                              - exact: x-user-roles
                  # 2. Router filter (must be last)
                  - name: envoy.filters.http.router

  clusters:
    - name: ext_authz
      connect_timeout: 0.25s
      type: logical_dns
      lb_policy: round_robin
      load_assignment:
        cluster_name: ext_authz
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: oathkeeper
                      port_value: 4456

    - name: graphql-backend
      connect_timeout: 0.25s
      type: logical_dns
      lb_policy: round_robin
      load_assignment:
        cluster_name: graphql-backend
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address:
                      address: graphql-faker
                      port_value: 9002
```

What happens:

- Client calls `POST http://localhost:8080/graphql` with `Authorization: Bearer <opaque>`.
- Envoy sends an authorization request to `http://oathkeeper:4456/decisions` with that header.
- If Oathkeeper returns `200`, Envoy applies any headers from Oathkeeper’s response (e.g. overwritten `Authorization` header) to the upstream request.
- The upstream (`graphql-faker`) sees **phantom JWT** (or user headers) instead of opaque token.

---

## 5. Oathkeeper Configuration (Decision API + Phantom Token)

You need:

1. A `config.yaml` telling Oathkeeper to:
   - run Decision API on 4456
   - load rules from `rules.yaml`
2. `rules.yaml` describing:
   - which URLs are protected
   - what authenticator to use (`oauth2_introspection` with Keycloak)
   - how to mutate the request (e.g., mint JWT or inject headers)

### 5.1 Oathkeeper `config.yaml`

Minimal example:

```yaml
serve:
  decisions:
    port: 4456
    host: 0.0.0.0

access_rules:
  repositories:
    - file:///etc/oathkeeper/rules.yaml

authenticators:
  oauth2_introspection:
    enabled: true

authorizers:
  allow:
    enabled: true

mutators:
  id_token:
    enabled: true
  header:
    enabled: true

log:
  level: debug
```

### 5.2 Oathkeeper `rules.yaml`

This rule protects `/graphql` and applies the phantom-token behavior.

You have two options:

- **Option A (full phantom-token)** – use `id_token` mutator to mint a new JWT and overwrite `Authorization`.
- **Option B (simpler for demo)** – use `header` mutator to add headers like `X-User-Id`, leaving the original token as-is.

I’ll show Option A (phantom token) and note the simple one.

```yaml
- id: graphql-api
  upstream:
    preserve_host: true
    url: http://graphql-faker:9002
  match:
    url: <http|https>://envoy:8080/graphql<.*>
    methods:
      - GET
      - POST
  authenticators:
    - handler: oauth2_introspection
      config:
        introspection_url: http://keycloak:8080/realms/demo/protocol/openid-connect/token/introspect
        introspection_request_headers:
          # For example, use client credentials of a dedicated introspection client
          Authorization: "Basic base64(client_id:client_secret)"
  authorizer:
    handler: allow
  mutators:
    - handler: id_token
      config:
        # The issuer URL for the phantom token
        issuer_url: http://oathkeeper:4456/
        # Optional audience you want your backends to check
        audiences:
          - graphql-backend
        # Map claims from introspection result into JWT
        claims:
          sub: "{{ .Subject }}"
          scope: "{{ .Extra.scope }}"
          preferred_username: "{{ .Extra.preferred_username }}"
        # Provide keys for signing the id_token (phantom token)
        jwks_url: file:///etc/oathkeeper/jwks.json
        # By default, the mutator will set Authorization: Bearer <id_token>
```

Notes:

- `introspection_url` points to Keycloak Introspection endpoint for realm `demo`. Adjust realm name as needed.
- `Authorization: "Basic ..."` should be the credentials of a **confidential client in Keycloak** that has permission to introspect tokens.
- `match.url` is a regex-style matcher. In decision mode you’re not proxying, Envoy is. The important thing: method + original URL must match what Oathkeeper expects.

**Simpler demo variant (no JWT, just headers)**:

Replace `mutators` with:

```yaml
  mutators:
    - handler: header
      config:
        headers:
          x-user-id: "{{ .Subject }}"
          x-user-scope: "{{ .Extra.scope }}"
```

Then Envoy passes those headers to `graphql-faker`. This is easier to get running initially; you can upgrade to `id_token` once introspection works.

---

## 6. Keycloak Setup for Opaque Tokens & Introspection

In Keycloak, you want:

1. **Realm** (e.g. `demo`).
2. **Client for your SPA/native/bot** (e.g. `frontend`):
   - Type: public (for SPA) or confidential (for native / bot).
   - In newer Keycloak versions you can set **Access Token Format = Opaque** at the client level.
   - This makes the `access_token` a random opaque string stored server-side.
3. **Introspection client** for Oathkeeper (e.g. `oathkeeper-introspector`):
   - Client type: confidential.
   - Allow service accounts.
   - Copy its `client_secret`.
   - Give a suitable role or configure it so it can introspect tokens of your realm.
4. **Token Introspection endpoint**:
   - URL used in Oathkeeper:  
     `http://keycloak:8080/realms/demo/protocol/openid-connect/token/introspect`
   - Oathkeeper will use HTTP Basic auth with the `oathkeeper-introspector` credentials to hit this.

**Flow validation:**

- From the client, obtain a token from Keycloak (e.g. Auth Code + PKCE).
- Use that access token in an `Authorization: Bearer` header to call Envoy.
- In Keycloak’s Admin Console, you can see active sessions and tokens; introspection endpoint should report `{ "active": true, ... }` when called with the proper client.

---

## 7. Testing the End-to-End Flow

Once `docker-compose up` is running:

1. **Login and get token:**
   - Visit `http://localhost:8081` to configure and test login.
   - Use Postman or curl to do the OAuth2 flow and get an access token for client `frontend`.

2. **Call the API via Envoy:**

   ```bash
   curl -X POST http://localhost:8080/graphql \
     -H "Authorization: Bearer <OPAQUE_ACCESS_TOKEN>" \
     -H "Content-Type: application/json" \
     -d '{"query": "{ hello }"}' -v
   ```

3. Check that:

   - Envoy logs show calls to `oathkeeper:4456/decisions`.
   - Oathkeeper logs show introspection calls to `keycloak:8080`.
   - Backend (`graphql-faker`) receives the call with either:
     - `Authorization: Bearer <phantom_jwt_from_oathkeeper>` (if using `id_token`), or
     - something like `X-User-Id` headers (if using header mutator).

That’s your phantom token pattern: the backend never sees the opaque access token.

---

## 8. Trade-offs & Why This Design Fits

- **Envoy + ext_authz + Oathkeeper**:
  - **Pros:** Very clean separation:
    - Envoy handles routing, retries, timeouts, observability.
    - Oathkeeper handles security logic & token exchange.
  - **Cons:** More moving parts than a single gateway, but very standard in modern service meshes.

- **Phantom token via Oathkeeper `id_token` mutator**:
  - **Pros:** Backends only need to understand a simple JWT; you can rotate Keycloak or change token model without touching them.
  - **Cons:** You must manage signing keys for Oathkeeper’s JWTs (`jwks.json`) and configure backends (if they validate JWTs instead of just trusting Envoy).

- **Opaque tokens from Keycloak**:
  - **Pros:** Access tokens aren’t self-contained; they must be introspected, so you can centrally revoke/rotate and keep payload minimal.
  - **Cons:** Forces online introspection at the gateway; you mitigate this with Oathkeeper’s caching and local phantom JWT to avoid introspection in your microservices.

This is very close to reference patterns you see with API gateways + OAuth2 introspection (e.g., “token exchange at the edge”).

---

## 9. Questions to Refine Further

To go from “brainstorm” to a ready-to-run repo, a couple of clarifications would help:

1. **Do you want the backend (GraphQL API) to actually verify the phantom JWT**, or for now is it enough that Envoy/Oathkeeper verify and the backend just trusts the headers?
2. **What Keycloak version are you targeting?** (This affects how we configure opaque tokens vs JWT and some of the UI details.)
3. **Do you plan to have multiple backends behind Envoy**, each with slightly different authz rules, or is everything behind one GraphQL API for now?

If you answer those, I can tighten the configs (e.g., add concrete `jwks.json`, an example Keycloak realm export, and a more detailed Oathkeeper `rules.yaml` tailored to your use case).
