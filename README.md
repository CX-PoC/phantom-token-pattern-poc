# phantom-token-pattern-poc

A PoC of deployment an API gateway with Phantom Token Pattern using Docker

Based on:

 - https://nordicapis.com/understanding-the-phantom-token-approach/
 - https://curity.io/resources/learn/phantom-token-pattern/

## Current Status

Problems:

- authkeeper need strict host, can it be wildcarded?
- need to hardcode base64ed client secret in config.yaml/rules.yaml, can it be from anywhere else?

Current Stuck issue:

- Stuck at "access token is not active" error from Keycloak introspection endpoint
