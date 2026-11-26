#!/usr/bin/env bash
# =============================================================================
#  docker-install-script
#  Instala, verifica e corrige o Docker Engine (repositório oficial) em
#  Debian/Ubuntu e derivados — e gera um relatório do ambiente.
#
#  https://github.com/ivancarlosdepaula/docker-install-script
#
#  Uso rápido:
#    curl -fsSL https://raw.githubusercontent.com/ivancarlosdepaula/docker-install-script/main/install.sh | bash
#
#  Somente relatório (não altera nada):
#    curl -fsSL https://raw.githubusercontent.com/ivancarlosdepaula/docker-install-script/main/install.sh | bash -s -- --check
#
#  Execute "bash install.sh --help" para ver todas as opções.
# =============================================================================

# Todo o script fica dentro de funções e só é executado na última linha.
# Assim, se o download via "curl | bash" for interrompido no meio,
# nada é executado pela metade.

set -Eeuo pipefail

SCRIPT_VERSION="2.0.0"
SCRIPT_URL="https://raw.githubusercontent.com/ivancarlosdepaula/docker-install-script/main/install.sh"

DOCKER_PACKAGES=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
CONFLICT_PACKAGES=(docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc)
DOCKER_SERVICES=(docker containerd)

KEYRING_DIR="/etc/apt/keyrings"
KEYRING_FILE="${KEYRING_DIR}/docker.asc"
REPO_FILE="/etc/apt/sources.list.d/docker.list"

# Opções (podem vir de variáveis de ambiente ou de argumentos)
CHECK_ONLY="${DOCKER_CHECK_ONLY:-0}"
RUN_TEST="${DOCKER_RUN_TEST:-0}"
TARGET_USER_OVERRIDE="${DOCKER_USER:-}"
REPORT_DIR="${REPORT_DIR:-/tmp}"
USE_COLOR=1

# Estado interno
declare -A ST=()        # chave -> ok | fail | warn | na
REPORT_LINES=()         # "status|item|detalhe"
ACTIONS=()              # ações executadas
REPORT_BUF=""           # relatório em texto puro (vai para o arquivo)
NEED_RELOGIN=0
APT_UPDATED=0

# -----------------------------------------------------------------------------
# Utilitários
# -----------------------------------------------------------------------------
setup_colors() {
    if [ "$USE_COLOR" = "1" ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
        C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
        C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_GRAY=$'\033[90m'
    else
        C_RESET=""; C_BOLD=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_GRAY=""
    fi
}

log()  { printf '%s==>%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
warn() { printf '%s[AVISO]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die()  { printf '%s[ERRO]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

# Imprime na tela (com cor) e guarda no relatório (sem cor)
out() {
    local color="${2:-}"
    printf '%s%s%s\n' "$color" "$1" "${color:+$C_RESET}"
    REPORT_BUF+="$1"$'\n'
}

as_root() {
    if [ "$EUID" -eq 0 ]; then "$@"; else sudo "$@"; fi
}

# apt-get não interativo e sem ler o stdin (importante no modo "curl | bash")
apt_get() {
    as_root env DEBIAN_FRONTEND=noninteractive apt-get "$@" </dev/null
}

apt_update_once() {
    if [ "$APT_UPDATED" = "0" ]; then
        log "Atualizando a lista de pacotes (apt-get update)..."
        apt_get update -qq
        APT_UPDATED=1
    fi
}

pkg_installed() {
    [ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" = "install ok installed" ]
}

pkg_version() {
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

unit_exists() {
    [ -n "$(systemctl list-unit-files --no-legend "$1.service" 2>/dev/null || true)" ]
}

user_in_docker_group() {
    [[ " $(id -nG "$TARGET_USER" 2>/dev/null || true) " == *" docker "* ]]
}

record() {
    # record <chave> <ok|fail|warn|na> <item> [detalhe]
    ST["$1"]="$2"
    REPORT_LINES+=("$2|$3|${4:-}")
}

action() {
    log "$1"
    ACTIONS+=("$1")
}

# shellcheck disable=SC2329  # chamada via trap ERR
on_error() {
    local code=$? line=$1 cmd=$2
    local stack="${FUNCNAME[*]:1:${#FUNCNAME[@]}-2}"
    printf '%s[ERRO]%s Falha (código %s) na linha %s: %s\n' "$C_RED" "$C_RESET" "$code" "$line" "$cmd" >&2
    printf '        Etapa: %s\n' "${stack// / < }" >&2
    printf '        Verifique a mensagem acima, corrija e execute o script novamente (ele é idempotente).\n' >&2
    exit "$code"
}

usage() {
    cat <<EOF
docker-install-script v${SCRIPT_VERSION}

Instala o Docker Engine pelo repositório oficial (Debian/Ubuntu e derivados).
Se o Docker já estiver instalado, verifica cada item da configuração, corrige
apenas o que estiver faltando e gera um relatório.

Uso:
  bash install.sh [opções]
  curl -fsSL ${SCRIPT_URL} | bash -s -- [opções]

Opções:
  -c, --check        Somente verifica e gera o relatório (não altera nada)
  -u, --user NOME    Usuário a ser adicionado ao grupo docker
                     (padrão: \$SUDO_USER ou o usuário atual)
  -t, --test         Ao final, executa "docker run --rm hello-world"
      --report-dir D Diretório do arquivo de relatório (padrão: /tmp)
      --no-color     Desativa as cores
  -v, --version      Mostra a versão
  -h, --help         Mostra esta ajuda

Variáveis de ambiente equivalentes:
  DOCKER_CHECK_ONLY=1  DOCKER_USER=nome  DOCKER_RUN_TEST=1  REPORT_DIR=/caminho  NO_COLOR=1

Código de saída: 0 = ambiente OK | 1 = há itens pendentes ou ocorreu erro
EOF
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -c|--check)    CHECK_ONLY=1 ;;
            -u|--user)     [ $# -ge 2 ] || die "A opção $1 exige um nome de usuário."; TARGET_USER_OVERRIDE="$2"; shift ;;
            --user=*)      TARGET_USER_OVERRIDE="${1#*=}" ;;
            -t|--test)     RUN_TEST=1 ;;
            --report-dir)  [ $# -ge 2 ] || die "A opção $1 exige um diretório."; REPORT_DIR="$2"; shift ;;
            --report-dir=*) REPORT_DIR="${1#*=}" ;;
            --no-color)    USE_COLOR=0 ;;
            -v|--version)  echo "$SCRIPT_VERSION"; exit 0 ;;
            -h|--help)     setup_colors; usage; exit 0 ;;
            *)             setup_colors; usage; echo; die "Opção desconhecida: $1" ;;
        esac
        shift
    done
}

# -----------------------------------------------------------------------------
# Pré-requisitos e detecção do ambiente
# -----------------------------------------------------------------------------
detect_os() {
    [ -r /etc/os-release ] || die "Não foi possível ler /etc/os-release."
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_PRETTY="${PRETTY_NAME:-${ID:-desconhecido}}"
    DISTRO=""; CODENAME=""
    case "${ID:-}" in
        ubuntu) DISTRO="ubuntu"; CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}" ;;
        debian) DISTRO="debian"; CODENAME="${VERSION_CODENAME:-}" ;;
        *)
            # Derivados (Linux Mint, Pop!_OS, Zorin, MX, etc.)
            case " ${ID_LIKE:-} " in
                *" ubuntu "*) DISTRO="ubuntu"; CODENAME="${UBUNTU_CODENAME:-}" ;;
                *" debian "*) DISTRO="debian"; CODENAME="${DEBIAN_CODENAME:-${VERSION_CODENAME:-}}" ;;
            esac
            ;;
    esac
    ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    HAS_SYSTEMD=0
    [ -d /run/systemd/system ] && HAS_SYSTEMD=1
    return 0
}

detect_user() {
    if [ -n "$TARGET_USER_OVERRIDE" ]; then
        TARGET_USER="$TARGET_USER_OVERRIDE"
    elif [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
        TARGET_USER="$SUDO_USER"
    else
        TARGET_USER="$(id -un)"
    fi
    id "$TARGET_USER" >/dev/null 2>&1 || die "O usuário '$TARGET_USER' não existe."
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    TARGET_GROUP="$(id -gn "$TARGET_USER")"
}

preflight() {
    [ "$(uname -s)" = "Linux" ] || die "Este script funciona apenas em Linux."
    if ! command -v apt-get >/dev/null 2>&1 || ! command -v dpkg-query >/dev/null 2>&1; then
        die "apt-get/dpkg não encontrados. Este script suporta apenas Debian, Ubuntu e derivados."
    fi

    if [ "$EUID" -ne 0 ]; then
        command -v sudo >/dev/null 2>&1 || die "Execute como root ou instale o sudo."
        if [ "$CHECK_ONLY" != "1" ]; then
            log "Solicitando permissão de administrador (sudo)..."
            sudo -v || die "Não foi possível obter permissão de sudo."
        fi
    fi
}

# -----------------------------------------------------------------------------
# Verificações
# -----------------------------------------------------------------------------
find_repo_files() {
    local f
    for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
        [ -f "$f" ] || continue
        if grep -qsE "^[^#]*download\.docker\.com/linux/${DISTRO}" "$f"; then
            echo "$f"
        fi
    done
}

repo_key_paths() {
    # Extrai os caminhos de "signed-by=" (.list) ou "Signed-By:" (.sources)
    [ $# -gt 0 ] || return 0
    grep -hoE '(signed-by=|Signed-By:[[:space:]]*)[^] [:space:]]+' "$@" 2>/dev/null \
        | sed -E 's/^(signed-by=|Signed-By:[[:space:]]*)//' | sort -u || true
}

check_docker_daemon() {
    # Retorna a versão do servidor se o daemon responder
    local v=""
    v="$(docker info --format '{{.ServerVersion}}' 2>/dev/null)" && { echo "$v"; return 0; }
    if [ "$EUID" -ne 0 ]; then
        if [ "$CHECK_ONLY" = "1" ]; then
            v="$(sudo -n docker info --format '{{.ServerVersion}}' 2>/dev/null)" && { echo "$v"; return 0; }
        else
            v="$(sudo docker info --format '{{.ServerVersion}}' 2>/dev/null)" && { echo "$v"; return 0; }
        fi
    fi
    return 1
}

run_checks() {
    ST=(); REPORT_LINES=()
    local p f k installed_conflicts=() repo_files=() keys=() bad_keys=() unreadable_keys=()

    # 1. Sistema operacional
    if [ -n "$DISTRO" ] && [ -n "$CODENAME" ]; then
        record os ok "Sistema operacional" "$OS_PRETTY (repo: $DISTRO/$CODENAME, $ARCH)"
    else
        record os fail "Sistema operacional" "$OS_PRETTY — não suportado (apenas Debian/Ubuntu e derivados)"
        return 0
    fi

    # 2. systemd
    if [ "$HAS_SYSTEMD" = "1" ]; then
        record systemd ok "systemd" "detectado"
    else
        record systemd warn "systemd" "não detectado (container/WSL?) — serviços não serão verificados"
    fi

    # 3. Pacotes conflitantes
    for p in "${CONFLICT_PACKAGES[@]}"; do
        pkg_installed "$p" && installed_conflicts+=("$p")
    done
    if [ ${#installed_conflicts[@]} -eq 0 ]; then
        record conflicts ok "Pacotes conflitantes" "nenhum instalado"
    else
        record conflicts fail "Pacotes conflitantes" "instalados: ${installed_conflicts[*]}"
    fi
    CONFLICTS_FOUND=("${installed_conflicts[@]+"${installed_conflicts[@]}"}")

    # 4. Repositório oficial
    mapfile -t repo_files < <(find_repo_files)
    REPO_FILES=("${repo_files[@]+"${repo_files[@]}"}")
    if [ ${#repo_files[@]} -gt 0 ]; then
        record repo ok "Repositório oficial do Docker" "${repo_files[*]}"
    else
        record repo fail "Repositório oficial do Docker" "não configurado"
    fi

    # 5. Chave GPG
    if [ ${#repo_files[@]} -gt 0 ]; then
        mapfile -t keys < <(repo_key_paths "${repo_files[@]}")
    fi
    [ ${#keys[@]} -gt 0 ] || keys=("$KEYRING_FILE")
    for k in "${keys[@]}"; do
        if [ ! -s "$k" ]; then
            bad_keys+=("$k")
        elif [ "$(stat -c '%A' "$k" | cut -c8)" != "r" ]; then
            unreadable_keys+=("$k")
        fi
    done
    MISSING_KEYS=("${bad_keys[@]+"${bad_keys[@]}"}")
    UNREADABLE_KEYS=("${unreadable_keys[@]+"${unreadable_keys[@]}"}")
    if [ ${#bad_keys[@]} -gt 0 ]; then
        record key fail "Chave GPG do repositório" "ausente: ${bad_keys[*]}"
    elif [ ${#unreadable_keys[@]} -gt 0 ]; then
        record key warn "Chave GPG do repositório" "sem permissão de leitura (a+r): ${unreadable_keys[*]}"
    else
        record key ok "Chave GPG do repositório" "${keys[*]}"
    fi

    # 6. Pacotes do Docker
    MISSING_PKGS=()
    for p in "${DOCKER_PACKAGES[@]}"; do
        if pkg_installed "$p"; then
            record "pkg:$p" ok "Pacote $p" "$(pkg_version "$p")"
        else
            record "pkg:$p" fail "Pacote $p" "não instalado"
            MISSING_PKGS+=("$p")
        fi
    done

    # 7. Serviços
    for p in "${DOCKER_SERVICES[@]}"; do
        if [ "$HAS_SYSTEMD" != "1" ]; then
            record "svc:$p" na "Serviço $p" "sem systemd"
            continue
        fi
        if ! unit_exists "$p"; then
            record "svc:$p" fail "Serviço $p" "unit não encontrada"
            continue
        fi
        local en ac
        en="$(systemctl is-enabled "$p.service" 2>/dev/null || true)"
        ac="$(systemctl is-active  "$p.service" 2>/dev/null || true)"
        if [ "$en" = "enabled" ] && [ "$ac" = "active" ]; then
            record "svc:$p" ok "Serviço $p" "habilitado no boot e em execução"
        else
            record "svc:$p" fail "Serviço $p" "boot: ${en:-desconhecido} | estado: ${ac:-desconhecido}"
        fi
    done

    # 8. Grupo docker
    if getent group docker >/dev/null 2>&1; then
        record group ok "Grupo 'docker'" "existe"
    else
        record group fail "Grupo 'docker'" "não existe"
    fi

    # 9. Usuário no grupo docker
    if [ "$TARGET_USER" = "root" ]; then
        record usergroup na "Usuário no grupo 'docker'" "root (não é necessário)"
    elif user_in_docker_group; then
        record usergroup ok "Usuário no grupo 'docker'" "$TARGET_USER"
    else
        record usergroup fail "Usuário no grupo 'docker'" "$TARGET_USER não pertence ao grupo"
    fi

    # 10. Permissões de ~/.docker
    DOCKER_DIR="${TARGET_HOME}/.docker"
    if [ ! -d "$DOCKER_DIR" ]; then
        record dockerdir ok "Permissões de ~/.docker" "$DOCKER_DIR não existe (nada a ajustar)"
    else
        local wrong=""
        if wrong="$(find "$DOCKER_DIR" ! -user "$TARGET_USER" -print -quit 2>/dev/null)" && [ -z "$wrong" ]; then
            record dockerdir ok "Permissões de ~/.docker" "$DOCKER_DIR pertence a $TARGET_USER"
        else
            record dockerdir fail "Permissões de ~/.docker" "há arquivos que não pertencem a $TARGET_USER em $DOCKER_DIR"
        fi
    fi

    # 11. Daemon respondendo
    if ! command -v docker >/dev/null 2>&1; then
        record daemon fail "Docker daemon" "comando 'docker' não encontrado"
    else
        local sv
        if sv="$(check_docker_daemon)"; then
            local extra=""
            local cv bv
            cv="$(docker compose version --short 2>/dev/null || true)"
            bv="$(docker buildx version 2>/dev/null | awk '{print $2}' || true)"
            [ -n "$cv" ] && extra+=" | compose $cv"
            [ -n "$bv" ] && extra+=" | buildx $bv"
            record daemon ok "Docker daemon" "respondendo (Engine $sv$extra)"
        elif [ "$CHECK_ONLY" = "1" ] && [ "$EUID" -ne 0 ]; then
            record daemon warn "Docker daemon" "não verificado (sem acesso ao socket; rode com sudo para checar)"
        else
            record daemon fail "Docker daemon" "não está respondendo"
        fi
    fi
    return 0
}

count_status() {
    local s n=0 line
    s="$1"
    for line in "${REPORT_LINES[@]}"; do
        [ "${line%%|*}" = "$s" ] && n=$((n + 1))
    done
    echo "$n"
}

print_report() {
    local title="$1" line status item detail tag color pad
    local LC_ALL=C.UTF-8   # para ${#item} contar caracteres, não bytes
    out ""
    out "-----------------------------------------------------------------------" "$C_BOLD"
    out " $title" "$C_BOLD"
    out "-----------------------------------------------------------------------" "$C_BOLD"
    for line in "${REPORT_LINES[@]}"; do
        status="${line%%|*}"; line="${line#*|}"
        item="${line%%|*}";   detail="${line#*|}"
        case "$status" in
            ok)   tag="[  OK  ]"; color="$C_GREEN" ;;
            fail) tag="[ FALTA]"; color="$C_RED" ;;
            warn) tag="[ AVISO]"; color="$C_YELLOW" ;;
            *)    tag="[  --  ]"; color="$C_GRAY" ;;
        esac
        # Preenchimento manual: printf %-Ns conta bytes e desalinha acentos
        pad=$((32 - ${#item})); [ "$pad" -lt 1 ] && pad=1
        printf '%s%s%s %s%*s%s\n' "$color" "$tag" "$C_RESET" "$item" "$pad" "" "$detail"
        REPORT_BUF+="$(printf '%s %s%*s%s' "$tag" "$item" "$pad" "" "$detail")"$'\n'
    done
    out ""
    out "Resumo: $(count_status ok) OK | $(count_status fail) pendente(s) | $(count_status warn) aviso(s)"
}

# -----------------------------------------------------------------------------
# Correções (só executa o que estiver faltando)
# -----------------------------------------------------------------------------
ensure_prereqs() {
    local need=()
    pkg_installed ca-certificates || need+=(ca-certificates)
    pkg_installed curl || need+=(curl)
    if [ ${#need[@]} -gt 0 ]; then
        apt_update_once
        action "Instalando dependências: ${need[*]}"
        apt_get install -y -qq "${need[@]}"
    fi
}

download_key() {
    local dest="$1"
    action "Baixando a chave GPG oficial do Docker em $dest"
    as_root install -m 0755 -d "$(dirname "$dest")"
    as_root curl -fsSL "https://download.docker.com/linux/${DISTRO}/gpg" -o "$dest"
    as_root chmod a+r "$dest"
}

write_repo_file() {
    action "Configurando o repositório oficial em $REPO_FILE"
    echo "deb [arch=${ARCH} signed-by=${KEYRING_FILE}] https://download.docker.com/linux/${DISTRO} ${CODENAME} stable" \
        | as_root tee "$REPO_FILE" >/dev/null
    APT_UPDATED=0
}

apply_fixes() {
    local p k f

    # Pacotes conflitantes
    if [ "${ST[conflicts]}" = "fail" ]; then
        action "Removendo pacotes conflitantes: ${CONFLICTS_FOUND[*]}"
        apt_get remove -y -qq "${CONFLICTS_FOUND[@]}"
    fi

    # Repositório e chave
    if [ "${ST[repo]}" = "fail" ] || [ "${ST[key]}" != "ok" ]; then
        ensure_prereqs

        for k in "${UNREADABLE_KEYS[@]+"${UNREADABLE_KEYS[@]}"}"; do
            action "Ajustando permissão de leitura da chave $k"
            as_root chmod a+r "$k"
        done

        if [ "${ST[repo]}" = "fail" ]; then
            [ -s "$KEYRING_FILE" ] || download_key "$KEYRING_FILE"
            write_repo_file
        else
            for k in "${MISSING_KEYS[@]+"${MISSING_KEYS[@]}"}"; do
                if [[ "$k" == *.asc ]]; then
                    download_key "$k"
                else
                    # Chave binária (.gpg) ausente: desativa a configuração antiga e usa a padrão
                    for f in "${REPO_FILES[@]}"; do
                        if [ "$f" = "/etc/apt/sources.list" ]; then
                            warn "A entrada do Docker em /etc/apt/sources.list aponta para uma chave ausente ($k). Remova-a manualmente."
                        elif [ "$f" != "$REPO_FILE" ]; then
                            action "Desativando configuração antiga do repositório: $f -> $f.disabled"
                            as_root mv "$f" "$f.disabled"
                        fi
                    done
                    [ -s "$KEYRING_FILE" ] || download_key "$KEYRING_FILE"
                    write_repo_file
                    break
                fi
            done
        fi
    fi

    # Pacotes do Docker
    if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
        apt_update_once
        action "Instalando pacotes: ${MISSING_PKGS[*]}"
        apt_get install -y -qq "${MISSING_PKGS[@]}"
    fi

    # Serviços (re-verifica ao vivo, pois a instalação pode tê-los iniciado)
    if [ "$HAS_SYSTEMD" = "1" ]; then
        for p in "${DOCKER_SERVICES[@]}"; do
            unit_exists "$p" || continue
            if [ "$(systemctl is-enabled "$p.service" 2>/dev/null || true)" != "enabled" ]; then
                action "Habilitando o serviço $p no boot"
                as_root systemctl enable "$p.service" --quiet
            fi
            if [ "$(systemctl is-active "$p.service" 2>/dev/null || true)" != "active" ]; then
                action "Iniciando o serviço $p"
                as_root systemctl start "$p.service"
            fi
        done
    fi

    # Sem systemd (WSL, containers): tenta iniciar o daemon via "service"
    if [ "$HAS_SYSTEMD" != "1" ] && command -v docker >/dev/null 2>&1 \
        && ! as_root docker info >/dev/null 2>&1 && command -v service >/dev/null 2>&1; then
        action "Iniciando o Docker via 'service docker start' (sem systemd)"
        as_root service docker start >/dev/null 2>&1 || warn "Não foi possível iniciar o Docker sem systemd."
        sleep 3
    fi

    # Grupo docker
    if ! getent group docker >/dev/null 2>&1; then
        action "Criando o grupo 'docker'"
        as_root groupadd docker
    fi

    # Usuário no grupo
    if [ "$TARGET_USER" != "root" ] && ! user_in_docker_group; then
        action "Adicionando o usuário '$TARGET_USER' ao grupo 'docker'"
        as_root usermod -aG docker "$TARGET_USER"
        NEED_RELOGIN=1
    fi

    # Permissões de ~/.docker
    if [ "${ST[dockerdir]}" = "fail" ]; then
        action "Ajustando o dono e as permissões de $DOCKER_DIR"
        as_root chown -R "$TARGET_USER":"$TARGET_GROUP" "$DOCKER_DIR"
        as_root chmod -R g+rwx "$DOCKER_DIR"
    fi
}

run_hello_world() {
    log "Testando: docker run --rm hello-world"
    if as_root docker run --rm hello-world >/dev/null 2>&1; then
        record test ok "Teste hello-world" "container executado com sucesso"
    else
        record test fail "Teste hello-world" "falhou (verifique rede/registro e o daemon)"
    fi
}

# -----------------------------------------------------------------------------
# Principal
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"
    setup_colors
    trap 'on_error $LINENO "$BASH_COMMAND"' ERR

    preflight
    detect_os
    detect_user

    local mode="instalar/corrigir"
    [ "$CHECK_ONLY" = "1" ] && mode="somente verificação (--check)"

    out "=======================================================================" "$C_BOLD"
    out " Docker install script v${SCRIPT_VERSION} — relatório do ambiente" "$C_BOLD"
    out "=======================================================================" "$C_BOLD"
    out " Host:    $(hostname -f 2>/dev/null || hostname)"
    out " Data:    $(date '+%Y-%m-%d %H:%M:%S %Z')"
    out " Kernel:  $(uname -r)"
    out " Usuário: $TARGET_USER (executando como $(id -un))"
    out " Modo:    $mode"

    run_checks
    print_report "ESTADO ATUAL"

    if [ "${ST[os]}" = "fail" ]; then
        die "Sistema operacional não suportado."
    fi

    local pending
    pending="$(count_status fail)"

    if [ "$CHECK_ONLY" != "1" ]; then
        if [ "$pending" -eq 0 ] && [ "${ST[key]}" = "ok" ]; then
            out ""
            out "Nada a fazer: o Docker já está instalado e configurado corretamente." "$C_GREEN"
        else
            out ""
            log "Aplicando correções..."
            apply_fixes
            run_checks
            print_report "ESTADO FINAL"
        fi
        [ "$RUN_TEST" = "1" ] && { run_hello_world; print_report "ESTADO FINAL (com teste)"; }

        if [ ${#ACTIONS[@]} -gt 0 ]; then
            out ""
            out "Ações executadas:" "$C_BOLD"
            local a
            for a in "${ACTIONS[@]}"; do out "  - $a"; done
        fi
    elif [ "$RUN_TEST" = "1" ]; then
        warn "--test ignorado no modo --check."
    fi

    pending="$(count_status fail)"

    # Salva o relatório
    local report_file
    report_file="${REPORT_DIR%/}/docker-report-$(hostname -s 2>/dev/null || hostname)-$(date +%Y%m%d-%H%M%S).txt"
    if printf '%s' "$REPORT_BUF" > "$report_file" 2>/dev/null; then
        echo
        log "Relatório salvo em: $report_file"
    else
        warn "Não foi possível salvar o relatório em $REPORT_DIR"
    fi

    if [ "$NEED_RELOGIN" = "1" ]; then
        echo
        printf '%s' "$C_YELLOW"
        echo "======================================================================="
        echo "AVISO IMPORTANTE:"
        echo "O usuário '$TARGET_USER' foi adicionado ao grupo 'docker'."
        echo "Para rodar 'docker ...' SEM sudo, é necessário:"
        echo "  1. Fazer LOGOUT e LOGIN novamente; OU"
        echo "  2. Executar agora mesmo:  newgrp docker"
        echo "======================================================================="
        printf '%s' "$C_RESET"
    fi

    if [ "$pending" -eq 0 ]; then
        exit 0
    else
        [ "$CHECK_ONLY" = "1" ] && warn "Há $pending item(ns) pendente(s). Rode sem --check para corrigir."
        exit 1
    fi
}

main "$@"
