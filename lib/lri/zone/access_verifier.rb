# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

require 'jwt'
require 'net/http'

# Valida o JWT que o Cloudflare Access envia em Cf-Access-Jwt-Assertion: assinatura RS256 pelas chaves públicas da
# equipe (https://<equipe>.cloudflareaccess.com/cdn-cgi/access/certs), emissor, audience do aplicativo e validade,
# com tolerância de relógio.
#
# Disponibilidade (a falha aqui rebaixa a equipe para a zona pública):
#   - as chaves ficam em cache por uma hora; um `kid` desconhecido força nova busca, no máximo a cada cinco minutos;
#   - se a busca falhar, as chaves anteriores continuam valendo por até 24 horas, e a falha fica em cache por 30
#     segundos, para não repetir a busca a cada requisição;
#   - só uma thread busca por vez (try_lock); as outras usam as chaves que já existem, sem esperar a rede.
# Falha de rede ou de formato devolve um motivo, nunca aceita o token.
class Lri::Zone::AccessVerifier
  CACHE_TTL       = 1.hour
  STALE_TTL       = 24.hours
  REFETCH_MINIMUM = 5.minutes
  FAILURE_BACKOFF = 30.seconds
  CLOCK_LEEWAY    = 30
  HTTP_TIMEOUT    = 5

  @cache       = {}
  @cache_mutex = Mutex.new
  @fetch_mutex = Mutex.new

  class << self
    attr_reader :cache, :cache_mutex, :fetch_mutex

    def for(team_domain:, audiences:)
      new(team_domain:, audiences:)
    end

    def reset_cache!
      cache_mutex.synchronize { cache.clear }
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
      leeway:          CLOCK_LEEWAY,
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

    keys = JSON.parse(response.body)['keys']
    raise "resposta sem 'keys' em #{certs_url}" if !keys.is_a?(Array) || keys.empty?

    { 'keys' => keys }
  end

  private

  def jwks_loader(options)
    entry = cached_entry
    return entry[:keys] if entry && fresh?(entry, kid_not_found: options[:kid_not_found])

    refreshed = refresh(entry)
    return refreshed[:keys] if refreshed&.dig(:keys)

    raise JWT::DecodeError, 'chaves públicas do Access indisponíveis'
  end

  def cached_entry
    self.class.cache_mutex.synchronize { self.class.cache[team_domain] }
  end

  def fresh?(entry, kid_not_found:)
    return false if entry[:keys].nil?
    return entry[:fetched_at] > REFETCH_MINIMUM.ago if kid_not_found

    entry[:fetched_at] > CACHE_TTL.ago
  end

  def usable_stale?(entry)
    entry&.dig(:keys) && entry[:fetched_at] > STALE_TTL.ago
  end

  def refresh(entry)
    stale = usable_stale?(entry) ? entry : nil

    # Falha recente: não tenta a rede de novo. Outra thread já buscando: não espera a rede.
    return stale if entry&.dig(:failed_at) && entry[:failed_at] > FAILURE_BACKOFF.ago
    return stale if !self.class.fetch_mutex.try_lock

    new_entry = begin
      { keys: fetch_jwks, fetched_at: Time.zone.now }
    rescue => e
      log_fetch_failure(e, stale)
      (entry || {}).merge(failed_at: Time.zone.now)
    ensure
      self.class.fetch_mutex.unlock
    end

    self.class.cache_mutex.synchronize { self.class.cache[team_domain] = new_entry }
    new_entry[:failed_at] ? stale : new_entry
  end

  def log_fetch_failure(error, stale)
    Rails.logger.error "Lri::Zone::AccessVerifier: falha ao buscar as chaves do Access em #{certs_url} " \
                       "(#{error.class}: #{error.message}); #{stale ? 'usando as chaves anteriores' : 'sem chaves anteriores válidas'}"
  end
end
