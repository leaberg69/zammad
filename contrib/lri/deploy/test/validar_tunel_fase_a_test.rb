# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Testes do validar_tunel_fase_a.rb: configurações aceitas e recusadas, em sintaxes YAML diferentes.
# Uso: ruby contrib/lri/deploy/test/validar_tunel_fase_a_test.rb

require 'open3'
require 'tmpdir'

SCRIPT = File.expand_path('../validar_tunel_fase_a.rb', __dir__)
HOST   = 'atendimento.example.com'.freeze

# [nome, aceito?, YAML, trecho esperado no motivo da recusa]
CASES = [
  ['bloco, só o interno com Access e 404 final', true, <<~YAML, nil],
    ingress:
      - hostname: atendimento.example.com
        service: http://127.0.0.1:8082
        originRequest:
          access:
            required: true
      - service: http_status:404
  YAML
  ['fluxo (sintaxe JSON), só o interno com Access e 404 final', true, <<~YAML, nil],
    {"ingress": [{"hostname": "atendimento.example.com", "service": "http://127.0.0.1:8082",
      "originRequest": {"access": {"required": true}}}, {"service": "http_status:404"}]}
  YAML
  ['portal público junto', false, <<~YAML, 'nomes além do interno'],
    ingress:
      - hostname: atendimento.example.com
        originRequest: {access: {required: true}}
      - hostname: suporte.example.com
        service: http://127.0.0.1:8081
      - service: http_status:404
  YAML
  ['regra final encaminhando para a aplicação', false, <<~YAML, 'exclusivamente http_status:404'],
    ingress:
      - hostname: atendimento.example.com
        originRequest: {access: {required: true}}
      - service: http://127.0.0.1:8081
  YAML
  ['Access na regra errada', false, <<~YAML, 'sem Access obrigatório'],
    ingress:
      - hostname: atendimento.example.com
        service: http://127.0.0.1:8082
      - service: http_status:404
        originRequest: {access: {required: true}}
  YAML
  ['Access como texto, não booleano', false, <<~YAML, 'sem Access obrigatório'],
    ingress:
      - hostname: atendimento.example.com
        originRequest: {access: {required: "true"}}
      - service: http_status:404
  YAML
  ['regra sem hostname antes da final', false, <<~YAML, 'sem hostname'],
    ingress:
      - service: http://127.0.0.1:8081
      - hostname: atendimento.example.com
        originRequest: {access: {required: true}}
      - service: http_status:404
  YAML
  ['nome entre aspas simples, sem Access', false, <<~YAML, 'sem Access obrigatório'],
    ingress:
      - hostname: 'atendimento.example.com'
      - service: http_status:404
  YAML
  ['YAML inválido', false, "ingress: [\n", 'YAML inválido'],
].freeze

failures = 0
Dir.mktmpdir do |dir|
  CASES.each do |name, accepted, yaml, reason|
    path = File.join(dir, 'config.yml')
    File.write(path, yaml)
    _out, err, status = Open3.capture3('ruby', SCRIPT, path, HOST)
    ok = status.success? == accepted && (accepted || err.include?(reason))
    puts "#{ok ? 'ok   ' : 'ERRO '} #{name}#{" (#{err.strip})" if !ok}"
    failures += 1 if !ok
  end
end
exit(failures.zero? ? 0 : 1)
