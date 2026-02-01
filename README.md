# phantom-token-pattern-poc

A PoC of deployment an API gateway with Phantom Token Pattern using Docker

Based on:

 - https://nordicapis.com/understanding-the-phantom-token-approach/
 - https://curity.io/resources/learn/phantom-token-pattern/

## Current Status

Problems:

- Need to stop hardcoding `client_secret` in Oathkeeper config/rules; check if it can be injected via env vars or templated at container start.
- Clarify whether Keycloak supports bearer-token auth for the introspection endpoint; current flow fails with bearer, so we use Basic auth for now.

- authkeeper still has config issue
  - however, manual token introspection with curl on both localhost and LAN IP seems to work
  - confirmed that `wget` from the authkeeper container to keycloak container also works

I think our biggest problem is we don't know what is authkeeper expecting in the request from envoy's ext_authz filter.

## Answer

1. all the suddent Keycloak is not returning full JWT on introspection request with `Accept: application/jwt` header
    - Answer: remember it should be the introspection client enabling the full JWT on introspection response, not the frontend user client
