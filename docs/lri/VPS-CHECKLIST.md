# Checklist da VPS — Central de Atendimento Grupo LRI

Servidor de destino da central (decisão 6 do [plano](PLANO.md#62-hospedagem)): a **VPS compartilhada do grupo**, que
já atende outros projetos. Este documento é a fonte única do checklist pré-implantação; a seção 6.2.1 do plano aponta
para cá.

## Regras

- Nada aqui altera o servidor. Cada item é verificado **somente em leitura**, com os comandos indicados.
- Entrar na VPS, mesmo só para ler, exige **OK explícito de Leandro na hora**. Ter a chave SSH não é autorização.
- Qualquer mudança (instalar, parar, remover, alterar Nginx, kernel, firewall, Cloudflare) é etapa própria, com
  snapshot prévio e autorização de Leandro. Remover ou parar qualquer coisa existente também.
- Este repositório é **público**. Endereço do servidor, projetos vizinhos, usuários, privilégios, versões instaladas,
  caminhos internos e o resultado de cada verificação ficam no **registro privado da operação**; aqui fica só o que
  verificar, como verificar e que decisão está pendente.
- O `contrib/lri/qa/wizard.json` cria usuários de teste com senha conhecida e **nunca** vira `auto_wizard.json` em
  homologação ou produção.

Legenda de estado: `a verificar` = falta rodar; `decisão` = depende de Leandro ou do Cogerente; `registrado` = o
fato já levantado está no registro privado e precisa ser reconferido.

## 1. Situação conhecida e decisões pendentes

| Estado | Item |
| ------ | ---- |
| registrado | levantamento anterior do servidor (sistema, proxy, projetos vizinhos, rede privada) — reconferir na execução |
| decisão | **instalação existente do Zammad no servidor**, sem dados e sem configuração inicial: parar até a fase 5, ou substituir pela stack `lri-helpdesk` com a imagem do fork depois do snapshot. Enquanto existir sem configuração inicial, quem alcançar a interface dela pode criar o primeiro administrador; por isso a recomendação é pará-la logo |
| decisão | **privilégio administrativo amplo de outro usuário de serviço no host** (detalhe no registro privado): reduzir ao que o serviço usa ou aceitar o risco por escrito. Isolar a central num usuário próprio não protege contra root |
| decisão | operação dos containers da central: Docker rootless, Podman rootless ou `sudo` restrito aos comandos do Compose |

## 2. Recursos disponíveis

| Estado | Item | Comando (somente leitura) |
| ------ | ---- | ------------------------- |
| a verificar | vCPU, memória e disco totais | `nproc; free -h; df -h` |
| a verificar | consumo atual por projeto, em horário de pico | `docker stats --no-stream`; `ps -eo user,rss,pcpu,cmd --sort=-rss \| head -40` |
| a verificar | sobra de pelo menos 4 vCPU, 8 GB e 100 GB para a central, mais 20% de margem para os outros projetos (seção 6.4 do plano) | conta a partir das linhas acima |
| a verificar | tipo de disco e possibilidade de ampliar disco e memória sem reinstalar | painel do provedor; `lsblk -d -o NAME,ROTA,SIZE` |
| a verificar | swap configurado | `swapon --show` |
| a verificar | país e região do datacenter, para a LGPD | painel do provedor |

## 3. Convivência com os outros projetos

| Estado | Item | Comando (somente leitura) |
| ------ | ---- | ------------------------- |
| a verificar | inventário de containers, redes e volumes | `docker ps -a; docker network ls; docker volume ls` |
| a verificar | nome `lri-helpdesk` livre para projeto Compose, rede e volumes | `docker compose ls; docker network ls \| grep -i helpdesk` |
| a verificar | PostgreSQL, Redis e Elasticsearch exclusivos da central, sem porta publicada no host | `ss -tlnp` |
| a verificar | limites `mem_limit` e `cpus` em todos os containers da central, somando no máximo a sobra medida | revisão do Compose antes da fase 5 |
| a verificar | versões de Docker e Compose atendem à stack oficial sem atualização que afete os outros projetos | `docker version; docker compose version` |
| a verificar | política de reinício `unless-stopped` e subida independente dos outros projetos | revisão do Compose |

## 4. Rede, portas e Cloudflare (seção 2.9 do plano)

A central não abre porta nova nem altera o Nginx compartilhado: o `cloudflared` dela só faz conexões de saída.

| Estado | Item | Comando ou local |
| ------ | ---- | ---------------- |
| a verificar | quem atende 80 e 443 hoje, para registrar que a central **não** entra nele | `ss -tlnp '( sport = :80 or sport = :443 )'` |
| a verificar | saída liberada para a Cloudflare na porta 7844 (TCP e UDP), usada pelo túnel | `nc -vz -w5 region1.v2.argotunnel.com 7844` |
| a verificar | saída liberada para Gmail (`imap.gmail.com:993`, `smtp.gmail.com:465/587`), APIs OAuth do Google, Microsoft Graph e Entra ID (`graph.microsoft.com`, `login.microsoftonline.com`) em 443 | `nc -vz -w5 <host> <porta>` |
| a verificar | firewall: nenhuma regra nova necessária | `sudo ufw status verbose` (leitura) |
| registrado | registros `suporte` das três zonas criados por Leandro em 31/10 (A com proxy); passam a `CNAME` do túnel quando ele existir | painel da Cloudflare |
| a verificar | registro `atendimento.lri.com.br` (nome interno decidido na issue #2) criado como `CNAME` do túnel | painel da Cloudflare |
| a verificar | túnel **gerenciado localmente** (`config.yml` versionado em `contrib/lri/`), não pelo painel | `cloudflared tunnel info` |
| a verificar | papéis da conta Cloudflare: quem pode editar Tunnel, Access e DNS; logs de auditoria de Tunnel e Access revisados periodicamente | painel da Cloudflare, Manage Account > Members e Audit Log |
| a verificar | plano do Cloudflare Zero Trust da conta e número de usuários (gratuito até 50; acima disso há custo, que exige aprovação de Leandro) | painel Zero Trust |
| a verificar | provedores de identidade do Access: Google Workspace da LRI (já usado pela intranet?) e Entra ID da IRD.Net (a cadastrar) | painel Zero Trust, Settings > Authentication |
| a verificar | `SameSite` do cookie do aplicativo do Access no nome interno não é `Strict` (o retorno de OAuth chega por 302 vindo de outro nome) | painel Zero Trust, aplicativo > Settings |
| a verificar | regras personalizadas de WAF disponíveis nas três zonas (o plano gratuito tem 5 por zona) e quantas já estão em uso | painel da Cloudflare, Security > WAF |
| a verificar | limite de upload da borda (100 MB no plano gratuito) frente ao limite de anexo planejado | painel da Cloudflare |

## 5. Zonas interna e pública (seção 2.9 do plano)

Itens verificados em homologação, antes de produção.

| Estado | Item |
| ------ | ---- |
| a verificar | o Nginx da central tem dois blocos: o público, para os três nomes `suporte`, e o interno, para `atendimento.lri.com.br`, ambos escutando só em `127.0.0.1` no namespace compartilhado com o `cloudflared` |
| a verificar | os cabeçalhos de zona ficam num arquivo incluído em **cada** `location` (`/`, `/api`, `/graphql`, `/ws`, `/cable`); `underscores_in_headers off`; `Remote-User`, `X-Forwarded-User` e `X-Forwarded-Host` do cliente apagados nos dois blocos |
| a verificar | zona interna só com `X-LRI-Zone: internal`, o segredo de zona (`X-LRI-Zone-Key`, só no listener interno) e JWT do Access válido; qualquer outra combinação é zona pública |
| a verificar | `zammad-railsserver` e `zammad-websocket` numa rede Docker `internal: true` só com o `zammad-nginx`; de outro container, `curl` a eles falha |
| a verificar | o `cloudflared` entrega o nome interno com `access.required: true` (equipe `lriauto`, `audTag` do aplicativo) e cai em `http_status:404` para qualquer nome desconhecido |
| a verificar | arquivo de credenciais do túnel legível pelo usuário do container `cloudflared` (uid 65532) e com permissão restrita; ao recriar o `zammad-nginx`, recriar também o `cloudflared` (usa o namespace de rede dele) |
| a verificar | `LRI_ZONE_GUARD=enforce` só depois dos pré-requisitos de go-live do PLANO §2.9.2; log da partida do railsserver mostra "guarda de zona LRI LIGADA" |
| a verificar | `RAILS_TRUSTED_PROXIES` igual à faixa fixa da rede `lri-app` (`LRI_APP_SUBNET`), sem colidir com outra rede Docker do host |
| a verificar | nenhuma porta da central publicada no host: `ss -tlnp` e tentativa de acesso direto, que deve falhar |
| a verificar | `RAILS_TRUSTED_PROXIES` no `zammad-railsserver` e no `zammad-websocket` e `set_real_ip_from` restritos ao Nginx e ao `cloudflared`; logs mostram o IP real (`CF-Connecting-IP`) |
| a verificar | 302 dos três retornos de OAuth (Google, Microsoft, caixas de e-mail) para o nome interno, só nos caminhos exatos (`location =`), destino fixo e query preservada; caminho, host ou maiúsculas manipulados não redirecionam |
| a verificar | todo `/auth/*` (inclusive `/auth/sso`, variantes de maiúsculas e barra final) bloqueado no listener público e no WAF, exceto os retornos exatos |
| a verificar | troca de `Origin` só em `/ws`, só para o valor exato do nome interno (e, se aprovado, de `suporte.meanwellbrasil.com.br` no listener público); continuam recusados em `/ws` e `/cable`: origem irmã (`https://intranet.lri.com.br`), sufixo (`https://atendimento.lri.com.br.evil.com`), `null`, maiúsculas e ausente |
| a verificar | conexões `/ws` e `/cable` sobrevivem a 5 min ociosas atrás da Cloudflare |
| a verificar | MFA obrigatório no Google Workspace (LRI) e no Entra ID (IRD.Net) |
| a verificar | `auth_sso` desligado, `api_password_access` desativado e nenhuma aplicação OAuth2 cadastrada no Zammad |
| a verificar | conta de emergência com 2FA do Zammad por **aplicativo autenticador (TOTP)** cadastrado antes de ativada (chave de segurança não funciona no nome interno); login aceito no nome interno e recusado no público |
| a verificar | sessão criada no nome interno e reapresentada pelo nome público é recusada, em HTTP, `/ws` e `/cable` |
| a verificar | pelos nomes `suporte`: portal do cliente, base de conhecimento e formulário funcionam; login de agente, SSO da equipe, autorização de caixas e administração são recusados |
| a verificar | pelo nome interno: Access com Google (conta LRI) e Microsoft (conta IRD.Net), login do Zammad, interface de agente, administração e tempo real funcionam; conta de fora das empresas é barrada no Access |
| a verificar | cada cliente vê só os próprios chamados (organização nova nasce com `shared = false`), testado com dois clientes da mesma organização |
| a verificar | retorno de autorização de caixa sem `state` é recusado; aplicativos de e-mail registrados como de um só tenant |
| a verificar | recebimento de e-mail pelos canais Google e Microsoft funciona sem nenhuma rota pública |

## 6. Elasticsearch e memória

| Estado | Item | Comando (somente leitura) |
| ------ | ---- | ------------------------- |
| a verificar | versão dentro da faixa aceita pelo Zammad: 8.15.0 até antes da 10 (`lib/search_index_backend.rb`); OpenSearch não serve | `docker inspect` do container |
| a verificar | heap fixado (`ES_JAVA_OPTS`) e teto de memória do container com folga para o consumo nativo da JVM (cerca de 1,5 a 2 vezes o heap) | `docker inspect`; `docker stats` |
| a verificar | `vm.max_map_count` do host (o Elasticsearch exige `262144`; o parâmetro vale para o host inteiro) | `sysctl vm.max_map_count` |
| a verificar | nó único, segurança do motor ativa, porta 9200 sem publicação no host | `docker inspect`; `ss -tlnp` |
| a verificar | `shared_buffers` do PostgreSQL e `maxmemory` do Redis coerentes com o `mem_limit` | revisão do Compose |

## 7. Backups, usuário isolado e segredos

| Estado | Item |
| ------ | ---- |
| a verificar | snapshot completo da VPS no provedor **antes** de qualquer mudança, com data e responsável |
| a verificar | backups dos outros projetos do servidor conferidos e recentes, com restauração testada |
| a verificar | procedimento de retorno escrito: voltar ao snapshot ou remover a central sem afetar os outros projetos |
| a verificar | destino externo do backup da central definido e com espaço (NAS do grupo, seção 6.5 do plano) |
| a verificar | usuário de sistema `lri-helpdesk`, sem senha, dono exclusivo do diretório da central, sem acesso aos outros projetos |
| a verificar | segredos (PostgreSQL, Redis, Elasticsearch, token do túnel, segredo de zona, credenciais OAuth e de e-mail) em `.env` `600` do `lri-helpdesk` ou em secrets, fora do repositório, gerados só para a central |
| a verificar | lista de quem administra o servidor e de quem tem acesso aos segredos |

## 8. Registro da execução

O resultado de cada execução fica no registro privado da operação. Aqui só a data e a autorização.

| Data | Seções | Autorização |
| ---- | ------ | ----------- |
| — | ainda não executado | aguarda OK de Leandro dado diretamente (em 31/10 a leitura na VPS foi barrada pelo controle de permissões da sessão) |
