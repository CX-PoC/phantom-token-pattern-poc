# Brainstorm

```
[SPA / Native App / bot with API key]
  |
 Envoy ---connect via ext_authz--- ory/oathkeeper -- idp (Keycloak)
  |
 Backend graphql API
```

# GPT 5.1 Answer

Below is a concrete way to realize your phantom-token gateway with Docker + Docker Compose, using:

- Envoy as edge/API gateway
- Envoy `ext_authz` → Ory Oathkeeper (Decision API)
- Oathkeeper → Keycloak (introspection)
- Oathkeeper requests the full JWT from Keycloak (`Accept: application/jwt`) and forwards that JWT (re-signed for ~30s via `id_token`) as the phantom token to the backend
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
  | 5. Introspects token with Keycloak (OAuth2 token introspection), using Accept: application/jwt to get full JWT
  | 6. If active, return Keycloak introspected full JWT back to Envoy as phantom token
  | 7. Returns decision + mutated headers (e.g. new Authorization header)
  v
[ Envoy forwards to backend ]
  |
  | 8. Backend receives request with Keycloak full JWT (or user headers)
  v
[ GraphQL Faker (backend) ]
```

**Phantom token aspect:**

- _External_ token to clients = opaque token from Keycloak, never directly accepted by your APIs.
- Gateway (Envoy + Oathkeeper) is the only component that:
  - understands that token
  - introspects it
  - rewrites `Authorization` with the introspected Keycloak JWT (requested with `Accept: application/jwt` and re-signed for ~30s via `id_token`)
- _Internal_ token seen by the backend = the Keycloak JWT (or its short-lived re-signed copy), never the opaque access token.

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
   - Uses `oauth2_introspection` handler against Keycloak with `Accept: application/jwt` and client-credentials pre-authorization to fetch the full Keycloak JWT.
   - Re-signs that JWT for ~30s via the `id_token` mutator (or switch to the `header` mutator if you only want contextual headers) before sending it back as the phantom token.

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
    config:
      introspection_url: http://keycloak:8080/realms/demo/protocol/openid-connect/token/introspect
      introspection_request_headers:
        accept: application/jwt
      pre_authorization:
        enabled: true
        client_id: oathkeeper-introspector
        client_secret: <CLIENT_SECRET>
        token_url: http://keycloak:8080/realms/demo/protocol/openid-connect/token
      cache:
        enabled: false # enable in prod
        ttl: 20s

authorizers:
  allow:
    enabled: true

mutators:
  id_token:
    enabled: true
    config:
      issuer_url: http://oathkeeper:4456/
      jwks_url: file:///etc/oathkeeper/jwks.json
      ttl: 30s
      claims: >
        {
          "aud": ["graphql-backend"],
          "preferred_username": "{{ .Extra.preferred_username }}",
          "scope": "{{ .Extra.scope }}"
        }
  header:
    enabled: true

log:
  level: debug
```

### 5.2 Oathkeeper `rules.yaml`

This rule protects `/graphql` and applies the phantom-token behavior.

You have two options:

- **Option A (full phantom-token)** – use `id_token` mutator to re-sign the introspected Keycloak JWT (fetched with `Accept: application/jwt` via client-credentials pre-authorization) for ~30s and overwrite `Authorization`.
- **Option B (simpler for demo)** – use `header` mutator to add headers like `X-User-Id`, leaving the original token as-is.

I’ll show Option A (phantom token) and note the simple one.

```yaml
- id: graphql-phantom-token
  upstream:
    preserve_host: true
    url: http://graphql-faker:9002
  match:
    url: <http|https>://<\w+>:<\d+>/graphql<.*>
    methods:
      - GET
      - POST
  authenticators:
    - handler: oauth2_introspection
  authorizer:
    handler: allow
  mutators:
    - handler: id_token
```

Notes:

- `introspection_url` points to Keycloak Introspection endpoint for realm `demo`; it is now set globally in `config.yaml` along with `Accept: application/jwt` and client-credentials pre-authorization so Keycloak returns its full JWT.
- The regex match accepts any host/port while you iterate locally; tighten it when you know your final hostnames.
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
   - Client type: confidential; enable service accounts.
   - Use its client credentials in `oathkeeper/config.yaml` under `pre_authorization` so Oathkeeper can fetch a token before calling introspection.
   - Give a suitable role or configure it so it can introspect tokens of your realm.
4. **Token Introspection endpoint**:
   - URL used in Oathkeeper:  
     `http://keycloak:8080/realms/demo/protocol/openid-connect/token/introspect`
   - Oathkeeper sends `Accept: application/jwt` and authenticates with the bearer token obtained from the `pre_authorization` client credentials.

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
     - `Authorization: Bearer <Keycloak_full_JWT_re-signed_by_Oathkeeper>` (short-lived, via `id_token`), or
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

# Updated Plan for Phantom Token Pattern PoC

Below is an updated version of the plan that:

- Pins each component to a **current GA/stable version** as of December 2025
- Avoids **deprecated configuration knobs**
- Keeps **two Oathkeeper rule variants** (phantom-token `id_token` vs simple `header` mutator)

I’ll flag the main changes vs the earlier sketch as we go.

---

## 1. Versions to Target (GA / Stable as of Dec 2025)

Based on current docs and release trackers:

- **Envoy**
  - Stable branches: 1.33–1.36; newest stable: **1.36.2**. ([endoflife.date](https://endoflife.date/envoy?utm_source=openai))  
  - Docker pattern: `envoyproxy/envoy:v1.36.2` or `envoyproxy/envoy:v1.36-latest`. ([envoyproxy.io](https://www.envoyproxy.io/docs/envoy/latest/start/install.html?utm_source=openai))  

- **Ory Oathkeeper (open source)**  
  - Latest OSS release: **v25.4.0** (shared version scheme with Ory OSS). ([ory.com](https://www.ory.com/blog/ory-oss-v-25-4-0-launch-recap?utm_source=openai))  
  - Docker: `oryd/oathkeeper:v25.4.0`. ([ory.com](https://www.ory.com/docs/oathkeeper/install?utm_source=openai))  

- **Keycloak**
  - Current stable series: **26.4**, latest patch **26.4.7**. ([endoflife.date](https://endoflife.date/keycloak?utm_source=openai))  
  - Docker (official): `quay.io/keycloak/keycloak:26.4.7`. ([keycloak.org](https://www.keycloak.org/getting-started/getting-started-docker?utm_source=openai))  

- **GraphQL Faker**
  - Project is essentially “stable” but not very actively developed; the documented Docker usage is still:  
    `docker run -p=9002:9002 apisguru/graphql-faker [options] [SDL file]`. ([app.unpkg.com](https://app.unpkg.com/graphql-faker%402.0.0-rc.17/files/README.md?utm_source=openai))  
  - We’ll just use `apisguru/graphql-faker:latest`.

---

## 2. Updated `docker-compose.yml` (version-pinned & non‑deprecated)

Key changes vs last time:

- Use **Envoy 1.36.2**.
- Use **Oathkeeper v25.4.0** and the modern **`serve.proxy` / `serve.api`** config (no `serve decision` subcommand).
- Use **Keycloak 26.4.7** and **`KC_BOOTSTRAP_ADMIN_*`** (the old `KEYCLOAK_ADMIN`/`KEYCLOAK_ADMIN_PASSWORD` vars are deprecated). ([keycloak.org](https://www.keycloak.org/docs/26.3.3/upgrading/?utm_source=openai))  
- Don’t pass unsupported `--open=false` to GraphQL Faker (its `--open` is a flag, and docs explicitly say `--open` doesn’t work in Docker). ([app.unpkg.com](https://app.unpkg.com/graphql-faker%402.0.0-rc.17/files/README.md?utm_source=openai))  

```yaml
version: "3.9"

services:
  keycloak:
    image: quay.io/keycloak/keycloak:26.4.7
    command: >
      start-dev
      --http-port=8080
      --hostname-strict=false
    environment:
      # New bootstrap env vars (KEYCLOAK_ADMIN* are deprecated in 26.x)
      KC_BOOTSTRAP_ADMIN_USERNAME: admin
      KC_BOOTSTRAP_ADMIN_PASSWORD: admin
    ports:
      - "8081:8080"   # Keycloak UI at http://localhost:8081
    networks:
      - mesh

  oathkeeper:
    image: oryd/oathkeeper:v25.4.0
    # ENTRYPOINT is "oathkeeper"; we just pass args:
    command: ["serve", "--config", "/etc/oathkeeper/config.yaml"]
    volumes:
      - ./oathkeeper/config.yaml:/etc/oathkeeper/config.yaml:ro
      - ./oathkeeper/rules.yaml:/etc/oathkeeper/rules.yaml:ro
      - ./oathkeeper/jwks.json:/etc/oathkeeper/jwks.json:ro
    ports:
      - "4456:4456"   # Oathkeeper API (Decision API + health + JWKS)
      # (You could expose 4455 if you ever use it as reverse proxy)
    networks:
      - mesh

  envoy:
    image: envoyproxy/envoy:v1.36.2
    command: ["envoy", "-c", "/etc/envoy/envoy.yaml", "--log-level", "info"]
    volumes:
      - ./envoy/envoy.yaml:/etc/envoy/envoy.yaml:ro
    ports:
      - "8080:8080"   # Public API gateway entrypoint
    depends_on:
      - oathkeeper
      - graphql-faker
    networks:
      - mesh

  graphql-faker:
    image: apisguru/graphql-faker:latest
    # Default port is 9002 per official README; no need for extra flags.
    ports:
      - "9002:9002"
    networks:
      - mesh

networks:
  mesh:
    driver: bridge
```

---

## 3. Envoy `envoy.yaml` — updated for Envoy 1.36, no deprecated fields

Two main points we must get right for Envoy 1.36:

1. Use the **v3 API** and `envoy.filters.http.ext_authz`.  
2. Avoid the now‑deprecated `authorization_request.allowed_headers` nested field; use the **top‑level** `allowed_headers` in `ExtAuthz` instead.([envoyproxy.io](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/ext_authz/v3/ext_authz.proto.html?utm_source=openai))  

Here’s a minimized config that:

- Listens on 8080
- Routes `/graphql` to `graphql-faker`
- Calls Oathkeeper Decision API at `http://oathkeeper:4456/decisions/...`
- Lets Oathkeeper overwrite `Authorization` (+ some extra headers)

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
                  - name: envoy.filters.http.ext_authz
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.ext_authz.v3.ExtAuthz
                      transport_api_version: V3
                      # NEW: use top-level allowed_headers (non-deprecated)
                      allowed_headers:
                        patterns:
                          - exact: authorization
                          - exact: x-request-id
                      with_request_body:
                        max_request_bytes: 8192
                        allow_partial_message: true
                      http_service:
                        server_uri:
                          uri: http://oathkeeper:4456
                          cluster: ext_authz
                          timeout: 0.25s
                        path_prefix: /decisions
                        # No need for nested authorization_request.allowed_headers here
                        authorization_response:
                          allowed_upstream_headers:
                            patterns:
                              - exact: authorization   # Phantom token
                              - exact: x-user-id      # Option B
                              - exact: x-user-roles   # Option B
                  - name: envoy.filters.http.router

  clusters:
    - name: ext_authz
      connect_timeout: 0.25s
      type: LOGICAL_DNS
      lb_policy: ROUND_ROBIN
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
      type: LOGICAL_DNS
      lb_policy: ROUND_ROBIN
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

**Why this is non‑deprecated for 1.36:**

- `ExtAuthz` v3 is the correct API. ([envoyproxy.io](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/ext_authz/v3/ext_authz.proto.html?utm_source=openai))  
- `allowed_headers` on `ExtAuthz` is the new recommended way to limit which request headers go to the auth service. The nested `authorization_request.allowed_headers` is explicitly marked deprecated. ([envoyproxy.io](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/ext_authz/v3/ext_authz.proto.html?utm_source=openai))  

---

## 4. Oathkeeper `config.yaml` for v25.4.0 (Decision API mode)

Modern Oathkeeper (including 25.4.0) uses a **single `oathkeeper serve`** command that exposes:

- a **proxy port** (`serve.proxy`)  
- an **API port** (`serve.api`) — this is where `/decisions` lives. ([ory.sh](https://www.ory.sh/docs/oathkeeper/cli/oathkeeper-serve?utm_source=openai))  

We do *not* use the old `serve decision` CLI subcommand or `serve.decisions` config block.

`./oathkeeper/config.yaml`:

```yaml
log:
  level: debug
  format: text

serve:
  proxy:
    port: 4455
    host: 0.0.0.0
  api:
    port: 4456
    host: 0.0.0.0

access_rules:
  matching_strategy: regexp
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

errors:
  fallback:
    - json
  handlers:
    json:
      enabled: true
      config:
        verbose: true
```

This matches the style in the current docs (proxy + api ports, `access_rules.repositories`). ([archive.ory.com](https://archive.ory.com/t/51614/serve-proxy-port-4455-run-the-proxy-at-port-4455-api-port-44?utm_source=openai))  

---

## 5. Oathkeeper `rules.yaml` – two non‑deprecated options

### Important matching detail for Decision API

For the Decision API, you send requests to:

```text
http://oathkeeper:4456/decisions/<original-path>
```

Oathkeeper:

- strips the `/decisions` prefix when matching rules;  
- matches on the **scheme + host + path** as seen by Oathkeeper’s API (or from `X-Forwarded-*` if present). ([ory.com](https://www.ory.com/docs/oathkeeper/?utm_source=openai))  

Given Envoy calls `http://oathkeeper:4456/decisions/graphql`, and we don’t set special `X-Forwarded-*`, Oathkeeper will match against:

```text
http://oathkeeper:4456/graphql
```

So your `match.url` should be:

```yaml
match:
  url: http://oathkeeper:4456/graphql<.*>
```

not `envoy:8080` (that was wrong in the earlier sketch).

---

### 5.1 Option A: Full Phantom Token (`id_token` mutator)

This is the true “phantom token” pattern:

- Client sends Keycloak token (ideally **lightweight access token**, see §6). ([docs.redhat.com](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.0/html-single/server_administration_guide/?utm_source=openai))  
- Oathkeeper introspects against Keycloak, sending `Accept: application/jwt` and authenticating via client-credentials pre-authorization.
- On success, Oathkeeper re-signs the Keycloak JWT via `id_token` (TTL ~30s) and overwrites `Authorization: Bearer <phantom-jwt>`.

`./oathkeeper/rules.yaml` (variant A):

```yaml
- id: graphql-phantom-token
  # Optional explicit version, otherwise Oathkeeper assumes current.
  version: v25.4.0
  match:
    url: <http|https>://<\w+>:<\d+>/graphql<.*>
    methods:
      - GET
      - POST
  # Upstream is unused by Decision API but harmless to keep for documentation.
  upstream:
    url: http://graphql-faker:9002
    preserve_host: true
  authenticators:
    - handler: oauth2_introspection
  authorizer:
    handler: allow
  mutators:
    - handler: id_token
      config:
        issuer_url: http://oathkeeper:4456/
        jwks_url: file:///etc/oathkeeper/jwks.json
        ttl: 30s
        # Phantom access token audience your backend might check
        claims: >
          {
            "aud": ["graphql-backend"],
            "preferred_username": "{{ .Extra.preferred_username }}",
            "scope": "{{ .Extra.scope }}"
          }
```

Notes:

- `introspection_url`, `Accept: application/jwt`, and the client-credentials `pre_authorization` live in `config.yaml`; the rule just references the authenticator by name.
- `jwks_url` is the modern way to supply signing keys; local filesystem `file:///...` is supported. ([ory.sh](https://www.ory.sh/docs/oathkeeper/pipeline/mutator?utm_source=openai))  
- Generate keys with (run once):

  ```bash
  docker run --rm oryd/oathkeeper:v25.4.0 \
    credentials generate --alg RS256 > ./oathkeeper/jwks.json
  ```

- Backends can validate this phantom JWT using Oathkeeper’s `/.well-known/jwks.json` on the API port if you expose it.

---

### 5.2 Option B: Simple header mutator (no JWT)

This is the lower-friction variant:

- Oathkeeper still does introspection & authz.
- Instead of minting JWT, it injects e.g. `X-User-Id` and `X-User-Role` into headers.
- Envoy forwards these headers; backend does not parse any tokens.

`./oathkeeper/rules.yaml` (variant B instead of A):

```yaml
- id: graphql-header-context
  version: v25.4.0
  match:
    url: <http|https>://<\w+>:<\d+>/graphql<.*>
    methods:
      - GET
      - POST
  upstream:
    url: http://graphql-faker:9002
    preserve_host: true
  authenticators:
    - handler: oauth2_introspection
  authorizer:
    handler: allow
  mutators:
    - handler: header
      config:
        headers:
          X-User-Id: "{{ .Subject }}"
          X-User-Roles: "{{ .Extra.realm_access.roles }}"
```

Because our Envoy `authorization_response.allowed_upstream_headers` already allows `x-user-id` and `x-user-roles`, these headers flow from Oathkeeper → Envoy → GraphQL Faker.

---

## 6. Keycloak 26.4.7 specifics (lightweight tokens, introspection, env vars)

### 6.1 Env vars for admin account

For Keycloak 26.x, the docs are clear:

- **Deprecated:** `KEYCLOAK_ADMIN`, `KEYCLOAK_ADMIN_PASSWORD`  
- **Use instead:** `KC_BOOTSTRAP_ADMIN_USERNAME`, `KC_BOOTSTRAP_ADMIN_PASSWORD` ([keycloak.org](https://www.keycloak.org/docs/26.3.3/upgrading/?utm_source=openai))  

We already reflected that in `docker-compose.yml`.

### 6.2 Lightweight access tokens vs “opaque”

Keycloak still issues **JWT** access tokens, but in 26.x you can configure **“lightweight access tokens”** via client policies:

- They strip most PII claims out of the access token.
- Resource servers can obtain extra info via **introspection**, including an optional `jwt` claim containing a full JWT, when requested with `Accept: application/jwt`. ([keycloak.org](https://www.keycloak.org/securing-apps/oidc-layers?utm_source=openai))  

So from the point of view of this pattern:

- The SPA / native app effectively sees a **lightweight access token** that you can *treat as opaque* (you don’t care about its content and don’t expose it to backends).
- Oathkeeper uses the **introspection endpoint**:

  ```text
  http://keycloak:8080/realms/demo/protocol/openid-connect/token/introspect
  ```

  which is unchanged in 26.x and is the right endpoint to call. ([keycloak.org](https://www.keycloak.org/securing-apps/oidc-layers?utm_source=openai))  

Configuration steps in Keycloak admin (high level):

1. Create realm `demo`.
2. Create public client for SPA/native: `frontend`.
3. Create confidential client for Oathkeeper: `oathkeeper-introspector` with a client secret and permission to introspect tokens.
4. Turn on **lightweight access token** for `frontend` using client policies (`use-lightweight-access-token` executor). ([docs.redhat.com](https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.0/html-single/server_administration_guide/?utm_source=openai))  
5. In Oathkeeper config, set `introspection_url`, `introspection_request_headers.accept: application/jwt`, and the `pre_authorization` client credentials (`oathkeeper-introspector` / secret) so introspection returns the Keycloak JWT.

---

## 7. GraphQL Faker – Docker usage

The current README (for `graphql-faker@2.0.0-rc.17`) still shows:

```bash
docker run -p=9002:9002 apisguru/graphql-faker [options] [SDL file]
```

and explains:

- default port = **9002**  
- `--open` does **not** work inside Docker. ([app.unpkg.com](https://app.unpkg.com/graphql-faker%402.0.0-rc.17/files/README.md?utm_source=openai))  

So for Compose we:

- Bind 9002
- Avoid invalid `--open=false` flags

No deprecated config to worry about here; this tool hasn’t changed much recently.

---

## 8. Sanity check of “no deprecated config” claim

Quick recap of deprecations we explicitly avoided or fixed:

- **Envoy 1.36.2**
  - Uses v3 API for `ext_authz`, which is the stable config surface. ([envoyproxy.io](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/ext_authz/v3/ext_authz.proto.html?utm_source=openai))  
  - Uses **top-level** `allowed_headers` on `ExtAuthz` (the nested `AuthorizationRequest.allowed_headers` is marked deprecated). ([envoyproxy.io](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/http/ext_authz/v3/ext_authz.proto.html?utm_source=openai))  

- **Oathkeeper v25.4.0**
  - Uses a single `serve` command with `serve.proxy` and `serve.api` sections — no use of the older `serve decision` CLI. ([ory.sh](https://www.ory.sh/docs/oathkeeper/cli/oathkeeper-serve?utm_source=openai))  
  - Uses the current `access_rules.repositories` format. ([ory.com](https://www.ory.com/docs/oathkeeper/api-access-rules?utm_source=openai))  
  - `id_token` mutator config (`issuer_url`, `jwks_url`, `claims`) matches current docs. ([ory.sh](https://www.ory.sh/docs/oathkeeper/pipeline/mutator?utm_source=openai))  

- **Keycloak 26.4.7**
  - Uses `KC_BOOTSTRAP_ADMIN_USERNAME` / `KC_BOOTSTRAP_ADMIN_PASSWORD` instead of deprecated `KEYCLOAK_ADMIN*`. ([keycloak.org](https://www.keycloak.org/docs/26.3.3/upgrading/?utm_source=openai))  
  - Token endpoints & introspection endpoints are unchanged and valid. ([keycloak.org](https://www.keycloak.org/securing-apps/oidc-layers?utm_source=openai))  

- **GraphQL Faker**
  - We follow currently documented CLI/Docker usage, avoiding unsupported flags. ([app.unpkg.com](https://app.unpkg.com/graphql-faker%402.0.0-rc.17/files/README.md?utm_source=openai))  

---

## 9. Next steps for you

If you want to go from here to a working prototype:

1. Drop these files into a repo (`docker-compose.yml`, `envoy/envoy.yaml`, `oathkeeper/config.yaml`, `oathkeeper/rules.yaml`, `oathkeeper/jwks.json`).
2. Generate `jwks.json` as shown above.
3. Configure Keycloak realm as described and get a token from `frontend`.
4. Run `docker-compose up` and test:

   ```bash
   curl -X POST http://localhost:8080/graphql \
     -H "Authorization: Bearer <keycloak_access_token>" \
     -H "Content-Type: application/json" \
     -d '{"query": "{ __typename }"}' -v
   ```

5. Check that:
   - Envoy queries Oathkeeper (`/decisions/graphql`).
   - Oathkeeper introspects at Keycloak’s `/token/introspect`.
   - Backend sees either:
     - `Authorization: Bearer <phantom_jwt>` (Option A), or
     - `X-User-Id`, `X-User-Roles` headers (Option B).

If you want, I can next:

- Add a minimal **“validate phantom JWT in backend”** example (for a Node or Go microservice instead of GraphQL Faker), or
- Sketch a **Keycloak realm export** with the client policy enabling lightweight access tokens and the introspection client preconfigured.
