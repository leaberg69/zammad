# Central de Atendimento Grupo LRI — Arquitetura e Plano

Este documento define a arquitetura e o plano de execução do helpdesk do Grupo LRI, construído sobre este fork do
Zammad (upstream `zammad/zammad`). É o primeiro entregável do projeto: descreve o que será feito, como e em que ordem.
Nenhum código de funcionalidade acompanha este documento.

## 1. Objetivo e escopo

O helpdesk atende duas empresas do grupo, em uma única plataforma:

| Marca | Razão / identificação | Contato de referência |
| ----- | --------------------- | --------------------- |
| **LRI** | LRI Automação Industrial — `lri.com.br` | +55 51 2129-3000 |
| **IRD.Net** | IRD Produtos de Informática — Navegantes/SC — `ird.net.br` | `suporte@ird.net.br` |

Públicos atendidos:

- **Suporte interno**: colaboradores das duas empresas abrem chamados para TI, infraestrutura e áreas de apoio.
- **Clientes externos**: abrem e acompanham chamados por **e-mail** e pelo **portal web do cliente**.

Premissas do produto:

- **pt-BR em primeiro lugar**: idioma padrão, fuso horário `America/Sao_Paulo`, formatos de data e número brasileiros.
- **Interface do Zammad preservada**, com identidade visual de cada marca (ver seção 3).
- **Esteira do time**: todo trabalho segue `leaberg69/esteira-softwarehouse-LR` (seção 9).

## 2. Arquitetura multimarca

### 2.1 Visão geral

Uma **única instância** do Zammad atende as três marcas: **LRI**, **IRD.Net** e **Mean Well Brasil** (marca da LRI,
incluída por decisão de Leandro em 31/10, [issue #2](https://github.com/leaberg69/zammad/issues/2)). A separação
entre as marcas é feita com os mecanismos nativos da plataforma — grupos, organizações, endereços de e-mail,
assinaturas, permissões e regras — sem alterar o núcleo do produto.

```text
 E-mail LRI ─────────────┐                                    ┌─▶ Grupos LRI::*     ─▶ Agentes LRI
 E-mail Mean Well Brasil ┤                                    ├─▶ Grupos MW::*      ─▶ Agentes MW
 E-mail IRD.Net ─────────┤                                    │
 Portal web ─────────────┼─▶ Zammad (instância única) ────────┼─▶ Grupos IRD::*     ─▶ Agentes IRD.Net
 Formulário web ─────────┤    roteamento por gatilhos e       │
 (futuro: WhatsApp, ERP Plune, site)           Core Workflow  └─▶ Grupos Interno::* ─▶ TI / áreas de apoio
```

Motivos da instância única:

- uma só operação: um banco, um backup, uma atualização;
- relatórios e indicadores consolidados do grupo, com recorte por marca;
- agentes que atendem as duas empresas trabalham em uma só tela, com permissões por grupo;
- clientes comuns às duas marcas têm um único cadastro e um único histórico.

### 2.2 Grupos

Os grupos do Zammad são hierárquicos. A primeira camada identifica a marca; a segunda, a fila de atendimento.
Estrutura decidida (decisão 4, seção 10):

| Grupo | Público | Uso |
| ----- | ------- | --- |
| `LRI::Suporte Técnico` | clientes | automação industrial, campo, pós-venda técnico |
| `LRI::Comercial` | clientes | orçamentos, pedidos, prazos |
| `LRI::Financeiro` | clientes | boletos, notas fiscais, cobrança |
| `MW::Suporte` | clientes | fontes Mean Well: suporte técnico, garantia e pós-venda (filas adicionais a definir) |
| `IRD::Suporte` | clientes | produtos de informática, garantia, RMA |
| `IRD::Comercial` | clientes | orçamentos, pedidos, revendas |
| `Interno::TI` | colaboradores | equipamentos, acessos, sistemas |
| `Interno::Administrativo` | colaboradores | RH, compras, facilities |

Cada grupo define:

- **endereço de e-mail de envio** próprio, para que a resposta saia sempre com o remetente da marca correta;
- **assinatura** própria (logo, nome da empresa, telefone e site da marca);
- **política de follow-up** (reabertura de chamados encerrados por resposta do cliente);
- **permissões**: agentes recebem acesso por grupo (leitura, criação, alteração total), seguindo o menor privilégio.

O setting `customer_ticket_create_group_ids` limita os grupos que clientes podem escolher no portal; os grupos
`Interno::*` ficam visíveis apenas a colaboradores, por meio de Core Workflow.

### 2.3 Organizações e usuários

- **Organizações internas**: `LRI Automação Industrial` e `IRD Produtos de Informática`, com atribuição automática por
  domínio de e-mail, para que colaboradores entrem já vinculados à empresa certa.
- **Organizações de clientes**: uma por empresa cliente, com atribuição por domínio quando o cliente usa domínio
  próprio.
- **Visibilidade (decidido)**: cada cliente vê **somente os próprios chamados**, nunca os da sua empresa. Toda
  organização é criada com **"Organização compartilhada" desativada** (atributo `shared = false`). Como o padrão do
  Zammad é `shared = true`, o provisionamento (seção 4) cria as organizações já com `false`, e um callback
  `before_create` no fork grava `false` em toda organização nova, sem janela (seção 2.9.3, item 6). A verificação faz
  parte dos testes da fase 1.
- **Perfis (roles)**: `Admin`, `Agente LRI`, `Agente Mean Well Brasil`, `Agente IRD.Net`, `Agente Interno` e
  `Cliente`. Colaboradores que abrem chamados internos usam o perfil `Cliente` e veem apenas os grupos `Interno::*`.

### 2.4 Canais de e-mail

Cada marca tem caixas de entrada próprias, configuradas como canais de e-mail do Zammad:

| Caixa | Grupo de destino | Situação |
| ----- | ---------------- | -------- |
| `suporte@lri.com.br` | `LRI::Suporte Técnico` | decidida |
| `comercial@lri.com.br` | `LRI::Comercial` | decidida antes; a lista de 31/10 cita só as três caixas `suporte@`, a confirmar |
| `suporte@meanwellbrasil.com.br` | `MW::Suporte` | decidida (31/10) |
| `suporte@ird.net.br` | `IRD::Suporte` | decidida |
| caixa comercial da IRD.Net | `IRD::Comercial` | endereço a definir |
| caixa da TI interna | `Interno::TI` | endereço a definir |
| caixa financeira da LRI | `LRI::Financeiro` | endereço a definir |

- **Canal por marca (decidido)**: cada marca usa o canal nativo do Zammad para o seu provedor de e-mail, com OAuth,
  sem senha de caixa guardada no Zammad.

  | Marca | Provedor | Canal do Zammad | Caixas |
  | ----- | -------- | --------------- | ------ |
  | LRI | Google Workspace | **Google Email** (Gmail por IMAP/SMTP com OAuth) | `suporte@lri.com.br`, `comercial@lri.com.br` e demais caixas `@lri.com.br` |
  | Mean Well Brasil | Google Workspace (MX do Google, conferido em 31/10) | **Google Email** | `suporte@meanwellbrasil.com.br` |
  | IRD.Net | Microsoft 365 | **Microsoft 365 Graph Email** (API Microsoft Graph) | `suporte@ird.net.br` e demais caixas `@ird.net.br` |

  - **Google**: projeto no Google Cloud do Workspace da LRI, com a API do Gmail habilitada e um cliente OAuth cujo
    URI de retorno é `https://suporte.lri.com.br/api/v1/external_credentials/google/callback`. A caixa é autorizada
    no próprio painel do Zammad (Canais › Google Email), com login da conta da caixa.
  - **Microsoft 365**: registro de aplicativo no Entra ID do tenant da IRD.Net, com URI de retorno
    `https://suporte.lri.com.br/api/v1/external_credentials/microsoft_graph/callback` e as permissões delegadas de
    e-mail que o assistente do canal solicita. A caixa é autorizada em Canais › Microsoft 365 Graph Email. O canal
    Graph é preferido ao canal "Microsoft 365 IMAP Email", também disponível.
  - Os URIs de retorno usam o endereço principal (`fqdn`, seção 2.6), porque o Zammad monta as URLs de OAuth a partir
    dele. Isso não muda a marca vista pelo cliente: remetente e assinatura continuam os do grupo.
- **Roteamento**: cada canal entrega no seu grupo; gatilhos refinam por remetente, domínio ou assunto.
- **Numeração**: o prefixo dos chamados (`ticket_hook`) é único no sistema; a marca aparece no remetente, na
  assinatura e no nome do grupo, o que mantém as respostas do cliente encadeadas corretamente.
- **Respostas automáticas**: um gatilho de confirmação de recebimento por marca, com texto e assinatura da marca.

### 2.5 Portal do cliente

O portal do cliente é a interface nativa do Zammad para clientes: login, abertura de chamado, acompanhamento e
resposta. Complementos:

- **Base de conhecimento pública**: uma base com categorias de primeiro nível por marca (`LRI`, `Mean Well Brasil` e
  `IRD.Net`), em pt-BR,
  publicada para clientes e, quando indicado, para o público geral.
- **Formulário web**: o formulário embutível do Zammad entra nas páginas de contato dos sites (fase 4).
- **Endereços (decidido)**: três subdomínios de cliente, um por marca, servidos pela mesma instância com HTTPS —
  `suporte.lri.com.br` (LRI), `suporte.meanwellbrasil.com.br` (Mean Well Brasil) e `suporte.ird.net.br` (IRD.Net) —,
  mais o nome interno da equipe `atendimento.lri.com.br` (detalhes nas seções 2.6 e 2.9). Os três registros
  `suporte` foram criados por Leandro em 31/10 (A para a VPS, com proxy da Cloudflare) e passam a `CNAME` do túnel
  quando ele existir.
- **Nome do produto (decidido)**: "Central de Atendimento Grupo LRI".
- **Identidade visual (decidida)**: o portal usa a identidade do **Grupo LRI**, com os logos das marcas, porque o
  logo e o nome do produto são configurações globais da instância; as marcas aparecem no logo composto definido pela
  `ux-spec` de branding. O cliente escolhe a marca e a fila na abertura do
  chamado; e-mails, assinaturas e respostas seguem a marca do grupo escolhido.

### 2.6 Vários endereços em uma instância

A instância responde pelos três subdomínios de cliente e pelo nome interno da equipe. Cada camada tem um papel
definido:

#### Configurações do Zammad

| Setting | Valor | Efeito |
| ------- | ----- | ------ |
| `http_type` | `https` | todos os links gerados usam HTTPS |
| `fqdn` | `suporte.lri.com.br` | endereço principal: links dos e-mails de sistema, formulário web, retornos de OAuth e origem aceita pelas chaves de segurança (WebAuthn) |
| `alternative_fqdn` | `suporte.ird.net.br` | segundo endereço aceito como origem das conexões WebSocket |

O servidor de WebSocket legado (`/ws`) aceita só o endereço principal e o alternativo como origem; os outros dois nomes
(`suporte.meanwellbrasil.com.br` e o interno `atendimento.lri.com.br`) usam a troca exata de `Origin` no proxy descrita
na seção 2.9.2. O ActionCable (`/cable`) já aceita a origem igual ao `Host` repassado
(`allow_same_origin_as_host`) e não precisa da troca. Depois de alterar `fqdn` ou `alternative_fqdn`, os serviços do
Zammad são reiniciados para que as origens permitidas sejam recarregadas.

#### Proxy reverso

- O proxy é o Nginx da própria stack da central, alcançado só pelo Cloudflare Tunnel (seção 2.9.2), com dois blocos
  de servidor: o público, para os três subdomínios de cliente, e o interno, para o nome da equipe. O Nginx
  compartilhado da VPS não participa.
- O proxy repassa os cabeçalhos `Host`, `X-Forwarded-For` (a partir de `CF-Connecting-IP`) e `X-Forwarded-Proto:
  https`. O cabeçalho `Host` original é o que permite ao ActionCable aceitar a conexão pelo endereço da IRD.Net.
- As rotas de WebSocket (`/ws` e `/cable`) recebem os cabeçalhos `Upgrade` e `Connection` de upgrade.
- HTTP é redirecionado para HTTPS na borda da Cloudflare ("Always Use HTTPS"), com HSTS.

#### Certificados TLS

- DNS: registros `CNAME` com proxy da Cloudflare de `suporte.lri.com.br`, `suporte.meanwellbrasil.com.br`,
  `suporte.ird.net.br` e do nome interno `atendimento.lri.com.br` apontando para o túnel
  (`<id-do-túnel>.cfargotunnel.com`). As três zonas já estão na Cloudflare.
- O certificado público é o da borda da Cloudflare (Universal SSL, que cobre o primeiro nível de subdomínio das
  três zonas). Entre a borda e o `cloudflared` o túnel é cifrado; a central não emite nem renova certificados.

#### Links nos e-mails

- **E-mails ao cliente gerados por gatilhos** (confirmação de recebimento, resposta, encerramento): há um gatilho por
  marca, condicionado aos grupos `LRI::*`, `MW::*` ou `IRD::*`, e cada um escreve o link com o endereço da sua marca, por
  exemplo `https://suporte.ird.net.br/#ticket/zoom/#{ticket.id}`. Assim o cliente da IRD.Net sempre volta pelo
  endereço da IRD.Net.
- **Assinaturas por grupo** trazem o endereço do portal da marca.
- **E-mails de sistema** (redefinição de senha, verificação de cadastro, convite, notificações a agentes) usam
  `config.fqdn` e apontam para `suporte.lri.com.br`. O link funciona para qualquer cliente, porque a instância é a
  mesma e o portal tem a identidade do Grupo LRI. Esses modelos se identificam pelo nome do produto
  (`config.product_name`), "Central de Atendimento Grupo LRI", válido para as três marcas.
- **Agentes** usam o nome interno `atendimento.lri.com.br` (seção 2.9). As chaves de segurança (WebAuthn) do Zammad
  aceitam só a origem do `fqdn` (`lib/auth/two_factor/authentication_method/security_keys.rb`, `allowed_origins`),
  então não funcionam no nome interno: o 2FA do Zammad, onde existir, é por aplicativo autenticador (TOTP).
- **Sessão**: o login vale por endereço; quem entrar por `suporte.ird.net.br` continua nele durante a navegação.
- **Evolução**: se o Grupo LRI quiser que os e-mails de sistema também saiam com o endereço da marca do cliente, isso
  pede uma mudança pequena no núcleo (escolher o endereço pela organização do destinatário). Ela segue a seção 4 e é
  proposta ao upstream.

### 2.7 Autenticação

- **Colaboradores (decidido)**: o login da equipe só se completa na zona interna (nome interno atrás do Cloudflare
  Access, seção 2.9). Cada empresa entra com a conta corporativa que já usa, pelos dois provedores nativos do Zammad.
  A tela de login da zona interna mostra os dois botões.

  | Empresa | Provedor | Setting do Zammad | URI de retorno |
  | ------- | -------- | ----------------- | -------------- |
  | LRI | Google Workspace | `auth_google_oauth2` | `https://suporte.lri.com.br/auth/google_oauth2/callback` |
  | IRD.Net | Microsoft 365 (Entra ID) | `auth_microsoft_office365` | `https://suporte.lri.com.br/auth/microsoft_office365/callback` |

  - **Google (LRI)**: cliente OAuth no Google Cloud do Workspace da LRI, com tela de consentimento do tipo "Interna",
    o que limita o login às contas `@lri.com.br`.
  - **Microsoft (IRD.Net)**: registro de aplicativo no Entra ID da IRD.Net, configurado com o **ID do tenant** da IRD.Net
    em `auth_microsoft_office365_credentials` (`app_tenant`). Com o tenant fixo, e não `common`, só contas da IRD.Net
    conseguem entrar.
  - IDs e segredos dos dois aplicativos são guardados como segredos (seção 6.2.1).
  - `auth_third_party_auto_link_at_inital_login` ativado: no primeiro login, a conta do colaborador já cadastrada é
    vinculada pelo e-mail.
  - `auth_third_party_no_create_user` ativado: os botões de login não criam contas novas. Só entra quem já foi
    cadastrado pelo administrador com o perfil certo, o que impede que uma conta qualquer ganhe acesso.
  - Os aplicativos de login e de e-mail de cada provedor podem ser o mesmo registro ou registros separados; registros
    separados mantêm as permissões de cada um mínimas e são a escolha deste plano.
- **Clientes**: continuam com e-mail e senha no portal, com cadastro próprio e redefinição de senha. Por isso
  `user_show_password_login` permanece ativado; ele vale para todos os usuários.

### 2.8 Horário de atendimento

O horário definitivo ainda será definido. Até lá, vale o padrão **provisório**:

| Item | Valor provisório |
| ---- | ---------------- |
| Dias | segunda a sexta-feira |
| Horário | 08:00 às 18:00 |
| Fuso | `America/Sao_Paulo` |
| Feriados | feriados nacionais; feriados locais da sede da LRI (RS) e de Navegantes/SC (IRD.Net), a confirmar |

- No Zammad, o horário é um **calendário**. São criados dois calendários com o mesmo horário provisório, "LRI —
  Horário comercial" e "IRD.Net — Horário comercial", porque os feriados municipais e estaduais diferem entre RS e SC.
  Feriados nacionais entram por assinatura iCal, e os locais, manualmente.
- Os SLAs (fase 4) usam esses calendários. O prazo de atendimento só corre dentro do horário comercial.
- Quando o horário definitivo for decidido, basta alterar os calendários. SLAs, gatilhos e relatórios continuam
  iguais.

### 2.9 Zonas: parte interna (intranet) e parte do cliente (internet)

**Decidido (Leandro)**: o sistema tem duas partes.

- **Parte interna, da equipe**: agentes respondendo chamados, administração e configurações. Fica dentro da intranet,
  **sem exposição pública**.
- **Parte do cliente**: portal do cliente para abrir e acompanhar chamados, base de conhecimento pública e formulário
  web, na internet, em `suporte.lri.com.br` e `suporte.ird.net.br`. A entrada por e-mail também atende o cliente e
  não exige exposição alguma (ver abaixo).

O plano abaixo é a **proposta de implementação**. Ele entra na esteira como slice próprio (seção 2.9.6) e só vira
código depois da `ux-spec` do UX-A e do threat model do security-A.

#### 2.9.1 O que o código do Zammad determina

Três fatos do código moldam a solução:

1. **Agentes e clientes usam as mesmas rotas.** A mesma aplicação web (`/`, `/desktop`, `/mobile`), a mesma API REST
   (`/api/v1/tickets`, `/api/v1/users`...), o mesmo GraphQL (`/graphql`) e os mesmos canais de tempo real (`/ws` e
   `/cable`). O que separa um do outro é o **perfil do usuário**, não o caminho. Um bloqueio só por caminho no proxy
   não separa as partes; ele é uma camada de defesa, não o controle principal.
2. **Os retornos de OAuth usam sempre o `fqdn`.** O login de agentes por Google e Microsoft
   (`OmniAuth.config.full_host`) e a autorização das caixas de e-mail (`ExternalCredential.callback_url`) montam a URL de
   retorno a partir de `fqdn` (`suporte.lri.com.br`). Os links dos e-mails de sistema ao cliente (redefinição de senha,
   verificação de cadastro) também. Por isso o `fqdn` continua sendo o endereço público, e a parte interna precisa
   ou responder pelo mesmo nome, ou receber de volta esses retornos a partir do nome público (solução da seção
   2.9.2).
3. **A entrada por e-mail é de saída.** Os canais Google Email (IMAP/SMTP com OAuth) e Microsoft 365 Graph Email
   buscam as mensagens a partir do servidor. Nenhuma porta ou rota pública é necessária para receber e-mail.

#### 2.9.2 Arquitetura decidida: Cloudflare Tunnel, Cloudflare Access e um nome interno

**Decidido** (Cogerente de Projetos, [issue #2](https://github.com/leaberg69/zammad/issues/2), 31/10): alternativa C,
nome interno `atendimento.lri.com.br`, login da equipe pela opção (i) e troca exata de `Origin` no proxy. Condições:
o `cloudflared` valida o JWT do Access (audience do aplicativo e domínio da equipe `lriauto`) e o listener interno
escuta só em `127.0.0.1`.

**Implementado (slice "Zonas interna e pública", PR #1)** — ainda sem implantação:

| Peça | Onde | Teste |
| ---- | ---- | ----- |
| Guarda de zona (zona por cabeçalho + segredo + JWT do Access; recusas na zona pública; zona gravada na sessão) | `lib/lri/`, `config/initializers/lri_zone_guard.rb` | `spec/lib/lri/`, `spec/requests/lri/` |
| Guarda no WebSocket legado e no ActionCable | `lib/sessions/event/login.rb`, `app/channels/application_cable/connection.rb` (uma linha cada) | `spec/lib/lri/zone_guard_realtime_spec.rb` |
| Ponto de checagem no login: na zona pública, a equipe nunca vira usuário corrente (fecha "login + ação + logout" numa só operação GraphQL, achado do Codex) | `app/controllers/application_controller/has_user.rb#current_user_set` (uma linha) | `spec/requests/lri/zone_guard_spec.rb` |
| Token de prévia da KB de um agente recusado na zona pública, na URL e na sessão (achado do Codex) | `app/controllers/knowledge_base/public/base_controller.rb` (uma linha), `lib/lri/zone_policy.rb` | `spec/requests/lri/zone_guard_spec.rb`, `spec/lib/lri/zone_policy_spec.rb` |
| WebSocket público reconferido a cada evento e no envio em segundo plano: se o cliente vira equipe, perde a autenticação (achado do Codex) | `lib/sessions/event/login.rb`, `lib/sessions/event/base.rb`, `lib/sessions/client.rb` (uma linha cada) | `spec/lib/lri/zone_guard_realtime_spec.rb` |
| Nginx com os dois listeners, cabeçalhos por `location`, troca exata de `Origin`, 302 dos retornos, bloqueios | `contrib/lri/deploy/nginx/`, `contrib/lri/deploy/nginx-entrypoint.sh` | `contrib/lri/deploy/test/nginx_zones_test.sh` |
| Túnel gerenciado localmente e sobreposição da stack oficial | `contrib/lri/deploy/cloudflared/config.yml.example`, `contrib/lri/deploy/docker-compose.lri.yml` | revisão |

A guarda só age com `LRI_ZONE_GUARD=enforce`; com qualquer outro valor que não seja vazio ou `off`, ou ligada com
configuração incompleta, a aplicação não sobe, e a partida registra no log se a guarda está ligada. Quando o listener
interno reivindica a zona mas a prova falha (JWT inválido ou chaves do Access indisponíveis), a resposta é 503 sem
destruir a sessão: uma falha do Access não desconecta a equipe. As chaves do Access ficam em cache, com tolerância de
relógio de 30 s e reaproveitamento das chaves anteriores por até 24 h se a busca falhar.

**Pré-requisitos para ligar `enforce` em produção** (próximo slice; sem eles o go-live não acontece, ou Leandro aceita
o risco por escrito):

1. recusa de login por senha, de 2FA e de redefinição de senha da equipe na zona pública **antes** de verificar a
   senha, com resposta igual à de credencial inválida — hoje a recusa vem depois do login, o que deixa um oráculo de
   senha de equipe e permite bloquear agentes por tentativas (revisões de código e de segurança);
2. conta de emergência com TOTP;
3. `before_create` de `Organization` com `shared = false`;
4. `state` obrigatório no retorno da autorização de caixa;
5. indicação de zona para a interface esconder os botões de SSO no portal.

Registrado e aceito: no WebSocket legado a zona fica gravada na sessão da conexão e é reconferida a cada evento e a
cada ciclo de envio em segundo plano (um cliente promovido a agente com o socket público aberto perde a
autenticação). No ActionCable a zona é avaliada na conexão; uma conexão pública de cliente promovido continua aberta
até reconectar, mas qualquer requisição HTTP dele já é recusada. Mitigação operacional: ao promover alguém, encerrar
as sessões dele. A recusa no tempo real deixa a sessão anônima, sem aviso ao cliente, porque o HTTP já recusou antes.

**Fatos do ambiente que pesam na escolha** (levantados em 2026-10-31):

- as zonas DNS `lri.com.br`, `ird.net.br` e `meanwellbrasil.com.br` estão na Cloudflare (conta LRI Group); os três
  registros `suporte` foram criados por Leandro em 31/10;
- a LRI já publica a sua intranet (`intranet.lri.com.br`) atrás do **Cloudflare Access** (equipe `lriauto`), com
  certificado de origem da Cloudflare e mTLS de origem por nome;
- a VPS compartilhada do grupo atende vários sites no Nginx compartilhado; mexer nele afeta todos (seção 6.2.1).

Desenho: **nenhum tráfego da central passa pelo Nginx compartilhado nem por porta nova aberta na VPS**. Um
`cloudflared` dentro do projeto Compose da central abre um túnel de saída até a Cloudflare e entrega cada nome a
um listener diferente do proxy próprio da central:

```text
 Cliente ─▶ suporte.lri.com.br ────────────┐                     ┌─▶ listener PÚBLICO  (127.0.0.1:8081)
            suporte.meanwellbrasil.com.br ─┤                     │   X-LRI-Zone: public
            suporte.ird.net.br ────────────┼─▶ borda ─▶ túnel ───┤   bloqueia rotas da equipe
 Equipe ──▶ atendimento.lri.com.br ─▶ Access ┘   Cloudflare      │
            (Google: LRI e MW · Microsoft: IRD.Net)              └─▶ listener INTERNO  (127.0.0.1:8082)
                                                                     X-LRI-Zone: internal
                                                                           │
                    cloudflared no mesmo namespace de rede do Nginx da central (network_mode: service:zammad-nginx);
                    Zammad numa rede Docker interna só com o Nginx; nenhuma porta publicada no host
```

- **Nomes**: `suporte.lri.com.br`, `suporte.meanwellbrasil.com.br` e `suporte.ird.net.br` (clientes) e o **nome
  interno** da equipe `atendimento.lri.com.br` (decidido). Todos passam a registros `CNAME` para o túnel, com proxy
  da Cloudflare, quando o túnel for criado (hoje os três `suporte` são `A` para a VPS).
- **Túnel (Cloudflare Tunnel), configurado localmente**: o `cloudflared` só faz conexões de saída e lê as regras de
  entrada de um `config.yml` versionado em `contrib/lri/` (túnel gerenciado localmente, não pelo painel), para que
  uma regra nova não possa ser criada pela conta da Cloudflare apontando para o Zammad sem o Access. Regras de
  entrada: os três nomes de
  cliente vão para `http://127.0.0.1:8081`; o nome interno vai para `http://127.0.0.1:8082` com
  `originRequest.access: { required: true, teamName: lriauto, audTag: [<aud do aplicativo>] }`. Assim o próprio
  `cloudflared` valida o JWT do Access (assinatura, audience e equipe) antes de entregar a requisição. Qualquer outro
  nome cai na regra final `http_status:404`.
- **Listener só em `127.0.0.1`**: o `cloudflared` roda no mesmo namespace de rede do container `zammad-nginx`
  (`network_mode: service:zammad-nginx`), e os dois blocos de servidor do Nginx escutam em `127.0.0.1`. Nenhum outro
  container nem o host alcança os listeners.
- **O cabeçalho de zona não basta sozinho**: na stack oficial, `zammad-scheduler`, `zammad-init`, `zammad-backup`,
  Elasticsearch, Redis e memcached estão na mesma rede que o `zammad-railsserver` e o `zammad-websocket` e conseguem
  falar com eles direto, mandando o `X-LRI-Zone` que quiserem. Por isso (exigência das revisões de segurança):
  - o `zammad-nginx` (e o `cloudflared`) sai da rede padrão: fica numa rede `internal: true` com o
    `zammad-railsserver` e o `zammad-websocket` e numa rede de saída só dele, sem enxergar banco, Redis ou
    Elasticsearch. Railsserver e websocket continuam na rede padrão, porque precisam do banco, então um container
    dali ainda os alcança por HTTP — e é por isso que os dois controles abaixo são obrigatórios
    (`contrib/lri/deploy/docker-compose.lri.yml`);
  - a zona interna só vale se vier junto um segredo de zona (`X-LRI-Zone-Key`, 32 bytes gerados para a central,
    no `.env`), que só o listener interno injeta e a guarda compara em tempo constante; o valor nunca vai para log;
  - a guarda também valida o `Cf-Access-Jwt-Assertion` (assinatura pelas chaves públicas da equipe `lriauto`,
    `aud` do aplicativo, validade) quando a zona é interna; sem JWT válido, a requisição é tratada como pública.
  Assim "zona interna" significa "chegou pelo listener interno **e** passou pelo Access", qualquer que seja o caminho
  de rede.
- **Cloudflare Access no nome interno**: aplicativo "Central de Atendimento — equipe" com dois provedores de
  identidade: **Google Workspace da LRI** e **Microsoft Entra ID da IRD.Net**. Política: permitir e-mails
  `@lri.com.br` e `@meanwellbrasil.com.br` autenticados pelo Google (a equipe Mean Well Brasil tem contas nos dois
  domínios, decisão de Leandro na issue #2) e `@ird.net.br` autenticados pelo Entra ID; MFA exigido nos provedores.
  Clientes da Mean Well Brasil verão `suporte.lri.com.br` nos links de e-mail de sistema e nos retornos de login
  (aprovado por Leandro).
  Os nomes de cliente **não** têm Access (o cliente usa o portal com e-mail e senha).
- **Listeners**: o Nginx que já existe na stack oficial do Zammad (`zammad-nginx`) ganha dois blocos de servidor,
  um por zona, ouvindo só em `127.0.0.1`. Os cabeçalhos de zona ficam num arquivo incluído **em cada `location`**
  (`/`, `/api`, `/graphql`, `/ws`, `/cable`), porque o Nginx descarta os `proxy_set_header` do nível de cima
  quando a `location` define os seus (caso de `/ws` e `/cable`, que definem `Upgrade` e `Connection`); com
  `underscores_in_headers off` e `ignore_invalid_headers on`. Os dois listeners apagam `Remote-User`,
  `X-Forwarded-User` e `X-Forwarded-Host` vindos do cliente. Cada um **sobrescreve** `X-LRI-Zone`, define
  `X-Forwarded-Proto: https` e copia o IP real de `CF-Connecting-IP` para `X-Forwarded-For` (com
  `set_real_ip_from` restrito ao `cloudflared`). O valor de `X-LRI-Zone` enviado pelo navegador é sempre
  descartado, e o Zammad só é alcançável por esse Nginx.
- **TLS**: o certificado público é o da borda da Cloudflare; entre a borda e o `cloudflared` o túnel é cifrado.
  Não há Let's Encrypt nem certificado de origem para gerenciar na central.
- **Nginx compartilhado da VPS**: não muda. A central não disputa as portas 80 e 443.
- **Base oficial**: a stack `zammad/zammad-docker-compose` já traz o cenário `scenarios/add-cloudflare-tunnel.yml`:
  container `cloudflared` com o token do túnel, `RAILS_TRUSTED_PROXIES` no `zammad-railsserver` e no
  `zammad-websocket` (o servidor de WebSocket calcula o IP do cliente por conta própria), `NGINX_SERVER_SCHEME=https`
  (sem ele o cookie de sessão não sai com `Secure` e o login falha por CSRF) e nenhuma porta publicada. A central
  parte desse cenário e acrescenta o listener interno e o Access.

**WebSocket**. A Cloudflare repassa WebSocket em todos os nomes, e os dois listeners mandam `Upgrade` e
`Connection` em `/ws` e `/cable`. O Zammad só aceita como origem `fqdn` e `alternative_fqdn`
(`lib/zammad/web_socket_origins.rb`):

| Setting | Valor |
| ------- | ----- |
| `fqdn` | `suporte.lri.com.br` |
| `alternative_fqdn` | `suporte.ird.net.br` |

Regras decididas para a troca de `Origin` (issue #2):

- o listener interno troca o cabeçalho `Origin` **somente quando ele é exatamente** `https://atendimento.lri.com.br`
  (comparação de texto inteiro num `map` com `default $http_origin`, sem curinga nem expressão regular) para
  `https://suporte.lri.com.br`, só na rota `/ws` (o `/cable` já aceita a origem igual ao `Host`);
- qualquer outro `Origin` passa sem alteração, e o Zammad o recusa;
- a troca existe só no listener interno, que só recebe tráfego já autenticado pelo Access;
- testes provam que continuam recusados, em `/ws` e em `/cable`: `https://atendimento.lri.com.br.evil.com`,
  `https://intranet.lri.com.br`, `null`, a origem em maiúsculas e o `Origin` ausente.

**Terceiro nome de cliente** (`suporte.meanwellbrasil.com.br`): os clientes da Mean Well Brasil também usam
WebSocket, e o Zammad só conhece duas origens. Proposta, com as mesmas regras de casamento exato: o listener público
troca `https://suporte.meanwellbrasil.com.br` por `https://suporte.lri.com.br` só em `/ws`. Diferente do
caso interno, aqui o tráfego não passa pelo Access; a troca continua segura porque só converte uma origem da própria
central em outra, e uma página de terceiro segue com o próprio `Origin` e é recusada. Pergunta aberta na issue #2;
a lista de origens no fork (candidata ao upstream) resolveria os dois casos sem troca no proxy.

A Cloudflare encerra conexões ociosas por 100 s; o teste de homologação confirma que os pings do `/ws` e do `/cable`
mantêm a conexão viva.

**Retornos de OAuth**. O Zammad monta a URL de retorno sempre a partir do `fqdn`:
`OmniAuth.config.full_host` (`config/initializers/omniauth.rb`) para o login da equipe e
`ExternalCredential.callback_url` (`app/models/external_credential.rb`) para a autorização das caixas de e-mail.
Os URIs registrados no Google e no Entra ID continuam sendo os do `fqdn` (seção 2.7). O login, porém, começa e
termina no nome interno:

1. o agente abre `atendimento.lri.com.br`, passa pelo Access e clica em "Google" ou "Microsoft";
2. o provedor devolve o navegador para `https://suporte.lri.com.br/auth/<provedor>/callback?code=…&state=…`;
3. o listener público responde **302 para o mesmo caminho e a mesma query em `atendimento.lri.com.br`**, apenas
   para os caminhos exatos de retorno (`/auth/google_oauth2/callback`, `/auth/microsoft_office365/callback` e
   `/api/v1/external_credentials/<provedor>/callback`), com destino fixo escrito na configuração (nunca o `Host` nem
   parâmetro da requisição) e a query string preservada, para não virar redirecionamento aberto (condição da
   issue #2);
4. no nome interno, a sessão que iniciou o fluxo confere o `state` e troca o `code` usando o mesmo `redirect_uri` do
   `fqdn`, que é só um texto comparado pelo provedor.

O `code` é de uso único e só vale com o segredo do aplicativo, que fica no servidor. Ao fim da autorização de uma
caixa, o Zammad redireciona para `https://suporte.lri.com.br/#channels/…` (`ExternalCredential.app_url`); o
administrador volta ao nome interno por conta própria. O teste de homologação cobre os três retornos.

**Login da equipe** (decidido: opção i):

- **(i) Login do Zammad por Google e Microsoft atrás do Access (decidida)**: nada muda no núcleo; o agente passa
  pelo Access e depois clica no botão do provedor, quase sempre sem digitar nada, porque já está autenticado nele.
- **(ii) SSO por cabeçalho (evolução futura, só com threat model próprio)**: o Zammad já aceita login pelo cabeçalho
  `X-Forwarded-User`
  (`app/controllers/sessions_controller.rb`). O listener interno preencheria esse cabeçalho a partir do e-mail
  validado pelo Access, e o listener público o apagaria. É um login só, mas o Zammad passa a confiar num cabeçalho;
  a guarda de zona teria de recusar esse cabeçalho fora da zona interna, e o caminho precisa de threat model
  próprio.

**Cookies e sessões**. Cada nome tem os seus cookies. A sessão da equipe fica presa a `atendimento.lri.com.br`, e a
dos clientes aos nomes `suporte`.

**Links aos agentes**. Os e-mails de notificação aos agentes usam o `fqdn` (`suporte.lri.com.br`). Fora do nome
interno, o agente cai no portal; a página de bloqueio (definida pela `ux-spec`) aponta o endereço interno. Uma
melhoria posterior pode gerar esses links com o nome interno.

#### 2.9.3 Controles, do mais forte ao complementar

1. **Guarda de zona no Zammad (controle principal)**. Uma camada pequena no fork, em **nível Rack** (middleware que
   roda antes de qualquer controller, inclusive das rotas `/oauth/*` do Doorkeeper, que não herdam do
   `ApplicationController`).
   - **Zona falha fechada**: só é zona interna a requisição com `X-LRI-Zone: internal`, o segredo de zona correto e
     um JWT válido do Access (seção 2.9.2). Qualquer outra combinação é zona pública.
   - **Zona de criação da sessão**: no login, a guarda grava em `session.data` a zona em que a sessão nasceu e recusa,
     para qualquer perfil, uma sessão nascida na zona interna usada na pública. A sessão do Zammad fica no banco e o
     valor do cookie vale em qualquer nome; essa regra não depende de checar o papel do usuário.
   - **SSO por cabeçalho desligado e barrado**: `/auth/sso` (`SessionsController#create_sso`) lê `REMOTE_USER`,
     depois `Remote-User` e depois `X-Forwarded-User`, e com `auth_sso_trusted_ips` vazio aceita qualquer IP. A guarda
     recusa `/auth/sso` na zona pública, o listener público o bloqueia, e um teste falha se `auth_sso` estiver ligado
     sem threat model aprovado (opção ii da seção 2.9.2).
   - **Quem é avaliado**: o **dono real** da credencial — o usuário da sessão, inclusive quando houve troca de sessão
     ("entrar como", `switched_from_user_id`), o dono do token de API, o dono do token OAuth2 e o usuário da
     autenticação básica —, nunca só o usuário efetivo, que muda com `From`/`X-On-Behalf-Of`. Na zona pública, a
     personificação é recusada para todos.
   - **O que é recusado na zona pública** para usuários com permissão de agente (`ticket.agent`) ou de administração
     (`admin*`):
     - login por senha em REST (`/api/v1/signin`) e GraphQL (mutation de login), com a mensagem definida pela
       `ux-spec`;
     - qualquer requisição autenticada — sessão, token de API, autenticação básica e token OAuth2 (Doorkeeper) — em
       REST, GraphQL, downloads de anexos, `/ical` e `/calendar_subscriptions`; a sessão é encerrada;
     - emissão e uso de tokens OAuth2 em `/oauth/*`;
     - a conclusão do login OmniAuth (Google e Microsoft) de perfil da equipe, explicitamente, porque o OmniAuth casa
       o caminho sem diferenciar maiúsculas e aceita barra final, e o bloqueio por caminho no Nginx diferencia;
     - o login no WebSocket (`/ws`) e a conexão do ActionCable (`/cable`). Esses dois pontos autenticam fora do fluxo
       Rack dos controllers (`lib/sessions/event/login.rb` e `app/channels/application_cable/connection.rb`), então a
       mesma política de zona é chamada explicitamente em cada um, com o cabeçalho de zona repassado pelo proxy e a
       verificação do dono real da sessão.
   - **Interface**: a guarda informa à interface que a zona é pública, para que a tela de login do cliente **não
     mostre** os botões de Google e Microsoft da equipe.

   A guarda segue a seção 4 (alteração pequena, coberta por testes, em caminho próprio do projeto) e é candidata a
   proposta ao upstream como recurso genérico ("perfis restritos a redes confiáveis").
2. **Equipe sem senha local, em qualquer zona**. A guarda também recusa, para perfis de agente e administração,
   o login por senha e a redefinição de senha (envio, verificação e troca, em REST e GraphQL). Assim "esqueci minha
   senha" no portal não cria uma senha de agente. Para não revelar quais e-mails pertencem à equipe, o pedido de
   redefinição de um perfil da equipe **não gera token nem e-mail, mas devolve a mesma resposta, no mesmo tempo**, que
   o Zammad já devolve para um e-mail desconhecido. Uma única conta administrativa de emergência mantém senha e só
   funciona na zona interna: ela é ativada apenas depois de ter o 2FA do Zammad **já cadastrado** por aplicativo
   autenticador (TOTP), nunca por chave de segurança, que não funciona no nome interno (seção 2.6) — o Zammad só
   exige o segundo fator de quem já o configurou —, e seu uso fica registrado.
3. **MFA no provedor de identidade**. O 2FA do Zammad (`two_factor_authentication_enforce_role_ids`) só se aplica a
   login por senha; logins por SSO não passam por ele. Por isso o segundo fator da equipe é **exigido no Google
   Workspace (LRI) e no Entra ID (IRD.Net)**. O 2FA do Zammad fica obrigatório apenas para a conta de emergência.
4. **Credenciais de API desligadas onde não são usadas**. `api_password_access` desativado (autenticação básica na API,
   que pula o 2FA em `/ical` e `/calendar_subscriptions`); nenhuma aplicação OAuth2 (Doorkeeper) cadastrada; tokens
   de API só para integrações que chegam pela zona interna (nome interno com token de serviço do Access).
   Assinaturas de calendário por autenticação básica deixam de funcionar; a alternativa para a
   equipe, na zona interna, fica definida no contrato do slice.
5. **Bloqueio de rotas da equipe no listener público (defesa em profundidade)**. O listener público responde com a
   página de bloqueio definida pela `ux-spec` para as rotas abaixo; as mesmas rotas também são barradas por regra
   personalizada do WAF da Cloudflare nos três nomes de cliente, antes de chegarem à VPS:
   - todo `/auth/*` por expressão sem diferenciar maiúsculas (`location ~* ^/auth/`), incluindo `/auth/sso`,
     **exceto** os caminhos exatos de retorno (`location =`), que recebem o 302 para o nome interno (seção 2.9.2);
   - autorização das caixas de e-mail: `/api/v1/external_credentials/*`, com a mesma exceção para o retorno;
   - provedor OAuth2: `/oauth/*`;
   - monitoramento (`/api/v1/monitoring/*`) e as rotas de administração, importação, integrações e telefonia cuja
     lista exata o architect define no contrato do slice, com teste para cada uma.
6. **Visibilidade entre clientes garantida no modelo**: em vez de só uma rotina que corrige organizações criadas com
   `shared = true` (seção 2.3), um callback `before_create` da `Organization`, em caminho próprio do fork, grava
   `shared = false`, com teste. Não fica janela em que um cliente veja os chamados de outro.
7. **Retorno da autorização de caixa exige `state`**: no upstream, `lib/external_credential/google.rb` e
   `microsoft_base.rb` aceitam o retorno quando `state` e o token da sessão são ambos vazios. O fork passa a exigir
   o token presente e a comparação em tempo constante, e a correção é proposta ao upstream. Os aplicativos de e-mail
   são registrados como de um só tenant.

#### 2.9.4 O que fica em cada zona

| Função | Zona pública (nomes `suporte`) | Zona interna (nome da equipe, atrás do Access) |
| ------ | ----------------------- | ------------------ |
| Portal do cliente: cadastro, login com senha, redefinição de senha, abrir e acompanhar chamados | sim | sim |
| Base de conhecimento pública (`/help`) e formulário web | sim | sim |
| WebSocket (`/ws`) e ActionCable (`/cable`) para sessões de cliente | sim | sim |
| Interface de agente, sessões e API de agente | **não** (guarda de zona) | sim |
| Administração e configurações | **não** (guarda + bloqueio de rotas) | sim |
| Login da equipe por Google e Microsoft | **não** (rotas bloqueadas; só o retorno do provedor, repassado ao nome interno) | sim |
| Autorização OAuth das caixas de e-mail | **não** (rotas bloqueadas; só o retorno, repassado ao nome interno) | sim |
| Recebimento de e-mail (Gmail IMAP e Microsoft Graph) | não se aplica: o servidor busca as mensagens | — |
| Webhooks de integrações futuras (por exemplo WhatsApp) | só a rota específica de cada webhook, quando a integração entrar | sim |

Os links das notificações aos agentes apontam para `suporte.lri.com.br`; ali o agente vê a página de bloqueio, que
indica o nome interno (seção 2.9.2).

#### 2.9.5 Riscos e alternativas

Riscos da proposta e como cada um é tratado:

| Risco | Tratamento |
| ----- | ---------- |
| Rota compartilhada expõe função de agente na internet | guarda de zona por perfil, não por caminho; testes negativos por tipo de autenticação |
| Cabeçalho de zona forjado, ausente ou inválido, inclusive de dentro da rede Docker | zona interna exige também o segredo de zona e o JWT do Access; railsserver e websocket numa rede interna só com o Nginx; cabeçalhos incluídos em cada `location`; testes por `location` (`/`, `/api`, `/graphql`, `/ws`, `/cable`) com cabeçalho forjado, ausente, malformado e com sublinhado |
| Regra nova do túnel criada pela conta da Cloudflare, sem o Access | túnel gerenciado por `config.yml` local versionado; papéis da conta Cloudflare restritos e logs de auditoria revisados (checklist); a guarda exige o JWT do Access de qualquer forma |
| Sessão de agente roubada usada pelo nome público | guarda recusa perfil da equipe na zona pública e recusa sessão nascida na zona interna; testes em HTTP, `/ws` e `/cable` |
| `Remote-User` ou `X-Forwarded-User` injetados (`/auth/sso`) | listeners apagam os dois cabeçalhos; `/auth/sso` bloqueado no público; teste que falha com `auth_sso` ligado |
| Administrador personifica um cliente ("entrar como" ou `X-On-Behalf-Of`) e passa pela zona pública | guarda avalia o dono real da credencial e recusa personificação na zona pública; testes para as duas trocas de sessão e para os cabeçalhos de personificação |
| Token OAuth2 (Doorkeeper) de agente usado pela internet | guarda em nível Rack cobre `/oauth/*` e o uso de bearer token; nenhuma aplicação OAuth2 cadastrada |
| 2FA do Zammad não cobre login por SSO | segundo fator exigido no Google Workspace e no Entra ID |
| Agente cria senha local pelo portal e entra pela internet | guarda recusa login por senha e redefinição de senha para perfis da equipe, em qualquer zona |
| Token de API ou autenticação básica de agente usados pela internet | guarda cobre token, autenticação básica, `/ical` e `/calendar_subscriptions`; `api_password_access` desativado; integrações (ERP Plune) chegam pela zona interna |
| Agente abre o nome público (link de notificação, favorito antigo) | falha fechada: a guarda recusa a sessão de agente e a página de bloqueio indica o nome interno |
| Listener interno alcançado sem passar pelo Access | o listener escuta só em `127.0.0.1` no namespace do Nginx, sem porta publicada; o `cloudflared` exige o token do Access (`access.required`) e a guarda confere o JWT; teste de acesso direto que deve falhar |
| Repasse dos retornos de OAuth vira redirecionamento aberto | só caminhos exatos, destino fixo no nome interno, query repassada sem alterar o host; teste com host e caminho manipulados |
| Origem do WebSocket do nome interno recusada | troca de `Origin` só para o valor exato do nome interno, só em `/ws`; testes com origem estranha, origem irmã, sufixo, `null`, maiúsculas e ausente, que devem continuar recusadas |
| Chaves de segurança (WebAuthn) presas ao `fqdn` | 2FA do Zammad por aplicativo autenticador (TOTP) na conta de emergência; teste de homologação |
| Cloudflare ou o túnel fora do ar | clientes e equipe ficam sem acesso web até o túnel voltar; a entrada de e-mail continua (é de saída); dois conectores `cloudflared` para o mesmo túnel e procedimento de contingência no guia de operação |
| Dependência da Cloudflare e dados em trânsito na borda | as zonas e os outros sites do grupo já dependem dela; registro como operador no inventário LGPD (seção 6.5); plano Zero Trust gratuito até 50 usuários — acima disso há custo, que exige aprovação de Leandro |
| Limite de 100 MB por requisição na borda (plano gratuito) | limite de anexo do Zammad configurado abaixo disso e informado na `ux-spec` |
| Botões de SSO da equipe visíveis ao cliente | guarda informa a zona à interface; `ux-spec` define a tela de login pública |
| Diferença a mais em relação ao upstream | guarda em caminho próprio, pequena, com testes; proposta ao upstream |
| Mudança no Nginx compartilhado afeta os outros sites | a central não usa o Nginx compartilhado nem abre porta nova; o túnel é só de saída |

Alternativas consideradas:

| Alternativa | Avaliação |
| ----------- | --------- |
| **C. Cloudflare Tunnel + Access com nome interno (decidida)** | as zonas já estão na Cloudflare e a LRI já usa Access na intranet; sem porta de entrada nem mudança no Nginx compartilhado; login por Google (LRI) e Microsoft (IRD.Net) na borda, sem cliente instalado; exige o repasse dos retornos de OAuth e a troca de `Origin` do WebSocket descritos na seção 2.9.2 |
| A. VPN WireGuard própria com DNS interno (proposta anterior, descartada) | sem dependência de terceiros e mesmo nome nas duas zonas, mas exige porta UDP nova, chaves por aparelho, DNS interno e cliente em cada máquina ou túnel por escritório, e o lado público continuaria no Nginx compartilhado. Descartada pela C, que segue o padrão da intranet e dispensa cliente e porta nova |
| B. Tailscale com DNS dividido | sem porta de entrada; exige cliente Tailscale em cada aparelho da equipe e licenças por usuário acima do plano gratuito |
| C2. Cloudflare WARP com o mesmo nome resolvido para rede privada | mesmo nome nas duas zonas; exige o cliente WARP em cada aparelho e política de DNS da Cloudflare Gateway; mais peças que a proposta |
| D. Access cobrindo os nomes `suporte` inteiros | agentes e clientes compartilham caminhos, então o cliente também teria de passar pelo login da Cloudflare. Descartada |
| E. `fqdn` apontando para o nome interno | links de redefinição de senha e de cadastro dos clientes apontariam para um nome inacessível na internet. Descartada |
| F. Tudo público, com 2FA e restrição por IP dentro do Zammad | contraria a decisão de não expor a parte interna; fica só como contingência temporária, com aprovação de Leandro |

#### 2.9.6 Como o slice passa pela esteira

A separação de zonas é um slice com `ui_impact` e `security_impact` diferentes de `none`:

1. **Planner**: define o slice "Zonas interna e pública".
2. **UX-A** ([`roles/2b-ux-engineer-a.md`](https://github.com/leaberg69/esteira-softwarehouse-LR/blob/main/roles/2b-ux-engineer-a.md)),
   **antes de qualquer código**: `ux-spec` com
   - a tela de login da zona pública, sem os botões de SSO da equipe, na interface atual do Zammad (UI-LRI-2);
   - a página de bloqueio em pt-BR para rotas da equipe acessadas pela internet, com a marca do Grupo LRI;
   - a mensagem ao agente que tenta entrar pela internet;
   - estados de erro e requisitos de acessibilidade.
3. **Architect**: contrato com `allowed_paths` (guarda de zona, configuração do proxy em `contrib/lri/`, testes), lista
   exata das rotas bloqueadas e o formato do cabeçalho de zona.
4. **Security-A**: threat model com os abuse cases da seção 2.9.5 e os controles obrigatórios.
5. **Coder** ([`roles/5-coder.md`](https://github.com/leaberg69/esteira-softwarehouse-LR/blob/main/roles/5-coder.md)):
   implementação com TDD e um teste negativo por abuse case — login por senha (REST e GraphQL), redefinição de
   senha (incluindo resposta e tempo idênticos aos de e-mail desconhecido), conta de emergência (senha e 2FA aceitos
   na zona interna e recusados na pública), sessão, troca de sessão, `X-On-Behalf-Of`, token de API, autenticação
   básica, `/ical`, `/calendar_subscriptions`, token OAuth2 e `/oauth/*`, GraphQL, `/ws`, `/cable`, cabeçalho
   forjado, ausente, malformado ou sem o segredo de zona, JWT do Access ausente ou inválido, sessão nascida na zona
   interna usada na pública, `/auth/sso` com `Remote-User`, variantes de maiúsculas e barra final em `/auth/*`, e
   retorno de caixa sem `state`.
6. **Revisões em paralelo**: Code Reviewer
   ([`roles/6-code-reviewer.md`](https://github.com/leaberg69/esteira-softwarehouse-LR/blob/main/roles/6-code-reviewer.md)),
   security-B e UX-B ([`roles/6b-ux-engineer-b.md`](https://github.com/leaberg69/esteira-softwarehouse-LR/blob/main/roles/6b-ux-engineer-b.md)),
   todos de família de modelo diferente da de quem escreveu.
7. **QA**: validação em homologação com as duas zonas, incluindo um agente que tenta entrar pelo nome público.

Nenhuma etapa deste slice executa comando no servidor de produção. Qualquer comando destrutivo em produção ou
homologação (por exemplo, alterar a configuração do proxy que atende os outros projetos) só acontece com
`python -m pipeline.cli destructive-check` devolvendo `LIBERADO` a partir do ack de Leandro em `acks.yaml`.

## 3. Princípios de UI e UX

### UI-LRI-1 — Decisões de UI pelos engenheiros de UI/UX da esteira

Toda decisão de interface — cores, logos, textos, disposição, fluxos — é tomada pelo papel de engenheiro de UI/UX da
esteira `leaberg69/esteira-softwarehouse-LR`, que atua em dois estágios:

- **UX Engineer A** — [`roles/2b-ux-engineer-a.md`](https://github.com/leaberg69/esteira-softwarehouse-LR/blob/main/roles/2b-ux-engineer-a.md):
  antes da arquitetura, converte o slice em contrato de design (`ux-spec-vN.yaml`) com fluxos, estados de cada
  componente, requisitos de acessibilidade com referência WCAG, `visual_tokens` da instância e `acceptance_visuals`.
  O valor de `ui_impact` que ele define prevalece.
- **UX Engineer B** — [`roles/6b-ux-engineer-b.md`](https://github.com/leaberg69/esteira-softwarehouse-LR/blob/main/roles/6b-ux-engineer-b.md):
  verifica a implementação contra a `ux-spec`, em paralelo à revisão de código e à revisão de segurança, com
  screenshots obrigatórios do Playwright headless em ambiente local (`ux-report-vN.yaml`). O approve fica preso ao
  `diff_sha256` revisado.

Todo slice que toca interface renderizada, e-mails ao cliente, textos exibidos ou apresentação de erro tem
`ui_impact` diferente de `none`, portanto `ux-spec` antes do código e `ux-report` aprovado antes do merge.
_Violação: uma mudança visual mesclada sem `ux-spec` do UX-A ou sem `ux-report` aprovado do UX-B._

### UI-LRI-2 — A interface do Zammad é mantida; sem redesign

A interface atual do Zammad é a base do produto e permanece como está: layout, navegação, componentes, fluxos de
atendimento e portal. O trabalho de UI se limita a três frentes:

- **Branding**: logos da LRI e da IRD.Net, cores das marcas, favicon, assinaturas e templates de e-mail;
- **Polimento pt-BR**: termos consistentes, tom adequado e textos completos em todo o produto;
- **Consistência**: mesmos nomes, termos e padrões em grupos, macros, módulos de texto, gatilhos e base de
  conhecimento.

Esse princípio é o mesmo que os papéis da esteira já impõem: o UX-A não redesenha UI que já tem contrato visual, e o
UX-B não aponta divergência de gosto como achado. A interface do Zammad é o contrato visual deste projeto; as
`ux-spec` descrevem apenas a camada de branding, texto e consistência sobre ela.

_Violação: novo layout, novo componente que substitui um existente, reordenação de telas ou fluxo de atendimento
alterado._

### UI-LRI-3 — Branding por camada de customização, nunca no núcleo

As cores e estilos das marcas entram pelas pastas de CSS customizado que o Zammad aplica no build, sem editar
arquivos do núcleo:

- `app/frontend/apps/desktop/styles/custom/` e `app/frontend/apps/mobile/styles/custom/` (interface nova em Vue);
- `app/assets/stylesheets/custom/` (interface atual em CoffeeScript);
- `app/assets/stylesheets/custom_knowledge_base_public/` (base de conhecimento pública).

Os arquivos usam os tokens de design existentes (`var(--color-…)`) e o atributo estável `data-zammad-target`. Logo e
nome do produto são configurados pelo painel de administração. _Violação: alterar `tokens.css` ou um componente do
núcleo para aplicar uma cor de marca._

### UI-LRI-4 — Textos pt-BR pelo caminho oficial

Os textos da interface vêm de `translations.zammad.org`. Ajustes de tradução são contribuídos lá e chegam ao fork pela
sincronização com o upstream, beneficiando também a comunidade. Os textos que são dados da instalação — nomes de
grupos, macros, módulos de texto, assinaturas, gatilhos, artigos da base de conhecimento — são escritos pela equipe e
especificados pelo UX-A e verificados pelo UX-B. _Violação: editar `i18n/*.po` diretamente._

### UI-LRI-5 — Acessibilidade e contraste preservados

As cores das marcas são aplicadas respeitando contraste WCAG AA nos dois temas (claro e escuro) da interface. Cada
`ux-spec` lista esse requisito no campo `accessibility`, com a referência WCAG, e o UX-B o verifica no
`accessibility_check`.
_Violação: cor de marca aplicada a texto ou botão sem atingir o contraste mínimo._

### Ativos de marca

Os ativos vêm das lojas e sites oficiais de cada marca, a pedido de Leandro, e ficam versionados em
[`docs/lri/brand-assets/`](brand-assets/) como **fonte**. As versões finais, já tratadas e aprovadas pelo UX-B, vão
para `public/assets/lri/` no slice de branding (fase 3).

#### Cores

| Marca | Papel | Cor | Origem |
| ----- | ----- | --- | ------ |
| LRI | primária | `#74b527` | `theme-color` de `www.lri.com.br` |
| LRI | secundária | `#3d7a12` | seção personalizada da loja da LRI |
| LRI | secundária escura | `#2c5a0d` | seção personalizada da loja da LRI |
| IRD.Net | primária | `#e46e33` | `theme-color` de `www.ird.net.br` |
| IRD.Net | apoio | `#000000` | logo da IRD.Net |
| IRD.Net | laranja do logo vetorial | `#e76e33` | `IRD.Net logo.ai` oficial; só dentro do logo |
| Mean Well Brasil | vermelho do logo | `#d92e27`, `#e42527` | logo vetorial oficial; só dentro do logo |

#### Logos

Fonte oficial (decisão de Leandro, 31/10): a pasta de logos dele, com os vetores AI/PDF quando existem. As cópias
usadas no repositório ficam em [`brand-assets/`](brand-assets/):

| Arquivo | Marca | Formato | Origem |
| ------- | ----- | ------- | ------ |
| [`lri-logo.svg`](brand-assets/lri-logo.svg) | LRI | SVG vetorial, `viewBox` 1000 × 775,4, sem `fill` | idêntico ao `SVG.svg` da pasta oficial |
| [`ird-logo.svg`](brand-assets/ird-logo.svg) | IRD.Net | SVG vetorial, 606,9 × 116,5, preto e laranja `#e76e33`, sem slogan | extraído do `IRD.Net logo.ai` oficial (versão em curvas) |
| [`mw-brasil-logo.svg`](brand-assets/mw-brasil-logo.svg) | Mean Well Brasil | SVG vetorial, 1000 × 1000 | `SVG.svg` do pacote de logos oficial da Mean Well Brasil |
| [`lri-logo-white.png`](brand-assets/lri-logo-white.png) e [`ird-logo.png`](brand-assets/ird-logo.png) | LRI, IRD.Net | PNG | fontes antigas, das lojas; não usadas pelo branding |

Os três SVG contêm só formas vetoriais, sem scripts, imagens embutidas nem referências externas. O gerador
`contrib/lri/branding/gerar_logos.py` produz em `public/assets/lri/` as variantes definidas pela `ux-spec` v2
(`docs/lri/esteira/branding/`): LRI com `fill` verde por tema, IRD.Net com o preto trocado por branco no tema escuro,
Mean Well Brasil com fundo branco sob as letras vazadas, e os logos compostos das três marcas (empilhado para o
login e horizontal para a base de conhecimento). O laranja da IRD.Net e o vermelho da Mean Well aparecem só dentro
dos logos.

#### Lacunas

| Item | LRI | IRD.Net | Mean Well Brasil |
| ---- | --- | ------- | ---------------- |
| Símbolo quadrado 512 px (favicon, avatar do sistema) | pendente | pendente | existe em PNG 500 × 500 |
| Logo para assinatura de e-mail (até 300 px de largura) | a gerar a partir do SVG (fase 2) | idem | idem |
| Regras de uso do logo (área de proteção, tamanho mínimo) | pendente | manual de marca na pasta oficial | pendente |

#### Verificação de contraste pelo UX-A

O **UX-A** ([`roles/2b-ux-engineer-a.md`](https://github.com/leaberg69/esteira-softwarehouse-LR/blob/main/roles/2b-ux-engineer-a.md))
verifica o contraste WCAG AA de cada cor contra os temas claro e escuro do Zammad e registra o resultado no campo
`accessibility` da `ux-spec` de branding, com a regra de uso de cada cor em `visual_tokens`. O UX-B confirma com
screenshots nos dois temas.

Razões de contraste calculadas pela fórmula WCAG 2.x, como ponto de partida para o UX-A. Fundos dos tokens do Zammad:
claro `#ffffff` e `neutral-50` `#fafafa`; escuro `gray-500` `#323234` e `gray-900` `#202021`.

| Cor | `#ffffff` | `#fafafa` | `#323234` | `#202021` | texto branco sobre a cor | texto preto sobre a cor |
| --- | --------- | --------- | --------- | --------- | ------------------------ | ----------------------- |
| `#74b527` | 2,51 | 2,40 | 5,11 | 6,50 | 2,51 | 8,38 |
| `#3d7a12` | 5,26 | 5,04 | 2,43 | 3,09 | 5,26 | 3,99 |
| `#2c5a0d` | 8,15 | 7,81 | 1,57 | 2,00 | 8,15 | 2,58 |
| `#e46e33` | 3,19 | 3,06 | 4,01 | 5,10 | 3,19 | 6,58 |

Limites WCAG AA: 4,5:1 para texto normal; 3:1 para texto grande e para componentes de interface (bordas, ícones,
foco). Pontos que a `ux-spec` resolve:

- **Verde LRI no tema claro**: `#74b527` fica abaixo de 3:1 sobre branco; o verde de texto e de botão no tema claro é
  `#3d7a12` ou `#2c5a0d`, e `#74b527` fica para áreas decorativas ou para o tema escuro, onde passa.
- **Verde LRI no tema escuro**: `#74b527` passa; os dois verdes secundários não.
- **Laranja IRD.Net**: passa 3:1 no tema claro (componentes e texto grande), mas não 4,5:1; texto normal laranja sobre
  branco e texto branco sobre laranja ficam de fora, e texto preto sobre laranja passa. No tema escuro passa 3:1 e
  fica abaixo de 4,5:1 sobre `#323234`.
- **Logos**: o preto da IRD.Net e o SVG da LRI sem `fill` não aparecem no tema escuro; daí as variantes para fundo
  escuro da tabela de lacunas.

A tipografia continua a do Zammad (UI-LRI-2). O logo do **Grupo LRI**, usado no portal, é uma composição dos dois
logos, especificada pelo UX-A nos `visual_tokens` da `ux-spec`.

## 4. Estratégia de customização do fork

A regra central é **configurar antes de codificar**. A ordem de preferência para qualquer necessidade é:

1. **Configuração** pelo painel: grupos, canais, gatilhos, SLAs, calendários, Core Workflow, macros, templates,
   campos customizados (Object Manager), base de conhecimento.
2. **Configuração como código**: um script de provisionamento idempotente em `contrib/lri/` (ou via auto wizard)
   cria grupos, perfis, organizações, SLAs e gatilhos. O ambiente se reconstrói do zero de forma reprodutível e a
   configuração é revisada em PR.
3. **Camada de customização**: CSS das pastas `custom`, assets de marca e a camada de addon do frontend
   (`.dev/agent_docs/frontend_addon_layer.md`), sem tocar arquivos do núcleo.
4. **Integração externa**: serviços separados que conversam com o Zammad pela API REST/GraphQL e por webhooks
   (ERP Plune, site).
5. **Alteração no núcleo**: último recurso. Quando necessária, a mudança é pequena, coberta por teste e, sempre que
   fizer sentido para a comunidade, proposta ao upstream para deixar de ser diferença do fork.

Arquivos exclusivos do projeto ficam em caminhos próprios e previsíveis:

| Caminho | Conteúdo |
| ------- | -------- |
| `docs/lri/` | documentação do projeto |
| `contrib/lri/` | provisionamento, scripts operacionais |
| `*/styles/custom/lri-*.css`, `app/assets/stylesheets/custom/lri-*.css` | branding |
| `docs/lri/brand-assets/` | ativos de marca originais (fonte) |
| `public/assets/lri/` | logos e imagens das marcas, versões finais |

## 5. Sincronização com o upstream

O fork acompanha o Zammad continuamente, para receber correções de segurança, melhorias e traduções.

- **Remotos**: `origin` = `leaberg69/zammad`; `upstream` = `zammad/zammad`.
- **Linha base**: a produção acompanha uma **versão estável** do Zammad (série `stable`), não a ponta do `develop`.
  O desenvolvimento do projeto ocorre sobre a mesma base, para que o que é testado seja o que vai para produção.
- **Cadência**: sincronização a cada release estável do upstream (patches mensais e versões maiores), sempre por PR
  dedicado, com CI verde e revisão independente — exatamente como qualquer outra mudança.
- **Versões maiores**: lidas com antecedência no `BREAKING_CHANGES.md` do upstream; o PR de atualização lista o impacto
  nas customizações do projeto.
- **Inventário de diferenças**: `docs/lri/DIFERENCAS-UPSTREAM.md` registra cada arquivo do núcleo alterado, o motivo e
  se há proposta ao upstream. A meta é manter essa lista próxima de zero.
- **Conflitos mínimos por construção**: como as customizações ficam em caminhos próprios (seção 4), a sincronização
  normalmente é um merge limpo.

## 6. Implantação e requisitos de servidor

Este documento apenas descreve as opções; a implantação acontece em etapa própria, com aprovação de Leandro.

### 6.1 Opções

| Opção | Descrição | Indicada quando |
| ----- | --------- | --------------- |
| **A. Docker Compose** | stack oficial (`zammad-docker-compose`) em um servidor | operação enxuta, atualização por troca de imagem |
| **B. Pacote DEB/RPM** | pacote oficial (packager.io) em Ubuntu/Debian/RHEL | equipe confortável com serviços Linux tradicionais |
| **C. Kubernetes (Helm)** | chart oficial | o grupo já opera Kubernetes |

**Decidido: opção A (Docker Compose)**, com imagem construída a partir deste fork pela CI. A imagem é imutável:
branding e customizações entram no build, nunca escritos em tempo de execução, o que segue o princípio `DEPLOY-1` do
produto (`.dev/agent_docs/product_principles.md`). Atualizar é publicar uma nova imagem e reiniciar a stack.

### 6.2 Hospedagem

**Decidido**: a central roda na **VPS compartilhada do grupo** (endereço e projetos vizinhos no registro privado da
operação). A central entra como mais um projeto isolado no servidor: Compose próprio, rede própria, volumes próprios,
limites de recursos próprios e nenhum impacto nos projetos que já estão no ar.

Este plano não altera o servidor. Todos os itens abaixo são verificados, somente em leitura, antes da implantação
(fase 5); a implantação só começa com a lista completa e a autorização de Leandro. O resultado da verificação fica
registrado em `docs/lri/VPS-CHECKLIST.md`.

#### 6.2.1 Checklist pré-implantação

O checklist completo, com o que já se sabe do servidor, os comandos somente de leitura de cada item e o registro da
execução, fica em [`VPS-CHECKLIST.md`](VPS-CHECKLIST.md). Ele cobre recursos disponíveis, convivência com os outros
projetos, rede e Cloudflare, as duas zonas da seção 2.9, Elasticsearch e memória, backups, usuário isolado e
segredos.

Achados do levantamento que pedem decisão antes da fase 5 ficam no registro privado da operação (o repositório é
público); o checklist aponta quais decisões estão pendentes.

### 6.3 Componentes

- **Zammad**: servidor web (Rails), websocket e processos de background (scheduler/jobs);
- **PostgreSQL**: banco principal (a CI do projeto usa PostgreSQL 18);
- **Redis**: websocket, assinaturas GraphQL e cache;
- **Elasticsearch** 8.15 a 9.x: busca de texto completo em chamados e anexos — presente desde o início (decidido).
  O OpenSearch não serve: `SearchIndexBackend` (`lib/search_index_backend.rb`) só aceita versões do Elasticsearch
  de 8.15.0 até antes da 10 e falha a verificação de compatibilidade com qualquer outra;
- **Proxy reverso**: o Nginx da stack da central, com os listeners público e interno, alcançado só pelo `cloudflared`
  (Cloudflare Tunnel); HTTPS na borda da Cloudflare (seção 2.9.2);
- **Armazenamento de anexos** em disco persistente ou S3 compatível.

### 6.4 Dimensionamento inicial

Reserva de recursos para a central na VPS, para até cerca de 30 agentes simultâneos:

| Recurso | Recomendado |
| ------- | ----------- |
| CPU | 4 vCPU |
| Memória | 8 GB (16 GB com folga para crescimento e busca) |
| Disco | 100 GB SSD, expansível conforme volume de anexos |
| Sistema | Ubuntu Server LTS suportado, com Docker e Docker Compose |
| Rede | domínio próprio, HTTPS, saída para Gmail (IMAP/SMTP) e para Microsoft Graph |

Com o crescimento, a central ganha recursos na própria VPS ou passa para um servidor dedicado; a imagem e o Compose são
os mesmos nos dois casos.

### 6.5 Operação

- **Backup** diário do banco e dos anexos, com retenção de 30 dias, cópia fora do servidor e teste de restauração
  trimestral;
- **Ambientes**: homologação e produção, com a mesma imagem promovida de um para o outro; na VPS compartilhada, a
  homologação é um projeto Compose separado, ligado apenas durante a validação, para não disputar recursos;
- **Monitoramento**: o endpoint de monitoramento nativo do Zammad, alertas de disco, memória e fila de jobs;
- **LGPD**: localização do datacenter registrada no checklist da seção 6.2.1, retenção de chamados definida,
  exclusão de dados pessoais pelo recurso nativo de remoção de dados do Zammad.

## 7. Integrações futuras

As integrações entram depois da operação básica estável. Todas usam os pontos de extensão do Zammad (API REST e
GraphQL, webhooks, gatilhos e canais nativos), sem alterar o núcleo.

### 7.1 ERP Plune

- **Clientes e organizações**: sincronização do cadastro de clientes do Plune para organizações e usuários do Zammad
  (CNPJ, razão social, contatos), com o Plune como fonte da verdade.
- **Contexto no chamado**: exibição de pedidos, notas fiscais e títulos do cliente ao lado do chamado, para o agente
  responder sem trocar de sistema.
- **Eventos**: webhooks do Zammad notificam o Plune quando um chamado comercial ou de RMA muda de estado, quando isso
  agregar ao processo.
- **Forma**: um serviço de integração separado, com credenciais próprias e escopo mínimo. O primeiro passo é mapear a
  API disponível no Plune.

### 7.2 Sites

- **Formulário de contato** embutido nos sites da LRI e da IRD.Net, criando chamados no grupo da marca;
- **Links** para o portal do cliente e para a base de conhecimento pública;
- **Chat** nativo do Zammad, como opção, para horário comercial.

### 7.3 WhatsApp

- O Zammad possui **canal nativo de WhatsApp** pela WhatsApp Business Cloud API (Meta): mensagens viram chamados e as
  respostas do agente voltam ao WhatsApp do cliente.
- Um número por marca, cada um entregando no grupo da marca;
- Pré-requisitos: conta Meta Business verificada para cada empresa, números dedicados e modelos de mensagem aprovados.

## 8. Roteiro por fases

Cada fase termina com seus PRs mesclados (CI verde e revisão independente). Nenhuma fase inclui implantação; a
implantação é autorizada à parte por Leandro.

| Fase | Entregas | Critério de conclusão |
| ---- | -------- | --------------------- |
| **0. Plano** | este documento | PLANO.md aprovado por Leandro |
| **1. Fundação** | CI do fork estável; remoto upstream; inventário de diferenças; provisionamento em `contrib/lri/` com pt-BR, fuso, grupos, perfis e organizações | ambiente de desenvolvimento recriado do zero pelo script |
| **2. Marcas e e-mail** | canais de e-mail por marca, endereços e assinaturas por grupo, gatilhos de confirmação, templates de e-mail com marca | e-mail de teste de cada marca vira chamado no grupo certo e a resposta sai com remetente e assinatura certos |
| **3. Portal e branding** | logos e cores LRI/IRD.Net nas pastas `custom`; portal do cliente; base de conhecimento com categorias por marca; revisão pt-BR | `ux-report` do UX-B aprovado, com screenshots, para identidade e textos |
| **4. Operação de atendimento** | SLAs e calendários (feriados nacionais e locais de RS e SC); macros e módulos de texto; Core Workflow; relatórios por marca | piloto interno com a equipe de TI usando a central |
| **5. Imagem e implantação** | imagem Docker do fork construída pela CI; slice de zonas interna e pública (seção 2.9) com guarda de zona, configuração do proxy, do Cloudflare Tunnel e do Access; guia de implantação, backup e restauração | homologação validada; produção sob autorização de Leandro |
| **6. Integrações** | site e formulário; WhatsApp; ERP Plune | cada integração em PR próprio, com testes e documentação |

## 9. Governança e esteira

O projeto segue a esteira `leaberg69/esteira-softwarehouse-LR` (v5.2): uma máquina de estados determinística que
coordena os papéis researcher → planner → UX-A → architect → security-A → coder → (code review ∥ security-B ∥
UX-B) → QA. Cada papel produz um artefato versionado que o orquestrador valida por schema e hash antes do handoff; o
próximo passo sai de `python -m pipeline.cli next`.

Regras que valem para todo PR deste projeto:

- **Toda mudança entra por PR**, inclusive configuração como código e sincronização com o upstream, dividida em slices
  com `allowed_paths` definidos pelo contrato do architect.
- **Quem escreve nunca aprova.** O revisor é outro agente, de contexto novo, e a revisão não usa a família de modelo de
  quem escreveu.
- **Coder** — [`roles/5-coder.md`](https://github.com/leaberg69/esteira-softwarehouse-LR/blob/main/roles/5-coder.md):
  implementa só dentro de `allowed_paths`, com TDD (teste que falha primeiro), um teste negativo para cada abuse case
  do threat model e todo controle exigido implementado. Desvios vão em `deviations` da `implementation-note`; o diff
  é gerado por `python -m pipeline.cli diff`. Slices com input, login ou e-mail (portal, login Google e Microsoft,
  canais) usam a skill de hardening.
- **Code Reviewer** — [`roles/6-code-reviewer.md`](https://github.com/leaberg69/esteira-softwarehouse-LR/blob/main/roles/6-code-reviewer.md):
  revisa corretude, regressões e manutenibilidade, em paralelo ao security-B e ao UX-B; não aprova com achado `high`
  aberto e encaminha achados de segurança ao security-B.
- **Approvals presos ao diff**: `review-report`, `security-report` e `ux-report` registram o `diff_sha256` revisado. Um
  byte alterado no diff derruba as aprovações e as revisões rodam de novo.
- **Segurança**: `security_impact: none` só com ack humano e nunca em slice com input externo, parsing, rede ou
  dependência nova — o que inclui e-mail, portal, OAuth e integrações.
- **CI verde** é condição para merge, além dos verdicts da esteira.
- **Nada é implantado** por este fluxo. Comando destrutivo em produção ou homologação exige
  `python -m pipeline.cli destructive-check` com saída `LIBERADO`, a partir de ack que só humano registra em
  `acks.yaml`.
- Documentação do projeto em pt-BR, em `docs/lri/`; mensagens de commit e código seguem as convenções do Zammad
  (`AGENTS.md`), o que facilita propor melhorias ao upstream.

## 10. Decisões

Leandro aceitou todas as recomendações deste plano. A numeração é mantida para que referências anteriores continuem
válidas.

### 10.1 Decididas

| Nº | Tema | Decisão |
| -- | ---- | ------- |
| 1 | Domínio e caixas de e-mail | IRD.Net usa `ird.net.br`; caixas `suporte@lri.com.br`, `comercial@lri.com.br` e `suporte@ird.net.br` (seção 2.4) |
| 2 | Endereços e nome da central | `suporte.lri.com.br` (LRI), `suporte.meanwellbrasil.com.br` (Mean Well Brasil) e `suporte.ird.net.br` (IRD.Net) na mesma instância; "Central de Atendimento Grupo LRI" (seções 2.5 e 2.6) |
| 3 | Identidade do portal | portal único com a identidade do Grupo LRI e os logos das marcas (seção 2.5) |
| 4 | Grupos e filas | estrutura da seção 2.2 |
| 6 | Hospedagem | VPS compartilhada do grupo, isolada por projeto Compose próprio (seção 6.2) |
| 8 | Login dos colaboradores | LRI por Google Workspace, IRD.Net por Microsoft 365 (Entra ID), sem criação automática de contas; clientes com e-mail e senha (seção 2.7) |
| — | Cores das marcas | LRI `#74b527`, `#3d7a12`, `#2c5a0d`; IRD.Net `#e46e33` e preto (seção 3) |
| — | Canais de e-mail | LRI pelo canal Google Email; IRD.Net pelo canal Microsoft 365 Graph Email (seção 2.4) |
| 9 | Horário de atendimento | provisório: segunda a sexta, 08:00–18:00, `America/Sao_Paulo` (seção 2.8) |
| 10 | Visibilidade dos clientes | cada cliente vê só os próprios chamados; organizações com `shared = false` (seção 2.3) |
| 13 | Esteira | papéis e regras de PR e revisão da esteira vinculados às seções 3 e 9 |
| — | Zonas | parte interna (equipe, administração) só na intranet; parte do cliente na internet nos subdomínios `suporte` (seção 2.9) |
| — | Separação das zonas | Cloudflare Tunnel + Access, nome interno `atendimento.lri.com.br`, login da equipe pelo Zammad atrás do Access, troca exata de `Origin` no listener interno, listener interno só em `127.0.0.1`, JWT do Access validado pelo `cloudflared` ([issue #2](https://github.com/leaberg69/zammad/issues/2), seção 2.9.2) |
| — | Terceira marca | Mean Well Brasil (marca da LRI): `suporte@meanwellbrasil.com.br` e `suporte.meanwellbrasil.com.br` na mesma instância (issue #2, 31/10) |
| — | Fonte dos logos | pasta oficial de logos de Leandro (vetores AI/PDF quando existem); IRD.Net vetorial extraído para `brand-assets/ird-logo.svg` |
| — | Arquitetura | instância única para as duas marcas (seção 2.1) |
| — | Opção de implantação | Docker Compose com imagem imutável construída pela CI (seção 6.1) |
| — | Busca | Elasticsearch 8.15 a 9.x desde o início; OpenSearch não é suportado pelo Zammad (seção 6.3) |
| — | Operação | backup diário com retenção de 30 dias e teste trimestral; homologação e produção (seção 6.5) |
| — | Linha base do upstream | série estável do Zammad (seção 5) |
| — | Customização | ordem de preferência e caminhos próprios das seções 4 e 5 |
| — | Roteiro | fases 0 a 6 da seção 8 |

### 10.2 Em aberto

1. **Caixas restantes**: endereços da caixa comercial da IRD.Net, da TI interna e do financeiro da LRI. O canal de
   cada uma já segue do domínio (seção 2.4).
2. **DNS**: os três registros `suporte` existem desde 31/10 (A para a VPS, com proxy); Leandro troca para `CNAME` do
   túnel quando ele for criado (seção 2.6).
3. **Ativos de marca**: vetores das três marcas e variantes geradas (seção 3, "Ativos de marca"); faltam o símbolo
   quadrado de 512 px da LRI e da IRD.Net e as regras de uso; perguntas de branding na
   [issue #3](https://github.com/leaberg69/zammad/issues/3).
4. **Checklist da VPS**: execução, somente em leitura e com OK de Leandro dado diretamente, do
   [`VPS-CHECKLIST.md`](VPS-CHECKLIST.md); decisões sobre os achados do registro privado da operação.
5. **Versão estável exata (decisão 7)**: a série do Zammad em vigor quando a fase 1 começar.
6. **Horário definitivo e SLAs (decisão 9)**: horário de atendimento definitivo (hoje provisório, seção 2.8), plantão,
   feriados locais e metas de SLA por marca e por tipo de cliente.
7. **ERP Plune (decisão 11)**: documentação da API e escopo da primeira integração.
8. **WhatsApp (decisão 12)**: números e contas Meta Business de cada marca.
9. **Zonas, pendências de Leandro** ([issue #2](https://github.com/leaberg69/zammad/issues/2)): criar o túnel, trocar os
   registros `suporte` para `CNAME` do túnel, criar `atendimento.lri.com.br` e os aplicativos do Access; registrar o
   aplicativo no Entra ID da IRD.Net; troca de `Origin` também para `suporte.meanwellbrasil.com.br` no listener público
   (pergunta aberta); domínio `@meanwellbrasil.com.br` na política do Access, se a equipe tiver contas próprias.
10. **Proposta da guarda de zona ao upstream**: autorização para propor a guarda de zona ao `zammad/zammad` depois de
    validada aqui.
