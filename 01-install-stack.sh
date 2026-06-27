#!/usr/bin/env bash
# =============================================================================
#  01-install-stack.sh  ·  FASE 1
#  Prepara uma VPS Ubuntu fresca e instala o Coolify (o teu "Vercel próprio").
#
#  O que faz, de forma automática e idempotente (podes correr outra vez):
#    - Verificações de segurança (root, Ubuntu, servidor fresco)
#    - Swap (se a RAM for baixa)
#    - Atualizações + pacotes essenciais
#    - Firewall ufw (22, 80, 443, 8000) + fail2ban + atualizações automáticas
#    - Instalação do Coolify (instala o Docker sozinho)
#    - (Opcional) cria a conta admin do Coolify sem ires ao browser
#    - (Opcional) instala o Tailscale para acesso privado
#
#  Como usar:
#    1) Edita o BLOCO DE CONFIGURAÇÃO abaixo
#    2) chmod +x 01-install-stack.sh
#    3) sudo ./01-install-stack.sh
# =============================================================================

set -Eeuo pipefail

# ┌─────────────────────────────────────────────────────────────────────────┐
# │  BLOCO DE CONFIGURAÇÃO — edita estes valores                             │
# └─────────────────────────────────────────────────────────────────────────┘

# Domínio do painel do Coolify (cria um registo A: coolify.teudominio.com -> IP da VPS)
COOLIFY_FQDN="coolify.teudominio.com"

# Conta admin do Coolify — preenche para a criar automaticamente (sem browser).
# Deixa em branco ("") para a criares manualmente no primeiro acesso.
ROOT_USER_EMAIL=""          # ex: "eu@teudominio.com"
ROOT_USER_PASSWORD=""       # mín. 8 caracteres
ROOT_USER_NAME="Admin"

# Tailscale: acesso privado à VPS sem expor portas. Recomendado. "yes" / "no"
INSTALL_TAILSCALE="no"

# Porta do painel do Coolify durante a instalação (fica aberta para o 1º registo).
COOLIFY_PORT="8000"

# ─────────────────────────  fim da configuração  ───────────────────────────

LOG="/var/log/install-stack.log"
exec > >(tee -a "$LOG") 2>&1

c_blue()  { printf '\033[1;34m%s\033[0m\n' "$*"; }
c_green() { printf '\033[1;32m%s\033[0m\n' "$*"; }
c_amber() { printf '\033[1;33m%s\033[0m\n' "$*"; }
c_red()   { printf '\033[1;31m%s\033[0m\n' "$*"; }
step()    { echo; c_blue "▸ $*"; }

trap 'c_red "✗ Erro na linha $LINENO. Vê o log em $LOG"; exit 1' ERR

# ── Verificações iniciais ───────────────────────────────────────────────────
step "Verificações iniciais"

if [[ $EUID -ne 0 ]]; then
  c_red "Corre como root:  sudo ./01-install-stack.sh"; exit 1
fi

if ! grep -qi ubuntu /etc/os-release; then
  c_amber "Aviso: o Coolify é testado em Ubuntu LTS. Continuar mesmo assim? [s/N]"
  read -r ans; [[ "${ans,,}" == "s" ]] || exit 1
fi

if [[ "$COOLIFY_FQDN" == "coolify.teudominio.com" ]]; then
  c_red "Edita COOLIFY_FQDN no bloco de configuração antes de correr."; exit 1
fi

# Avisa se já houver outro servidor web a ocupar as portas (causa conflitos)
if ss -tlnp 2>/dev/null | grep -qE ':(80|443)\s'; then
  c_amber "Aviso: algo já escuta na porta 80/443. O Coolify deve correr numa VPS fresca."
  c_amber "Continuar? [s/N]"; read -r ans; [[ "${ans,,}" == "s" ]] || exit 1
fi

c_green "OK · FQDN do painel: $COOLIFY_FQDN"

# ── Swap (se RAM < 6 GB) ────────────────────────────────────────────────────
step "Swap"
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
if [[ "$RAM_MB" -lt 6000 ]] && ! swapon --show | grep -q .; then
  c_amber "RAM baixa (${RAM_MB}MB) e sem swap. A criar 4G de swap..."
  fallocate -l 4G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  c_green "Swap de 4G ativa."
else
  c_green "Swap não necessária (RAM ${RAM_MB}MB)."
fi

# ── Atualizações + essenciais ───────────────────────────────────────────────
step "Atualizações e pacotes essenciais"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y curl wget git ufw fail2ban unattended-upgrades \
                   ca-certificates jq openssl
c_green "Pacotes instalados."

# ── Atualizações de segurança automáticas ──────────────────────────────────
step "Atualizações de segurança automáticas"
dpkg-reconfigure -f noninteractive unattended-upgrades || true
systemctl enable --now unattended-upgrades || true
c_green "unattended-upgrades ativo."

# ── Firewall ────────────────────────────────────────────────────────────────
step "Firewall (ufw)"
ufw allow 22/tcp                 comment 'SSH'        >/dev/null
ufw allow 80/tcp                 comment 'HTTP'       >/dev/null
ufw allow 443/tcp                comment 'HTTPS'      >/dev/null
ufw allow "${COOLIFY_PORT}"/tcp  comment 'Coolify UI' >/dev/null
ufw --force enable >/dev/null
c_green "Firewall ativo: 22, 80, 443, ${COOLIFY_PORT}."
c_amber "Depois do 1º login no Coolify, fecha a porta ${COOLIFY_PORT}:"
c_amber "    ufw delete allow ${COOLIFY_PORT}/tcp"

# ── fail2ban ────────────────────────────────────────────────────────────────
step "fail2ban (proteção contra brute-force no SSH)"
systemctl enable --now fail2ban
c_green "fail2ban ativo."

# ── Tailscale (opcional) ────────────────────────────────────────────────────
if [[ "${INSTALL_TAILSCALE,,}" == "yes" ]]; then
  step "Tailscale"
  if ! command -v tailscale >/dev/null; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  c_amber "Corre depois:  tailscale up   (e autentica no browser)"
  c_green "Tailscale instalado."
fi

# ── Coolify ─────────────────────────────────────────────────────────────────
step "Instalação do Coolify (instala o Docker automaticamente)"
if [[ -d /data/coolify ]]; then
  c_green "Coolify já parece instalado em /data/coolify — a saltar instalação."
else
  # Pré-cria a conta admin se foram dadas credenciais
  if [[ -n "$ROOT_USER_EMAIL" && -n "$ROOT_USER_PASSWORD" ]]; then
    c_amber "A criar a conta admin automaticamente para $ROOT_USER_EMAIL"
    export ROOT_USERNAME="$ROOT_USER_NAME"
    export ROOT_USER_EMAIL
    export ROOT_USER_PASSWORD
  else
    c_amber "Sem credenciais admin no script — vais criar a conta no 1º acesso."
  fi
  curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
  c_green "Coolify instalado."
fi

# ── Resumo ──────────────────────────────────────────────────────────────────
IP=$(curl -fsS https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
echo
c_green "════════════════════════════════════════════════════════════════"
c_green "  FASE 1 COMPLETA"
c_green "════════════════════════════════════════════════════════════════"
echo
echo "  Painel do Coolify:   http://${IP}:${COOLIFY_PORT}"
echo "  (abre JÁ para criar/confirmar a conta admin — o 1º a registar-se fica admin)"
echo
echo "  PRÓXIMOS PASSOS MANUAIS (inevitáveis):"
echo "   1. No teu registrar de DNS, cria:"
echo "        A    coolify.teudominio.com   ->  ${IP}"
echo "        A    *.teudominio.com         ->  ${IP}   (wildcard, p/ subdomínios automáticos)"
echo
echo "   2. No painel do Coolify:"
echo "        Settings -> instance URL ->  https://${COOLIFY_FQDN}"
echo "        Deploy do Supabase:  + New Resource -> Services -> Supabase -> Deploy"
echo "        Deploy de cada projeto:  + New Resource -> Application -> repo GitHub"
echo
echo "   3. Quando o Supabase estiver de pé, corre a FASE 2:"
echo "        sudo ./02-deploy-mcp.sh"
echo
echo "   4. Depois do 1º login, fecha a porta do painel:"
echo "        ufw delete allow ${COOLIFY_PORT}/tcp"
echo
c_green "  Log completo: $LOG"
c_green "════════════════════════════════════════════════════════════════"
