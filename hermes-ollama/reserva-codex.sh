#!/usr/bin/env bash
# =============================================================================
# reserva-codex.sh
# Deixa o Llama local como modelo principal do Hermes e o OpenAI Codex
# (assinatura do ChatGPT já logada no Hermes) apenas como RESERVA, usada
# só quando o modelo local falhar (erro, timeout, servidor fora).
#
# Uso, como root na VPS:   bash reserva-codex.sh
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
  warn "não vi 'OpenAI Codex auth (logged in)' no hermes doctor. Para logar: hermes auth add openai-codex"
fi

log "Gravando a reserva em $CFG"
cp "$CFG" "$CFG.bak.$(date +%Y%m%d%H%M%S)"
# remove blocos antigos fallback_providers:/fallback_model: (até a próxima chave de nível 0)
awk 'BEGIN{skip=0}
     /^(fallback_providers|fallback_model):/{skip=1; next}
     skip && /^[^ \t#-]/{skip=0}
     !skip{print}' "$CFG" > "$CFG.tmp"
cat >> "$CFG.tmp" <<YAML

# Reserva: só entra quando o modelo local (Ollama) falhar. Gasta a cota do
# ChatGPT apenas nesses casos. Para usar o Codex de propósito numa tarefa
# difícil, dentro do chat: /model openai-codex:$CODEX_MODEL
fallback_providers:
  - provider: openai-codex
    model: $CODEX_MODEL
YAML
mv "$CFG.tmp" "$CFG"
ok "fallback_providers = openai-codex / $CODEX_MODEL"

log "Reiniciando o gateway do Hermes"
if "$HERMES_BIN" gateway status >/dev/null 2>&1; then
  "$HERMES_BIN" gateway restart >/dev/null 2>&1 && ok "gateway reiniciado" || warn "rode: hermes gateway restart"
else
  warn "gateway não estava ativo (só afeta Telegram/WhatsApp; o chat 'hermes' no terminal já usa a config nova)"
fi

echo
grep -n -A3 '^model:' "$CFG" | sed 's/^/    /'
grep -n -A2 '^fallback_providers:' "$CFG" | sed 's/^/    /'
echo
ok "pronto. Principal: Llama local. Reserva: Codex (só em falha)."
