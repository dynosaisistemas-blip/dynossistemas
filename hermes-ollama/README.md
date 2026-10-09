# Conectar o Hermes Agent ao Llama (Ollama) na VPS da Hostinger

> **Premissa:** entendi "Laya" como **Llama**, o modelo open-source da Meta, rodando
> localmente pelo **Ollama** na mesma VPS onde está o Hermes Agent (template Docker
> da Hostinger). Se "Laya" for outra coisa (um app, um número de WhatsApp, outro
> serviço), me diga o que é e eu refaço o guia.

## O que este guia faz

Ao final, o Hermes Agent da sua VPS passa a usar um modelo Llama local em vez de
uma API paga. Nada sai do servidor, sem custo por token.

Arquitetura resultante:

```
[ você: Telegram / WhatsApp / terminal web ]
                 |
     container Docker "hermes" (Hermes Agent)
                 |  http://<gateway-docker>:11434/v1
     Ollama no host da VPS  ->  modelo llama3.x
```

O Hermes do template da Hostinger roda **dentro de um container Docker**. Por isso
`localhost:11434` **não funciona** de dentro do container: o Ollama fica no host, e
o container precisa falar com o IP do gateway da rede Docker (normalmente
`172.17.0.1` ou `172.18.0.1`). O script descobre esse IP sozinho.

## Requisitos

| Item | Mínimo | Recomendado |
| --- | --- | --- |
| RAM da VPS | 8 GB (modelo `llama3.2:3b`) | 16 GB ou mais (modelo `llama3.1:8b`) |
| Disco livre | 5 GB | 15 GB |
| CPU | 2 núcleos | 4 ou mais (KVM 4 / KVM 8 da Hostinger) |
| Hermes Agent | template "Hermes Agent" já instalado pelo hPanel | |

Sem GPU, as respostas são lentas: 5 a 15 tokens por segundo no 3B, 2 a 6 no 8B.
Funciona, mas a primeira resposta de cada conversa pode levar 1 a 3 minutos
(o Hermes manda um prompt grande com as ferramentas). O script já aumenta o
timeout do Hermes para 30 minutos por causa disso.

## Passo a passo (opção automática, recomendada)

1. **Entre na VPS por SSH** como root (ou com `sudo -i`):

   ```bash
   ssh root@SEU_IP_DA_VPS
   ```

2. **Copie o script para a VPS.** Do seu computador:

   ```bash
   scp hermes-ollama/conectar-hermes-ollama.sh root@SEU_IP_DA_VPS:/root/
   ```

   Ou, dentro da VPS, cole o conteúdo do arquivo com `nano /root/conectar-hermes-ollama.sh`.

3. **Rode o script:**

   ```bash
   bash /root/conectar-hermes-ollama.sh
   ```

   Para forçar um modelo específico:

   ```bash
   MODEL=llama3.1:8b NUM_CTX=32768 bash /root/conectar-hermes-ollama.sh
   ```

4. **Teste:**

   ```bash
   docker exec -it hermes hermes
   ```

   (se o container tiver outro nome, o script mostra o nome certo no final).
   Pergunte algo que use ferramenta, por exemplo: *"o que tem no diretório atual?"*.

O script é idempotente. Pode rodar de novo à vontade; ele faz backup do
`config.yaml` antes de mexer.

## O que o script faz, em ordem

1. Acha o container do Hermes e a pasta de dados montada em `/opt/data`
   (na Hostinger costuma ser `~/.hermes`).
2. Descobre o IP do gateway Docker que o container usa para chegar ao host.
3. Escolhe o modelo pela RAM: `llama3.2:3b` abaixo de 10 GB, `llama3.1:8b` acima.
4. Instala o Ollama, se faltar, e o configura para:
   escutar em todas as interfaces (`OLLAMA_HOST=0.0.0.0:11434`),
   manter o modelo carregado 24 h (`OLLAMA_KEEP_ALIVE=24h`),
   subir depois do Docker.
5. Fecha a porta 11434 para a internet. Só `localhost` e as redes Docker
   (`172.16.0.0/12`) podem acessar. Usa `ufw` se estiver ativo, senão `iptables`.
6. Baixa o modelo e cria uma variante com contexto maior (`num_ctx` 32k ou 64k),
   porque o padrão do Ollama (2048 tokens) é pequeno demais para o Hermes usar
   ferramentas.
7. Grava no Hermes:

   ```yaml
   model:
     default: "llama3.1-8b-32k"        # ou llama3.2-3b-32k
     provider: "custom"
     base_url: "http://172.17.0.1:11434/v1"
   ```

   e, em `.env`, `HERMES_API_TIMEOUT=1800`.
8. Reinicia o container e testa o acesso ao Ollama de dentro dele.

## Passo a passo manual (se preferir fazer na mão)

```bash
# 1. Ollama
curl -fsSL https://ollama.com/install.sh | sh
mkdir -p /etc/systemd/system/ollama.service.d
cat > /etc/systemd/system/ollama.service.d/override.conf <<'CONF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_KEEP_ALIVE=24h"
CONF
systemctl daemon-reload && systemctl restart ollama

# 2. Modelo com contexto maior
ollama pull llama3.1:8b
printf 'FROM llama3.1:8b\nPARAMETER num_ctx 32768\n' > /tmp/Modelfile
ollama create llama3.1-8b-32k -f /tmp/Modelfile

# 3. IP do host visto pelo container
docker inspect hermes --format '{{range .NetworkSettings.Networks}}{{.Gateway}}{{end}}'

# 4. Hermes (troque o IP pelo que apareceu acima)
docker exec hermes hermes config set model.provider custom
docker exec hermes hermes config set model.base_url http://172.17.0.1:11434/v1
docker exec hermes hermes config set model.default llama3.1-8b-32k
echo 'HERMES_API_TIMEOUT=1800' >> ~/.hermes/.env
docker restart hermes

# 5. Firewall (não deixe a 11434 aberta para a internet)
ufw allow from 172.16.0.0/12 to any port 11434 proto tcp
ufw deny 11434/tcp
```

Alternativa sem editar arquivos: no terminal web do Hermes, rode `hermes setup`,
escolha **Custom Endpoint** (ou **Ollama**), informe a URL
`http://172.17.0.1:11434/v1`, deixe a chave vazia e digite o nome do modelo.

## Problemas comuns

| Sintoma | Causa provável | Correção |
| --- | --- | --- |
| `Connection refused` | Hermes tentando `localhost` de dentro do container | use o IP do gateway Docker no `base_url` |
| `Connection refused` mesmo com IP certo | Ollama só escutando em `127.0.0.1` | confira `OLLAMA_HOST=0.0.0.0:11434` no override e `systemctl restart ollama` |
| Resposta vazia / timeout no 1º turno | CPU lenta processando o prompt | normal; espere, ou use modelo menor; confirme `HERMES_API_TIMEOUT=1800` |
| Modelo imprime JSON em vez de executar a ferramenta | modelo pequeno sem bom suporte a tool calling | use `llama3.1:8b` ou configure fallback na nuvem (abaixo) |
| Erro de contexto | `num_ctx` padrão de 2048 | use a variante `-32k` criada pelo script |
| VPS trava / swap | modelo maior que a RAM | troque para `llama3.2:3b` |

Comandos úteis:

```bash
ollama list                 # modelos locais
ollama ps                   # modelo carregado agora
journalctl -u ollama -f     # logs do Ollama
docker logs -f hermes       # logs do Hermes
docker exec hermes hermes doctor
```

## Fallback na nuvem (opcional)

Modelos Llama pequenos erram em tarefas complexas. Dá para manter o local como
padrão e cair para a nuvem só quando ele falhar, acrescentando ao `config.yaml`:

```yaml
fallback_providers:
  - provider: openrouter
    model: anthropic/claude-sonnet-4
```

A chave vai em `~/.hermes/.env` como `OPENROUTER_API_KEY=...`.

## Fontes

- Hermes Agent, guia oficial "Run Hermes Locally with Ollama":
  https://hermes-agent.nousresearch.com/docs/guides/local-ollama-setup
- Hostinger, "Como configurar o Hermes Agent (guia completo)":
  https://www.hostinger.com/pt/tutoriais/como-configurar-o-hermes-agent
- Hostinger, "How to set up Hermes Agent (managed or self-hosted)":
  https://www.hostinger.com/tutorials/how-to-set-up-hermes-agent/
