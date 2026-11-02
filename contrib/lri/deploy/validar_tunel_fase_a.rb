# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Confere o config.yml do cloudflared para a fase A do go-live (guarda de zona desligada, docs/lri/GO-LIVE.md): só o
# nome interno, com Access obrigatório nessa regra, e a regra final exclusivamente http_status:404. Lê o YAML de verdade
# (qualquer sintaxe). Uso: ruby validar_tunel_fase_a.rb <config.yml> <nome interno>. Sai com 0 ou com os motivos.

require 'yaml'

def problemas(config, internal_host)
  return ['config.yml não é um mapa YAML'] if !config.is_a?(Hash)

  rules = config['ingress']
  return ['config.yml sem a lista ingress'] if !rules.is_a?(Array) || rules.empty?
  return ['há regra do ingress que não é um mapa'] if !rules.all?(Hash)

  list   = []
  final  = rules.last
  named  = rules[0..-2]
  others = named.map { |rule| rule['hostname'] }.reject { |host| host == internal_host }

  list << "nomes além do interno: #{others.map(&:inspect).join(' ')}" if others.any?
  list << 'regra antes da final sem hostname (pega qualquer nome)' if named.any? { |rule| !rule.key?('hostname') }
  if final.key?('hostname') || final['service'] != 'http_status:404' || final.key?('path')
    list << "regra final não é exclusivamente http_status:404 (#{final.inspect})"
  end

  internal = named.select { |rule| rule['hostname'] == internal_host }
  list << "nome interno #{internal_host} ausente" if internal.empty?
  internal.each do |rule|
    next if rule.dig('originRequest', 'access', 'required') == true

    list << 'regra do nome interno sem Access obrigatório (originRequest.access.required: true)'
  end
  list
end

if $PROGRAM_NAME == __FILE__
  path, internal_host = ARGV
  abort 'uso: ruby validar_tunel_fase_a.rb <config.yml> <nome interno>' if path.to_s.empty? || internal_host.to_s.empty?

  begin
    config = YAML.safe_load_file(path, aliases: false)
  rescue => e
    abort "config.yml ilegível ou YAML inválido: #{e.class}: #{e.message}"
  end

  list = problemas(config, internal_host)
  abort list.join('; ') if list.any?

  puts "túnel só no nome interno #{internal_host}, com Access obrigatório e 404 para o resto"
end
