#!/usr/bin/env bash
# =============================================================================
# principal-codex.sh
# Em TODOS os perfis do Hermes (padrão + ~/.hermes/profiles/*): OpenAI Codex
# (assinatura do ChatGPT) como modelo PRINCIPAL e o Llama local (Ollama) como
# RESERVA para quando o Codex falhar ou a cota acabar. Também leva a skill do
# Laya para cada perfil.
#
# Uso, como root na VPS:   bash principal-codex.sh
# Variáveis opcionais:     CODEX_MODEL=gpt-5.5
# =============================================================================
set -euo pipefail
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m    OK: %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m    AVISO: %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m    ERRO: %s\033[0m\n' "$*" >&2; exit 1; }

CODEX_MODEL="${CODEX_MODEL:-gpt-5.5}"
HERMES_BIN="$(command -v hermes 2>/dev/null || echo /usr/local/bin/hermes)"
[ -x "$HERMES_BIN" ] || die "não achei o comando hermes"
DEFAULT_HOME=/root/.hermes
[ -f "$DEFAULT_HOME/config.yaml" ] || die "não achei $DEFAULT_HOME/config.yaml"

# modelo local já criado pelo conectar-hermes-ollama.sh (ex.: llama3.2-3b-64k)
LOCAL_MODEL="$(ollama list 2>/dev/null | awk 'NR>1 && $1 ~ /^llama[0-9.]+-[0-9]+b-[0-9]+k/ {sub(":latest","",$1); print $1; exit}' || true)"
[ -n "$LOCAL_MODEL" ] && ok "reserva local: $LOCAL_MODEL" || warn "sem variante local do Llama (rode o conectar-hermes-ollama.sh); vou configurar sem reserva"

PENDENTES=()

aplicar_perfil() {
  local home="$1" nome="$2" cfg="$1/config.yaml"
  log "Perfil '$nome' ($home)"
  [ -f "$cfg" ] || { warn "sem config.yaml, pulando"; return; }

  if HERMES_HOME="$home" "$HERMES_BIN" doctor 2>/dev/null | grep -q 'OpenAI Codex auth (logged in)'; then
    ok "Codex logado neste perfil"
  else
    warn "Codex NÃO está logado neste perfil. Vou pular. Para logar:"
    warn "    HERMES_HOME=$home hermes auth add openai-codex"
    PENDENTES+=("$nome|$home")
    return
  fi

  cp "$cfg" "$cfg.bak.$(date +%Y%m%d%H%M%S)"
  awk 'BEGIN{skip=0}
       /^(model|fallback_providers|fallback_model):/{skip=1; next}
       skip && /^[^ \t#-]/{skip=0}
       !skip{print}' "$cfg" > "$cfg.tmp"
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
  } >> "$cfg.tmp"
  mv "$cfg.tmp" "$cfg"
  ok "model = openai-codex / $CODEX_MODEL ${LOCAL_MODEL:+(reserva $LOCAL_MODEL)}"

  # skill do Laya + variáveis, copiadas do perfil padrão
  if [ "$home" != "$DEFAULT_HOME" ] && [ -f "$DEFAULT_HOME/skills/laya/SKILL.md" ]; then
    mkdir -p "$home/skills/laya"
    cp "$DEFAULT_HOME/skills/laya/SKILL.md" "$home/skills/laya/SKILL.md"
    touch "$home/.env"
    sed -i '/^LAYA_BASE_URL=/d;/^LAYA_API_KEY=/d' "$home/.env"
    grep -E '^LAYA_(BASE_URL|API_KEY)=' "$DEFAULT_HOME/.env" >> "$home/.env" 2>/dev/null || true
    ok "skill laya + LAYA_BASE_URL/LAYA_API_KEY copiados"
  fi

  if HERMES_HOME="$home" "$HERMES_BIN" gateway status >/dev/null 2>&1; then
    HERMES_HOME="$home" "$HERMES_BIN" gateway restart >/dev/null 2>&1 && ok "gateway reiniciado" || warn "rode: HERMES_HOME=$home hermes gateway restart"
  else
    warn "gateway deste perfil não estava ativo"
  fi
}

aplicar_perfil "$DEFAULT_HOME" "padrão"
for d in "$DEFAULT_HOME"/profiles/*/; do
  [ -d "$d" ] || continue
  aplicar_perfil "${d%/}" "$(basename "$d")"
done

# Ollama só como reserva: descarrega o modelo após 10 min ocioso (libera ~4 GB)
if [ -f /etc/systemd/system/ollama.service.d/override.conf ]; then
  log "Ollama em modo reserva: descarregar o modelo após 10 min ocioso"
  sed -i 's/^Environment="OLLAMA_KEEP_ALIVE=.*/Environment="OLLAMA_KEEP_ALIVE=10m"/' /etc/systemd/system/ollama.service.d/override.conf
  systemctl daemon-reload && systemctl restart ollama
  ok "OLLAMA_KEEP_ALIVE=10m"
fi

echo
if [ "${#PENDENTES[@]}" -gt 0 ]; then
  warn "Perfis que ficaram de fora por falta de login no Codex:"
  for p in "${PENDENTES[@]}"; do
    warn "    ${p%%|*}:  HERMES_HOME=${p##*|} hermes auth add openai-codex   (depois rode este script de novo)"
  done
fi
ok "pronto. Teste com: hermes   (perfil padrão)  ou  hermes -p <perfil>"
warn "se o Codex recusar o modelo '$CODEX_MODEL', rode 'hermes model', escolha 'ChatGPT or Codex Subscription' e pegue um da lista."
