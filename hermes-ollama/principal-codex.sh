#!/usr/bin/env bash
# =============================================================================
# principal-codex.sh
# Hermes com o OpenAI Codex (assinatura do ChatGPT, já logada) como modelo
# PRINCIPAL e o Llama local (Ollama) como RESERVA para quando o Codex falhar
# ou a cota da assinatura acabar.
#
# Uso, como root na VPS:   bash principal-codex.sh
# Variáveis opcionais:     CODEX_MODEL=gpt-5.5   HERMES_HOME=/root/.hermes
# =============================================================================
set -euo pipefail
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    OK: %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    AVISO: %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m    ERRO: %s\033[0m\n' "$*" >&2; exit 1; }

HERMES_HOME="${HERMES_HOME:-/root/.hermes}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
CFG="$HERMES_HOME/config.yaml"
[ -f "$CFG" ] || die "não achei $CFG"
HERMES_BIN="$(command -v hermes 2>/dev/null || echo /usr/local/bin/hermes)"

log "Conferindo o login do Codex no Hermes"
if "$HERMES_BIN" doctor 2>/dev/null | grep -q 'OpenAI Codex auth (logged in)'; then
  ok "Codex logado"
else
  die "Codex não está logado. Rode: hermes auth add openai-codex   (e depois este script de novo)"
fi

# modelo local já criado pelo conectar-hermes-ollama.sh (ex.: llama3.2-3b-64k)
LOCAL_MODEL="$(ollama list 2>/dev/null | awk 'NR>1 && $1 ~ /^llama[0-9.]+-[0-9]+b-[0-9]+k/ {sub(":latest","",$1); print $1; exit}' || true)"
if [ -n "$LOCAL_MODEL" ]; then
  ok "reserva local: $LOCAL_MODEL"
else
  warn "não achei a variante local do Llama (rode o conectar-hermes-ollama.sh). Vou configurar sem reserva."
fi

log "Gravando a configuração em $CFG"
cp "$CFG" "$CFG.bak.$(date +%Y%m%d%H%M%S)"
awk 'BEGIN{skip=0}
     /^(model|fallback_providers|fallback_model):/{skip=1; next}
     skip && /^[^ \t#-]/{skip=0}
     !skip{print}' "$CFG" > "$CFG.tmp"
{
  echo
  echo "# Principal: Codex (cota da assinatura do ChatGPT, sem cobrança por token)."
  echo "model:"
  echo "  default: \"$CODEX_MODEL\""
  echo "  provider: \"openai-codex\""
  if [ -n "$LOCAL_MODEL" ]; then
    echo
    echo "# Reserva: Llama local, só quando o Codex falhar ou a cota acabar."
    echo "# Para forçar o local numa conversa: /model custom:$LOCAL_MODEL"
    echo "fallback_providers:"
    echo "  - provider: custom"
    echo "    model: $LOCAL_MODEL"
    echo "    base_url: http://127.0.0.1:11434/v1"
  fi
} >> "$CFG.tmp"
mv "$CFG.tmp" "$CFG"
ok "principal = openai-codex / $CODEX_MODEL"

# Ollama só como reserva: descarrega o modelo após 10 min ocioso (libera ~4 GB)
if [ -f /etc/systemd/system/ollama.service.d/override.conf ]; then
  log "Ollama em modo reserva: descarregar o modelo após 10 min ocioso"
  sed -i 's/^Environment="OLLAMA_KEEP_ALIVE=.*/Environment="OLLAMA_KEEP_ALIVE=10m"/' /etc/systemd/system/ollama.service.d/override.conf
  systemctl daemon-reload && systemctl restart ollama
  ok "OLLAMA_KEEP_ALIVE=10m"
fi

log "Reiniciando o gateway do Hermes"
if "$HERMES_BIN" gateway status >/dev/null 2>&1; then
  "$HERMES_BIN" gateway restart >/dev/null 2>&1 && ok "gateway reiniciado" || warn "rode: hermes gateway restart"
else
  warn "gateway não estava ativo (só afeta Telegram/WhatsApp; o chat 'hermes' no terminal já usa a config nova)"
fi

echo
grep -n -A2 '^model:' "$CFG" | sed 's/^/    /'
grep -n -A3 '^fallback_providers:' "$CFG" | sed 's/^/    /' || true
echo
ok "pronto. Teste com: hermes"
warn "se o Codex recusar o modelo '$CODEX_MODEL', rode 'hermes model', escolha 'ChatGPT or Codex Subscription' e pegue um da lista."
