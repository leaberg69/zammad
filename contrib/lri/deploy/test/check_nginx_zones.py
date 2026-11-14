# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

"""Confere o Nginx das zonas (contrib/lri/deploy/nginx) contra o upstream de eco. Roda no namespace de rede do Nginx.

Cada verificação imprime OK ou FALHA com o motivo; o código de saída é o número de falhas.
"""

import http.client
import json
import sys

KEY = sys.argv[1]
PUBLIC = 8081
INTERNAL = 8082
FQDN = 'suporte.lri.com.br'
MW = 'suporte.meanwellbrasil.com.br'
IRD = 'suporte.ird.net.br'
STAFF = 'atendimento.lri.com.br'

FORGED = {
    'X-LRI-Zone': 'internal',
    'X-LRI-Zone-Key': KEY,
    'Cf-Access-Jwt-Assertion': 'forjado',
    'Remote-User': 'admin@lri.com.br',
    'X-Forwarded-User': 'admin@lri.com.br',
    'X-Forwarded-Host': 'evil.example',
    'X-Forwarded-For': '6.6.6.6',
    'CF-Connecting-IP': '203.0.113.7',
    'From': 'admin@lri.com.br',
    'X-On-Behalf-Of': 'admin@lri.com.br',
}

failures = 0


def req(port, host, path, headers=None):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
    conn.request('GET', path, headers={'Host': host, **(headers or {})})
    resp = conn.getresponse()
    body = resp.read().decode('utf-8', 'replace')
    conn.close()
    return resp.status, dict(resp.getheaders()), body


def check(name, cond, detail=''):
    global failures
    if cond:
        print(f'OK     {name}')
    else:
        failures += 1
        print(f'FALHA  {name} {detail}')


def upstream(port, host, path, headers=None):
    status, _, body = req(port, host, path, headers)
    if status != 200:
        return status, {}
    return status, json.loads(body)


# Zona pública: cabeçalhos forjados nunca chegam ao Zammad, em todas as locations.
for host in (FQDN, MW, IRD):
    for path in ('/', '/api/v1/users/me', '/graphql', '/ws', '/cable'):
        status, data = upstream(PUBLIC, host, path, FORGED)
        h = data.get('headers', {})
        check(f'público {host}{path}: zona public', status == 200 and h.get('x-lri-zone') == 'public', f'status={status} {h.get("x-lri-zone")}')
        stripped = ('x-lri-zone-key', 'cf-access-jwt-assertion', 'remote-user', 'x-forwarded-user', 'x-forwarded-host', 'from', 'x-on-behalf-of')
        check(f'público {host}{path}: sem segredo, JWT, SSO por cabeçalho, X-Forwarded-Host nem personificação',
              not any(h.get(k) for k in stripped), str({k: h.get(k) for k in stripped}))
        check(f'público {host}{path}: IP real da Cloudflare, não o X-Forwarded-For do cliente',
              h.get('x-forwarded-for') == '203.0.113.7', f'xff={h.get("x-forwarded-for")}')

# Zona interna: valor fixo, segredo de zona e JWT repassado.
for path in ('/', '/api/v1/users/me', '/graphql', '/ws', '/cable'):
    status, data = upstream(INTERNAL, STAFF, path, {'X-LRI-Zone': 'public', 'X-LRI-Zone-Key': 'errado', 'Cf-Access-Jwt-Assertion': 'jwt-do-access', 'Remote-User': 'x'})
    h = data.get('headers', {})
    check(f'interno {path}: zona internal com o segredo', h.get('x-lri-zone') == 'internal' and h.get('x-lri-zone-key') == KEY, str(h.get('x-lri-zone')))
    check(f'interno {path}: JWT do Access repassado', h.get('cf-access-jwt-assertion') == 'jwt-do-access')
    check(f'interno {path}: sem Remote-User', not h.get('remote-user'))

# Rota do monitor externo, só no listener interno: vai ao health check do Zammad com o token do cabeçalho e os
# cabeçalhos da zona. MONITOR_TOKEN também é procurado no log do Nginx pelo nginx_zones_test.sh (não pode aparecer).
MONITOR_TOKEN = 'tokdomonitor_0123456789-abcdef'
status, data = upstream(INTERNAL, STAFF, '/lri-monitor/health_check',
                        {'Cf-Access-Jwt-Assertion': 'jwt-do-monitor', 'X-LRI-Monitor-Token': MONITOR_TOKEN})
h = data.get('headers', {})
check('interno /lri-monitor/health_check: vai ao health check do railsserver, token no cabeçalho e nunca na URL',
      status == 200 and data.get('port') == 3000 and data.get('path') == '/api/v1/monitoring/health_check'
      and h.get('x-lri-monitor-token') == MONITOR_TOKEN and data.get('body') == '',
      f'status={status} {data.get("port")} {data.get("path")} {h.get("x-lri-monitor-token")!r} {data.get("body")!r}')
check('interno /lri-monitor/health_check: zona internal, segredo e JWT do Access repassados',
      h.get('x-lri-zone') == 'internal' and h.get('x-lri-zone-key') == KEY and h.get('cf-access-jwt-assertion') == 'jwt-do-monitor')
for path in ('/lri-monitor/health_check?token=pela-url-0123456789abc', '/lri-monitor/health_check?x=1'):
    status, _, _ = req(INTERNAL, STAFF, path, {'X-LRI-Monitor-Token': MONITOR_TOKEN})
    check(f'interno {path}: query recusada (400) sem ir ao upstream', status == 400, f'status={status}')
for nome, path, headers in (
        ('token com & não injeta parâmetros', '/lri-monitor/health_check',
         {'X-LRI-Monitor-Token': 'abcdefghij0123456789&format=x'}),
        ('token curto demais vira vazio', '/lri-monitor/health_check', {'X-LRI-Monitor-Token': 'curto'})):
    status, data = upstream(INTERNAL, STAFF, path, headers)
    check(f'interno /lri-monitor/health_check: {nome}',
          data.get('path') == '/api/v1/monitoring/health_check' and not data.get('headers', {}).get('x-lri-monitor-token'),
          f'status={status} {data.get("path")} {data.get("headers", {}).get("x-lri-monitor-token")!r}')
conn = http.client.HTTPConnection('127.0.0.1', INTERNAL, timeout=5)
conn.request('POST', '/lri-monitor/health_check', body='token=x', headers={'Host': STAFF, 'X-LRI-Monitor-Token': MONITOR_TOKEN})
post_status = conn.getresponse().status
conn.close()
check('interno /lri-monitor/health_check: só GET', post_status == 403, f'status={post_status}')
status, data = upstream(INTERNAL, STAFF, '/lri-monitor/health_check/../status?token=tok123')
check('interno: só o caminho exato vira o health check', not str(data.get('path', '')).startswith('/api/v1/monitoring/'),
      f'status={status} {data.get("path")}')
# O Access casa o caminho do monitor por prefixo: o resto do prefixo para no Nginx, sem ir ao upstream.
for path in ('/lri-monitor/health_check/', '/lri-monitor/health_check/x', '/lri-monitor/outro', '/lri-monitor',
             '/LRI-Monitor/health_check', '/%6cri-monitor/health_check/x', '/lri-monitor/health_check;x'):
    status, _, body = req(INTERNAL, STAFF, path, {'X-LRI-Monitor-Token': MONITOR_TOKEN})
    check(f'interno {path}: 404 no Nginx, sem ir ao upstream', status == 404 and '"path"' not in body,
          f'status={status}')
# Caminho ambíguo: a borda escolhe o aplicativo pelo caminho normalizado e entrega o cru, que o Nginx decodifica de
# novo. Barra, contrabarra ou ponto codificados e segmentos "."/".." no caminho são recusados antes da location.
for path in ('/lri-monitor/health_check/..%2F..%2Fapi%2Fv1%2Fusers%2Fme', '/%6cri-monitor/health_check/..%2f..%2fapi',
             '/lri-monitor/health_check%2F..%2F..%2Fapi%2Fv1%2Fusers', '/lri-monitor/health_check/..%5C..%5Capi',
             '/lri-monitor/health_check/%2e%2e/%2e%2e/api/v1/users/me',
             '/lri-monitor/health_check/../../api/v1/users/me',
             '/x/../api/v1/users/me', '/api/v1/./users/me', '/api/v1/users/..', '/api/v1/users/me/..?a=1',
             '/desktop/../lri-monitor/health_check/..%2F..%2Fapi', '/desktop/%2e%2e/api/v1/users/me',
             '/mobile/x/../../api/v1/users/me', '/Desktop/x%2F..%2F..%2Fapi'):
    status, _, body = req(INTERNAL, STAFF, path, {'X-LRI-Monitor-Token': MONITOR_TOKEN})
    check(f'interno {path}: caminho ambíguo recusado (400) sem ir ao upstream', status == 400 and '"path"' not in body,
          f'status={status}')
# Codificação na query, ponto literal e "..." no nome continuam valendo.
for path in ('/api/v1/search?query=a%2Fb%2E..%5C', '/api/v1/users/me?x=../y',
             '/api/v1/ticket_attachment/1/2/3?disposition=attachment',
             '/api/v1/tags/a...b', '/help/pt-br/um.nome', '/desktop/search/OC%20123%2F2026',
             '/mobile/search/a%2Fb%5Cc'):
    status, data = upstream(INTERNAL, STAFF, path)
    check(f'interno {path}: não é ambíguo, vai ao upstream', status == 200 and data.get('port') == 3000,
          f'status={status} {data.get("port")}')
# A zona pública não muda (o aplicativo do monitor é só do nome interno).
status, data = upstream(PUBLIC, FQDN, '/api/v1/users/me?x=a%2Fb')
check('público: query codificada segue ao upstream', status == 200, f'status={status}')
# Caminho que só começa parecido não é do monitor e segue para o Rails.
status, data = upstream(INTERNAL, STAFF, '/lri-monitorx')
check('interno /lri-monitorx: não é do monitor, vai ao railsserver', status == 200 and data.get('port') == 3000,
      f'status={status} {data.get("port")}')

# WebSocket e ActionCable vão para o upstream certo.
check('público /ws vai ao websocket (6042)', upstream(PUBLIC, FQDN, '/ws')[1].get('port') == 6042)
check('público /cable vai ao railsserver (3000)', upstream(PUBLIC, FQDN, '/cable')[1].get('port') == 3000)
check('interno /ws vai ao websocket (6042)', upstream(INTERNAL, STAFF, '/ws')[1].get('port') == 6042)

# Troca exata de Origin.
def origin_seen(port, host, path, origin):
    headers = {'Origin': origin} if origin is not None else {}
    return upstream(port, host, path, headers)[1].get('headers', {}).get('origin')


check('interno /ws: Origin do nome interno vira o fqdn', origin_seen(INTERNAL, STAFF, '/ws', f'https://{STAFF}') == f'https://{FQDN}')
for other in (f'https://{STAFF}.evil.com', 'https://intranet.lri.com.br', 'null', f'HTTPS://{STAFF.upper()}',
              'https://atendimentoXlri.com.br', f'http://{STAFF}'):
    check(f'interno /ws: Origin {other} passa inalterado', origin_seen(INTERNAL, STAFF, '/ws', other) == other)
check('interno /ws: Origin ausente continua ausente', origin_seen(INTERNAL, STAFF, '/ws', None) is None)
check('interno /cable: sem troca (ActionCable aceita Origin igual ao Host)', origin_seen(INTERNAL, STAFF, '/cable', f'https://{STAFF}') == f'https://{STAFF}')
check('público /ws: Origin da Mean Well vira o fqdn', origin_seen(PUBLIC, MW, '/ws', f'https://{MW}') == f'https://{FQDN}')
check('público /cable: Origin da Mean Well vira o fqdn', origin_seen(PUBLIC, MW, '/cable', f'https://{MW}') == f'https://{FQDN}')
check('público /ws: Origin de terceiro passa inalterado', origin_seen(PUBLIC, MW, '/ws', 'https://evil.example') == 'https://evil.example')
check('público /ws: Origin ausente continua ausente', origin_seen(PUBLIC, MW, '/ws', None) is None)
check('público /: sem troca fora de /ws e /cable', origin_seen(PUBLIC, MW, '/', f'https://{MW}') == f'https://{MW}')

# Retornos de OAuth: 302 exato para o nome interno, com a query, destino fixo.
for path in ('/auth/google_oauth2/callback', '/auth/microsoft_office365/callback',
             '/api/v1/external_credentials/google/callback', '/api/v1/external_credentials/microsoft_graph/callback'):
    status, headers, _ = req(PUBLIC, FQDN, f'{path}?code=abc&state=xyz', {'X-Forwarded-Host': 'evil.example'})
    location = headers.get('Location', '')
    check(f'público {path}: 302 para o nome interno com a query', status == 302 and location == f'https://{STAFF}{path}?code=abc&state=xyz', f'{status} {location}')
status, headers, _ = req(PUBLIC, 'evil.example', '/auth/google_oauth2/callback?code=abc')
check('Host desconhecido não redireciona (404)', status == 404, f'{status} {headers.get("Location")}')

# Rotas da equipe bloqueadas na zona pública, em qualquer caixa e com barra final.
for path in ('/auth/sso', '/auth/google_oauth2', '/AUTH/GOOGLE_OAUTH2/CALLBACK', '/auth/google_oauth2/callback/',
             '/oauth/token', '/api/v1/external_credentials/google/link_account', '/API/V1/Monitoring/health_check',
             '/lri-monitor/health_check', '/LRI-Monitor/health_check?token=x'):
    status, headers, body = req(PUBLIC, FQDN, path)
    check(f'público {path}: 403 com a página de bloqueio, sem cache',
          status == 403 and 'endereço interno' in body and 'no-store' in headers.get('Cache-Control', ''),
          f'status={status} cache={headers.get("Cache-Control")}')

# Nomes desconhecidos.
check('público: Host desconhecido dá 404', req(PUBLIC, 'evil.example', '/')[0] == 404)
check('interno: Host público no listener interno dá 404', req(INTERNAL, FQDN, '/')[0] == 404)

print(f'\n{failures} falha(s)')
sys.exit(failures)
