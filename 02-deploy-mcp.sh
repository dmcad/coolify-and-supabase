#!/usr/bin/env bash
# =============================================================================
#  02-deploy-mcp.sh  ·  FASE 2
#  Liga um MCP server ao teu Supabase self-hosted e expõe-o num URL HTTPS
#  público (pelo proxy Traefik do Coolify) que colas nos Conectores do Claude.
#
#  Corre ISTO **depois** de teres o Supabase de pé no Coolify.
#
#  Usa o MCP server da comunidade (HenkDz) feito p/ Supabase self-hosted:
#  https://github.com/HenkDz/selfhosted-supabase-mcp
#
#  Como usar:
#    1) Tem o Supabase já deployado no Coolify
#    2) chmod +x 02-deploy-mcp.sh
#    3) sudo ./02-deploy-mcp.sh
#  O script pergunta o que precisa e gera tudo.
# =============================================================================

set -Eeuo pipefail

# ┌─────────────────────────────────────────────────────────────────────────┐
# │  BLOCO DE CONFIGURAÇÃO                                                    │
# └─────────────────────────────────────────────────────────────────────────┘

BASE_DOMAIN="teudominio.com"          # o teu domínio raiz

# Subdomínio do MCP. Por defeito gera um aleatório (mcp-xxxxxx) como "segredo"
# na própria URL — assim mesmo público é difícil de descobrir.
MCP_SUBDOMAIN=""                      # vazio = gerado automaticamente

# ─── Detalhes do proxy do Coolify (verificados na doc oficial) ──────────────
# Rede externa do Traefik do Coolify e nome do resolver de certificados.
# Por defeito é "coolify" e "letsencrypt". Só mexe se mudaste o proxy.
COOLIFY_NETWORK="coolify"
CERT_RESOLVER="letsencrypt"

# ─── Onde o MCP escuta (interno) ────────────────────────────────────────────
MCP_PORT="8765"
MCP_DIR="/data/mcp-supabase"

# ─────────────────────────  fim da configuração  ───────────────────────────

c_blue()  { printf '\033[1;34m%s\033[0m\n' "$*"; }
c_green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_amber() { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
step()    { echo; c_blue "▸ $*"; }
trap 'c_red "✗ Erro na linha $LINENO"; exit 1' ERR

[[ $EUID -eq 0 ]] || { c_red "Corre como root: sudo ./02-deploy-mcp.sh"; exit 1; }
command -v docker >/dev/null || { c_red "Docker não encontrado. Corre a Fase 1 primeiro."; exit 1; }

# ── 1. Descobrir os containers do Supabase ──────────────────────────────────
step "A procurar os containers do Supabase deployados pelo Coolify..."
mapfile -t DB_CANDIDATES < <(docker ps --format '{{.Names}}' | grep -iE 'supabase.*db|db.*supabase' || true)

if [[ ${#DB_CANDIDATES[@]} -eq 0 ]]; then
  c_amber "Não encontrei automaticamente o container da base de dados do Supabase."
  c_amber "Containers a correr:"
  docker ps --format '   {{.Names}}'
  read -rp "  Nome do container Postgres do Supabase: " DB_CONTAINER
else
  echo "  Encontrados:"
  for i in "${!DB_CANDIDATES[@]}"; do echo "    [$i] ${DB_CANDIDATES[$i]}"; done
  read -rp "  Índice do container Postgres [0]: " idx; idx="${idx:-0}"
  DB_CONTAINER="${DB_CANDIDATES[$idx]}"
fi
c_green "Container DB: $DB_CONTAINER"

# IP de bridge do container (NUNCA usar localhost nem domínio Traefik p/ o MCP)
DB_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$DB_CONTAINER" | awk '{print $1}')
[[ -n "$DB_IP" ]] || { c_red "Não consegui obter o IP do container $DB_CONTAINER"; exit 1; }
c_green "IP de bridge do Postgres: $DB_IP  (é este que o MCP vai usar)"

# ── 2. Recolher chaves do Supabase ──────────────────────────────────────────
step "Chaves do Supabase"
c_amber "Encontra-as no Coolify -> recurso Supabase -> Environment Variables:"
c_amber "  ANON key         = SERVICE_SUPABASEANON_KEY"
c_amber "  service_role key = SERVICE_SUPABASESERVICE_KEY"
echo
read -rp "  SUPABASE_URL interno [http://${DB_IP}:8000]: " SUPABASE_URL
SUPABASE_URL="${SUPABASE_URL:-http://${DB_IP}:8000}"
read -rp "  SUPABASE_ANON_KEY: " SUPABASE_ANON_KEY
read -rp "  SUPABASE_SERVICE_ROLE_KEY: " SUPABASE_SERVICE_ROLE_KEY
read -rp "  Password do Postgres (SERVICE_PASSWORD_POSTGRES no Coolify): " PG_PASSWORD
read -rp "  Nome da base de dados [postgres]: " PG_DB; PG_DB="${PG_DB:-postgres}"

DB_URL="postgresql://postgres:${PG_PASSWORD}@${DB_IP}:5432/${PG_DB}"

# ── 3. Segredos e URL pública ───────────────────────────────────────────────
step "A gerar segredos"
[[ -n "$MCP_SUBDOMAIN" ]] || MCP_SUBDOMAIN="mcp-$(openssl rand -hex 4)"
MCP_HOST="${MCP_SUBDOMAIN}.${BASE_DOMAIN}"
JWT_SECRET=$(openssl rand -hex 32)
# Bearer fixo que o proxy injeta -> a URL "funciona só ao colar" no Claude
MCP_BEARER=$(openssl rand -hex 24)
c_green "Host público do MCP: https://${MCP_HOST}/mcp"

# ── 4. Dockerfile do MCP (HenkDz) ───────────────────────────────────────────
step "A preparar a imagem do MCP server"
mkdir -p "$MCP_DIR"

cat > "${MCP_DIR}/Dockerfile" <<'DOCKER'
# Imagem do MCP server self-hosted para Supabase (HenkDz)
FROM oven/bun:1
WORKDIR /app
RUN apt-get update && apt-get install -y git ca-certificates && rm -rf /var/lib/apt/lists/*
RUN git clone https://github.com/HenkDz/selfhosted-supabase-mcp.git .
RUN bun install
RUN bun run build || true
EXPOSE 8765
# NOTA: confirma a flag de modo HTTP no README do repo (pode ser --http ou
# --transport http). Está isolada na variável MCP_ARGS do compose para editares.
CMD ["sh","-c","bun run dist/index.js ${MCP_ARGS}"]
DOCKER

# ── 5. docker-compose com routing automático pelo Traefik do Coolify ────────
# A magia: ligamos o container à rede externa do Coolify ("coolify") e pomos
# as labels do Traefik. O Coolify emite o SSL Let's Encrypt sozinho.
# Um middleware injeta o header Authorization -> a URL funciona só ao colar.
cat > "${MCP_DIR}/docker-compose.yml" <<COMPOSE
services:
  mcp-supabase:
    build: .
    container_name: mcp-supabase
    restart: unless-stopped
    environment:
      SUPABASE_URL: "${SUPABASE_URL}"
      SUPABASE_ANON_KEY: "${SUPABASE_ANON_KEY}"
      SUPABASE_SERVICE_ROLE_KEY: "${SUPABASE_SERVICE_ROLE_KEY}"
      DATABASE_URL: "${DB_URL}"
      SUPABASE_AUTH_JWT_SECRET: "${JWT_SECRET}"
      # Argumentos passados ao MCP (modo HTTP + porta + jwt). Ajusta se o
      # README do repo usar nomes de flags diferentes.
      MCP_ARGS: "--http --port ${MCP_PORT} --jwt-secret ${JWT_SECRET} --url ${SUPABASE_URL} --anon-key ${SUPABASE_ANON_KEY} --service-key ${SUPABASE_SERVICE_ROLE_KEY} --db-url ${DB_URL}"
    networks:
      - coolify
    labels:
      - "traefik.enable=true"
      # HTTP -> redireciona para HTTPS
      - "traefik.http.routers.mcp-supabase-http.entryPoints=http"
      - "traefik.http.routers.mcp-supabase-http.rule=Host(\`${MCP_HOST}\`)"
      - "traefik.http.routers.mcp-supabase-http.middlewares=redirect-to-https"
      # HTTPS + Let's Encrypt
      - "traefik.http.routers.mcp-supabase-https.entryPoints=https"
      - "traefik.http.routers.mcp-supabase-https.rule=Host(\`${MCP_HOST}\`)"
      - "traefik.http.routers.mcp-supabase-https.tls=true"
      - "traefik.http.routers.mcp-supabase-https.tls.certresolver=${CERT_RESOLVER}"
      - "traefik.http.routers.mcp-supabase-https.service=mcp-supabase-svc"
      - "traefik.http.services.mcp-supabase-svc.loadbalancer.server.port=${MCP_PORT}"
      # Injeta o Bearer -> a URL "funciona só ao colar" no Claude
      - "traefik.http.routers.mcp-supabase-https.middlewares=mcp-auth"
      - "traefik.http.middlewares.mcp-auth.headers.customrequestheaders.Authorization=Bearer ${MCP_BEARER}"

networks:
  coolify:
    external: true
    name: ${COOLIFY_NETWORK}
COMPOSE

# ── 6. Build + arranque ─────────────────────────────────────────────────────
step "Build da imagem (demora 1-2 min na 1ª vez)..."
cd "$MCP_DIR"
docker compose build
step "A arrancar o MCP server..."
docker compose up -d
sleep 4
docker compose ps

# ── 7. Firewall: o subdomínio do MCP já passa pelo 443 (não abrir portas) ────

# ── 8. Guardar credenciais ──────────────────────────────────────────────────
CRED="/root/mcp-credentials.txt"
cat > "$CRED" <<CREDS
=== Credenciais do MCP Supabase  ($(date)) ===
URL pública (cola nos Conectores do Claude):
    https://${MCP_HOST}/mcp

Host        : ${MCP_HOST}
DB container: ${DB_CONTAINER}
DB IP       : ${DB_IP}
DATABASE_URL: ${DB_URL}
JWT secret  : ${JWT_SECRET}
Bearer      : ${MCP_BEARER}   (injetado pelo proxy)
Pasta       : ${MCP_DIR}
CREDS
chmod 600 "$CRED"

# ── Resumo ──────────────────────────────────────────────────────────────────
echo
c_green "════════════════════════════════════════════════════════════════"
c_green "  FASE 2 COMPLETA — MCP a correr"
c_green "════════════════════════════════════════════════════════════════"
echo
echo "  1. DNS — cria (se ainda não tens o wildcard):"
echo "        A    ${MCP_HOST}   ->  IP da VPS"
echo "     (o wildcard *.${BASE_DOMAIN} já cobre isto)"
echo
echo "  2. Aguarda 1-2 min pelo certificado SSL (Let's Encrypt)."
echo "     Testa:   curl -I https://${MCP_HOST}/mcp"
echo
echo "  3. No Claude:  Conectores -> Adicionar conector personalizado"
echo "        URL:  https://${MCP_HOST}/mcp"
echo "     -> Vincular."
echo
echo "  Credenciais guardadas em: $CRED"
echo
c_amber "  Sobre segurança: a proteção aqui é o subdomínio aleatório + Bearer"
c_amber "  injetado pelo proxy (bom para uso pessoal). Para algo mais forte,"
c_amber "  usa o Claude Desktop com o MCP só acessível via Tailscale (privado)."
echo
c_amber "  Pontos a confirmar com o README do repo HenkDz, se algo falhar:"
c_amber "   - a flag de modo HTTP (MCP_ARGS no docker-compose.yml)"
c_amber "   - o comando de build (bun run build / dist/index.js)"
c_green "════════════════════════════════════════════════════════════════"
