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
| Imagem escolhida: uma tag `develop-<sha>` publicada pelo workflow `LRI imagem` (resumo da execução no GitHub Actions) ou uma versão `X.Y.Z` (tag `lri-vX.Y.Z`); anotar o digest e o **commit do fork** que gerou a imagem (o `<sha>` da tag `develop-`, ou o commit da tag `lri-v`) | GitHub, aba Actions e pacote `zammad-lri` |
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
mkdir -p cloudflared
curl -fsSL "https://raw.githubusercontent.com/leaberg69/zammad/$FORK_COMMIT/contrib/lri/deploy/cloudflared/config.yml.example" \
  -o cloudflared/config.yml
```

Overlay e configuração do túnel vêm do **mesmo commit da imagem**, nunca da ponta da `develop`: é esse par que o
workflow `LRI imagem` conferiu (o overlay renderizado dentro da imagem construída). O commit da stack oficial é o
mesmo que o CI usa nessa conferência; outro commit exige refazê-la.

## 3. Cloudflare

1. Criar o túnel **gerenciado localmente** (`cloudflared tunnel create central-atendimento`) e obter o token
   (`cloudflared tunnel token central-atendimento`). O token vai só para o `.env` (passo 4).
2. Preencher `cloudflared/config.yml`: ID do túnel e AUD do aplicativo do Access. Na **fase A** (passo 6), deixar só
   o bloco do nome interno e o `http_status:404` final; os três nomes `suporte` entram na fase B.
3. DNS: `atendimento.lri.com.br` como `CNAME` do túnel. Os três `suporte` só na fase B.
4. Access: aplicativo do nome interno com os provedores da equipe (Google Workspace da LRI, Entra ID da IRD.Net) e
   `SameSite` diferente de `Strict` (checklist, seção 4).

## 4. Arquivo `.env`

No diretório da central, `chmod 600 .env`. Valores gerados só para a central, guardados no cofre do grupo:

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
docker compose -f docker-compose.yml -f docker-compose.lri.yml up -d
docker compose -f docker-compose.yml -f docker-compose.lri.yml ps -a
```

- `lri-config-check` terminou com código 0, e `zammad-init` também; os demais estão `healthy` ou `running`.
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
6. Login por Google e Microsoft configurados (com `auth_third_party_no_create_user` ligado) e agentes cadastrados com
   o perfil da marca.

## 7. Fase B — guarda ligada e portais públicos

A guarda é ligada e conferida **com o túnel ainda só interno**; os portais públicos só entram depois.

1. No `.env`, remover `LRI_ZONE_GUARD` (o overlay usa `enforce`).
2. Recriar os serviços com a guarda e só seguir se a recriação der certo:

   ```sh
   docker compose -f docker-compose.yml -f docker-compose.lri.yml up -d --force-recreate \
     zammad-railsserver zammad-websocket zammad-scheduler && \
   docker compose -f docker-compose.yml -f docker-compose.lri.yml ps zammad-railsserver zammad-websocket zammad-scheduler
   ```

3. Conferir, ainda sem portais públicos: os três serviços `healthy` ou `running`; nos logs de railsserver,
   websocket e scheduler, `guarda de zona LRI LIGADA`; no railsserver, `conta de emergência: (login), com 2FA`; nenhum
   container da fase A sobrando (`docker compose ... ps -a`). Se qualquer item falhar, parar aqui.
4. Senhas locais da equipe, exceto a de emergência, trocadas por valores aleatórios (checklist, seção 5).
5. Só então abrir os portais: em `cloudflared/config.yml`, acrescentar os três nomes `suporte`;
   `docker compose -f docker-compose.yml -f docker-compose.lri.yml up -d --force-recreate cloudflared`; e, por último,
   trocar o DNS dos três `suporte` para `CNAME` do túnel.

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
- **Imagem com defeito**: uma imagem nova pode migrar o banco, e a anterior pode não funcionar com o banco migrado.
  Por isso, **toda troca de imagem** (inclusive a primeira atualização depois do go-live) começa com backup
  consistente: parar a central (`docker compose ... stop`, os volumes ficam), copiar os volumes `postgresql-data` e
  `zammad-storage` (ou um `zammad-backup` com o `BACKUP_ON_START`), guardar uma cópia de `docker-compose.lri.yml` e
  `cloudflared/config.yml` em uso, anotar a tag e o commit do fork em uso e só então trocar. A troca leva tag,
  overlay e configuração do túnel juntos, todos do commit da imagem nova (passo 2); o `.env` só muda na tag. Para
  voltar, sempre com o conjunto da versão anterior (tag, overlay e `config.yml` guardados):
  - se as notas da versão nova confirmarem que não há migração de banco entre as duas, repor o conjunto anterior e
    repetir os passos 5 e 7 (tags publicadas são imutáveis, a anterior continua igual);
  - nos demais casos, parar a central, restaurar o backup feito antes da troca (banco e arquivos juntos, do mesmo
    momento), repor o conjunto anterior e só então subir. Restaurar apaga o que entrou depois do backup: decisão do
    Leandro.
- **Servidor comprometido**: restaurar o snapshot do passo 0 (decisão do Leandro).

## 10. Registro

No registro privado: data e hora de cada fase, quem autorizou, tag, digest e commit do fork da imagem, commit da stack oficial,
resultado das conferências e qualquer desvio deste runbook. Aqui, só a data e a fase concluída.

| Data | Fase | Autorização |
| ---- | ---- | ----------- |
| — | ainda não executado | go-live liberado por Leandro em 02/11; aguarda a imagem publicada e as decisões do passo 0 |
