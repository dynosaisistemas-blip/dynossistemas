---
name: laya
description: Decisões tipadas rápidas e sem custo (classificar, pontuar, sim/não) usando o modelo Laya rodando localmente na VPS. Use para triagem de e-mails/tickets, roteamento, detecção de intenção, prioridade, moderação ou qualquer "if inteligente" sobre um texto. NÃO gera texto.
---

# Laya: decisões tipadas locais

O Laya (Convai Innovations) é um modelo System-1: recebe um **estado** (texto ou JSON)
e **perguntas tipadas** e devolve respostas com probabilidades calibradas em ~0,3 s na CPU.
Não escreve texto. Use-o quando a tarefa é **decidir**, não **redigir**.

Endpoint (na própria VPS, alcançável do host e de dentro da sandbox Docker):

- URL: `__LAYA_URL__/v1/systemone`
- Header: `Authorization: Bearer __LAYA_KEY__`

Use esses valores literalmente no comando. Não dependa de variáveis de ambiente
(`LAYA_BASE_URL`/`LAYA_API_KEY`): dentro da sandbox elas não existem.

## Tipos de pergunta

| type     | devolve                                   | criteria                                   |
| -------- | ----------------------------------------- | ------------------------------------------ |
| `choice` | uma opção entre várias + probabilidades   | objeto `{opcao: "descrição", ...}`          |
| `score`  | nível numa escala ordenada + distribuição | lista ordenada `["baixo", "médio", "alto"]` |
| `noul`   | probabilidade de "sim" (0 a 1)            | nenhum                                      |

## Como chamar (terminal)

```bash
curl -s "__LAYA_URL__/v1/systemone" \
  -H "Authorization: Bearer __LAYA_KEY__" \
  -H "Content-Type: application/json" \
  -d '{
    "state": {"body": "Fui cobrado duas vezes em março. Quero o reembolso hoje ou cancelo o plano."},
    "questions": {
      "setor":      {"type": "choice", "instructions": "Qual setor deve atender?",
                     "criteria": {"financeiro": "cobranças, pagamentos, reembolsos",
                                  "tecnico": "bugs, falhas, erros do sistema",
                                  "outro": "tudo o mais"}},
      "urgencia":   {"type": "score",  "instructions": "Quão urgente é?",
                     "criteria": ["sem urgência", "em breve", "bloqueante"]},
      "cancelar":   {"type": "noul",   "instructions": "O usuário ameaça cancelar?"}
    }
  }'
```

Resposta (resumida): `answers.setor.choice` = "financeiro", `answers.urgencia.score` ≈ 1.8,
`answers.cancelar.noul` ≈ 0.9, mais `confidence` por pergunta.

## Regras de uso

- Use `choice` com no máximo ~20 opções. Para mais, divida em duas etapas.
- Confie em `confidence`; abaixo de 0,6 trate como incerto e decida você mesmo.
- Em português o roteador escolhe o checkpoint `multilingual` sozinho.
- Se a resposta `noul` parecer travada, refaça como `choice` com duas opções neutras ("A"/"B").
- Vários textos de uma vez: `POST /v1/systemone/batch` com `"states": [...]` (até 64).
