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
trap 'rc=$?; [ $rc -ne 0 ] && printf "\n\033[1;31mERRO: o script parou na linha %s (código %s).\033[0m\n" "$LINENO" "$rc"' EXIT

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
is_ipv4() { [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; }
DOCKER_GW=""
NET_MODE="$(docker inspect "$HERMES_CT" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null || true)"
if [ "$NET_MODE" = "host" ]; then
  DOCKER_GW="127.0.0.1"
else
  for net in $(docker inspect "$HERMES_CT" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null); do
    for gw in $(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Gateway}} {{end}}' 2>/dev/null); do
      if is_ipv4 "$gw"; then DOCKER_GW="$gw"; break 2; fi
    done
    # rede sem gateway declarado: usa o .1 da sub-rede do container
    cip="$(docker inspect "$HERMES_CT" --format "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" 2>/dev/null || true)"
    if is_ipv4 "$cip"; then DOCKER_GW="${cip%.*}.1"; break; fi
  done
fi
if ! is_ipv4 "$DOCKER_GW"; then
  DOCKER_GW="$(ip -4 addr show docker0 2>/dev/null | awk '/inet / {sub("/.*","",$2); print $2; exit}')"
fi
is_ipv4 "$DOCKER_GW" || DOCKER_GW="172.17.0.1"
ok "o container alcança o host em: $DOCKER_GW"

# -----------------------------------------------------------------------------
# 2. Escolher o modelo conforme a RAM da VPS
# -----------------------------------------------------------------------------
RAM_GB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
if [ -z "${MODEL:-}" ]; then
  if   [ "$RAM_GB" -ge 24 ]; then MODEL="llama3.1:8b";  NUM_CTX="${NUM_CTX:-65536}"
  elif [ "$RAM_GB" -ge 14 ]; then MODEL="llama3.1:8b";  NUM_CTX="${NUM_CTX:-32768}"
  elif [ "$RAM_GB" -ge 10 ]; then MODEL="llama3.2:3b";  NUM_CTX="${NUM_CTX:-32768}"
  else                            MODEL="llama3.2:3b";  NUM_CTX="${NUM_CTX:-16384}"
  fi
fi
NUM_CTX="${NUM_CTX:-16384}"
TAG_CTX="$(( NUM_CTX / 1024 ))k"
MODEL_CTX="$(echo "$MODEL" | tr ':' '-')-${TAG_CTX}"   # ex: llama3.1-8b-32k
log "RAM detectada: ${RAM_GB} GB -> modelo: $MODEL (contexto ${NUM_CTX} tokens, nome final: $MODEL_CTX)"

# -----------------------------------------------------------------------------
# 2b. Swap de 4 GB (evita o OOM killer derrubar o Ollama em VPS com pouca RAM)
# -----------------------------------------------------------------------------
if [ "$RAM_GB" -lt 16 ] && [ -z "$(swapon --show --noheadings 2>/dev/null)" ]; then
  log "Criando swap de 4 GB em /swapfile"
  if [ ! -f /swapfile ]; then
    fallocate -l 4G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=4096 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -q vm.swappiness=10
  grep -q '^vm.swappiness' /etc/sysctl.conf 2>/dev/null || echo 'vm.swappiness=10' >> /etc/sysctl.conf
  ok "swap ativo: $(swapon --show --noheadings | awk '{print $3}' | head -n1)"
else
  ok "swap: $(swapon --show --noheadings 2>/dev/null | awk '{print $3}' | head -n1 || echo 'não necessário')"
fi

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
Environment="OLLAMA_MAX_LOADED_MODELS=1"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
Environment="OLLAMA_LOAD_TIMEOUT=15m"
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
for old_variant in $(ollama list 2>/dev/null | awk -v base="$(echo "$MODEL" | tr ':' '-')-" 'NR>1 && index($1, base)==1 {sub(":latest","",$1); print $1}'); do
  [ "$old_variant" = "$MODEL_CTX" ] && continue
  ollama rm "$old_variant" >/dev/null 2>&1 && warn "variante antiga removida: $old_variant" || true
done

# Teste do endpoint OpenAI-compatível (primeira carga na CPU pode levar 1-2 min)
log "Testando o modelo pelo endpoint OpenAI-compatível"
TEST_OK=0
for tentativa in 1 2 3; do
  systemctl is-active --quiet ollama || { warn "ollama parado, reiniciando"; systemctl restart ollama; sleep 5; }
  RESP="$(curl -sS --max-time 600 "http://127.0.0.1:11434/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$MODEL_CTX\",\"messages\":[{\"role\":\"user\",\"content\":\"Responda só: ok\"}],\"max_tokens\":5}" 2>&1 || true)"
  if printf '%s' "$RESP" | grep -q '"choices"'; then TEST_OK=1; break; fi
  warn "tentativa $tentativa falhou: $(printf '%s' "$RESP" | head -c 200)"
  sleep 10
done
if [ "$TEST_OK" -eq 1 ]; then
  printf '%s\n' "$RESP" | head -c 300; echo
  ok "modelo responde"
else
  warn "o modelo não respondeu. Últimas linhas do log do Ollama:"
  journalctl -u ollama -n 30 --no-pager || true
  warn "Vou gravar a configuração do Hermes mesmo assim; teste depois com: docker exec -it $HERMES_CT hermes"
fi

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
