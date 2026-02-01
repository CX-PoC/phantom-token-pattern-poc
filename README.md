# phantom-token-pattern-poc

A PoC of deployment an API gateway with Phantom Token Pattern using Docker

Based on:

 - https://nordicapis.com/understanding-the-phantom-token-approach/
 - https://curity.io/resources/learn/phantom-token-pattern/

## Current Status

Problems:

- Need to stop hardcoding `client_secret` in Oathkeeper config/rules; check if it can be injected via env vars or templated at container start.
- Clarify whether Keycloak supports bearer-token auth for the introspection endpoint; current flow fails with bearer, so we use Basic auth for now.

## Answer

1. all the suddent Keycloak is not returning full JWT on introspection request with `Accept: application/jwt` header
    - Answer: remember it should be the introspection client enabling the full JWT on introspection response, not the frontend user client
2. what is authkeeper expecting in the request from envoy's ext_authz filter.
    - Answer:
      - The access token (lightweight token from keycloak as phantom token) should be passed in the `Authorization` header as `Bearer <access_token>` format.
      - Then configure `oauth2_introspection` in the authkeeper `authenticators`. Configure the `token_from` section  to extract the token from the `Authorization` header.
      - Then configure `header` mutator in the authkeeper `mutators`, to set the full JWT token (from introspection response with `application/jwt` accept header) into the `Authorization` header for upstream services.
3. why keycloak doesn't support bearer auth for introspection endpoint (which break oathkeeper `pre_authorization` section in `oauth2_introspection` authenticator)
    - Answer:
      - Keycloak requires *confidential client authentication* on `/token/introspect` (Basic auth, `client_secret_post`, or JWT-based client auth). It does **not** accept a Bearer token to authorize the introspection call.
      - RFC 7662 allows either client auth or a Bearer token, but Keycloak chooses the stricter client-auth-only path. That is why Bearer fails with 401 and Basic succeeds in our tests.
