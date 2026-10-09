#!/usr/bin/env bash
# =============================================================================
# conectar-hermes-ollama.sh
# Conecta o Hermes Agent (template Docker da Hostinger) a um modelo Llama
# rodando localmente via Ollama, na mesma VPS.
#
# Uso (como root, via SSH na VPS):
#   bash conectar-hermes-ollama.sh
#
# Variáveis opcionais:
#   MODEL=llama3.1:8b   NUM_CTX=32768   bash conectar-hermes-ollama.sh
#
# O script é idempotente: pode rodar de novo sem quebrar nada.
# =============================================================================
set -euo pipefail

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    OK: %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    AVISO: %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m    ERRO: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "rode como root (sudo -i)."
command -v docker >/dev/null || die "docker não encontrado. Este script é para a VPS com o template Hermes Agent da Hostinger."

# -----------------------------------------------------------------------------
# 1. Localizar o container do Hermes e a pasta de dados (~/.hermes no host)
# -----------------------------------------------------------------------------
log "Procurando o container do Hermes Agent"
HERMES_CT="$(docker ps -a --filter ancestor=nousresearch/hermes-agent --format '{{.Names}}' | head -n1 || true)"
if [ -z "$HERMES_CT" ]; then
  HERMES_CT="$(docker ps -a --format '{{.Names}} {{.Image}}' | awk '/hermes/ {print $1; exit}' || true)"
fi
[ -n "$HERMES_CT" ] || die "nenhum container do Hermes encontrado. Instale o template 'Hermes Agent' no hPanel primeiro."
ok "container: $HERMES_CT"

HERMES_DATA="$(docker inspect "$HERMES_CT" --format '{{range .Mounts}}{{if eq .Destination "/opt/data"}}{{.Source}}{{end}}{{end}}')"
[ -n "$HERMES_DATA" ] || HERMES_DATA="$HOME/.hermes"
mkdir -p "$HERMES_DATA"
ok "pasta de dados do Hermes no host: $HERMES_DATA"

# IP pelo qual o container enxerga o host (gateway da rede Docker dele)
DOCKER_GW="$(docker inspect "$HERMES_CT" --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}' | head -n1)"
[ -n "$DOCKER_GW" ] || DOCKER_GW="172.17.0.1"
ok "o container alcança o host em: $DOCKER_GW"

# -----------------------------------------------------------------------------
# 2. Escolher o modelo conforme a RAM da VPS
# -----------------------------------------------------------------------------
RAM_GB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
if [ -z "${MODEL:-}" ]; then
  if   [ "$RAM_GB" -ge 24 ]; then MODEL="llama3.1:8b";  NUM_CTX="${NUM_CTX:-65536}"
  elif [ "$RAM_GB" -ge 10 ]; then MODEL="llama3.1:8b";  NUM_CTX="${NUM_CTX:-32768}"
  else                            MODEL="llama3.2:3b";  NUM_CTX="${NUM_CTX:-32768}"
  fi
fi
NUM_CTX="${NUM_CTX:-32768}"
TAG_CTX="$(( NUM_CTX / 1024 ))k"
MODEL_CTX="$(echo "$MODEL" | tr ':' '-')-${TAG_CTX}"   # ex: llama3.1-8b-32k
log "RAM detectada: ${RAM_GB} GB -> modelo: $MODEL (contexto ${NUM_CTX} tokens, nome final: $MODEL_CTX)"

# -----------------------------------------------------------------------------
# 3. Instalar o Ollama (se faltar)
# -----------------------------------------------------------------------------
log "Instalando / verificando o Ollama"
if ! command -v ollama >/dev/null; then
  curl -fsSL https://ollama.com/install.sh | sh
fi
ok "ollama $(ollama --version 2>/dev/null | head -n1)"

# -----------------------------------------------------------------------------
# 4. Fazer o Ollama escutar no IP do gateway Docker (acessível pelo container,
#    NÃO acessível pela internet) e manter o modelo carregado.
# -----------------------------------------------------------------------------
log "Configurando o serviço do Ollama"
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<CONF
[Unit]
After=network-online.target docker.service
Wants=network-online.target

[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_KEEP_ALIVE=24h"
Environment="OLLAMA_NUM_PARALLEL=1"
CONF
systemctl daemon-reload
systemctl enable ollama >/dev/null 2>&1 || true
systemctl restart ollama
sleep 3
curl -fsS "http://127.0.0.1:11434/api/tags" >/dev/null || die "Ollama não respondeu em 127.0.0.1:11434. Veja: journalctl -u ollama -n 50"
ok "Ollama no ar"

# Firewall: só o loopback e as redes Docker podem falar com a porta 11434
log "Protegendo a porta 11434 (só containers Docker e localhost)"
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
  ufw allow from 172.16.0.0/12 to any port 11434 proto tcp >/dev/null
  ufw deny 11434/tcp >/dev/null
  ok "regras ufw aplicadas"
else
  if ! iptables -C INPUT -p tcp --dport 11434 ! -s 172.16.0.0/12 ! -i lo -j DROP 2>/dev/null; then
    iptables -I INPUT -p tcp --dport 11434 ! -s 172.16.0.0/12 ! -i lo -j DROP
  fi
  if command -v netfilter-persistent >/dev/null; then netfilter-persistent save >/dev/null 2>&1 || true; fi
  warn "regra iptables aplicada. Para persistir após reboot: apt install -y iptables-persistent"
  warn "Também bloqueie a porta 11434 no firewall do hPanel (VPS -> Segurança -> Firewall)."
fi

# -----------------------------------------------------------------------------
# 5. Baixar o modelo e criar a variante com contexto maior
# -----------------------------------------------------------------------------
log "Baixando o modelo $MODEL (pode demorar alguns minutos)"
ollama pull "$MODEL"
ok "modelo baixado"

log "Criando a variante $MODEL_CTX com num_ctx=$NUM_CTX"
TMP_MF="$(mktemp)"
printf 'FROM %s\nPARAMETER num_ctx %s\n' "$MODEL" "$NUM_CTX" > "$TMP_MF"
ollama create "$MODEL_CTX" -f "$TMP_MF"
rm -f "$TMP_MF"
ok "variante criada"

# Teste rápido do endpoint OpenAI-compatível
log "Testando o modelo pelo endpoint OpenAI-compatível"
curl -fsS "http://127.0.0.1:11434/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"$MODEL_CTX\",\"messages\":[{\"role\":\"user\",\"content\":\"Responda só: ok\"}],\"max_tokens\":5}" \
  | head -c 300; echo
ok "modelo responde"

# -----------------------------------------------------------------------------
# 6. Apontar o Hermes para o Ollama
# -----------------------------------------------------------------------------
BASE_URL="http://${DOCKER_GW}:11434/v1"
log "Gravando a configuração do Hermes (base_url=$BASE_URL, modelo=$MODEL_CTX)"

CFG="$HERMES_DATA/config.yaml"
[ -f "$CFG" ] && cp "$CFG" "$CFG.bak.$(date +%Y%m%d%H%M%S)"

hermes_cli() {
  if docker ps --format '{{.Names}}' | grep -qx "$HERMES_CT"; then
    docker exec "$HERMES_CT" hermes "$@"
  else
    docker run --rm -v "$HERMES_DATA:/opt/data" nousresearch/hermes-agent "$@"
  fi
}

if hermes_cli config set model.provider custom \
   && hermes_cli config set model.base_url "$BASE_URL" \
   && hermes_cli config set model.default "$MODEL_CTX"; then
  ok "config gravada via 'hermes config set'"
else
  warn "'hermes config set' falhou; escrevendo o bloco model: direto no config.yaml"
  touch "$CFG"
  # remove bloco model: antigo (até a próxima chave de nível 0) e acrescenta o novo
  awk 'BEGIN{skip=0} /^model:/{skip=1; next} skip && /^[^ \t#]/{skip=0} !skip{print}' "$CFG" > "$CFG.tmp"
  cat >> "$CFG.tmp" <<YAML

model:
  default: "$MODEL_CTX"
  provider: "custom"
  base_url: "$BASE_URL"
YAML
  mv "$CFG.tmp" "$CFG"
  ok "config.yaml atualizado"
fi

# Timeout maior para CPU (modelos locais demoram no primeiro turno)
ENVF="$HERMES_DATA/.env"
touch "$ENVF"
if grep -q '^HERMES_API_TIMEOUT=' "$ENVF"; then
  sed -i 's/^HERMES_API_TIMEOUT=.*/HERMES_API_TIMEOUT=1800/' "$ENVF"
else
  echo 'HERMES_API_TIMEOUT=1800' >> "$ENVF"
fi
ok ".env: HERMES_API_TIMEOUT=1800"

# -----------------------------------------------------------------------------
# 7. Reiniciar o Hermes e testar de dentro do container
# -----------------------------------------------------------------------------
log "Reiniciando o container $HERMES_CT"
docker restart "$HERMES_CT" >/dev/null
sleep 5

log "Testando o acesso ao Ollama de DENTRO do container"
if docker exec "$HERMES_CT" sh -c "command -v curl >/dev/null && curl -fsS ${BASE_URL%/v1}/api/tags >/dev/null" 2>/dev/null; then
  ok "o container alcança o Ollama em $BASE_URL"
elif docker exec "$HERMES_CT" python3 -c "import urllib.request;urllib.request.urlopen('${BASE_URL%/v1}/api/tags',timeout=10)" 2>/dev/null; then
  ok "o container alcança o Ollama em $BASE_URL"
else
  warn "não consegui confirmar o acesso de dentro do container. Teste manualmente:"
  warn "  docker exec -it $HERMES_CT hermes"
fi

cat <<FIM

=============================================================================
 PRONTO.
   Modelo:    $MODEL_CTX  (Ollama, local, sem custo de API)
   Endpoint:  $BASE_URL
   Container: $HERMES_CT
   Dados:     $HERMES_DATA  (config.yaml / .env)

 Para conversar:   docker exec -it $HERMES_CT hermes
 Ver logs:         docker logs -f $HERMES_CT
 Trocar modelo:    dentro do chat, /model custom:<nome>
 Modelos locais:   ollama list
=============================================================================
FIM
