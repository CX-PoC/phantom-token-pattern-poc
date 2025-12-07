# phantom-token-pattern-poc

A PoC of deployment an API gateway with Phantom Token Pattern using Docker

Based on:

 - https://nordicapis.com/understanding-the-phantom-token-approach/
 - https://curity.io/resources/learn/phantom-token-pattern/

## Current Status

Problems:

- authkeeper need strict host, can it be wildcarded?
- need to hardcode client secret in config.yaml/rules.yaml, can it be from anywhere else?

Current Stuck issue:

Keycloak can only accept from `http://localhost:8081`?

checkout and verify from https://www.keycloak.org/server/hostname

```
❯ curl --location 'http://localhost:8081/realms/demo/protocol/openid-connect/token/introspect' \
> --header 'Accept: application/jwt' \
> --header 'Content-Type: application/x-www-form-urlencoded' \
> --header 'Authorization: Basic b2F0aGtlZXBlci1pbnRyb3NwZWN0b3I6MzRJTTZ4dk5xcU5kNDdzRzR0SVhuMENiT1JBTVp4Tks=' \
> --data-urlencode 'token=<the minimal token>'
{"active":true,"jwt":"<the full token>", "other fields": "other fields"}%

❯ curl --location 'http://192.168.1.155:8081/realms/demo/protocol/openid-connect/token/introspect' \
--header 'Accept: application/jwt' \
--header 'Content-Type: application/x-www-form-urlencoded' \
--header 'Authorization: Basic <base64ed client credential>' \
--data-urlencode 'token=<the minimal token>'
{"active":false}%
```