# Copyright (C) 2012-2026 Zammad Foundation, https://zammad-foundation.org/

"""Renderiza a stack oficial com contrib/lri/deploy/docker-compose.lri.yml e confere as regras do go-live.

Uso: python3 check_compose_overlay.py <docker-compose.yml oficial> <overlay> [--image <imagem construída>]
Com --image, a checagem de tag roda dentro da imagem e o entrypoint do Nginx do overlay tem de existir nela.
Cada regra violada é listada com o serviço e o motivo; o código de saída é o número de violações.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

IMAGE_PREFIX = "ghcr.io/leaberg69/zammad-lri:"
ZAMMAD_SERVICES = {
    "zammad-backup", "zammad-init", "zammad-railsserver", "zammad-websocket", "zammad-scheduler", "zammad-nginx",
}
MAX_HEAP_BYTES = 1024 ** 3

DUMMY_ENV = {
    "LRI_IMAGE_TAG": "develop-" + "0" * 40,
    "LRI_ZONE_KEY": "k" * 40,
    "LRI_ACCESS_AUD": "aud-teste",
    "CLOUDFLARED_VERSION": "2025.1.0",
    "CLOUDFLARED_TUNNEL_TOKEN": "token-de-teste",
}


def render(official, overlay, env, config_args=("--format", "json")):
    # Só valem as variáveis de env: nem as herdadas do processo nem o .env que o compose carregaria sozinho do
    #   diretório do projeto (--env-file vazio).
    base = {key: value for key, value in os.environ.items()
            if not key.startswith(("LRI_", "CLOUDFLARED_"))}
    # Arquivo fechado antes do subprocesso, para o compose conseguir abri-lo também no Windows.
    with tempfile.TemporaryDirectory() as directory:
        empty_env = os.path.join(directory, "vazio.env")
        with open(empty_env, "w", encoding="utf-8"):
            pass
        return subprocess.run(
            ["docker", "compose", "--env-file", empty_env, "-f", official, "-f", overlay, "config", *config_args],
            capture_output=True, text=True, env={**base, **env}, check=False,
        )


def check_images_listing(official, overlay):
    """A leitura que subir-central.sh faz (config --images, filtrada pelo repositório do fork) dá uma só imagem."""
    result = render(official, overlay, DUMMY_ENV, ("--images", "zammad-railsserver"))
    if result.returncode != 0:
        return [f"config --images zammad-railsserver falhou: {result.stderr.strip()}"]
    fork_images = sorted({line for line in result.stdout.splitlines() if line.startswith(IMAGE_PREFIX)})
    expected = IMAGE_PREFIX + DUMMY_ENV["LRI_IMAGE_TAG"]
    if fork_images != [expected]:
        return [f"config --images zammad-railsserver, filtrada pelo fork, deu {fork_images}; esperado [{expected!r}]"]
    return []


GUARDED_SERVICES = ("zammad-railsserver", "zammad-websocket", "zammad-scheduler")


def check_guard_modes(official, overlay):
    """Fase A do go-live (LRI_ZONE_GUARD=off) e o padrão enforce com a variável vazia."""
    problems = []
    for value, expected in (("off", "off"), ("", "enforce")):
        result = render(official, overlay, {**DUMMY_ENV, "LRI_ZONE_GUARD": value})
        if result.returncode != 0:
            problems.append(f"LRI_ZONE_GUARD={value!r}: compose recusou: {result.stderr.strip()}")
            continue
        services = json.loads(result.stdout)["services"]
        for name in GUARDED_SERVICES:
            guard = services.get(name, {}).get("environment", {}).get("LRI_ZONE_GUARD")
            if guard != expected:
                problems.append(f"LRI_ZONE_GUARD={value!r}: {name} ficou {guard!r}, esperado {expected!r}")

    # Um .env com off ao lado da stack não pode vazar para a verificação do padrão enforce. Numa cópia da stack em
    #   diretório temporário, para nunca deixar um .env no diretório real.
    with tempfile.TemporaryDirectory() as directory:
        isolated = os.path.join(directory, "docker-compose.yml")
        shutil.copyfile(official, isolated)
        with open(os.path.join(directory, ".env"), "w", encoding="utf-8") as handle:
            handle.write("LRI_ZONE_GUARD=off\n")
        result = render(isolated, overlay, DUMMY_ENV)
        guard = json.loads(result.stdout)["services"]["zammad-railsserver"]["environment"].get("LRI_ZONE_GUARD") \
            if result.returncode == 0 else None
        if guard != "enforce":
            problems.append(f".env externo com off alterou a renderização (railsserver ficou {guard!r}): {result.stderr.strip()}")
    return problems


def heap_bytes(value):
    match = re.fullmatch(r"(\d+)([kKmMgG]?)", value)
    if not match:
        return None
    number, unit = int(match.group(1)), match.group(2).lower()
    return number * {"": 1, "k": 1024, "m": 1024 ** 2, "g": 1024 ** 3}[unit]


GOOD_TAGS = ["develop-" + "a1" * 20, "1.2.3", "7.3.0-rc.1"]
BAD_TAGS = ["latest", "develop", "develop-abc1234", "1.2", "v1.2.3", "1.2.3-", "01.2.3", "1.2.3; true"]


def run_shell(script, env, image):
    """sh -c no runner ou, com image, dentro da imagem (o mesmo shell que o compose usará)."""
    if image:
        args = ["docker", "run", "--rm", "--network", "none", "--entrypoint", "/bin/sh"]
        for key, value in env.items():
            args += ["-e", f"{key}={value}"]
        return subprocess.run([*args, image, "-c", script], capture_output=True, text=True, check=False)
    return subprocess.run(["sh", "-c", script], env={"PATH": os.environ["PATH"], **env},
                          capture_output=True, text=True, check=False)


def check_tag_command(service, image=None):
    """Executa o comando real do lri-config-check contra tags válidas e inválidas."""
    command = service.get("command") or []
    if service.get("entrypoint") != ["/bin/sh", "-c"] or len(command) != 1:
        return ["lri-config-check: ausente ou fora do formato esperado (sh -c <comando>)"]

    script = command[0].replace("$$", "$")
    problems = []
    for tag, should_pass in [(t, True) for t in GOOD_TAGS] + [(t, False) for t in BAD_TAGS]:
        result = run_shell(script, {"LRI_IMAGE_TAG": tag}, image)
        if (result.returncode == 0) != should_pass:
            problems.append(f"lri-config-check: tag {tag!r} {'recusada' if should_pass else 'aceita'} indevidamente")
        if not should_pass and "recusada" not in result.stderr:
            problems.append(f"lri-config-check: tag {tag!r} recusada sem dizer o motivo")
    return problems


def check_image(services, image):
    """O entrypoint do Nginx usado pelo overlay tem de existir e ser executável na imagem construída."""
    entrypoint = (services.get("zammad-nginx", {}).get("entrypoint") or [""])[0]
    result = run_shell(f'test -x "{entrypoint}"', {}, image)
    if not entrypoint or result.returncode != 0:
        return [f"zammad-nginx: entrypoint {entrypoint!r} ausente ou não executável na imagem {image}"]
    return []


def check(config, image=None):
    problems = []
    services = config["services"]

    for name, service in sorted(services.items()):
        if service.get("ports"):
            problems.append(f"{name}: publica porta no host {service['ports']}")
        if not service.get("mem_limit"):
            problems.append(f"{name}: sem mem_limit")

    expected_image = IMAGE_PREFIX + DUMMY_ENV["LRI_IMAGE_TAG"]
    for name in sorted(ZAMMAD_SERVICES):
        service = services.get(name, {})
        if service.get("image") != expected_image:
            problems.append(f"{name}: imagem {service.get('image')!r}, esperada {expected_image!r}")
        condition = service.get("depends_on", {}).get("lri-config-check", {}).get("condition")
        if condition != "service_completed_successfully":
            problems.append(f"{name}: não espera a checagem da tag (lri-config-check)")

    # Sem LRI_ZONE_GUARD no .env (fase B e qualquer instalação normal), a guarda fica ligada.
    for name in GUARDED_SERVICES:
        guard = services.get(name, {}).get("environment", {}).get("LRI_ZONE_GUARD")
        if guard != "enforce":
            problems.append(f"{name}: LRI_ZONE_GUARD={guard!r}, esperado 'enforce' quando o .env não define")

    problems += check_tag_command(services.get("lri-config-check", {}), image)
    if image:
        problems += check_image(services, image)

    opts = services.get("zammad-elasticsearch", {}).get("environment", {}).get("ES_JAVA_OPTS", "")
    heaps = [heap_bytes(h) for h in re.findall(r"-Xm[sx](\S+)", opts)]
    if len(heaps) != 2 or any(h is None or h > MAX_HEAP_BYTES for h in heaps):
        problems.append(f"zammad-elasticsearch: heap {opts!r} ausente ou acima de 1g")

    cloudflared = services.get("cloudflared", {})
    if cloudflared.get("network_mode") != "service:zammad-nginx":
        problems.append("cloudflared: fora do namespace de rede do zammad-nginx")
    if cloudflared.get("environment", {}).get("TUNNEL_TOKEN") != DUMMY_ENV["CLOUDFLARED_TUNNEL_TOKEN"]:
        problems.append("cloudflared: TUNNEL_TOKEN não vem de CLOUDFLARED_TUNNEL_TOKEN")

    return problems


def main(official, overlay, image=None):
    result = render(official, overlay, DUMMY_ENV)
    if result.returncode != 0:
        print(f"docker compose config falhou:\n{result.stderr}")
        return 1
    problems = check(json.loads(result.stdout), image)
    problems += check_guard_modes(official, overlay)
    problems += check_images_listing(official, overlay)

    # Sem token, a stack não pode subir: o compose tem de recusar com a mensagem do overlay.
    without_token = {**DUMMY_ENV, "CLOUDFLARED_TUNNEL_TOKEN": ""}
    result = render(official, overlay, without_token)
    if result.returncode == 0 or "CLOUDFLARED_TUNNEL_TOKEN" not in result.stderr:
        problems.append("sem CLOUDFLARED_TUNNEL_TOKEN o compose deveria recusar e citar a variável")

    for problem in problems:
        print(f"ERRO  {problem}")
    if not problems:
        where = f" (checagens dentro de {image})" if image else ""
        print(f"ok    overlay: sem portas no host, imagem do fork, heap do ES <= 1g, mem_limit em todos, token por env{where}")
    return len(problems)


if __name__ == "__main__":
    args = sys.argv[1:]
    built_image = None
    if "--image" in args:
        position = args.index("--image")
        built_image = args[position + 1]
        del args[position:position + 2]
    sys.exit(main(args[0], args[1], built_image))
