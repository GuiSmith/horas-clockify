# horas

Script em Bash que consulta a API do Clockify e mostra, no terminal, um relatório das horas trabalhadas no **mês de faturamento**, com um gráfico de barras em texto (uma linha por dia) e um resumo de horas máximas, meta e realizadas no período.

## Como usar

```bash
cp .env.example .env   # e preencha os valores (seção 3)
./horas.sh
```

Teclas: **A** mês anterior · **D** próximo mês · **Q** sair. Se a saída for redirecionada (ex.: `./horas.sh > relatorio.txt`), o script imprime o mês atual sem cores e encerra.

---

## 1. Visão geral

Ao executar o script:

1. Ele lê as configurações do arquivo `.env`.
2. Descobre quem é o usuário dono da API key (rota de "usuário atual" do Clockify).
3. Busca o nome do workspace configurado.
4. Calcula qual é o **mês de faturamento atual** (que **não** é necessariamente o mês do calendário do dia de hoje — ver seção 4).
5. Busca os feriados nacionais na BrasilAPI para saber quais dias são úteis.
6. Busca todas as entradas de horas (*time entries*) do usuário dentro do período.
7. Desenha o relatório: cabeçalho, uma linha por dia com barra e total, e o resumo do período.
8. Fica aguardando uma tecla para navegar entre períodos:
   - **A** → mês de faturamento anterior
   - **D** → próximo mês de faturamento (só existe se não estiver no mês atual)
   - **Q** → sair

---

## 2. Requisitos

| Ferramenta | Uso |
|---|---|
| `bash` 4.4+ | interpretador do script |
| `curl` | chamadas HTTP (Clockify e BrasilAPI) |
| `jq` | leitura do JSON retornado pelas APIs |
| `date` (GNU coreutils) | cálculos de datas e fuso horário |
| `awk` | contas com decimais (ex.: meta diária de 7.5h) |
| Terminal com cores ANSI | barras e totais coloridos |

---

## 3. Configuração (`.env`)

Copie o `.env.example` para `.env` e preencha. O `.env` **não é versionado** (está no `.gitignore`).

```dotenv
# --- Clockify ---
CLOCKIFY_API_KEY=
CLOCKIFY_WORKSPACE_ID=

# --- Mês de faturamento ---
FATURAMENTO_DIA_INICIAL=26

# --- Horas ---
HORAS_MAX_MES=168
HORAS_META_DIA=7
```

| Variável | Valores aceitos | Como é usada |
|---|---|---|
| `CLOCKIFY_API_KEY` | texto | É a chave que autentica todas as chamadas ao Clockify (header `X-Api-Key`). Nunca é impressa nem aparece em mensagens de erro. |
| `CLOCKIFY_WORKSPACE_ID` | texto | Diz qual workspace consultar: é usada para buscar o nome do workspace e as entradas de horas. |
| `FATURAMENTO_DIA_INICIAL` | inteiro de 1 a 28 | É o dia em que cada período de faturamento começa. O período termina no dia anterior, no mês seguinte. O limite de 28 garante que a regra funcione em fevereiro. Com `1`, o período coincide com o mês do calendário. |
| `HORAS_MAX_MES` | número > 0 | É o teto de horas do período. Aparece na linha **Máximo** do resumo e, quando ultrapassado, deixa o **Realizado** amarelo (seção 6.5). |
| `HORAS_META_DIA` | número > 0, decimal com ponto (`7.5` = 7h30) | É a meta de horas por dia útil. Decide a cor da barra e do total de cada dia (seções 6.3 e 6.4) e é a base do cálculo da **Meta** e do **Esperado** (seção 6.5). |

Se alguma variável estiver ausente ou inválida, o script para antes de chamar qualquer API, com uma mensagem dizendo qual variável corrigir.

---

## 4. Mês de faturamento

O relatório é sempre organizado por **mês de faturamento** (período de faturamento), e não pelo mês do calendário.

- Cada período começa no dia `FATURAMENTO_DIA_INICIAL` de um mês e termina no dia anterior, no mês seguinte.
- O período recebe o **nome do mês em que termina**.
- O **período atual** é o que contém o dia de hoje.

Exemplos com `FATURAMENTO_DIA_INICIAL=26`:

| Hoje | Período atual | Nome |
|---|---|---|
| 03/10/2026 | 26/09/2026 → 25/10/2026 | Outubro/2026 |
| 25/10/2026 | 26/09/2026 → 25/10/2026 | Outubro/2026 |
| 26/10/2026 | 26/10/2026 → 25/11/2026 | Novembro/2026 |
| 28/12/2026 | 26/12/2026 → 25/01/2027 | Janeiro/2027 |

Contexto: o salário pago no dia 15 de um mês corresponde ao período de faturamento que terminou no dia 25 do mês anterior. Exemplo: o pagamento de 15/10 se refere ao período de 26/08 a 25/09 ("Setembro").

---

## 5. Dias úteis e feriados

- **Dia útil:** qualquer dia de segunda a sexta que não seja feriado nacional.
- **Dia não útil:** sábado, domingo ou feriado nacional.
- **Fonte dos feriados:** BrasilAPI, `GET https://brasilapi.com.br/api/feriados/v1/{ano}` (pública, sem chave, só leitura).
- **Todos os dias retornados pela BrasilAPI são considerados não úteis**, inclusive os que pela lei são ponto facultativo e a API marca como "national" (segunda e terça de Carnaval, Corpus Christi).
- Se o período cruza a virada do ano (ex.: 26/12/2026 → 25/01/2027), o script busca os feriados **dos dois anos**.
- Se a BrasilAPI não responder, o script continua considerando apenas sábados e domingos como dias não úteis e mostra um aviso no rodapé de que os feriados não foram considerados.
- Essas regras ficam fixas no código, não no `.env`.

---

## 6. Layout do relatório

```
Usuário:    Fulano da Silva
Workspace:  Aktie Now
Mês:        Outubro/2026 (26/09/2026 a 25/10/2026)

26/09/26 [          ] 00:00 (sáb)
27/09/26 [          ] 00:00 (dom)
28/09/26 [=====     ] 04:59
29/09/26 [=======   ] 07:08
30/09/26 [=======   ] 06:53
...

Máximo:     168:00
Meta:       133:00
Esperado:   035:00
Realizado:  029:09
Diferença:  005:51

[A] mês anterior   [D] próximo mês   [Q] sair
```

### 6.1 Cabeçalho

Três informações, nesta ordem:
1. **Usuário:** nome vindo da rota de usuário atual do Clockify.
2. **Workspace:** nome do workspace de `CLOCKIFY_WORKSPACE_ID`.
3. **Mês:** nome do período de faturamento exibido, seguido das datas de início e fim.

### 6.2 Linhas de dia

Uma linha por dia do período, em ordem cronológica, **incluindo** fins de semana, feriados e dias sem horas lançadas:

```
DD/MM/AA [barra] HH:MM [marcador]
```

- **Data:** dia/mês/ano com 2 dígitos cada.
- **Barra:** entre colchetes; cada caractere `=` representa uma hora (seção 6.3). O espaço restante é preenchido com espaços, para que todos os `]` fiquem alinhados.
- **Total do dia:** soma de todas as entradas do dia, em `HH:MM` (seção 6.4).
- **Marcador:** só em dias não úteis: `(sáb)`, `(dom)` ou `(feriado: <nome>)`.
- **Dias sem entradas:** barra vazia e `00:00`.
- **Período atual:** a lista vai só até **hoje**; dias futuros não aparecem.

### 6.3 Regra da barra (cada `=` = 1 hora)

Dado o total do dia em horas cheias `H` e minutos restantes `M`:

1. São desenhados `H` sinais `=`, um para cada hora completa. A **cor** deles depende da meta diária:
   - total do dia **≥** `HORAS_META_DIA` → **verdes**;
   - total do dia **<** `HORAS_META_DIA` → **vermelhos**.
2. Se `M > 30`, entra mais um `=` **amarelo** no final, independentemente da meta.
3. Se `M ≤ 30`, não entra nenhum `=` extra. Exatamente 30 minutos **não** gera o amarelo.

Em **dias não úteis** não há meta (ela é zero), então as horas completas são sempre **verdes**.

Exemplos com `HORAS_META_DIA=7`, em dia útil:

| Total | Barra | Composição |
|---|---|---|
| `04:59` | `[=====     ]` | 4 vermelhos + 1 amarelo |
| `07:08` | `[=======   ]` | 7 verdes |
| `07:45` | `[========  ]` | 7 verdes + 1 amarelo |
| `06:53` | `[=======   ]` | 6 vermelhos + 1 amarelo |
| `03:30` | `[===       ]` | 3 vermelhos (30 min exatos não geram amarelo) |
| `00:20` | `[          ]` | vazio |

**Largura da barra:** mínimo de 10 posições. Se algum dia do período exibido passar disso, a largura aumenta em todas as linhas daquele período para caber o maior dia, mantendo o alinhamento.

### 6.4 Regra da cor do total do dia

O texto `HH:MM` do dia segue a mesma comparação com a meta diária:

| Situação | Cor |
|---|---|
| Dia útil, total **≥** `HORAS_META_DIA` | **verde** |
| Dia útil, total **<** `HORAS_META_DIA` | **vermelho** |
| Dia não útil (sábado, domingo, feriado) | **cinza** (neutro), com o marcador da seção 6.2 |

### 6.5 Resumo do período

| Linha | Cálculo | Cor |
|---|---|---|
| **Máximo** | `HORAS_MAX_MES` | sem cor |
| **Meta** | quantidade de dias úteis do **período inteiro** (do dia inicial ao dia final, mesmo no período atual) × `HORAS_META_DIA` | sem cor |
| **Esperado** | quantidade de dias úteis do dia inicial do período até **ontem** × `HORAS_META_DIA`. É quanto já deveria ter sido trabalhado. Em períodos passados, todos os dias já passaram, então o Esperado é igual à Meta. | sem cor |
| **Realizado** | soma das horas e minutos lançados do **dia inicial** do período até **hoje** (no período atual) ou até o **dia final** (em períodos passados). Horas lançadas em dias não úteis também contam. | **amarelo** se passar de `HORAS_MAX_MES` (essa regra tem prioridade); senão **verde** se for maior ou igual ao Esperado e **vermelho** se for menor |
| **Diferença** | Esperado − Realizado. Positiva = horas que faltam; negativa (com `-` na frente) = horas trabalhadas a mais. | **vermelha** se maior que zero; **verde** se zero ou negativa |

Todos os valores aparecem no formato `HHH:MM`.

Exemplo do Esperado: em 03/10/2026 (sábado), os dias úteis já passados do período são 28/09 a 02/10, ou seja, 5 dias × 7h = **035:00**. Com 029:09 realizadas, a Diferença é **005:51** (vermelha).

Exemplo: o período de 26/09/2026 a 25/10/2026 tem 20 dias de segunda a sexta, e um deles é feriado (12/10, Nossa Senhora Aparecida). Sobram **19 dias úteis**, então a Meta é 19 × 7h = **133:00**.

---

## 7. Fontes de dados

### 7.1 Clockify

Base: `https://api.clockify.me/api/v1`, com autenticação pelo header `X-Api-Key`.

| Etapa | Rota | O que se usa da resposta |
|---|---|---|
| Usuário atual | `GET /user` | `id`, `name`, fuso horário do usuário (`settings.timeZone`) |
| Workspace | `GET /workspaces/{workspaceId}` | `name` |
| Entradas de horas | `GET /workspaces/{workspaceId}/user/{userId}/time-entries?start=…&end=…&page=…&page-size=…` | `timeInterval.start`, `timeInterval.end` |

- A busca de entradas é **paginada**: o script continua pedindo páginas até receber uma página incompleta.
- `start` da busca é o início do dia **anterior** ao dia inicial (margem para pegar entradas que começaram antes e terminaram dentro do período); `end` é o fim do dia final. Ambos no fuso do usuário, convertidos para UTC. A parte de cada entrada fora do período é descartada.
- Todas as datas e horas exibidas usam o **fuso horário configurado no perfil do Clockify do usuário**.

### 7.2 BrasilAPI

`GET https://brasilapi.com.br/api/feriados/v1/{ano}`: usa `date` e `name` de cada feriado (ver seção 5).

### 7.3 Cache em memória

Os dados de cada período (entradas e feriados) são buscados uma única vez por execução. Ao voltar para um período já visto, nenhuma chamada é refeita.

---

## 8. Navegação entre períodos

- Ao abrir, o script sempre mostra o **período de faturamento atual**.
- No rodapé aparecem as opções disponíveis:
  - `[A] mês anterior`: sempre disponível.
  - `[D] próximo mês`: **só aparece** quando o período exibido é anterior ao atual. No período atual, a opção não é mostrada e a tecla D é ignorada.
  - `[Q] sair`.
- As teclas funcionam sem precisar apertar Enter e aceitam maiúscula ou minúscula.
- A cada troca de período, a tela é limpa e o relatório é redesenhado.

---

## 9. Regras de borda

| Situação | Comportamento |
|---|---|
| Timer em andamento (entrada sem `end`) | Conta até o momento atual. |
| Entrada que atravessa a meia-noite | É dividida entre os dias. Exemplo: de 23h25 do dia 03 até 00h25 do dia 04 → 35 min no dia 03 e 25 min no dia 04. |
| Entrada que começa antes ou termina depois do período | Só a parte dentro do período é contada. |
| Dia sem nenhuma entrada | Linha com barra vazia e `00:00`. |
| Dias futuros do período atual | Não aparecem. |
| BrasilAPI fora do ar | Considera só fins de semana como dias não úteis e mostra um aviso (seção 5). |
| Erro no Clockify (rede, 401, 403/404) | Mensagem de erro clara e saída com código diferente de zero. |
| Saída não é um terminal (ex.: redirecionada para arquivo) | Sem cores e sem navegação: imprime o período atual e encerra. |

---

## 10. Segurança

- A API key fica **apenas** no `.env`, que está no `.gitignore`.
- O script nunca imprime a API key, nem em mensagens de erro.
- Só leitura: o script faz apenas chamadas `GET`, ao Clockify e à BrasilAPI.
- Recomendado: `chmod 600 .env`, para só o seu usuário ler a API key.

---

## 11. Testes

Não há testes automatizados (o projeto é um script Bash pessoal, sem Jest). A validação é manual: rodar `./horas.sh` e conferir as regras das seções 4 a 9.
