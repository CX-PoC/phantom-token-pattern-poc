# phantom-token-pattern-poc

A PoC of deployment an API gateway with Phantom Token Pattern using Docker

Based on:

 - https://nordicapis.com/understanding-the-phantom-token-approach/
 - https://curity.io/resources/learn/phantom-token-pattern/

## Current Status

Problems:

- all the suddent Keycloak is not returning full JWT on introspection request with `Accept: application/jwt` header
- authkeeper still has config issue
  - however, manual token introspection with curl on both localhost and LAN IP seems to work
  - confirmed that `wget` from the authkeeper container to keycloak container also works
