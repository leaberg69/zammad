# Cabeçalhos da ZONA PÚBLICA (portais suporte.*). Incluído em CADA location: o Nginx descarta os
# proxy_set_header do nível de cima quando a location define os seus (caso de /ws e /cable).
proxy_http_version 1.1;
proxy_set_header Host $http_host;
proxy_set_header CLIENT_IP $remote_addr;
proxy_set_header X-Forwarded-For $remote_addr;
proxy_set_header X-Forwarded-Proto https;
proxy_set_header Forwarded "";
proxy_set_header X-Forwarded-Scheme "";
proxy_set_header X-Forwarded-Ssl "";
proxy_set_header X-Forwarded-Host "";
# SSO por cabeçalho nunca vem do cliente.
proxy_set_header X-Forwarded-User "";
proxy_set_header Remote-User "";
# Zona: sobrescrita sempre; o que o navegador mandar é descartado.
proxy_set_header X-LRI-Zone "public";
proxy_set_header X-LRI-Zone-Key "";
proxy_set_header Cf-Access-Jwt-Assertion "";
