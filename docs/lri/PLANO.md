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

Uma **única instância** do Zammad atende as duas marcas. A separação entre LRI e IRD.Net é feita com os mecanismos
nativos da plataforma — grupos, organizações, endereços de e-mail, assinaturas, permissões e regras — sem alterar o
núcleo do produto.

```text
 E-mail LRI ─────┐                                    ┌─▶ Grupos LRI::*     ─▶ Agentes LRI
 E-mail IRD.Net ─┤                                    │
 Portal web ─────┼─▶ Zammad (instância única) ────────┼─▶ Grupos IRD::*     ─▶ Agentes IRD.Net
 Formulário web ─┤    roteamento por gatilhos e       │
 (futuro: WhatsApp, ERP Plune, site)   Core Workflow  └─▶ Grupos Interno::* ─▶ TI / áreas de apoio
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
  Zammad é `shared = true`, o provisionamento (seção 4) cria as organizações já com `false`, e um gatilho ou rotina
  agendada corrige qualquer organização criada depois com o valor padrão. A verificação faz parte dos testes da fase 1.
- **Perfis (roles)**: `Admin`, `Agente LRI`, `Agente IRD.Net`, `Agente Interno` e `Cliente`. Colaboradores que abrem
  chamados internos usam o perfil `Cliente` e veem apenas os grupos `Interno::*`.

### 2.4 Canais de e-mail

Cada marca tem caixas de entrada próprias, configuradas como canais de e-mail do Zammad:

| Caixa | Grupo de destino | Situação |
| ----- | ---------------- | -------- |
| `suporte@lri.com.br` | `LRI::Suporte Técnico` | decidida |
| `comercial@lri.com.br` | `LRI::Comercial` | decidida |
| `suporte@ird.net.br` | `IRD::Suporte` | decidida |
| caixa comercial da IRD.Net | `IRD::Comercial` | endereço a definir |
| caixa da TI interna | `Interno::TI` | endereço a definir |
| caixa financeira da LRI | `LRI::Financeiro` | endereço a definir |

- **Canal por marca (decidido)**: cada marca usa o canal nativo do Zammad para o seu provedor de e-mail, com OAuth,
  sem senha de caixa guardada no Zammad.

  | Marca | Provedor | Canal do Zammad | Caixas |
  | ----- | -------- | --------------- | ------ |
  | LRI | Google Workspace | **Google Email** (Gmail por IMAP/SMTP com OAuth) | `suporte@lri.com.br`, `comercial@lri.com.br` e demais caixas `@lri.com.br` |
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

- **Base de conhecimento pública**: uma base com categorias de primeiro nível por marca (`LRI` e `IRD.Net`), em pt-BR,
  publicada para clientes e, quando indicado, para o público geral.
- **Formulário web**: o formulário embutível do Zammad entra nas páginas de contato dos sites (fase 4).
- **Endereços (decidido)**: dois subdomínios, um por marca, servidos pela mesma instância com HTTPS —
  `suporte.lri.com.br` para a LRI e `suporte.ird.net.br` para a IRD.Net (detalhes na seção 2.6).
- **Nome do produto (decidido)**: "Central de Atendimento Grupo LRI".
- **Identidade visual (decidida)**: o portal usa a identidade do **Grupo LRI**, com os logos das duas marcas, porque o
  logo e o nome do produto são configurações globais da instância. O cliente escolhe a marca e a fila na abertura do
  chamado; e-mails, assinaturas e respostas seguem a marca do grupo escolhido.

### 2.6 Dois endereços em uma instância

A instância responde pelos dois subdomínios. Cada camada tem um papel definido:

#### Configurações do Zammad

| Setting | Valor | Efeito |
| ------- | ----- | ------ |
| `http_type` | `https` | todos os links gerados usam HTTPS |
| `fqdn` | `suporte.lri.com.br` | endereço principal: links dos e-mails de sistema, formulário web, SSO e chaves de segurança |
| `alternative_fqdn` | `suporte.ird.net.br` | segundo endereço aceito como origem das conexões WebSocket |

O Zammad aceita um endereço principal e um alternativo, o que corresponde exatamente às duas marcas. Depois de alterar
`fqdn` ou `alternative_fqdn`, os serviços do Zammad são reiniciados para que as origens permitidas sejam recarregadas.

#### Proxy reverso

- Um bloco de servidor por subdomínio (ou um bloco com os dois nomes), ambos encaminhando para o mesmo Zammad. Esses
  blocos existem em dois listeners, público e interno, conforme a seção 2.9.
- O proxy repassa os cabeçalhos `Host`, `X-Forwarded-For` e `X-Forwarded-Proto`. O cabeçalho `Host` original é o que
  permite ao ActionCable aceitar a conexão pelo endereço da IRD.Net.
- As rotas de WebSocket (`/ws` e `/cable`) recebem os cabeçalhos `Upgrade` e `Connection` de upgrade.
- Porta 80 redireciona para 443 nos dois nomes, mantendo livre o caminho `/.well-known/acme-challenge/`.

#### Certificados TLS

- DNS: registros `A` de `suporte.lri.com.br` (zona `lri.com.br`) e `suporte.ird.net.br` (zona `ird.net.br`) apontando
  para o IP do servidor da central.
- Certificados Let's Encrypt emitidos pelo proxy por desafio HTTP-01 — um certificado por nome ou um certificado com
  os dois nomes —, com renovação automática.

#### Links nos e-mails

- **E-mails ao cliente gerados por gatilhos** (confirmação de recebimento, resposta, encerramento): há um gatilho por
  marca, condicionado aos grupos `LRI::*` ou `IRD::*`, e cada um escreve o link com o endereço da sua marca, por
  exemplo `https://suporte.ird.net.br/#ticket/zoom/#{ticket.id}`. Assim o cliente da IRD.Net sempre volta pelo
  endereço da IRD.Net.
- **Assinaturas por grupo** trazem o endereço do portal da marca.
- **E-mails de sistema** (redefinição de senha, verificação de cadastro, convite, notificações a agentes) usam
  `config.fqdn` e apontam para `suporte.lri.com.br`. O link funciona para qualquer cliente, porque a instância é a
  mesma e o portal tem a identidade do Grupo LRI. Esses modelos se identificam pelo nome do produto
  (`config.product_name`), "Central de Atendimento Grupo LRI", válido para as duas marcas.
- **Agentes** usam `suporte.lri.com.br`, o endereço ao qual SSO e chaves de segurança (WebAuthn) estão vinculados.
- **Sessão**: o login vale por endereço; quem entrar por `suporte.ird.net.br` continua nele durante a navegação.
- **Evolução**: se o Grupo LRI quiser que os e-mails de sistema também saiam com o endereço da marca do cliente, isso
  pede uma mudança pequena no núcleo (escolher o endereço pela organização do destinatário). Ela segue a seção 4 e é
  proposta ao upstream.

### 2.7 Autenticação

- **Colaboradores (decidido)**: o login da equipe só se completa na zona interna (VPN, seção 2.9). Cada empresa entra
  com a conta corporativa que já usa, pelos dois provedores nativos do
  Zammad. A tela de login mostra os dois botões.

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
   responder **pelo mesmo nome**.
3. **A entrada por e-mail é de saída.** Os canais Google Email (IMAP/SMTP com OAuth) e Microsoft 365 Graph Email
   buscam as mensagens a partir do servidor. Nenhuma porta ou rota pública é necessária para receber e-mail.

#### 2.9.2 Arquitetura proposta: mesmo nome, duas portas de entrada

```text
                        Internet                                   Intranet (VPN WireGuard)
 Cliente ── DNS público ──▶ suporte.lri.com.br        Agente ── DNS interno ──▶ suporte.lri.com.br
                            suporte.ird.net.br                                  suporte.ird.net.br
                                   │ IP público da VPS                                 │ IP da VPN na VPS
                                   ▼                                                   ▼
                     Listener PÚBLICO do proxy                          Listener INTERNO do proxy
                     - define X-LRI-Zone: public                        - define X-LRI-Zone: internal
                     - bloqueia rotas da equipe                         - todas as rotas
                                   └──────────────────┐   ┌────────────────────────────┘
                                                      ▼   ▼
                                        Zammad (127.0.0.1, só o proxy alcança)
                                        guarda de zona: na zona pública, nenhuma
                                        sessão de agente ou administrador é aceita
```

- **DNS com duas visões (split-horizon)**: na internet, os dois nomes apontam para o IP público da VPS. Dentro da VPN,
  o DNS interno resolve os mesmos nomes para o IP da VPN na VPS. Assim os retornos de OAuth, os cookies de sessão, as
  origens de WebSocket (`fqdn` e `alternative_fqdn`) e os certificados funcionam igual nas duas zonas, sem mudar nada
  do que as seções 2.6 e 2.7 já definem.
- **Listener público**: o bloco do proxy existente na VPS (seção 6.2), escutando 80/443 no IP público.
- **Listener interno**: um segundo bloco do mesmo proxy, escutando 443 **apenas no IP da interface da VPN**. Usa os
  mesmos certificados Let's Encrypt, que continuam sendo emitidos pelo listener público (HTTP-01).
- **Cabeçalho de zona**: cada listener **sobrescreve** `X-LRI-Zone` (o valor enviado pelo navegador é sempre
  descartado). O Zammad só aceita conexões do proxy (`127.0.0.1` ou a rede Docker do proxy), então ninguém fala direto
  com ele para forjar o cabeçalho. `RAILS_TRUSTED_PROXIES` aponta para o proxy, para que o IP real do cliente apareça
  nos logs.

#### 2.9.3 Controles, do mais forte ao complementar

1. **Guarda de zona no Zammad (controle principal)**. Uma camada pequena no fork, em **nível Rack** (middleware que
   roda antes de qualquer controller, inclusive das rotas `/oauth/*` do Doorkeeper, que não herdam do
   `ApplicationController`).
   - **Zona falha fechada**: só `X-LRI-Zone: internal` é zona interna. Cabeçalho ausente, vazio ou com qualquer outro
     valor é tratado como zona pública.
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
     - o login no WebSocket (`/ws`) e a conexão do ActionCable (`/cable`).
   - **Interface**: a guarda informa à interface que a zona é pública, para que a tela de login do cliente **não
     mostre** os botões de Google e Microsoft da equipe.

   A guarda segue a seção 4 (alteração pequena, coberta por testes, em caminho próprio do projeto) e é candidata a
   proposta ao upstream como recurso genérico ("perfis restritos a redes confiáveis").
2. **Equipe sem senha local, em qualquer zona**. A guarda também recusa, para perfis de agente e administração,
   o login por senha e a redefinição de senha (envio, verificação e troca, em REST e GraphQL). Assim "esqueci minha
   senha" no portal não cria uma senha de agente. Uma única conta administrativa de emergência mantém senha e 2FA do
   Zammad e só funciona na zona interna; seu uso fica registrado.
3. **MFA no provedor de identidade**. O 2FA do Zammad (`two_factor_authentication_enforce_role_ids`) só se aplica a
   login por senha; logins por SSO não passam por ele. Por isso o segundo fator da equipe é **exigido no Google
   Workspace (LRI) e no Entra ID (IRD.Net)**. O 2FA do Zammad fica obrigatório apenas para a conta de emergência.
4. **Credenciais de API desligadas onde não são usadas**. `api_password_access` desativado (autenticação básica na API,
   que pula o 2FA em `/ical` e `/calendar_subscriptions`); nenhuma aplicação OAuth2 (Doorkeeper) cadastrada; tokens
   de API só para integrações que rodam dentro da VPN. Assinaturas de calendário por autenticação básica deixam de
   funcionar; a alternativa para a equipe, dentro da VPN, fica definida no contrato do slice.
5. **Bloqueio de rotas da equipe no listener público (defesa em profundidade)**. O listener público responde com a
   página de bloqueio definida pela `ux-spec` para:
   - início e retorno do login da equipe: `/auth/google_oauth2*` e `/auth/microsoft_office365*`;
   - autorização das caixas de e-mail: `/api/v1/external_credentials/*`;
   - provedor OAuth2: `/oauth/*`;
   - monitoramento (`/api/v1/monitoring/*`) e as rotas de administração, importação, integrações e telefonia cuja
     lista exata o architect define no contrato do slice, com teste para cada uma.

#### 2.9.4 O que fica em cada zona

| Função | Zona pública (internet) | Zona interna (VPN) |
| ------ | ----------------------- | ------------------ |
| Portal do cliente: cadastro, login com senha, redefinição de senha, abrir e acompanhar chamados | sim | sim |
| Base de conhecimento pública (`/help`) e formulário web | sim | sim |
| WebSocket (`/ws`) e ActionCable (`/cable`) para sessões de cliente | sim | sim |
| Interface de agente, sessões e API de agente | **não** (guarda de zona) | sim |
| Administração e configurações | **não** (guarda + bloqueio de rotas) | sim |
| Login da equipe por Google e Microsoft | **não** (rotas bloqueadas) | sim |
| Autorização OAuth das caixas de e-mail | **não** (rotas bloqueadas) | sim |
| Recebimento de e-mail (Gmail IMAP e Microsoft Graph) | não se aplica: o servidor busca as mensagens | — |
| Webhooks de integrações futuras (por exemplo WhatsApp) | só a rota específica de cada webhook, quando a integração entrar | sim |

Os links das notificações aos agentes apontam para `suporte.lri.com.br`; dentro da VPN eles abrem a parte interna, e
fora dela o agente vê a página de bloqueio.

#### 2.9.5 Riscos e alternativas

Riscos da proposta e como cada um é tratado:

| Risco | Tratamento |
| ----- | ---------- |
| Rota compartilhada expõe função de agente na internet | guarda de zona por perfil, não por caminho; testes negativos por tipo de autenticação |
| Cabeçalho de zona forjado, ausente ou inválido | proxy sobrescreve o cabeçalho; Zammad só alcançável pelo proxy; qualquer valor diferente de `internal` é zona pública; testes com cabeçalho forjado, ausente e malformado em HTTP e WebSocket |
| Administrador personifica um cliente ("entrar como" ou `X-On-Behalf-Of`) e passa pela zona pública | guarda avalia o dono real da credencial e recusa personificação na zona pública; testes para as duas trocas de sessão e para os cabeçalhos de personificação |
| Token OAuth2 (Doorkeeper) de agente usado pela internet | guarda em nível Rack cobre `/oauth/*` e o uso de bearer token; nenhuma aplicação OAuth2 cadastrada |
| 2FA do Zammad não cobre login por SSO | segundo fator exigido no Google Workspace e no Entra ID |
| Agente cria senha local pelo portal e entra pela internet | guarda recusa login por senha e redefinição de senha para perfis da equipe, em qualquer zona |
| Token de API ou autenticação básica de agente usados pela internet | guarda cobre token, autenticação básica, `/ical` e `/calendar_subscriptions`; `api_password_access` desativado; integrações (ERP Plune) rodam dentro da VPN |
| DNS interno mal configurado manda o agente ao listener público | falha fechada: o agente vê a página de bloqueio, nenhum dado da equipe é exposto |
| VPN fora do ar | a equipe fica sem acesso até a VPN voltar; clientes e entrada de e-mail não são afetados; procedimento de contingência no guia de operação |
| Botões de SSO da equipe visíveis ao cliente | guarda informa a zona à interface; `ux-spec` define a tela de login pública |
| Diferença a mais em relação ao upstream | guarda em caminho próprio, pequena, com testes; proposta ao upstream |
| Porta nova na VPS para a VPN | uma porta UDP do WireGuard, registrada no checklist (seção 6.2.1), sem efeito nos outros projetos |

Alternativas consideradas:

| Alternativa | Avaliação |
| ----------- | --------- |
| **A. VPN WireGuard própria com DNS interno (proposta)** | sem dependência de terceiros, mesmo nome nas duas zonas, custo zero; exige DNS interno e clientes WireGuard ou túnel a partir das redes dos escritórios |
| B. Tailscale (WireGuard gerenciado) com DNS dividido | configuração mais simples e sem porta de entrada na VPS; depende de serviço externo para coordenação |
| C. Cloudflare Tunnel + Cloudflare Access | sem porta de entrada e com login por identidade; como agentes e clientes compartilham caminhos, o Access precisaria cobrir o nome inteiro, exigindo login Cloudflare também dos clientes, ou um nome separado, o que quebra os retornos de OAuth atrelados ao `fqdn` |
| D. Nome interno separado (por exemplo `helpdesk.intranet`) | os retornos de OAuth e os e-mails de sistema continuam usando o `fqdn` público; o login da equipe acabaria completado no nome público. Descartada |
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
   senha, sessão, troca de sessão, `X-On-Behalf-Of`, token de API, autenticação básica, `/ical`,
   `/calendar_subscriptions`, token OAuth2 e `/oauth/*`, GraphQL, `/ws`, `/cable` e cabeçalho forjado, ausente ou
   malformado.
6. **Revisões em paralelo**: Code Reviewer
   ([`roles/6-code-reviewer.md`](https://github.com/leaberg69/esteira-softwarehouse-LR/blob/main/roles/6-code-reviewer.md)),
   security-B e UX-B ([`roles/6b-ux-engineer-b.md`](https://github.com/leaberg69/esteira-softwarehouse-LR/blob/main/roles/6b-ux-engineer-b.md)),
   todos de família de modelo diferente da de quem escreveu.
7. **QA**: validação em homologação com as duas zonas, incluindo um agente fora da VPN.

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

#### Logos

| Arquivo | Marca | Formato | Observação |
| ------- | ----- | ------- | ---------- |
| [`lri-logo.svg`](brand-assets/lri-logo.svg) | LRI | SVG vetorial, `viewBox` 1000 × 775,4 | sem `fill`: renderiza preto |
| [`lri-logo-white.png`](brand-assets/lri-logo-white.png) | LRI | PNG 181 × 93, branco, fundo transparente | da loja; pequeno para telas de alta densidade |
| [`ird-logo.png`](brand-assets/ird-logo.png) | IRD.Net | PNG 874 × 246, preto e laranja, fundo transparente | não existe SVG |

O SVG da LRI contém apenas caminhos vetoriais, sem scripts nem referências externas.

#### Lacunas

| Item | LRI | IRD.Net | Grupo LRI |
| ---- | --- | ------- | --------- |
| Logo vetorial (SVG) | existe, **precisa de cor de preenchimento** | **não existe** | pendente |
| Versão para fundo escuro | PNG branco pequeno; SVG com `fill` claro a gerar | pendente: o preto do logo some no tema escuro | pendente |
| Símbolo quadrado 512 px (favicon, avatar do sistema) | pendente | pendente | pendente |
| Logo para assinatura de e-mail (até 300 px de largura) | a gerar a partir do SVG | a gerar a partir do PNG | — |
| Regras de uso do logo (área de proteção, tamanho mínimo) | pendente | pendente | — |

- **SVG da LRI**: o slice de branding gera duas variantes a partir do original — `fill` na cor definida pelo UX-A para
  fundo claro e `fill` claro para o tema escuro —, sem alterar o desenho.
- **IRD.Net**: o PNG de 874 × 246 atende ao portal e às assinaturas. Um SVG oficial é solicitado à IRD.Net; até lá, o
  PNG é a fonte, e a versão para fundo escuro troca o preto por branco mantendo o laranja.

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

**Decidido**: a central roda na **VPS existente 72.62.108.138**, que também hospeda os projetos Justiano, Plaixec e
sferalabs. A central entra como mais um projeto isolado no servidor: Compose próprio, rede própria, volumes próprios,
limites de recursos próprios e nenhum impacto nos projetos que já estão no ar.

Este plano não altera o servidor. Todos os itens abaixo são verificados, somente em leitura, antes da implantação
(fase 5); a implantação só começa com a lista completa e a autorização de Leandro. O resultado da verificação fica
registrado em `docs/lri/VPS-CHECKLIST.md`.

#### 6.2.1 Checklist pré-implantação

##### Recursos disponíveis

- [ ] vCPU, memória e disco totais do servidor e consumo atual de Justiano, Plaixec e sferalabs, medido em horário de
  pico (`docker stats`, `free`, `df`).
- [ ] Sobra, depois do consumo atual, de pelo menos o dimensionamento da seção 6.4: 4 vCPU, 8 GB de memória e 100 GB
  de disco para a central, mais uma margem de 20% para os projetos existentes.
- [ ] Tipo de disco (SSD/NVMe) e possibilidade de expandir disco e memória no provedor sem reinstalação.
- [ ] Swap configurado, para absorver picos sem acionar o OOM killer sobre os outros projetos.
- [ ] País e região do datacenter da VPS e provedor, registrados para a LGPD (seção 6.5).

##### Convivência com os outros containers

- [ ] Inventário dos containers, redes e volumes existentes (`docker ps`, `docker network ls`, `docker volume ls`).
- [ ] Projeto Compose da central com nome próprio (`lri-helpdesk`), rede Docker própria e volumes com prefixo próprio,
  sem colidir com nomes já usados.
- [ ] PostgreSQL, Redis e Elasticsearch/OpenSearch exclusivos da central, sem compartilhar instâncias dos outros
  projetos e sem portas publicadas no host.
- [ ] Limites de memória e CPU (`mem_limit`, `cpus`) em cada container da central, somando no máximo a sobra medida
  acima.
- [ ] Política de reinício (`restart: unless-stopped`) e ordem de subida que não dependam dos outros projetos.
- [ ] Versões de Docker e Docker Compose atendem à stack oficial do Zammad sem exigir atualização que afete os outros
  projetos; se exigirem, a atualização vira mudança própria, planejada à parte.

##### Portas e proxy reverso

- [ ] Quem atende hoje as portas 80 e 443 (Nginx, Caddy, Traefik ou container) e como os outros projetos são
  roteados.
- [ ] A central entra como **mais um site no proxy existente**, com os nomes `suporte.lri.com.br` e
  `suporte.ird.net.br`, seguindo a seção 2.6 (cabeçalho `Host`, upgrade de WebSocket em `/ws` e `/cable`).
- [ ] O container web da central publica a porta apenas em `127.0.0.1` (ou só na rede Docker do proxy), em uma porta
  livre conferida no inventário (`ss -tlnp`).
- [ ] Emissão e renovação dos certificados dos dois nomes pelo mesmo mecanismo que já atende os outros projetos.
- [ ] Firewall: além de 80 e 443, que já estão em uso, apenas a porta UDP do WireGuard (seção 2.9) é aberta para a
  internet, e só depois de aprovada.
- [ ] Saída de rede liberada para Gmail (IMAP 993 e SMTP 465/587 em `imap.gmail.com` e `smtp.gmail.com`), para as
  APIs OAuth do Google e para Microsoft Graph e Entra ID (`graph.microsoft.com`, `login.microsoftonline.com`), em HTTPS.

##### Zonas interna e pública (seção 2.9)

- [ ] O proxy existente suporta dois listeners para os mesmos nomes: o público (IP da VPS) e o interno (IP da VPN),
  sem alterar os blocos dos outros projetos.
- [ ] Cada listener sobrescreve o cabeçalho `X-LRI-Zone` (`public` ou `internal`); o valor enviado pelo navegador nunca
  chega ao Zammad. Requisição sem o cabeçalho é tratada como zona pública.
- [ ] MFA obrigatório para a equipe no Google Workspace (LRI) e no Entra ID (IRD.Net).
- [ ] `api_password_access` desativado e nenhuma aplicação OAuth2 cadastrada no Zammad.
- [ ] O Zammad escuta só em `127.0.0.1` ou na rede Docker do proxy, confirmado por `ss -tlnp` e por tentativa de acesso
  externo direto à porta, que deve falhar.
- [ ] Lista de rotas bloqueadas no listener público (seção 2.9.3) aplicada e testada de fora da VPN.
- [ ] `RAILS_TRUSTED_PROXIES` aponta para o proxy, e os logs do Zammad mostram o IP real do cliente.
- [ ] WireGuard: porta UDP livre, chaves geradas por par, interface da VPN com IP fixo na VPS, e nada além do
  listener interno exposto nessa interface.
- [ ] DNS interno das redes da LRI e da IRD.Net (ou dos clientes WireGuard) resolve `suporte.lri.com.br` e
  `suporte.ird.net.br` para o IP da VPN.
- [ ] Teste de fora da VPN: portal do cliente, base de conhecimento e formulário funcionam; login de agente, rotas de
  SSO da equipe, autorização de caixas e administração são recusados.
- [ ] Teste dentro da VPN: login por Google (LRI) e por Microsoft (IRD.Net), interface de agente, administração e
  tempo real (`/ws` e `/cable`) funcionam.
- [ ] Recebimento de e-mail pelos canais Google e Microsoft funciona sem nenhuma rota pública.

##### Elasticsearch/OpenSearch e memória

- [ ] Heap fixado em valor conhecido (`ES_JAVA_OPTS` ou `OPENSEARCH_JAVA_OPTS`, por exemplo `-Xms1g -Xmx1g`) e
  `mem_limit` do container em cerca do dobro do heap.
- [ ] `vm.max_map_count` atual do host. O Elasticsearch/OpenSearch exige `262144`; esse parâmetro vale para o host
  inteiro, então a mudança é avaliada quanto ao efeito nos outros projetos e aplicada como mudança própria.
- [ ] Execução em nó único (`discovery.type=single-node`), segurança do motor habilitada e porta 9200 sem publicação no
  host.
- [ ] Limites de memória do PostgreSQL (`shared_buffers`) e do Redis (`maxmemory`) coerentes com o `mem_limit` de cada
  container.

##### Backups antes de qualquer mudança

- [ ] Snapshot completo da VPS no provedor tirado **antes** de qualquer alteração no servidor, com data e responsável
  registrados.
- [ ] Backups dos projetos Justiano, Plaixec e sferalabs conferidos e recentes, com restauração já testada ou testada
  antes da implantação.
- [ ] Procedimento de retorno escrito: como voltar ao snapshot ou remover a central sem afetar os outros projetos.
- [ ] Destino da cópia externa do backup da central (seção 6.5) definido e com espaço.
- [ ] O mesmo snapshot prévio vale para toda mudança futura na central: atualização de versão, ajuste de kernel ou
  troca de configuração do proxy.

##### Usuário de sistema isolado e segredos

- [ ] Usuário de sistema dedicado (`lri-helpdesk`), sem login por senha, dono exclusivo do diretório da central (por
  exemplo `/srv/lri-helpdesk`), sem acesso aos diretórios dos outros projetos.
- [ ] Forma de operar o Docker por esse usuário definida com cuidado: participar do grupo `docker` equivale a acesso de
  root ao host, então a escolha entre Docker rootless, `sudo` restrito aos comandos do Compose ou operação por um
  administrador fica registrada.
- [ ] Segredos (senhas de PostgreSQL, Redis e Elasticsearch/OpenSearch, credenciais de e-mail, tokens de API) em
  arquivo `.env` com permissão `600`, dono `lri-helpdesk`, fora do repositório, ou em Docker secrets.
- [ ] Segredos exclusivos da central, gerados para ela, sem reaproveitar senhas ou chaves dos outros projetos.
- [ ] Acesso SSH por chave, lista de quem administra o servidor e registro de quem tem acesso aos segredos.

### 6.3 Componentes

- **Zammad**: servidor web (Rails), websocket e processos de background (scheduler/jobs);
- **PostgreSQL**: banco principal (a CI do projeto usa PostgreSQL 18);
- **Redis**: websocket, assinaturas GraphQL e cache;
- **Elasticsearch ou OpenSearch**: busca de texto completo em chamados e anexos — presente desde o início (decidido);
- **Proxy reverso** (Nginx ou Caddy) com HTTPS (Let's Encrypt);
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
| **5. Imagem e implantação** | imagem Docker do fork construída pela CI; slice de zonas interna e pública (seção 2.9) com guarda de zona, configuração do proxy e da VPN; guia de implantação, backup e restauração | homologação validada; produção sob autorização de Leandro |
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
| 2 | Endereços e nome da central | `suporte.lri.com.br` (LRI) e `suporte.ird.net.br` (IRD.Net) na mesma instância; "Central de Atendimento Grupo LRI" (seções 2.5 e 2.6) |
| 3 | Identidade do portal | portal único com a identidade do Grupo LRI e os logos das duas marcas (seção 2.5) |
| 4 | Grupos e filas | estrutura da seção 2.2 |
| 6 | Hospedagem | VPS existente 72.62.108.138, ao lado de Justiano, Plaixec e sferalabs, isolada por projeto Compose próprio (seção 6.2) |
| 8 | Login dos colaboradores | LRI por Google Workspace, IRD.Net por Microsoft 365 (Entra ID), sem criação automática de contas; clientes com e-mail e senha (seção 2.7) |
| — | Cores das marcas | LRI `#74b527`, `#3d7a12`, `#2c5a0d`; IRD.Net `#e46e33` e preto (seção 3) |
| — | Canais de e-mail | LRI pelo canal Google Email; IRD.Net pelo canal Microsoft 365 Graph Email (seção 2.4) |
| 9 | Horário de atendimento | provisório: segunda a sexta, 08:00–18:00, `America/Sao_Paulo` (seção 2.8) |
| 10 | Visibilidade dos clientes | cada cliente vê só os próprios chamados; organizações com `shared = false` (seção 2.3) |
| 13 | Esteira | papéis e regras de PR e revisão da esteira vinculados às seções 3 e 9 |
| — | Zonas | parte interna (equipe, administração) só na intranet; parte do cliente na internet nos dois subdomínios (seção 2.9) |
| — | Arquitetura | instância única para as duas marcas (seção 2.1) |
| — | Opção de implantação | Docker Compose com imagem imutável construída pela CI (seção 6.1) |
| — | Busca | Elasticsearch ou OpenSearch desde o início (seção 6.3) |
| — | Operação | backup diário com retenção de 30 dias e teste trimestral; homologação e produção (seção 6.5) |
| — | Linha base do upstream | série estável do Zammad (seção 5) |
| — | Customização | ordem de preferência e caminhos próprios das seções 4 e 5 |
| — | Roteiro | fases 0 a 6 da seção 8 |

### 10.2 Em aberto

1. **Caixas restantes**: endereços da caixa comercial da IRD.Net, da TI interna e do financeiro da LRI. O canal de
   cada uma já segue do domínio (seção 2.4).
2. **Acesso aos DNS**: quem cria os registros `suporte` nas zonas `lri.com.br` e `ird.net.br` (seção 2.6).
3. **Ativos de marca**: cores e logos recebidos (seção 3, "Ativos de marca"); faltam o SVG da IRD.Net, as versões
   para fundo escuro, o símbolo quadrado e as regras de uso. A cor de preenchimento do SVG da LRI sai da `ux-spec`.
4. **Checklist da VPS**: execução, somente em leitura, do checklist pré-implantação da seção 6.2.1 no servidor
   72.62.108.138.
5. **Versão estável exata (decisão 7)**: a série do Zammad em vigor quando a fase 1 começar.
6. **Horário definitivo e SLAs (decisão 9)**: horário de atendimento definitivo (hoje provisório, seção 2.8), plantão,
   feriados locais e metas de SLA por marca e por tipo de cliente.
7. **ERP Plune (decisão 11)**: documentação da API e escopo da primeira integração.
8. **WhatsApp (decisão 12)**: números e contas Meta Business de cada marca.
9. **Acesso à intranet**: confirmar a alternativa A da seção 2.9.5 (WireGuard próprio) ou escolher B (Tailscale) ou C
   (Cloudflare); como as redes dos escritórios da LRI e da IRD.Net chegam à VPN (túnel a partir do roteador de cada
   escritório ou cliente em cada máquina); quem mantém o DNS interno.
10. **Proposta da guarda de zona ao upstream**: autorização para propor a guarda de zona ao `zammad/zammad` depois de
    validada aqui.
