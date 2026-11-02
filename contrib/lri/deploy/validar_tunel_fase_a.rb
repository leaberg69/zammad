# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Confere o config.yml do cloudflared para a fase A do go-live (guarda de zona desligada, docs/lri/GO-LIVE.md): só o
# nome interno, entregue ao listener interno do Nginx, com o Access da equipe e do aplicativo da central obrigatório, e
# a regra final exclusivamente http_status:404. Lê o YAML de verdade (qualquer sintaxe).
# Uso: ruby validar_tunel_fase_a.rb <config.yml> <nome interno> <equipe do Access> <AUD[,AUD...]>

require 'yaml'

class ValidarTunelFaseA
  INTERNAL_SERVICE = 'http://127.0.0.1:8082'.freeze

  def initialize(config, internal_host:, team:, audiences:)
    @config        = config
    @internal_host = internal_host
    @team          = team
    @audiences     = audiences
  end

  def problemas
    return ['config.yml não é um mapa YAML'] if !@config.is_a?(Hash)

    rules = @config['ingress']
    return ['config.yml sem a lista ingress'] if !rules.is_a?(Array) || rules.empty?
    return ['há regra do ingress que não é um mapa'] if !rules.all?(Hash)

    problemas_dos_nomes(rules[0..-2]) + problemas_da_final(rules.last) + problemas_do_interno(rules[0..-2])
  end

  private

  # Toda regra antes da final tem de ser do nome interno, com hostname em texto e igual a ele: nada é descartado antes
  #   de comparar (hostname nulo, vazio ou com path pegaria outros nomes, e o cloudflared avalia as regras em ordem).
  def problemas_dos_nomes(named)
    others = named.reject { |rule| rule['hostname'].is_a?(String) && rule['hostname'] == @internal_host }
    return [] if others.empty?

    ["regras além da do nome interno: #{others.map { |rule| rule['hostname'].inspect }.join(' ')}"]
  end

  def problemas_da_final(final)
    return [] if final.keys == ['service'] && final['service'] == 'http_status:404'

    ["regra final não é exclusivamente http_status:404 (#{final.inspect})"]
  end

  def problemas_do_interno(named)
    internal = named.select { |rule| rule['hostname'] == @internal_host }
    return ["nome interno #{@internal_host} ausente"] if internal.empty?

    internal.flat_map { |rule| problemas_da_regra_interna(rule) }
  end

  def problemas_da_regra_interna(rule)
    list   = []
    origin = rule['originRequest']
    access = origin.is_a?(Hash) ? origin['access'] : nil
    access = {} if !access.is_a?(Hash)
    list << "nome interno entregue a #{rule['service'].inspect}, esperado #{INTERNAL_SERVICE}" if rule['service'] != INTERNAL_SERVICE
    list << 'regra do nome interno sem Access obrigatório (originRequest.access.required: true)' if access['required'] != true
    list << "equipe do Access #{access['teamName'].inspect}, esperada #{@team.inspect}" if access['teamName'] != @team
    list << audience_problem(access['audTag'])
    list.compact
  end

  def audience_problem(tags)
    tags = Array(tags)
    return if tags.any? && (tags - @audiences).empty?

    "audTag do Access #{tags.inspect} fora das audiences da central (#{@audiences.join(', ')})"
  end
end

if $PROGRAM_NAME == __FILE__
  path, internal_host, team, audiences = ARGV
  if [path, internal_host, team, audiences].any? { |value| value.to_s.empty? }
    abort 'uso: ruby validar_tunel_fase_a.rb <config.yml> <nome interno> <equipe do Access> <AUD[,AUD...]>'
  end

  begin
    config = YAML.safe_load_file(path, aliases: false)
  rescue => e
    abort "config.yml ilegível ou YAML inválido: #{e.class}: #{e.message}"
  end

  list = ValidarTunelFaseA.new(config, internal_host:, team:, audiences: audiences.split(',').map(&:strip)).problemas
  abort list.join('; ') if list.any?

  puts "túnel só no nome interno #{internal_host}, para #{ValidarTunelFaseA::INTERNAL_SERVICE}, com o Access da central"
end
