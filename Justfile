# Network management
net-up:
  @docker network inspect phantom-net >/dev/null 2>&1 || docker network create phantom-net
  @echo "✓ Network phantom-net ready"

net-down:
  @docker network inspect phantom-net >/dev/null 2>&1 && docker network rm phantom-net || true
  @echo "✓ Network phantom-net removed"

# Keycloak stack
keycloak-up: net-up
  docker compose -f keycloak/compose.yml --project-name phantom-keycloak up -d
  @echo "✓ Keycloak stack started"

keycloak-down:
  docker compose -f keycloak/compose.yml --project-name phantom-keycloak down
  @echo "✓ Keycloak stack stopped"

# Gateway stack
gateway-up: net-up
  docker compose -f gateway/compose.yml --project-name phantom-gateway up -d
  @echo "✓ Gateway stack started"

gateway-down:
  docker compose -f gateway/compose.yml --project-name phantom-gateway down
  @echo "✓ Gateway stack stopped"

# Combined operations
up: keycloak-up gateway-up
  @echo "✓ All stacks started"

down: gateway-down keycloak-down
  @echo "✓ All stacks stopped"

# Utility recipes
logs-keycloak:
  docker compose -f keycloak/compose.yml --project-name phantom-keycloak logs -f

logs-gateway:
  docker compose -f gateway/compose.yml --project-name phantom-gateway logs -f

ps:
  @echo "=== Keycloak stack ==="
  @docker compose -f keycloak/compose.yml --project-name phantom-keycloak ps
  @echo ""
  @echo "=== Gateway stack ==="
  @docker compose -f gateway/compose.yml --project-name phantom-gateway ps
