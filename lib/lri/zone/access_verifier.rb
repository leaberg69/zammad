# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'jwt'
require 'net/http'

# Valida o JWT que o Cloudflare Access envia em Cf-Access-Jwt-Assertion: assinatura RS256 pelas chaves públicas da
# equipe (https://<equipe>.cloudflareaccess.com/cdn-cgi/access/certs), emissor, audience do aplicativo e validade.
#
# As chaves ficam em cache por uma hora e são buscadas de novo quando chega um `kid` desconhecido (rotação), no
# máximo uma vez a cada cinco minutos. Falha de rede ou de formato devolve um motivo, nunca aceita o token.
class Lri::Zone::AccessVerifier
  CACHE_TTL       = 1.hour
  REFETCH_MINIMUM = 5.minutes
  HTTP_TIMEOUT    = 5

  @cache = {}
  @mutex = Mutex.new

  class << self
    attr_reader :cache, :mutex

    def for(team_domain:, audiences:)
      new(team_domain:, audiences:)
    end

    def reset_cache!
      mutex.synchronize { cache.clear }
    end

    # Fonte alternativa das chaves (lambda que recebe a URL e devolve { 'keys' => [...] }); nil = HTTPS real.
    #   Existe para os testes; em produção fica nil.
    def jwks_fetcher
      nil
    end
  end

  attr_reader :team_domain, :audiences

  def initialize(team_domain:, audiences:)
    @team_domain = team_domain
    @audiences   = audiences
  end

  def issuer
    "https://#{team_domain}"
  end

  def certs_url
    "#{issuer}/cdn-cgi/access/certs"
  end

  # nil quando o token é válido; senão, o motivo (sem o conteúdo do token).
  def failure_reason(token)
    return 'cabeçalho ausente' if token.blank?
    return 'equipe ou audience do Access não configuradas' if team_domain.blank? || audiences.empty?

    JWT.decode(
      token, nil, true,
      algorithms:      ['RS256'],
      jwks:            method(:jwks_loader),
      iss:             issuer,
      verify_iss:      true,
      aud:             audiences,
      verify_aud:      true,
      required_claims: %w[exp iat],
    )
    nil
  rescue JWT::DecodeError => e
    "#{e.class.name.demodulize}: #{e.message}"
  rescue => e
    Rails.logger.error "Lri::Zone::AccessVerifier: erro ao validar o JWT do Access (#{e.class}: #{e.message})"
    "erro na validação (#{e.class.name})"
  end

  # Busca as chaves públicas da equipe.
  def fetch_jwks
    return self.class.jwks_fetcher.call(certs_url) if self.class.jwks_fetcher

    uri      = URI(certs_url)
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: HTTP_TIMEOUT, read_timeout: HTTP_TIMEOUT) do |http|
      http.get(uri.request_uri)
    end
    raise "HTTP #{response.code} em #{certs_url}" if !response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body).slice('keys')
  end

  private

  def jwks_loader(options)
    self.class.mutex.synchronize do
      entry = self.class.cache[team_domain]
      if entry.nil? || entry[:fetched_at] < CACHE_TTL.ago || (options[:kid_not_found] && entry[:fetched_at] < REFETCH_MINIMUM.ago)
        entry = { keys: fetch_jwks, fetched_at: Time.zone.now }
        self.class.cache[team_domain] = entry
      end
      entry[:keys]
    end
  end
end
