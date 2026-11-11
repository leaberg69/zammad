# Runbook de go-live — Central de Atendimento Grupo LRI

Passo a passo da fase 5 do [plano](PLANO.md#8-roteiro-por-fases): subir a central na VPS do grupo com a imagem do
fork, atrás do Cloudflare Tunnel, sem porta publicada no host.

Este repositório é público. Endereços, nomes de usuário do servidor, tokens e saídas de comando ficam no **registro
privado da operação**, nunca aqui. Cada etapa no servidor exige OK do Leandro dado na hora; apagar qualquer coisa
existente (volumes, containers, stacks) é etapa à parte, com OK próprio.

## 0. Antes de começar

| Item | Onde |
| ---- | ---- |
| Decisão de capacidade da VPS (ampliar ou reduzir a central) tomada; a soma dos `mem_limit` do overlay em operação é de cerca de 8,2 GB | [checklist](VPS-CHECKLIST.md), seção 1 |
| Snapshot completo da VPS no provedor, com data e responsável | checklist, seção 7 |
| Leitura do servidor refeita com LF (`contrib/lri/vps/checklist-leitura.sh`) e registrada | checklist, introdução |
| Imagem escolhida: uma tag `develop-<sha>` publicada pelo workflow `LRI imagem` (resumo da execução no GitHub Actions) ou uma versão `X.Y.Z` (tag `lri-vX.Y.Z`), de um commit que contenha este runbook (seção 11); anotar o digest e o **commit do fork** que gerou a imagem (o `<sha>` da tag `develop-`, ou o commit da tag `lri-v`) | GitHub, aba Actions e pacote `zammad-lri` |
| Scan da imagem conferido: artefato `trivy-zammad-lri` da mesma execução, sem CRITICAL com correção disponível | GitHub Actions |

## 1. Acesso da VPS à imagem

O pacote `ghcr.io/leaberg69/zammad-lri` nasce **privado**. Escolher um caminho (decisão do Leandro):

- **Pacote público**: em GitHub › Packages › `zammad-lri` › Package settings, mudar a visibilidade. A imagem não tem
  segredos (o repositório já é público); nada mais é preciso na VPS.
- **Pacote privado**: criar um token clássico só com `read:packages`, com validade curta, e na VPS, como o usuário
  da central: `docker login ghcr.io -u <usuário do GitHub>` (o token é a senha; não fica em arquivo do repositório).

## 2. Diretório da central

Como o usuário de sistema da central (checklist, seção 7):

```sh
git clone https://github.com/zammad/zammad-docker-compose.git central && cd central
git checkout cee5e1cef02543977de6d13937ba8cc7276b5a5a   # o commit conferido pelo CI do fork
FORK_COMMIT=<commit do fork anotado no passo 0>         # o mesmo da imagem: overlay e imagem conferidos juntos
curl -fsSL "https://raw.githubusercontent.com/leaberg69/zammad/$FORK_COMMIT/contrib/lri/deploy/docker-compose.lri.yml" \
  -o docker-compose.lri.yml
curl -fsSL "https://raw.githubusercontent.com/leaberg69/zammad/$FORK_COMMIT/contrib/lri/deploy/subir-central.sh" \
  -o subir-central.sh
mkdir -p cloudflared
curl -fsSL "https://raw.githubusercontent.com/leaberg69/zammad/$FORK_COMMIT/contrib/lri/deploy/cloudflared/config.yml.example" \
  -o cloudflared/config.yml
```

`subir-central.sh` é a subida com portões usada no go-live, nas atualizações e no retorno: para o túnel e a
aplicação, confere a tag, sobe banco, cache, Redis e Elasticsearch (em yellow ou green), roda o `zammad-init` da
imagem escolhida (migrações) com prazo, sobe Rails, WebSocket e Nginx e confere imagem e resposta de cada um,
reconstrói o índice se `REINDEXAR=1` e, só com `ABRIR_TUNEL=1` e tudo aprovado, libera: sobe scheduler e backup e
reabre o túnel até a conexão ficar ativa. Sem `ABRIR_TUNEL=1`, scheduler, backup e túnel ficam parados para
conferência manual. Qualquer falha para com `PARAR:`, o motivo e o estado do túnel e do init. O CI testa essa
sequência (`subir_central_test.sh`).

Overlay, script e configuração do túnel vêm do **mesmo commit da imagem**, nunca da ponta da `develop`: é esse
conjunto que o workflow `LRI imagem` conferiu (o overlay renderizado dentro da imagem construída). O commit da stack
oficial é o mesmo que o CI usa nessa conferência; outro commit exige refazê-la.

## 3. Cloudflare

1. Criar o túnel **gerenciado localmente** (`cloudflared tunnel create central-atendimento`) e obter o token
   (`cloudflared tunnel token central-atendimento`). O token vai só para o `.env` (passo 4).
2. Preencher `cloudflared/config.yml`: ID do túnel e AUD do aplicativo do Access. Na **fase A** (passo 6), deixar só
   o bloco do nome interno e o `http_status:404` final; os três nomes `suporte` entram na fase B.
3. DNS: `atendimento.lri.com.br` como `CNAME` do túnel. Os três `suporte` só na fase B.
4. Access: aplicativo do nome interno com os provedores da equipe (Google Workspace da LRI, Entra ID da IRD.Net) e
   `SameSite` diferente de `Strict` (checklist, seção 4).

## 4. Arquivo `.env`

No diretório da central, criar o arquivo já restrito, **antes** de pôr qualquer segredo nele, e conferir:

```sh
(umask 077 && touch .env) && chmod 600 .env && stat -c '%a %U' .env   # 600 e o usuário da central
```

Valores gerados só para a central, guardados no cofre do grupo:

| Variável | Valor |
| -------- | ----- |
| `LRI_IMAGE_TAG` | a tag escolhida no passo 0 (`develop-<sha de 40>` ou `X.Y.Z`; `latest` é recusado na partida) |
| `LRI_ZONE_KEY` | 48+ caracteres aleatórios `[A-Za-z0-9_-]`, por exemplo `openssl rand -base64 48 \| tr '+/' '-_' \| tr -d '='` |
| `LRI_ACCESS_AUD` | AUD do aplicativo do Access do nome interno |
| `LRI_EMERGENCY_LOGIN` | login da conta de emergência (a única da equipe com senha) |
| `CLOUDFLARED_VERSION` | versão fixa do `cloudflare/cloudflared` |
| `CLOUDFLARED_TUNNEL_TOKEN` | token do passo 3 |
| `POSTGRES_PASS`, `POSTGRES_SUPERUSER_PASS` | senhas aleatórias, diferentes entre si |
| `TZ` | `America/Sao_Paulo` |
| `LRI_ZONE_GUARD` | `off` na fase A; removida (padrão `enforce`) na fase B |
| `LRI_MEM_*` | só se a decisão de capacidade pedir tetos diferentes dos do overlay |

Conferir a renderização sem subir nada:

```sh
docker compose -f docker-compose.yml -f docker-compose.lri.yml config --quiet
```

## 5. Imagens

```sh
docker compose -f docker-compose.yml -f docker-compose.lri.yml pull
docker image inspect ghcr.io/leaberg69/zammad-lri:<tag do .env> --format '{{index .RepoDigests 0}}'
```

O digest tem de ser o anotado no passo 0.

## 6. Fase A — só o nome interno, guarda desligada

Objetivo: criar a conta de emergência com 2FA e provisionar antes de ligar a guarda (PLANO, seção 2.9.2). Nesta
fase só o nome interno, protegido pelo Access, chega à central.

```sh
ABRIR_TUNEL=1 bash subir-central.sh
```

- A saída termina com `PORTÕES OK` e o túnel reaberto (só com o nome interno no `config.yml`).
- Log do railsserver: `guarda de zona LRI desligada`.

No nome interno, pelo navegador (passando pelo Access):

1. Assistente inicial do Zammad: criar o administrador com o login de `LRI_EMERGENCY_LOGIN`.
2. Nesse usuário, cadastrar o 2FA por **aplicativo autenticador (TOTP)**; manter o método ligado nas configurações.
3. Endereços da aplicação (PLANO, seção 2.6), **antes** de configurar os provedores de login e e-mail, porque os
   retornos de OAuth, os links dos e-mails e a origem aceita no WebSocket saem deles. O assistente, aberto pelo nome
   interno, pode ter gravado outro endereço:

   ```sh
   docker compose -f docker-compose.yml -f docker-compose.lri.yml exec zammad-railsserver bundle exec rails runner '
     Setting.set("http_type", "https"); Setting.set("fqdn", "suporte.lri.com.br")
     Setting.set("alternative_fqdn", "suporte.ird.net.br")
     puts %w[http_type fqdn alternative_fqdn].map { |name| "#{name}=#{Setting.get(name)}" }'
   ```

   A saída tem de mostrar `http_type=https fqdn=suporte.lri.com.br alternative_fqdn=suporte.ird.net.br`. Depois,
   recriar `zammad-railsserver` e `zammad-websocket` (`up -d --force-recreate`), que leem esses valores na partida.
4. Provisionamento: simular, aplicar e conferir. O mesmo comando três vezes, a primeira com `DRY_RUN=1`:

   ```sh
   docker compose -f docker-compose.yml -f docker-compose.lri.yml exec zammad-railsserver \
     sh -c 'DRY_RUN=1 bundle exec rails runner contrib/lri/provisionamento/provisionar.rb'   # Simulação: nada foi gravado.
   docker compose -f docker-compose.yml -f docker-compose.lri.yml exec zammad-railsserver \
     bundle exec rails runner contrib/lri/provisionamento/provisionar.rb                     # Provisionamento aplicado.
   docker compose -f docker-compose.yml -f docker-compose.lri.yml exec zammad-railsserver \
     bundle exec rails runner contrib/lri/provisionamento/provisionar.rb                     # Nada a mudar
   ```

   Nenhuma linha `CONFLITO` em nenhuma das três; a terceira, que confere a idempotência, termina com `Nada a mudar`.
5. Branding, no mesmo container: `docker compose -f docker-compose.yml -f docker-compose.lri.yml exec
   zammad-railsserver bundle exec rails runner contrib/lri/branding/aplicar_branding.rb`.
6. Login por Google e Microsoft **cadastrados**, com `auth_third_party_no_create_user` ligado, e agentes cadastrados
   com o perfil da marca. Só cadastrados: o retorno do OAuth vai para o `fqdn` público, que ainda não está no túnel,
   então o teste fica para a fase B (passo 6); até lá a equipe entra só pela conta de emergência.

## 7. Fase B — guarda ligada e portais públicos

A guarda é ligada e conferida **com o túnel ainda só interno**; os portais públicos só entram depois.

1. No `.env`, remover `LRI_ZONE_GUARD` (o overlay usa `enforce`).
2. Subir com os portões e **sem** reabrir o túnel: `bash subir-central.sh` (termina com `PORTÕES OK` e o túnel
   parado).
3. Conferir, ainda com túnel e processos de fundo parados: nos logs de railsserver e websocket, `guarda de zona LRI
   LIGADA`; no railsserver, `conta de emergência: (login), com 2FA`. Se qualquer item falhar, parar aqui. (O
   scheduler só é recriado na liberação, no passo 5, e é conferido ali.)
4. Senhas locais da equipe, exceto a de emergência, trocadas por valores aleatórios (checklist, seção 5).
5. Só então abrir os portais: em `cloudflared/config.yml`, acrescentar os três nomes `suporte`; validar
   (`ingress validate`, seção 10); `ABRIR_TUNEL=1 bash subir-central.sh` (repete os portões, libera scheduler e
   backup e reabre o túnel até a conexão ficar ativa); conferir no log do scheduler `guarda de zona LRI LIGADA`; e,
   por último, trocar o DNS dos três `suporte` para `CNAME` do túnel.
6. **Validar o login da equipe** (obrigatório antes de dar o go-live por concluído): pelo nome interno, entrar com
   Google (conta da LRI) e com Microsoft (conta da IRD.Net); o retorno passa pelo `fqdn` e volta ao nome interno
   (PLANO, seção 2.9.2). Se falhar, a equipe continua só com a conta de emergência e o go-live não fecha.

## 8. Conferências

- Seções 4 e 5 do [checklist](VPS-CHECKLIST.md), item a item, com o resultado no registro privado.
- Nenhuma porta da central no host: `ss -tlnp` não mostra nada da central, e acesso direto ao IP falha.
- Portal público de cada marca: login do cliente sem os botões de Google e Microsoft; abrir chamado; a mesma
  tentativa com uma conta da equipe é recusada.
- Nome interno: equipe entra por Google ou Microsoft; WebSocket conectado; conta de emergência com senha e 2FA.
- Memória: `docker stats --no-stream` dentro dos tetos e sem reinícios por falta de memória
  (`docker inspect --format '{{.State.OOMKilled}}'`).

## 9. Retorno

- **Problema na central, VPS sã**: `docker compose -f docker-compose.yml -f docker-compose.lri.yml down` (os volumes
  ficam) e DNS dos `suporte` de volta ao estado anterior. Os outros projetos do servidor não são tocados.
- **Imagem com defeito**: voltar ao conjunto anterior guardado na atualização (seção 10). Se as notas da versão nova
  confirmarem que não há migração de banco entre as duas, basta repor o conjunto e subir a stack inteira; nos demais
  casos, parar a central, restaurar o backup feito antes da troca (banco e arquivos juntos, do mesmo momento), repor
  o conjunto e só então subir. Restaurar apaga o que entrou depois do backup: decisão do Leandro.

  O atendimento só reabre no fim:

  1. Com o conjunto anterior reposto (e o backup restaurado, se for o caso), subir com os portões e o túnel parado.
     Se o banco foi restaurado, o índice de busca ficou mais novo que ele (a partida não o refaz quando o índice já
     existe), então reconstruir junto: `REINDEXAR=1 bash subir-central.sh`. Sem restauração: `bash
     subir-central.sh`.
  2. Com `PORTÕES OK` e ainda com túnel e processos de fundo parados, conferir a busca (só quando houve restauração),
     de dentro da stack: o número de chamados no índice tem de ser igual ao do banco, e o chamado mais recente do banco
     tem de ser encontrado pelo número.

     ```sh
     docker compose -f docker-compose.yml -f docker-compose.lri.yml exec zammad-railsserver bundle exec rails runner '
       url = SearchIndexBackend.build_url(type: "Ticket", action: "_count",
                                          with_pipeline: false, with_document_type: false)
       resp = url.present? && SearchIndexBackend.make_request(url, data: { query: { match_all: {} } }, method: :post)
       indice = resp && resp.success? && resp.data.is_a?(Hash) ? resp.data["count"] : nil
       abort "FALHA: contagem do índice não respondeu (#{resp ? resp.code : "sem URL"})" if !indice.is_a?(Integer)
       ultimo = Ticket.order(updated_at: :desc).first
       if ultimo.nil?
         puts "banco=0 indice=#{indice} achado=sem_chamados"
       else
         ids = SearchIndexBackend.search("number:#{ultimo.number}", "Ticket", limit: 5).map { |hit| hit[:id].to_s }
         puts "banco=#{Ticket.count} indice=#{indice} ultimo=#{ultimo.number} achado=#{ids.include?(ultimo.id.to_s)}"
       end'
     ```

     A contagem vai direto ao `_count` do índice e só vale com resposta de sucesso: índice inexistente ou busca fora do
     ar terminam em `FALHA:` com o código HTTP, nunca em contagem 0.
     Aceite: `banco` igual a `indice` e `achado=true` (ou `achado=sem_chamados` com os dois em 0). A busca é pelo campo
     `number`, não por texto livre, para outro chamado que cite o número não atrapalhar. Outro resultado: não liberar;
     repetir a reconstrução do índice e, se persistir, levar ao Leandro com a saída.
  3. Só então liberar: `ABRIR_TUNEL=1 bash subir-central.sh` (sem `REINDEXAR`, já feito), que sobe scheduler e
     backup e reabre o túnel.
- **Servidor comprometido**: restaurar o snapshot do passo 0 (decisão do Leandro).

## 10. Atualização da imagem depois do go-live

Uma imagem nova pode migrar o banco, e a anterior pode não funcionar com o banco migrado. Toda troca, portanto:

1. **Guardar o conjunto em uso**: `.env` (só a linha `LRI_IMAGE_TAG` muda), `docker-compose.lri.yml`,
   `subir-central.sh` e `cloudflared/config.yml`, com a tag e o commit do fork anotados. É o que a seção 9 repõe.
2. **Backup consistente**: parar a stack inteira (`docker compose -f docker-compose.yml -f docker-compose.lri.yml
   stop`, os volumes ficam; conferir com `ps -a` que nenhum serviço ficou de pé) e só então copiar os volumes
   `postgresql-data` e `zammad-storage`, do mesmo momento. Não usar o `zammad-backup` para isso: ele copia os arquivos
   antes do banco com a aplicação gravando, e banco e anexos podem sair de momentos diferentes.
3. **Arquivos do commit novo, sem perder os valores reais**: baixar o overlay, o `subir-central.sh` e o exemplo do
   túnel do commit da imagem nova (como no passo 2) para `docker-compose.lri.yml.novo`, `subir-central.sh.novo` e
   `cloudflared/config.yml.novo`. Overlay e script novos substituem os antigos inteiros (não têm valor local). No
   túnel, comparar (`diff cloudflared/config.yml cloudflared/config.yml.novo`) e levar só as mudanças de estrutura
   para o `config.yml` em uso, mantendo ID do túnel, AUD do Access e os nomes da fase em que se está; depois,
   `docker run --rm -v "$PWD/cloudflared:/etc/cloudflared:ro" cloudflare/cloudflared:<versão do .env> tunnel --config
   /etc/cloudflared/config.yml ingress validate` tem de responder `OK`.
4. Trocar `LRI_IMAGE_TAG`, repetir o passo 5 (pull e digest) e subir: `ABRIR_TUNEL=1 bash subir-central.sh`. O
   script roda o `zammad-init` da imagem nova (migrações) antes da aplicação e só reabre o túnel com todos os portões
   aprovados.

## 11. Registro

No registro privado: data e hora de cada fase, quem autorizou, tag, digest e commit do fork da imagem, commit da
stack oficial, resultado das conferências e qualquer desvio deste runbook. Aqui, só a data e a fase concluída.

| Data | Fase | Autorização |
| ---- | ---- | ----------- |
| — | ainda não executado | go-live liberado por Leandro em 02/11; aguarda as decisões do passo 0 |

A imagem do go-live tem de vir de um commit que **já contenha este runbook**: só a partir dele o overlay aceita
`LRI_ZONE_GUARD=off`, necessário para a fase A. As imagens `develop-` anteriores (por exemplo, `develop-7cda0a69…`)
fixam `enforce` e não servem para a primeira subida.

## 12. Monitoramento externo

### 12.1 Por que o monitor recebe 403

O nome interno não tem nenhuma rota anônima, por desenho (PLANO, seções 2.9.2 e 2.9.3). Um `curl` sem credencial
pode ser barrado em três camadas, e só a primeira é a negação esperada do Access:

- **Access (borda)**: o aplicativo do nome interno só deixa passar a equipe, com login. O monitor não tem
  identidade, então é barrado, como qualquer anônimo.
- **WAF e proteção contra bots (borda, antes do Access)**: um cliente automatizado sem credencial pode ser desafiado
  ou bloqueado pelas regras de segurança da zona, com 403, antes de o Access avaliar a requisição.
- **Origem**: a guarda de zona e o listener público do Nginx recusam `/api/v1/monitoring/*` fora da zona interna,
  de propósito. Um `curl` local direto ao Rails também é zona pública e recebe essa recusa quando a guarda está
  ligada.

Para saber qual camada respondeu, sem mudar nada, olhar a resposta:

```sh
curl -sS -o /dev/null -D - https://atendimento.lri.com.br/api/v1/monitoring/health_check \
  | grep -iE '^(HTTP|location|cf-ray|cf-mitigated|content-type|cache-control):?'
```

| O que aparece | Quem respondeu |
| ------------- | -------------- |
| `302` com `location` em `https://lriauto.cloudflareaccess.com/cdn-cgi/access/login` | Access pedindo login (esperado) |
| `403` com `cf-mitigated: challenge` | desafio das regras de segurança da zona |
| `403` em página da Cloudflare com Ray ID | bloqueio por regra de segurança ou contra bots |
| `403`/`503` em JSON com `zone_restricted` ou `zone_unconfirmed` | guarda de zona, na origem |
| `403` com a página "endereço interno" | listener público do Nginx (nome público, rota da equipe) |

O `cf-ray` localiza a requisição em Security > Events (WAF e bots) e nos logs do Access, no Zero Trust. Anotar o
resultado e o Ray ID no registro privado. Nenhuma das correções abaixo libera por User-Agent, desliga o Access,
pula as regras gerenciadas do WAF ou expõe a administração.

### 12.2 Correção recomendada: service token do Access num caminho só do monitor

O monitor ganha uma credencial própria, que vale **só** num caminho dele. O resto do nome interno continua
exigindo login da equipe. Tudo no painel da Cloudflare e na VPS é feito pelo Leandro.

O caminho é `/lri-monitor/health_check`, que só o listener interno do Nginx conhece: ele repassa ao health check do
Zammad e não serve mais nada. O listener público o recusa. O `/api/v1/monitoring/*` não muda de aplicativo, porque a
tela de monitoramento da administração o consulta pelo navegador, com o login da equipe. Um aplicativo só com
Service Auth nesse caminho deixaria a tela sem resposta.

0. **Imagem com a rota**: a rota vem no Nginx da imagem, então a imagem em uso tem de vir de um commit que já a
   contenha. Conferir antes de tudo; a resposta tem de ser `1`:

   ```sh
   docker compose -f docker-compose.yml -f docker-compose.lri.yml exec zammad-nginx \
     grep -c 'location = /lri-monitor/health_check' /etc/nginx/sites-enabled/default
   ```

   Com `0` ou erro, primeiro atualizar a imagem pela seção 10 (tag nova, pull, digest conferido), e só depois
   seguir.
1. **Service token**: Zero Trust > Access > Service credentials > criar `monitor-central`, com validade de um
   ano. O Client ID e o Client Secret vão para o cofre (o secret aparece uma vez só). A data de renovação vai
   para o registro privado.
2. **Aplicativo só do caminho**: novo aplicativo self-hosted com domínio `atendimento.lri.com.br` e caminho
   `lri-monitor/health_check`, sem curinga. Uma única política, de ação **Service Auth**, que inclui só o token
   `monitor-central`: nada de Allow, Bypass ou Everyone. O caminho mais específico prevalece sobre o aplicativo do
   nome inteiro, e as outras rotas continuam no aplicativo da equipe. Anotar o AUD desse aplicativo.
3. **Origem aceita o AUD novo**: acrescentar esse AUD, separado por vírgula, em `LRI_ACCESS_AUD` no `.env` e na
   lista `audTag` da regra do nome interno em `cloudflared/config.yml`. O cloudflared confere o JWT contra o
   `audTag`, e a guarda de zona contra `LRI_ACCESS_AUD`. Validar o túnel (`ingress validate`, seção 10, passo 3) e
   aplicar com `ABRIR_TUNEL=1 bash subir-central.sh`, com a imagem do passo 0. Na fase A, o validador do túnel aceita
   a lista porque o `audTag` continua contido em `LRI_ACCESS_AUD`.
4. **Token de monitoramento do Zammad**: gerado em Administração > Sistema > Monitoramento. O monitor chama
   `https://atendimento.lri.com.br/lri-monitor/health_check`, **sem query**, com três cabeçalhos:
   `CF-Access-Client-Id`, `CF-Access-Client-Secret` e `X-LRI-Monitor-Token: <token>`. O Nginx confere o formato do
   token e o entrega ao Rails no corpo da requisição, como formulário: o Zammad lê `params[:token]`, que junta query
   e corpo. O token não entra em nenhuma URL, nem na do cliente (um token na query é descartado) nem na do
   upstream. Por isso ele não fica nos logs da Cloudflare nem nos do Nginx, inclusive na linha de erro de um
   502/504, que continua trazendo a causa. O Rails filtra `token` nos parâmetros que registra. O token só dá acesso
   à saúde, é guardado como credencial e trocado se vazar. O endpoint responde `200` mesmo com problema, então o
   monitor só considera no ar a resposta com `"healthy":true`.
5. **Prova de que nada além abriu e nada parou**, com o resultado no registro privado:
   - com o service token, `/`, `/api/v1/monitoring/health_check` e `/api/v1/monitoring/status` continuam barrados
     pelo Access;
   - sem o service token, `/lri-monitor/health_check` continua barrado;
   - com o service token e o token do Zammad, `/lri-monitor/health_check` responde `200` com `"healthy":true`;
   - em `https://suporte.lri.com.br/lri-monitor/health_check` (fase B), a página de bloqueio;
   - logado como administrador pelo navegador, a tela Administração > Sistema > Monitoramento continua mostrando o
     estado, sem erro no console.

Se a seção 12.1 mostrar que o bloqueio vem das regras contra bots, e não do Access, o service token sozinho não
basta. A exceção, se o Leandro decidir abrir uma, fica limitada ao mínimo: pula só a fase contra bots, só para o
host `atendimento.lri.com.br`, o caminho exato `/lri-monitor/health_check` e o Client ID do `monitor-central`. As
regras gerenciadas do WAF continuam valendo. Como o Client ID não é segredo, quem o souber passa da checagem de bots
nesse único caminho, mas o Access continua exigindo o secret. A alternativa sem exceção na borda é a da seção 12.3.

### 12.3 Alternativa sem mudar a borda: verificação local com aviso de saída

Na VPS, um agendamento (systemd timer ou cron do usuário da central, com OK do Leandro) confere de dentro da stack
e avisa um serviço de heartbeat por conexão de saída. Nada novo fica exposto, e o alerta dispara quando o aviso
para de chegar. O aviso só sai quando **todas** as conferências passam; a primeira que falhar encerra o script com
o motivo, sem aviso. `HEARTBEAT_URL` vem do ambiente do agendamento, nunca do repositório.

```sh
#!/usr/bin/env bash
set -euo pipefail
cd "$DIRETORIO_DA_CENTRAL"
DC=(docker compose -f docker-compose.yml -f docker-compose.lri.yml)
falha() { echo "FALHA: $*" >&2; exit 1; }
for servico in ${SERVICOS:-zammad-postgresql zammad-redis zammad-memcached zammad-elasticsearch zammad-railsserver \
               zammad-websocket zammad-nginx zammad-scheduler cloudflared}; do
  estado=$("${DC[@]}" ps --format '{{.State}} {{.Health}}' "$servico" 2> /dev/null) || falha "consulta de $servico"
  case "$estado" in "running healthy" | "running " | running) ;; *) falha "$servico: '${estado:-sem container}'" ;; esac
done
"${DC[@]}" exec -T zammad-nginx curl -sf --max-time 5 -o /dev/null "${READY_URL:-http://127.0.0.1:20241/ready}" \
  || falha "túnel sem conexão ativa (/ready)"
"${DC[@]}" exec -T zammad-railsserver bundle exec rails runner '
  checker = MonitoringHelper::HealthChecker.new; checker.check_health
  abort "Zammad: #{checker.message}" if !checker.healthy?' || falha "health check do Zammad"
curl -fsS --max-time 10 -o /dev/null "$HEARTBEAT_URL" || falha "heartbeat não entregue"
echo "OK: todas as conferências passaram; heartbeat enviado"
```

Provas antes de ligar o agendamento, sem parar nada da central (resultado no registro privado):

- com tudo no ar, termina em `OK` e o heartbeat aparece no serviço;
- `SERVICOS="zammad-railsserver servico-inexistente"` termina em `FALHA:` com o nome `servico-inexistente`, sem
  heartbeat (simula um serviço obrigatório ausente; um serviço parado sai como `'sem container'`);
- `READY_URL=http://127.0.0.1:1/ready` termina em `FALHA: túnel sem conexão ativa`, sem heartbeat (simula o túnel
  indisponível).

O `rails runner` carrega a aplicação inteira. Na VPS de 16 GB compartilhada, o agendamento roda a cada 15 minutos,
não a cada minuto. A limitação é que essa verificação não passa por DNS, Cloudflare e Access. Por isso ela
complementa a seção 12.2, sem substituí-la.

## 13. Login da equipe por Google e Microsoft: pré-requisitos

Lista de conferência, só leitura: nada aqui é alterado por este runbook. O estado de cada item vai para o registro
privado. São duas camadas diferentes, cada uma com o seu cadastro.

### 13.1 Cloudflare Access (porta do nome interno)

1. **Google (Workspace da LRI)**, no projeto do Google Cloud da LRI:
   - tela de consentimento OAuth do tipo **Interno**, só para contas do Workspace;
   - cliente OAuth do tipo "Aplicativo da Web", com origem `https://lriauto.cloudflareaccess.com` e URI de
     redirecionamento `https://lriauto.cloudflareaccess.com/cdn-cgi/access/callback`;
   - se as políticas usarem grupos do Workspace, a Admin SDK API habilitada no mesmo projeto;
   - Client ID e secret cadastrados em Zero Trust > Settings > Authentication, como provedor Google Workspace.
2. **Microsoft Entra ID (tenant da IRD.Net)**, num registro de aplicativo no tenant da IRD:
   - tipo de conta "somente este diretório organizacional", ou seja, um só tenant;
   - URI de redirecionamento (Web) `https://lriauto.cloudflareaccess.com/cdn-cgi/access/callback`;
   - segredo do cliente com a validade e a data de renovação no registro privado;
   - permissões delegadas do Microsoft Graph que a página da Cloudflare para Entra ID pede (`openid`, `email`,
     `profile`, `offline_access`, `User.Read` e, se houver política por grupo, as de leitura de grupos), com o
     consentimento do administrador do tenant;
   - Application (client) ID, Directory (tenant) ID e segredo cadastrados no Zero Trust como provedor Microsoft Entra
     ID.
3. **Permissão no token da API da Cloudflare**, se o cadastro for feito por automação: "Access: Organizations,
   Identity Providers, and Groups" (leitura para conferir, edição para cadastrar) e "Access: Apps and Policies"
   (para ligar os provedores ao aplicativo). Pelo painel, basta o papel de administrador do Zero Trust.
4. **Aplicativo do nome interno**: os dois provedores marcados na lista de provedores do aplicativo, e a política da
   equipe por domínio de e-mail (`lri.com.br`, `ird.net.br`) ou por grupo. Manter ou não o PIN de uso único por
   e-mail como contingência é decisão do Leandro.
5. **Teste**: entrar no nome interno com cada provedor. Os logs do Access no Zero Trust mostram o provedor usado.

### 13.2 Zammad (login dentro da central)

É outro cadastro, com os retornos do próprio Zammad, que chegam pelo `fqdn` e o Nginx manda para o nome interno
(PLANO, seção 2.9.2). Usado no passo 6 da fase A e testado no passo 6 da fase B:

- Google: URI de redirecionamento `https://suporte.lri.com.br/auth/google_oauth2/callback`;
- Microsoft (aplicativo de um só tenant, na IRD.Net): `https://suporte.lri.com.br/auth/microsoft_office365/callback`,
  com o ID do tenant preenchido no Zammad;
- no Zammad, `auth_third_party_no_create_user` ligado: o login por Google ou Microsoft não cria usuário, só entra
  em conta que já existe com o mesmo e-mail, **de qualquer papel**. A opção não confere se a conta é de agente.

O que restringe o nome interno à equipe é a política do Access: só e-mails da equipe chegam até lá. Falta garantir
que nenhuma conta de cliente use e-mail dos domínios da equipe, porque essa conta entraria como cliente no nome
interno. Conferir antes da fase B e depois de cada importação; a lista tem de sair vazia:

```sh
docker compose -f docker-compose.yml -f docker-compose.lri.yml exec zammad-railsserver bundle exec rails runner '
  contas = User.where("email ILIKE ? OR email ILIKE ?", "%@lri.com.br", "%@ird.net.br")
  puts contas.reject { |user| user.role?("Agent") || user.role?("Admin") }.map(&:login)'
```
