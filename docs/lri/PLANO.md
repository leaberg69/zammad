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

- **Protocolo**: Microsoft Graph quando as caixas estão no Microsoft 365; IMAP/SMTP nos demais casos. Ambos são
  nativos do Zammad.
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

- Um bloco de servidor por subdomínio (ou um bloco com os dois nomes), ambos encaminhando para o mesmo Zammad.
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

- **Colaboradores (decidido)**: login com **Google** (Google OAuth), recurso nativo do Zammad.
  - Cliente OAuth criado no Google Cloud da empresa, com URI de retorno
    `https://suporte.lri.com.br/auth/google_oauth2/callback` (endereço principal, seção 2.6).
  - `auth_google_oauth2` ativado, com `client_id` e `client_secret` guardados como segredos (seção 6.2.1).
  - `auth_third_party_auto_link_at_inital_login` ativado: no primeiro login com Google, a conta do colaborador já
    cadastrada é vinculada pelo e-mail.
  - `auth_third_party_no_create_user` ativado: o botão do Google não cria contas novas. Só entra quem já foi cadastrado
    pelo administrador com o perfil certo, o que impede que uma conta Google qualquer ganhe acesso.
  - Se as duas empresas estiverem no mesmo Google Workspace, a tela de consentimento fica como "Interna", o que limita
    o login às contas da organização.
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

## 3. Princípios de UI e UX

### UI-LRI-1 — Decisões de UI pelo engenheiro de UI/UX da esteira

Toda decisão de interface — cores, logos, textos, disposição, fluxos — é tomada pelo papel de **engenheiro de UI/UX**
definido na esteira `leaberg69/esteira-softwarehouse-LR`. PRs que tocam a interface têm a revisão desse papel antes do
merge. _Violação: uma mudança visual mesclada sem passar pelo engenheiro de UI/UX._

### UI-LRI-2 — A interface do Zammad é mantida; sem redesign

A interface atual do Zammad é a base do produto e permanece como está: layout, navegação, componentes, fluxos de
atendimento e portal. O trabalho de UI se limita a três frentes:

- **Branding**: logos da LRI e da IRD.Net, cores das marcas, favicon, assinaturas e templates de e-mail;
- **Polimento pt-BR**: termos consistentes, tom adequado e textos completos em todo o produto;
- **Consistência**: mesmos nomes, termos e padrões em grupos, macros, módulos de texto, gatilhos e base de
  conhecimento.

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
revisados pelo engenheiro de UI/UX. _Violação: editar `i18n/*.po` diretamente._

### UI-LRI-5 — Acessibilidade e contraste preservados

As cores das marcas são aplicadas respeitando contraste WCAG AA nos dois temas (claro e escuro) da interface.
_Violação: cor de marca aplicada a texto ou botão sem atingir o contraste mínimo._

### Ativos de marca

Logos e cores vêm dos ativos de marca já existentes nos repositórios do Leandro (por exemplo `minissites`), para que a
central tenha exatamente a mesma identidade dos sites. Os arquivos aprovados ficam em `public/assets/lri/`, com a
origem de cada um registrada no PR que os adiciona.

Situação do levantamento: o repositório `minissites` não está visível para o agente do projeto, e os repositórios
públicos do Leandro (`leaberg69/*`) não contêm logos nem paletas da LRI ou da IRD.Net. O levantamento é concluído
assim que `minissites` for compartilhado com o agente, ou os arquivos forem enviados diretamente.

Itens necessários, ainda pendentes:

| Item | LRI | IRD.Net | Grupo LRI |
| ---- | --- | ------- | --------- |
| Logo horizontal em SVG (fundo claro) | pendente | pendente | pendente |
| Logo em versão negativa SVG (tema escuro) | pendente | pendente | pendente |
| Símbolo quadrado SVG/PNG 512 px (favicon, avatar do sistema) | pendente | pendente | pendente |
| Logo PNG para assinatura de e-mail (até 300 px de largura) | pendente | pendente | — |
| Paleta oficial em hexadecimal (primária, secundária, apoio) | pendente | pendente | — |
| Regras de uso do logo (área de proteção, tamanho mínimo) | pendente | pendente | — |

A tipografia continua a do Zammad (UI-LRI-2). O logo do **Grupo LRI**, usado no portal, pode ser uma composição dos
dois logos, desenhada sob responsabilidade do engenheiro de UI/UX se ainda não existir.

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
| `public/assets/lri/` | logos e imagens das marcas |

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
- [ ] Firewall: nenhuma porta nova aberta para a internet além de 80 e 443, que já estão em uso.
- [ ] Saída de rede para e-mail (IMAP 993, SMTP 587/465 ou Microsoft Graph) liberada no provedor.

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
| Rede | domínio próprio, HTTPS, saída SMTP/IMAP ou acesso ao Microsoft Graph |

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
| **3. Portal e branding** | logos e cores LRI/IRD.Net nas pastas `custom`; portal do cliente; base de conhecimento com categorias por marca; revisão pt-BR | engenheiro de UI/UX aprova a identidade e os textos |
| **4. Operação de atendimento** | SLAs e calendários (feriados nacionais e locais de RS e SC); macros e módulos de texto; Core Workflow; relatórios por marca | piloto interno com a equipe de TI usando a central |
| **5. Imagem e implantação** | imagem Docker do fork construída pela CI; guia de implantação, backup e restauração | homologação validada; produção sob autorização de Leandro |
| **6. Integrações** | site e formulário; WhatsApp; ERP Plune | cada integração em PR próprio, com testes e documentação |

## 9. Governança e esteira

O projeto segue a esteira `leaberg69/esteira-softwarehouse-LR`:

- **toda mudança entra por PR**, inclusive configuração como código e sincronização com o upstream;
- **CI verde** é condição para merge;
- **revisão independente** antes do merge; PRs de interface têm também a revisão do engenheiro de UI/UX;
- **nada é implantado** por este fluxo; implantação é etapa separada e autorizada;
- documentação do projeto em pt-BR, em `docs/lri/`; mensagens de commit e código seguem as convenções do Zammad
  (`AGENTS.md`), o que facilita propor melhorias ao upstream.

O vínculo com a definição do papel de engenheiro de UI/UX na esteira será adicionado a este documento assim que o
repositório da esteira for compartilhado com o agente do projeto.

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
| 8 | Login dos colaboradores | Google OAuth, sem criação automática de contas; clientes com e-mail e senha (seção 2.7) |
| 9 | Horário de atendimento | provisório: segunda a sexta, 08:00–18:00, `America/Sao_Paulo` (seção 2.8) |
| 10 | Visibilidade dos clientes | cada cliente vê só os próprios chamados; organizações com `shared = false` (seção 2.3) |
| — | Arquitetura | instância única para as duas marcas (seção 2.1) |
| — | Opção de implantação | Docker Compose com imagem imutável construída pela CI (seção 6.1) |
| — | Busca | Elasticsearch ou OpenSearch desde o início (seção 6.3) |
| — | Operação | backup diário com retenção de 30 dias e teste trimestral; homologação e produção (seção 6.5) |
| — | Linha base do upstream | série estável do Zammad (seção 5) |
| — | Customização | ordem de preferência e caminhos próprios das seções 4 e 5 |
| — | Roteiro | fases 0 a 6 da seção 8 |

### 10.2 Em aberto

1. **Caixas restantes e provedor de e-mail**: endereços da caixa comercial da IRD.Net, da TI interna e do financeiro da
   LRI; se as caixas estão no Microsoft 365 (define Microsoft Graph ou IMAP/SMTP).
2. **Acesso aos DNS**: quem cria os registros `suporte` nas zonas `lri.com.br` e `ird.net.br` (seção 2.6).
3. **Ativos de marca**: compartilhar `minissites` com o agente ou enviar os arquivos da tabela "Ativos de marca"
   (seção 3).
4. **Checklist da VPS**: execução, somente em leitura, do checklist pré-implantação da seção 6.2.1 no servidor
   72.62.108.138.
5. **Versão estável exata (decisão 7)**: a série do Zammad em vigor quando a fase 1 começar.
6. **Horário definitivo e SLAs (decisão 9)**: horário de atendimento definitivo (hoje provisório, seção 2.8), plantão,
   feriados locais e metas de SLA por marca e por tipo de cliente.
7. **Google Workspace**: se LRI e IRD.Net estão no mesmo Workspace (define o consentimento "Interno", seção 2.7) e quem
   cria o cliente OAuth no Google Cloud.
8. **ERP Plune (decisão 11)**: documentação da API e escopo da primeira integração.
9. **WhatsApp (decisão 12)**: números e contas Meta Business de cada marca.
10. **Esteira (decisão 13)**: o repositório `leaberg69/esteira-softwarehouse-LR` ainda não está visível para o agente
    do projeto; com o acesso efetivo, a definição do papel de engenheiro de UI/UX e as regras de PR e revisão são
    vinculadas às seções 3 e 9.
