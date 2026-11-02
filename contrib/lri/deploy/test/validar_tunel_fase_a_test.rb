# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

# Testes do validar_tunel_fase_a.rb: configurações aceitas e recusadas, em sintaxes YAML diferentes.
# Uso: ruby contrib/lri/deploy/test/validar_tunel_fase_a_test.rb

require 'open3'
require 'tmpdir'

SCRIPT = File.expand_path('../validar_tunel_fase_a.rb', __dir__)
ARGS   = %w[atendimento.example.com lriteste aud-um,aud-dois].freeze

# A regra interna correta, em bloco; os casos negativos mudam um pedaço dela.
INTERNAL = <<~YAML.freeze
  - hostname: atendimento.example.com
    service: http://127.0.0.1:8082
    originRequest:
      access:
        required: true
        teamName: lriteste
        audTag: [aud-um]
YAML

def ingress(*rules)
  "ingress:\n#{rules.join.gsub(%r{^}, '  ')}"
end

FINAL = "- service: http_status:404\n".freeze

# [nome, aceito?, YAML, trecho esperado no motivo da recusa]
CASES = [
  ['bloco, só o interno com o Access da central e 404 final', true, ingress(INTERNAL, FINAL), nil],
  ['fluxo (sintaxe JSON), mesma configuração', true, <<~YAML, nil],
    {"ingress": [{"hostname": "atendimento.example.com", "service": "http://127.0.0.1:8082",
      "originRequest": {"access": {"required": true, "teamName": "lriteste", "audTag": ["aud-dois"]}}},
     {"service": "http_status:404"}]}
  YAML
  ['portal público junto', false,
   ingress(INTERNAL, "- hostname: suporte.example.com\n  service: http://127.0.0.1:8081\n", FINAL), 'além da do nome interno'],
  ['regra com hostname nulo e path antes da interna', false,
   ingress("- hostname: null\n  path: ^/\n  service: http://127.0.0.1:8081\n", INTERNAL, FINAL), 'além da do nome interno'],
  ['regra só com path antes da final', false,
   ingress(INTERNAL, "- path: ^/api\n  service: http://127.0.0.1:8081\n", FINAL), 'além da do nome interno'],
  ['hostname como número', false, ingress("- hostname: 8082\n  service: http://127.0.0.1:8082\n", INTERNAL, FINAL),
   'além da do nome interno'],
  ['regra final encaminhando para a aplicação', false, ingress(INTERNAL, "- service: http://127.0.0.1:8081\n"),
   'exclusivamente http_status:404'],
  ['regra sem hostname antes da final', false, ingress("- service: http://127.0.0.1:8081\n", INTERNAL, FINAL),
   'além da do nome interno'],
  ['nome interno para a porta errada', false, ingress(INTERNAL.sub('8082', '8081'), FINAL), 'esperado http://127.0.0.1:8082'],
  ['nome interno para 404', false, ingress(INTERNAL.sub('http://127.0.0.1:8082', 'http_status:404'), FINAL),
   'esperado http://127.0.0.1:8082'],
  ['Access sem required', false, ingress(INTERNAL.sub("required: true\n", ''), FINAL), 'sem Access obrigatório'],
  ['Access com required em texto', false, ingress(INTERNAL.sub('required: true', 'required: "true"'), FINAL),
   'sem Access obrigatório'],
  ['equipe do Access ausente', false, ingress(INTERNAL.sub("teamName: lriteste\n", ''), FINAL), 'equipe do Access'],
  ['equipe do Access de outra conta', false, ingress(INTERNAL.sub('lriteste', 'outra'), FINAL), 'equipe do Access'],
  ['audTag de outro aplicativo', false, ingress(INTERNAL.sub('aud-um', 'aud-estranho'), FINAL), 'fora das audiences'],
  ['audTag ausente', false, ingress(INTERNAL.sub("audTag: [aud-um]\n", ''), FINAL), 'fora das audiences'],
  ['Access na regra errada', false,
   ingress(INTERNAL.sub(%r{    originRequest:.*}m, ''), "- service: http_status:404\n  originRequest: {access: {required: true}}\n"),
   'sem Access obrigatório'],
  ['YAML inválido', false, "ingress: [\n", 'YAML inválido'],
].freeze

failures = 0
Dir.mktmpdir do |dir|
  CASES.each do |name, accepted, yaml, reason|
    path = File.join(dir, 'config.yml')
    File.write(path, yaml)
    _out, err, status = Open3.capture3('ruby', SCRIPT, path, *ARGS)
    ok = status.success? == accepted && (accepted || err.include?(reason))
    puts "#{ok ? 'ok   ' : 'ERRO '} #{name}#{" (#{err.strip})" if !ok}"
    failures += 1 if !ok
  end
end
exit(failures.zero? ? 0 : 1)
