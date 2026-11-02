#!/usr/bin/env bash
# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Itens do docs/lri/VPS-CHECKLIST.md que falharam na leitura de 01/11 (script com CRLF) ou ficaram de fora.
# Só leitura. A saída tem dados do servidor: vai para o registro privado da operação, nunca para o repositório.
# Uso, na VPS: bash checklist-leitura.sh > saida.txt 2>&1

set -u

secao() { printf '\n== %s ==\n' "$1"; }

# Sem set -e: um item que falha não interrompe os outros, e a falha fica registrada na saída com o código.
rodar() {
  printf '$ %s\n' "$*"
  local codigo=0
  "$@" || codigo=$?
  if [ "$codigo" -ne 0 ]; then
    printf '(falhou com código %s: %s)\n' "$codigo" "$*"
  fi
  return 0
}

# Conexão TCP de saída; na falha, registra o código (124 = tempo esgotado) e a mensagem do sistema.
saida_tcp() {
  local host=$1 porta=$2 erro codigo=0
  # shellcheck disable=SC2016 # $1 e $2 são expandidos pelo bash -c, não aqui
  erro=$(timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$porta" 2>&1) || codigo=$?
  if [ "$codigo" -eq 0 ]; then
    printf 'OK    %s:%s\n' "$host" "$porta"
  elif [ "$codigo" -eq 124 ]; then
    printf 'FALHA %s:%s (código 124: sem resposta em 5 s)\n' "$host" "$porta"
  else
    printf 'FALHA %s:%s (código %s: %s)\n' "$host" "$porta" "$codigo" "${erro:-sem mensagem}"
  fi
  return 0
}

main() {
  secao '2. recursos'
  rodar nproc
  rodar free -h
  rodar df -h /
  rodar swapon --show
  rodar lsblk -d -o NAME,ROTA,SIZE

  secao '3. convivência'
  rodar docker compose ls
  rodar docker volume ls --filter name=helpdesk
  rodar docker network ls --filter name=helpdesk

  secao '4. saída de rede (TCP; UDP 7844 não se confere daqui, ver o checklist)'
  saida_tcp region1.v2.argotunnel.com 7844
  saida_tcp imap.gmail.com 993
  saida_tcp smtp.gmail.com 465
  saida_tcp smtp.gmail.com 587
  saida_tcp oauth2.googleapis.com 443
  saida_tcp gmail.googleapis.com 443
  saida_tcp graph.microsoft.com 443
  saida_tcp login.microsoftonline.com 443

  secao '4. firewall do host (o host não usa ufw)'
  rodar sudo -n iptables -S INPUT
  rodar sudo -n ip6tables -S INPUT
  rodar sudo -n nft list ruleset

  secao '6. limites do host para o Elasticsearch'
  rodar sysctl vm.max_map_count

  secao '7. backups e tarefas agendadas existentes'
  rodar systemctl list-timers --all --no-pager
  rodar ls -la /etc/cron.d
}

# Carregado pelo teste (source), só define as funções.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main
fi
