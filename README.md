# VPS Stack — Coolify + Supabase self-hosted + MCP para Claude

Dois scripts para montar uma VPS única que aloja 10+ projetos (migrados do Lovable),
com Supabase self-hosted e um MCP server ligado ao Claude.

## Ordem de execução

```bash
# 1. Clonar na VPS
git clone https://github.com/dmcad/coolify-and-supabase.git
cd coolify-and-supabase

# 2. Editar o bloco de configuração no topo do script (domínio, email, etc.)
nano 01-install-stack.sh

# 3. Correr a Fase 1 — hardening + Coolify
sudo ./01-install-stack.sh

# 4. No painel do Coolify (browser):
#    - criar/confirmar conta admin
#    - + New Resource -> Services -> Supabase -> Deploy
#    - + New Resource -> Application -> repo GitHub  (para cada projeto)

# 5. Editar o bloco de configuração do segundo script
nano 02-deploy-mcp.sh

# 6. Correr a Fase 2 — liga o MCP ao Supabase e dá o URL para o Claude
sudo ./02-deploy-mcp.sh

# 7. Colar o URL gerado em: Claude -> Conectores -> Adicionar conector personalizado
```

## Ficheiros

| Ficheiro | O que faz |
|---|---|
| `01-install-stack.sh` | Swap, atualizações, firewall (ufw), fail2ban, Coolify (instala Docker), conta admin opcional, Tailscale opcional |
| `02-deploy-mcp.sh` | Descobre o Supabase, faz deploy do MCP server (HenkDz), HTTPS automático via Traefik do Coolify, gera o URL para o Claude |

## Passos manuais inevitáveis (não dá para meter no `.sh`)

1. **DNS** no teu registrar: `A coolify.teudominio.com -> IP` e `A *.teudominio.com -> IP`
2. **Deploy do Supabase** no painel do Coolify (template de 1 clique)
3. **Colar o URL** nos Conectores do Claude

## Notas

- Os scripts são idempotentes (podes correr de novo sem partir nada).
- Não contêm segredos — todos são gerados em runtime e guardados em
  `/root/mcp-credentials.txt` (chmod 600) na VPS.
- Requisitos: VPS Ubuntu LTS fresca, mínimo 8 GB RAM para 10+ projetos.
