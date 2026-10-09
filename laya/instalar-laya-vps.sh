#!/usr/bin/env bash
# =============================================================================
# instalar-laya-vps.sh
# Instala o Laya (Convai Innovations) como serviço HTTP na VPS (só CPU) e
# liga o Hermes Agent a ele por uma skill. Não precisa de Docker.
#
# Uso, como root na VPS (terminal do hPanel ou SSH):
#   bash instalar-laya-vps.sh
#
# Idempotente: pode rodar de novo. Variáveis opcionais:
#   LAYA_PORT=8000  LAYA_MODELS=multilingual  LAYA_THREADS=2
# =============================================================================
set -euo pipefail
trap 'rc=$?; [ $rc -ne 0 ] && printf "\n\033[1;31mERRO: o script parou na linha %s (código %s).\033[0m\n" "$LINENO" "$rc"' EXIT

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    OK: %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    AVISO: %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m    ERRO: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "rode como root (sudo -i)."

LAYA_PORT="${LAYA_PORT:-8000}"
LAYA_MODELS="${LAYA_MODELS:-multilingual}"
LAYA_THREADS="${LAYA_THREADS:-$(nproc)}"
LAYA_HOME=/opt/laya
RAM_GB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
log "VPS: $(nproc) CPUs, ${RAM_GB} GB RAM. Laya vai usar o checkpoint: $LAYA_MODELS"
[ "$RAM_GB" -ge 4 ] || warn "menos de 4 GB de RAM: o Laya pode não carregar junto com o Hermes."

# -----------------------------------------------------------------------------
# 1. Dependências do sistema
# -----------------------------------------------------------------------------
log "Instalando python3-venv e curl"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 python3-venv python3-pip curl >/dev/null
ok "python $(python3 --version 2>&1)"

# -----------------------------------------------------------------------------
# 2. Usuário de serviço + venv + laya[serve] (torch só CPU)
# -----------------------------------------------------------------------------
log "Criando usuário 'laya' e ambiente em $LAYA_HOME"
id laya >/dev/null 2>&1 || useradd --system --home-dir "$LAYA_HOME" --shell /usr/sbin/nologin laya
mkdir -p "$LAYA_HOME/hf" "$LAYA_HOME/env"
if [ ! -x "$LAYA_HOME/venv/bin/laya-serve" ]; then
  log "Instalando torch (CPU) e laya[serve]. Demora de 3 a 10 min."
  python3 -m venv "$LAYA_HOME/venv"
  "$LAYA_HOME/venv/bin/pip" install -q --upgrade pip
  "$LAYA_HOME/venv/bin/pip" install -q torch --index-url https://download.pytorch.org/whl/cpu
  "$LAYA_HOME/venv/bin/pip" install -q "laya[serve]"
else
  log "Atualizando o pacote laya"
  "$LAYA_HOME/venv/bin/pip" install -q -U "laya[serve]"
fi
ok "laya $("$LAYA_HOME/venv/bin/pip" show laya 2>/dev/null | awk '/^Version/ {print $2}')"

# -----------------------------------------------------------------------------
# 3. Chave de API (gerada uma vez) e arquivo de ambiente
# -----------------------------------------------------------------------------
ENVFILE="$LAYA_HOME/env/laya.env"
if [ -f "$ENVFILE" ] && grep -q '^LAYA_API_KEY=' "$ENVFILE"; then
  LAYA_API_KEY="$(grep '^LAYA_API_KEY=' "$ENVFILE" | cut -d= -f2-)"
else
  LAYA_API_KEY="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
fi
cat > "$ENVFILE" <<CONF
LAYA_HOST=0.0.0.0
LAYA_PORT=$LAYA_PORT
LAYA_DEVICE=cpu
LAYA_PRELOAD=1
LAYA_MODELS=$LAYA_MODELS
LAYA_DEFAULT_MODEL=multilingual
LAYA_MAX_LOADED=1
LAYA_IDLE_UNLOAD_SECONDS=300
LAYA_THREADS=$LAYA_THREADS
OMP_NUM_THREADS=$LAYA_THREADS
LAYA_API_KEY=$LAYA_API_KEY
HF_HOME=$LAYA_HOME/hf
TORCH_DISABLE_NATIVE_JIT=1
USE_TF=0
CONF
chmod 600 "$ENVFILE"
chown -R laya:laya "$LAYA_HOME"
ok "ambiente em $ENVFILE (chave de API guardada lá)"

# -----------------------------------------------------------------------------
# 4. Serviço systemd
# -----------------------------------------------------------------------------
log "Criando o serviço systemd laya-serve"
cat > /etc/systemd/system/laya-serve.service <<UNIT
[Unit]
Description=Laya System-1 decision server (CPU)
After=network-online.target
Wants=network-online.target

[Service]
User=laya
Group=laya
EnvironmentFile=$ENVFILE
ExecStart=$LAYA_HOME/venv/bin/laya-serve
Restart=always
RestartSec=5
TimeoutStartSec=1800
MemoryMax=3G
NoNewPrivileges=true
ProtectSystem=full
ReadWritePaths=$LAYA_HOME

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable laya-serve >/dev/null 2>&1
systemctl restart laya-serve
ok "serviço iniciado (o primeiro boot baixa ~650 MB do checkpoint)"

# -----------------------------------------------------------------------------
# 5. Firewall: porta só para localhost e containers Docker
# -----------------------------------------------------------------------------
log "Protegendo a porta $LAYA_PORT"
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow from 172.16.0.0/12 to any port "$LAYA_PORT" proto tcp >/dev/null
  ufw deny "$LAYA_PORT"/tcp >/dev/null
  ok "regras ufw aplicadas"
else
  iptables -C INPUT -p tcp --dport "$LAYA_PORT" ! -s 172.16.0.0/12 ! -i lo -j DROP 2>/dev/null || \
  iptables -I INPUT -p tcp --dport "$LAYA_PORT" ! -s 172.16.0.0/12 ! -i lo -j DROP
  command -v netfilter-persistent >/dev/null && netfilter-persistent save >/dev/null 2>&1 || \
  warn "para a regra sobreviver ao reboot: apt install -y iptables-persistent"
fi

# -----------------------------------------------------------------------------
# 6. Esperar o Laya ficar pronto e testar
# -----------------------------------------------------------------------------
log "Aguardando o Laya carregar o modelo (até 15 min na primeira vez)"
for i in $(seq 1 180); do
  if curl -fsS "http://127.0.0.1:$LAYA_PORT/health" >/dev/null 2>&1; then break; fi
  sleep 5
  [ $((i % 12)) -eq 0 ] && echo "    ... ainda carregando ($((i*5))s). Logs: journalctl -u laya-serve -f"
done
curl -fsS "http://127.0.0.1:$LAYA_PORT/health" >/dev/null || die "Laya não subiu. Veja: journalctl -u laya-serve -n 100"
ok "Laya no ar"

log "Teste em português"
curl -s "http://127.0.0.1:$LAYA_PORT/v1/systemone" \
  -H "Authorization: Bearer $LAYA_API_KEY" -H "Content-Type: application/json" \
  -d '{"state":{"body":"Fui cobrado duas vezes em março. Quero o reembolso hoje ou cancelo o plano."},
       "questions":{"setor":{"type":"choice","instructions":"Qual setor deve atender?",
                     "criteria":{"financeiro":"cobranças, pagamentos, reembolsos","tecnico":"bugs e falhas","outro":"tudo o mais"}},
                    "cancelar":{"type":"noul","instructions":"O usuário ameaça cancelar?"}}}' | head -c 600; echo

# -----------------------------------------------------------------------------
# 7. Ligar ao Hermes Agent (skill + variáveis no .env)
# -----------------------------------------------------------------------------
log "Procurando o Hermes Agent"
HERMES_BIN=""; HERMES_CT=""; HERMES_DATA=""
for cand in "$(command -v hermes 2>/dev/null || true)" /root/.local/bin/hermes /usr/local/bin/hermes \
            $(find /root/.hermes /opt -maxdepth 5 -type f -name hermes -perm -u+x 2>/dev/null | head -n3); do
  [ -n "$cand" ] && [ -x "$cand" ] && { HERMES_BIN="$cand"; break; }
done
if [ -n "$HERMES_BIN" ]; then
  HERMES_DATA="${HERMES_HOME:-/root/.hermes}"
elif command -v docker >/dev/null; then
  HERMES_CT="$(docker ps -a --filter ancestor=nousresearch/hermes-agent --format '{{.Names}}' 2>/dev/null | head -n1 || true)"
  [ -n "$HERMES_CT" ] && HERMES_DATA="$(docker inspect "$HERMES_CT" --format '{{range .Mounts}}{{if eq .Destination "/opt/data"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)"
fi
[ -n "$HERMES_DATA" ] || { for d in /root/.hermes /home/*/.hermes; do [ -d "$d" ] && { HERMES_DATA="$d"; break; }; done; }

if [ -z "$HERMES_DATA" ]; then
  warn "não achei a pasta ~/.hermes. Instale a skill depois: copie hermes-skill/laya para ~/.hermes/skills/laya"
else
  ok "Hermes em: $HERMES_DATA ${HERMES_BIN:+(binário $HERMES_BIN)}${HERMES_CT:+(container $HERMES_CT)}"
  if [ -n "$HERMES_CT" ]; then
    is_ipv4() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
    GW=""
    for net in $(docker inspect "$HERMES_CT" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null); do
      for g in $(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Gateway}} {{end}}' 2>/dev/null); do
        if is_ipv4 "$g"; then GW="$g"; break 2; fi
      done
    done
    is_ipv4 "$GW" || GW="$(ip -4 addr show docker0 2>/dev/null | awk '/inet / {sub("/.*","",$2); print $2; exit}')"
    is_ipv4 "$GW" || GW="172.17.0.1"
    LAYA_URL="http://$GW:$LAYA_PORT"
  else
    LAYA_URL="http://127.0.0.1:$LAYA_PORT"
  fi
  mkdir -p "$HERMES_DATA/skills/laya"
  SKILL_SRC="$(dirname "$0")/hermes-skill/laya/SKILL.md"
  SKILL_URL="https://raw.githubusercontent.com/dynosaisistemas-blip/dynossistemas/master/laya/hermes-skill/laya/SKILL.md"
  if [ -f "$SKILL_SRC" ]; then
    cp "$SKILL_SRC" "$HERMES_DATA/skills/laya/SKILL.md"
  elif curl -fsSL "$SKILL_URL" -o "$HERMES_DATA/skills/laya/SKILL.md.tmp" 2>/dev/null; then
    mv "$HERMES_DATA/skills/laya/SKILL.md.tmp" "$HERMES_DATA/skills/laya/SKILL.md"
  else
    cat > "$HERMES_DATA/skills/laya/SKILL.md" <<'SKILL'
---
name: laya
description: Decisões tipadas rápidas e sem custo (classificar, pontuar, sim/não) usando o modelo Laya local. Use para triagem, roteamento, intenção, prioridade ou moderação de um texto. NÃO gera texto.
---
# Laya: decisões tipadas locais
Endpoint: `$LAYA_BASE_URL/v1/systemone`, header `Authorization: Bearer $LAYA_API_KEY` (ambos no .env).
Tipos: `choice` (criteria = objeto opcao:descrição), `score` (criteria = lista ordenada), `noul` (sim/não).
Exemplo:
curl -s "$LAYA_BASE_URL/v1/systemone" -H "Authorization: Bearer $LAYA_API_KEY" -H "Content-Type: application/json" \
  -d '{"state":{"body":"TEXTO"},"questions":{"setor":{"type":"choice","instructions":"Qual setor?","criteria":{"financeiro":"cobranças","tecnico":"bugs","outro":"resto"}}}}'
Use `confidence`; abaixo de 0,6 decida você. Máximo ~20 opções por choice. Lote: POST /v1/systemone/batch com "states".
SKILL
  fi
  touch "$HERMES_DATA/.env"
  sed -i '/^LAYA_BASE_URL=/d;/^LAYA_API_KEY=/d' "$HERMES_DATA/.env"
  printf 'LAYA_BASE_URL=%s\nLAYA_API_KEY=%s\n' "$LAYA_URL" "$LAYA_API_KEY" >> "$HERMES_DATA/.env"
  ok "skill instalada em $HERMES_DATA/skills/laya e variáveis no .env (LAYA_BASE_URL=$LAYA_URL)"
  if [ -n "$HERMES_BIN" ]; then
    "$HERMES_BIN" gateway status >/dev/null 2>&1 && { "$HERMES_BIN" gateway restart >/dev/null 2>&1 && ok "gateway do Hermes reiniciado" || true; }
  elif [ -n "$HERMES_CT" ]; then
    docker restart "$HERMES_CT" >/dev/null && ok "container $HERMES_CT reiniciado"
  fi
fi

cat <<FIM

=============================================================================
 LAYA PRONTO.
   Serviço:   systemctl status laya-serve   |  journalctl -u laya-serve -f
   Endpoint:  http://127.0.0.1:$LAYA_PORT/v1/systemone  (chave em $ENVFILE)
   Hermes:    skill "laya" + LAYA_BASE_URL / LAYA_API_KEY no .env

 Teste no Hermes:  "use a skill laya para classificar este e-mail: ..."
=============================================================================
FIM
