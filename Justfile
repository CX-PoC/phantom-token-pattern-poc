set windows-shell := ["powershell", "-Command"]

# Network management
net-up:
  -@docker network create phantom-net
  @echo "✓ Network phantom-net ready"

net-down:
  -@docker network rm phantom-net
  @echo "✓ Network phantom-net removed"

# Keycloak stack
keycloak-up: net-up
  docker compose -f keycloak/compose.yml  up -d
  @echo "✓ Keycloak stack started"

keycloak-down:
  docker compose -f keycloak/compose.yml  down
  @echo "✓ Keycloak stack stopped"

keycloak-reboot: keycloak-down keycloak-up
  @echo "✓ Keycloak stack rebooted"

# Gateway stack
gateway-up: net-up
  docker compose -f gateway/compose.yml  up -d
  @echo "✓ Gateway stack started"

gateway-down:
  docker compose -f gateway/compose.yml  down
  @echo "✓ Gateway stack stopped"

gateway-reboot: gateway-down gateway-up
  @echo "✓ Gateway stack rebooted"

# Combined operations
up: keycloak-up gateway-up
  @echo "✓ All stacks started"

down: gateway-down keycloak-down
  @echo "✓ All stacks stopped"

# Utility recipes
logs-keycloak:
  docker compose -f keycloak/compose.yml  logs -f

logs-gateway:
  docker compose -f gateway/compose.yml  logs -f

ps:
  @echo "=== Keycloak stack ==="
  @docker compose -f keycloak/compose.yml  ps
  @echo ""
  @echo "=== Gateway stack ==="
  @docker compose -f gateway/compose.yml  ps