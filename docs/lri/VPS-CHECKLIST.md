# Checklist da VPS — Central de Atendimento Grupo LRI

Servidor de destino da central (decisão 6 do [plano](PLANO.md#62-hospedagem)): **VPS 72.62.108.138**, a mesma que já
atende Justiano, sferalabs, Plaxec e outros projetos do grupo. Este documento é a fonte única do checklist
pré-implantação; a seção 6.2.1 do plano aponta para cá.

## Regras

- Nada aqui altera o servidor. Cada item é verificado **somente em leitura**, com os comandos indicados.
- Entrar na VPS, mesmo só para ler, exige **OK explícito de Leandro na hora**. Ter a chave SSH não é autorização.
- Qualquer mudança (instalar, parar, remover, alterar Nginx, kernel, firewall, Cloudflare) é etapa própria, com
  snapshot prévio e autorização de Leandro. Remoção de qualquer coisa existente, inclusive a instalação do Zammad
  descrita abaixo, também.
- Cada item marcado registra a data, o comando e o resultado resumido.

Legenda de estado: `conhecido` = já levantado antes, com fonte e data; `a verificar` = falta rodar;
`decisão` = depende de Leandro ou do Cogerente.

## 1. O que já se sabe do servidor

Fatos registrados em sessões anteriores. Todos precisam ser **reconferidos** na execução, porque podem ter mudado.
Este repositório é **público**: usuários, privilégios, caminhos internos e qualquer detalhe de credencial ficam fora
dele, no registro privado da operação, e aqui aparecem só como achado a decidir.

| Item | Valor conhecido | Fonte e data |
| ---- | --------------- | ------------ |
| Provedor e sistema | Hostinger, Ubuntu 24.04 | sessões de implantação, 2026-06 a 2026-10 |
| Proxy de entrada | Nginx compartilhado em 80/443, com cerca de 11 sites | idem |
| DNS dos sites | zonas `lri.com.br` e `ird.net.br` na Cloudflare, com proxy | idem; conferido de fora em 2026-10-31 |
| Intranet | `intranet.lri.com.br` já publicada atrás do Cloudflare Access | sessão da intranet |
| Rede privada | Tailscale ativo no servidor | 2026-06 |
| Projetos coexistentes | Justiano, sferalabs, Plaxec, intranet e outros serviços do grupo, cada um com seu próprio isolamento | sessões de 2026-06 a 2026-10 |
| **Zammad já instalado** | stack oficial `zammad-docker-compose` com limites de recursos, Zammad 7.2.0, Elasticsearch 9.5.3, PostgreSQL 17.11, Redis 8.10.2; interface só na interface local do servidor; sem DNS, vhost ou SSO; assistente de configuração **não executado** | sessão do projeto da intranet, 2026-09-28 |
| Impacto medido na instalação | carga com pico de cerca de 4,1 no boot, de volta a cerca de 1,06 em 2 min; swap estável; outros serviços sem degradação; teto de memória do Elasticsearch elevado de 1 GB para 1,5 GB com heap de 512 MB | idem |

### 1.1 Achados que pedem decisão antes da implantação

1. **Instalação existente do Zammad 7.2.0.** O plano usa imagem construída a partir deste fork (seção 6.1). Como o
   assistente nunca rodou, a instalação não guarda dados de atendimento. Proposta: na fase 5, substituir pela stack
   `lri-helpdesk` com a imagem do fork, depois do snapshot. Remover ou reaproveitar os volumes da instalação atual é
   `decisão` de Leandro.
2. **Privilégio de outro usuário de serviço no host.** Há no servidor um usuário de serviço com privilégio
   administrativo amplo (detalhe no registro privado). Qualquer falha em um serviço que rode com ele dá acesso total
   ao host e, portanto, aos dados da central. Isolar a central num usuário próprio não protege contra isso. Opções:
   reduzir esse privilégio ao que o serviço realmente usa, ou aceitar o risco por escrito. `decisão` de Leandro.
3. **Credenciais da instalação existente** não servem para a stack definitiva: a stack `lri-helpdesk` gera segredos
   próprios (seção 7).

## 2. Recursos disponíveis

| Estado | Item | Comando (somente leitura) |
| ------ | ---- | ------------------------- |
| a verificar | vCPU, memória e disco totais | `nproc; free -h; df -h` |
| a verificar | consumo atual por projeto, em horário de pico, inclusive a stack do Zammad existente | `docker stats --no-stream; podman stats --no-stream` (como cada usuário); `ps -eo user,rss,pcpu,cmd --sort=-rss \| head -40` |
| a verificar | sobra de pelo menos 4 vCPU, 8 GB e 100 GB para a central, mais 20% de margem para os outros projetos (seção 6.4 do plano) | conta a partir das linhas acima |
| a verificar | tipo de disco e possibilidade de ampliar disco e memória sem reinstalar | painel da Hostinger; `lsblk -d -o NAME,ROTA,SIZE` |
| a verificar | swap configurado | `swapon --show` |
| a verificar | país e região do datacenter, para a LGPD | painel da Hostinger |

## 3. Convivência com os outros projetos

| Estado | Item | Comando (somente leitura) |
| ------ | ---- | ------------------------- |
| a verificar | inventário de containers, redes e volumes (Docker e Podman) | `docker ps -a; docker network ls; docker volume ls` |
| a verificar | nome `lri-helpdesk` livre para projeto Compose, rede e volumes | `docker compose ls; docker network ls \| grep -i helpdesk` |
| a verificar | PostgreSQL, Redis e Elasticsearch exclusivos da central, sem porta publicada no host | `ss -tlnp` |
| a verificar | limites `mem_limit` e `cpus` em todos os containers da central, somando no máximo a sobra medida | revisão do Compose antes da fase 5 |
| a verificar | versões de Docker e Compose atendem à stack oficial sem atualização que afete os outros projetos | `docker version; docker compose version` |
| a verificar | política de reinício `unless-stopped` e subida independente dos outros projetos | revisão do Compose |

## 4. Rede, portas e Cloudflare (seção 2.9 do plano)

A proposta não abre porta nova nem altera o Nginx compartilhado: o `cloudflared` da central só faz conexões de saída.

| Estado | Item | Comando ou local |
| ------ | ---- | ---------------- |
| a verificar | quem atende 80 e 443 hoje, para registrar que a central **não** entra nele | `ss -tlnp '( sport = :80 or sport = :443 )'`; `ls /etc/nginx/sites-enabled` |
| a verificar | saída liberada para a Cloudflare na porta 7844 (TCP e UDP), usada pelo túnel | `nc -vz -w5 region1.v2.argotunnel.com 7844` |
| a verificar | saída liberada para Gmail (`imap.gmail.com:993`, `smtp.gmail.com:465/587`), APIs OAuth do Google, Microsoft Graph e Entra ID (`graph.microsoft.com`, `login.microsoftonline.com`) em 443 | `nc -vz -w5 <host> <porta>` |
| a verificar | firewall: nenhuma regra nova necessária | `sudo ufw status verbose` ou `sudo nft list ruleset` (leitura) |
| a verificar | registros `suporte` livres nas zonas `lri.com.br` e `ird.net.br`, e nome interno livre | painel da Cloudflare; conferido de fora em 2026-10-31: `suporte.lri.com.br` e `suporte.ird.net.br` não existem |
| decisão | nome interno da equipe (proposta: `atendimento.lri.com.br`) | issue de decisão |
| a verificar | plano do Cloudflare Zero Trust da conta e número de usuários (gratuito até 50) | painel Zero Trust |
| a verificar | provedores de identidade do Access: Google Workspace da LRI já existente? Entra ID da IRD.Net a cadastrar | painel Zero Trust, Settings > Authentication |
| a verificar | regras personalizadas de WAF disponíveis nas duas zonas (o plano gratuito tem 5 por zona) e quantas já estão em uso | painel da Cloudflare, Security > WAF |
| a verificar | limite de upload da borda (100 MB no plano gratuito) frente ao limite de anexo planejado | painel da Cloudflare |

## 5. Zonas interna e pública (seção 2.9 do plano)

Itens verificados em homologação, antes de produção.

| Estado | Item |
| ------ | ---- |
| a verificar | o Nginx da central tem dois blocos: o público, para os dois nomes `suporte`, e o interno, para o nome da equipe, ouvindo só na rede Docker da central |
| a verificar | cada bloco **sobrescreve** `X-LRI-Zone` (`public` ou `internal`); o valor do navegador nunca chega ao Zammad; sem cabeçalho = zona pública |
| a verificar | o `cloudflared` entrega o nome interno com `access.required: true` e cai em `http_status:404` para qualquer nome desconhecido |
| a verificar | nenhuma porta da central publicada no host: `ss -tlnp` e tentativa de acesso direto, que deve falhar |
| a verificar | `RAILS_TRUSTED_PROXIES` e `set_real_ip_from` restritos ao Nginx e ao `cloudflared`; logs do Zammad mostram o IP real (`CF-Connecting-IP`) |
| a verificar | repasse 302 dos três retornos de OAuth (Google, Microsoft, caixas de e-mail) para o nome interno, só nos caminhos exatos; caminho ou host manipulado não redireciona |
| a verificar | troca de `Origin` do WebSocket só para o valor exato do nome interno; origem estranha continua recusada; conexões `/ws` e `/cable` sobrevivem a 5 min ociosas atrás da Cloudflare |
| a verificar | MFA obrigatório no Google Workspace (LRI) e no Entra ID (IRD.Net) |
| a verificar | `api_password_access` desativado e nenhuma aplicação OAuth2 cadastrada no Zammad |
| a verificar | conta de emergência com 2FA do Zammad cadastrado antes de ativada; login aceito no nome interno e recusado no público |
| a verificar | rotas da equipe bloqueadas no listener público e no WAF da Cloudflare, testadas pelos nomes `suporte` |
| a verificar | pelos nomes `suporte`: portal do cliente, base de conhecimento e formulário funcionam; login de agente, SSO da equipe, autorização de caixas e administração são recusados |
| a verificar | pelo nome interno: Access com Google (conta LRI) e Microsoft (conta IRD.Net), login do Zammad, interface de agente, administração e tempo real funcionam; conta de fora das duas empresas é barrada no Access |
| a verificar | cada cliente vê só os próprios chamados (organizações com `shared = false`), testado com dois clientes da mesma organização |
| a verificar | recebimento de e-mail pelos canais Google e Microsoft funciona sem nenhuma rota pública |

## 6. Elasticsearch e memória

| Estado | Item | Comando (somente leitura) |
| ------ | ---- | ------------------------- |
| conhecido | instalação existente usa Elasticsearch 9.5.3, heap 512 MB, teto do container 1,5 GB (2026-09-28) | `docker inspect` do container |
| a verificar | versão dentro da faixa aceita pelo Zammad: 8.15.0 até antes da 10 (`lib/search_index_backend.rb`); OpenSearch não serve | idem |
| a verificar | `vm.max_map_count` do host (o Elasticsearch exige `262144`; o parâmetro vale para o host inteiro) | `sysctl vm.max_map_count` |
| a verificar | nó único, segurança do motor ativa, porta 9200 sem publicação no host | `docker inspect`; `ss -tlnp` |
| a verificar | `shared_buffers` do PostgreSQL e `maxmemory` do Redis coerentes com o `mem_limit` | revisão do Compose |

## 7. Backups, usuário isolado e segredos

| Estado | Item |
| ------ | ---- |
| a verificar | snapshot completo da VPS na Hostinger **antes** de qualquer mudança, com data e responsável |
| a verificar | backups de Justiano, sferalabs, Plaxec e intranet conferidos e recentes, com restauração testada |
| a verificar | procedimento de retorno escrito: voltar ao snapshot ou remover a central sem afetar os outros projetos |
| a verificar | destino externo do backup da central definido e com espaço (NAS do grupo, seção 6.5 do plano) |
| a verificar | usuário de sistema `lri-helpdesk`, sem senha, dono exclusivo de `/srv/lri-helpdesk`, sem acesso aos outros projetos |
| decisão | operação do contêiner pela central: Docker rootless, Podman rootless (como o Justiano) ou `sudo` restrito aos comandos do Compose |
| a verificar | segredos (PostgreSQL, Redis, Elasticsearch, token do túnel, credenciais OAuth e de e-mail) em `.env` `600` do `lri-helpdesk` ou em secrets, fora do repositório, gerados só para a central |
| a verificar | lista de quem administra o servidor e de quem tem acesso aos segredos |

## 8. Registro da execução

| Data | Quem | Seções | Resultado | Autorização |
| ---- | ---- | ------ | --------- | ----------- |
| — | — | — | ainda não executado | aguarda OK de Leandro |
