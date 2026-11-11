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

A espera pelo Elasticsearch é pela condição, não por tempo fixo: o `_cluster/health?wait_for_status=yellow` é
repetido até `SUBIR_ES_PRAZO` (padrão 300 s). Na primeira subida o container acabou de ser criado e a JVM leva um
tempo para abrir a porta 9200; o `--wait` do compose não cobre isso, porque a stack oficial não tem healthcheck no
Elasticsearch. Se o container reiniciar ou sair durante a espera, o script para na hora. No prazo esgotado ou no
reinício, o `PARAR:` traz o estado do container (reinícios, `OOMKilled`), a última resposta de saúde, o heap, o limite
de memória e as últimas linhas do log. Com `OOMKilled=true`, liberar memória no host (`free -m`, `docker stats`) em
vez de aumentar o heap, que fica em 1 GB.

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
