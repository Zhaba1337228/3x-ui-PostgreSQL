#!/bin/bash

red='\033[0;31m'
green='\033[0;32m'
blue='\033[0;34m'
yellow='\033[0;33m'
plain='\033[0m'
XUI_EFFECTIVE_PG_PORT=""

cur_dir=$(pwd)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

xui_folder="${XUI_MAIN_FOLDER:=/usr/local/x-ui}"
xui_service="${XUI_SERVICE:=/etc/systemd/system}"

# check root
[[ $EUID -ne 0 ]] && echo -e "${red}Fatal error: ${plain} Please run this script with root privilege \n " && exit 1

# Check OS and set release variable
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    release=$ID
    elif [[ -f /usr/lib/os-release ]]; then
    source /usr/lib/os-release
    release=$ID
else
    echo "Failed to check the system OS, please contact the author!" >&2
    exit 1
fi
echo "The OS release is: $release"

arch() {
    case "$(uname -m)" in
        x86_64 | x64 | amd64) echo 'amd64' ;;
        i*86 | x86) echo '386' ;;
        armv8* | armv8 | arm64 | aarch64) echo 'arm64' ;;
        armv7* | armv7 | arm) echo 'armv7' ;;
        armv6* | armv6) echo 'armv6' ;;
        armv5* | armv5) echo 'armv5' ;;
        s390x) echo 's390x' ;;
        *) echo -e "${green}Unsupported CPU architecture! ${plain}" && rm -f install.sh && exit 1 ;;
    esac
}

echo "Arch: $(arch)"

# Simple helpers
is_ipv4() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0 || return 1
}
is_ipv6() {
    [[ "$1" =~ : ]] && return 0 || return 1
}
is_ip() {
    is_ipv4 "$1" || is_ipv6 "$1"
}
is_domain() {
    [[ "$1" =~ ^([A-Za-z0-9](-*[A-Za-z0-9])*\.)+(xn--[a-z0-9]{2,}|[A-Za-z]{2,})$ ]] && return 0 || return 1
}

# Port helpers
is_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk -v p=":${port}$" '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -lnt 2>/dev/null | awk -v p=":${port} " '$4 ~ p {exit 0} END {exit 1}'
        return
    fi
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:${port} -sTCP:LISTEN >/dev/null 2>&1 && return 0
    fi
    return 1
}

get_listening_process_for_port() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p {print; exit}'
        return
    fi
    return 1
}

postgres_cluster_on_port() {
    local pg_port="$1"
    if ! command -v pg_lsclusters >/dev/null 2>&1; then
        return 1
    fi
    pg_lsclusters --no-header 2>/dev/null | awk -v p="${pg_port}" '$3 == p {found=1} END {exit(found ? 0 : 1)}'
}

postgres_cluster_status_on_port() {
    local pg_port="$1"
    if ! command -v pg_lsclusters >/dev/null 2>&1; then
        return 1
    fi
    pg_lsclusters --no-header 2>/dev/null | awk -v p="${pg_port}" '$3 == p {print $4; exit}'
}

find_free_port() {
    local start_port="${1:-5432}"
    local end_port="${2:-65535}"
    local candidate=""

    for candidate in $(seq "${start_port}" "${end_port}"); do
        if postgres_cluster_on_port "${candidate}"; then
            continue
        fi
        if ! is_port_in_use "${candidate}"; then
            echo "${candidate}"
            return 0
        fi
    done

    return 1
}

get_primary_postgres_cluster() {
    if ! command -v pg_lsclusters >/dev/null 2>&1; then
        return 1
    fi

    pg_lsclusters --no-header 2>/dev/null | awk 'NR==1 {print $1" "$2" "$3" "$4; exit}'
}

choose_postgres_port() {
    local default_port="${1:-5432}"
    local selected_port=""
    while true; do
        read -rp "PostgreSQL port [default ${default_port}]: " selected_port
        selected_port="${selected_port:-${default_port}}"

        if ! [[ "${selected_port}" =~ ^[0-9]+$ ]] || ((selected_port < 1 || selected_port > 65535)); then
            echo -e "${red}Invalid PostgreSQL port. Choose a number between 1 and 65535.${plain}" >&2
            continue
        fi

        if postgres_cluster_on_port "${selected_port}"; then
            local cluster_status=""
            cluster_status=$(postgres_cluster_status_on_port "${selected_port}" 2>/dev/null || true)
            if [[ "${cluster_status}" == "online" ]]; then
                echo -e "${green}Existing PostgreSQL cluster already uses port ${selected_port}. Will reuse it.${plain}" >&2
            else
                echo -e "${yellow}PostgreSQL cluster is configured for port ${selected_port} but is not running. Installer will recover or move it automatically if needed.${plain}" >&2
            fi
            echo "${selected_port}"
            return 0
        fi

        if is_port_in_use "${selected_port}"; then
            echo -e "${red}Port ${selected_port} is already occupied. Choose another port.${plain}" >&2
            echo -e "${yellow}Listener:${plain} $(get_listening_process_for_port "${selected_port}")" >&2
            continue
        fi

        echo "${selected_port}"
        return 0
    done
}

install_base() {
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update && apt-get install -y -q cron curl tar tzdata socat ca-certificates
        ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf -y update && dnf install -y -q curl tar tzdata socat ca-certificates
        ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum -y update && yum install -y curl tar tzdata socat ca-certificates
            else
                dnf -y update && dnf install -y -q curl tar tzdata socat ca-certificates
            fi
        ;;
        arch | manjaro | parch)
            pacman -Syu && pacman -Syu --noconfirm curl tar tzdata socat ca-certificates
        ;;
        opensuse-tumbleweed | opensuse-leap)
            zypper refresh && zypper -q install -y curl tar timezone socat ca-certificates
        ;;
        alpine)
            apk update && apk add curl tar tzdata socat ca-certificates
        ;;
        *)
            apt-get update && apt-get install -y -q curl tar tzdata socat ca-certificates
        ;;
    esac
}

get_xui_env_file() {
    case "${release}" in
        alpine)
            echo "/etc/conf.d/x-ui"
        ;;
        ubuntu | debian | armbian)
            echo "/etc/default/x-ui"
        ;;
        *)
            echo "/etc/sysconfig/x-ui"
        ;;
    esac
}

upsert_env_var() {
    local file="$1"
    local key="$2"
    local value="$3"

    mkdir -p "$(dirname "$file")"
    touch "$file"

    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s#^${key}=.*#${key}=${value}#g" "$file"
    else
        echo "${key}=${value}" >> "$file"
    fi
}

install_postgres_local() {
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get update && apt-get install -y -q postgresql postgresql-contrib
            systemctl enable postgresql >/dev/null 2>&1
            systemctl start postgresql >/dev/null 2>&1
            if command -v pg_lsclusters >/dev/null 2>&1; then
                local cluster_ver cluster_name
                cluster_ver=$(pg_lsclusters --no-header 2>/dev/null | awk 'NR==1{print $1}')
                cluster_name=$(pg_lsclusters --no-header 2>/dev/null | awk 'NR==1{print $2}')
                if [[ -n "${cluster_ver}" && -n "${cluster_name}" ]]; then
                    pg_ctlcluster "${cluster_ver}" "${cluster_name}" start >/dev/null 2>&1 || true
                fi
            fi
        ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol)
            dnf install -y -q postgresql-server postgresql-contrib
            postgresql-setup --initdb >/dev/null 2>&1 || true
            systemctl enable postgresql >/dev/null 2>&1
            systemctl start postgresql >/dev/null 2>&1
        ;;
        centos)
            if [[ "${VERSION_ID}" =~ ^7 ]]; then
                yum install -y postgresql-server postgresql-contrib
                postgresql-setup initdb >/dev/null 2>&1 || true
            else
                dnf install -y -q postgresql-server postgresql-contrib
                postgresql-setup --initdb >/dev/null 2>&1 || true
            fi
            systemctl enable postgresql >/dev/null 2>&1
            systemctl start postgresql >/dev/null 2>&1
        ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm postgresql
            su - postgres -c "initdb -D /var/lib/postgres/data" >/dev/null 2>&1 || true
            systemctl enable postgresql >/dev/null 2>&1
            systemctl start postgresql >/dev/null 2>&1
        ;;
        alpine)
            apk add --no-cache postgresql postgresql-client
            rc-update add postgresql default >/dev/null 2>&1 || true
            rc-service postgresql start >/dev/null 2>&1 || true
        ;;
        *)
            echo -e "${red}Automatic local PostgreSQL install is not supported on this OS yet.${plain}"
            return 1
        ;;
    esac

    return 0
}

ensure_postgres_running() {
    local pg_port="${1:-5432}"

    if command -v pg_lsclusters >/dev/null 2>&1 && command -v pg_ctlcluster >/dev/null 2>&1; then
        while read -r ver name _; do
            [[ -z "${ver}" || -z "${name}" ]] && continue
            pg_ctlcluster "${ver}" "${name}" start >/dev/null 2>&1 || true
        done < <(pg_lsclusters --no-header 2>/dev/null | awk '{print $1" "$2" "$4}')
    fi

    systemctl start postgresql >/dev/null 2>&1 || rc-service postgresql start >/dev/null 2>&1 || true

    if command -v pg_lsclusters >/dev/null 2>&1; then
        for _ in $(seq 1 20); do
            local cluster_status
            cluster_status=$(pg_lsclusters --no-header 2>/dev/null | awk -v p="${pg_port}" '$3 == p {print $4; exit}')
            if [[ "${cluster_status}" == "online" ]]; then
                return 0
            fi
            sleep 1
        done
    elif command -v pg_isready >/dev/null 2>&1; then
        for _ in $(seq 1 20); do
            if pg_isready -h 127.0.0.1 -p "${pg_port}" >/dev/null 2>&1; then
                return 0
            fi
            sleep 1
        done
    fi

    if is_port_in_use "${pg_port}"; then
        echo -e "${red}Port ${pg_port} is already occupied by another process.${plain}"
        echo -e "${yellow}Listener:${plain} $(get_listening_process_for_port "${pg_port}")"
    fi

    echo -e "${red}PostgreSQL is still not running on 127.0.0.1:${pg_port}.${plain}"
    if command -v pg_lsclusters >/dev/null 2>&1; then
        echo -e "${yellow}Current clusters:${plain}"
        pg_lsclusters || true
    fi
    return 1
}

prepare_local_postgres_port() {
    local requested_port="${1:-5432}"
    local effective_port="${requested_port}"
    local cluster_status=""

    cluster_status=$(postgres_cluster_status_on_port "${requested_port}" 2>/dev/null || true)

    if is_port_in_use "${requested_port}"; then
        if ! postgres_cluster_on_port "${requested_port}" || [[ "${cluster_status}" != "online" ]]; then
            local replacement_port=""
            replacement_port=$(find_free_port 1024 65535) || {
                echo -e "${red}No free TCP port was found for local PostgreSQL.${plain}" >&2
                return 1
            }
            echo -e "${yellow}Port ${requested_port} is already occupied by another process. Using port ${replacement_port} for PostgreSQL instead.${plain}" >&2
            echo -e "${yellow}Listener:${plain} $(get_listening_process_for_port "${requested_port}")" >&2
            effective_port="${replacement_port}"
        fi
    fi

    if [[ "${effective_port}" == "${requested_port}" ]] && postgres_cluster_on_port "${requested_port}" && [[ "${cluster_status}" == "online" ]]; then
        echo -e "${green}Existing PostgreSQL cluster already runs on port ${requested_port}. Reusing it.${plain}" >&2
    fi

    echo "${effective_port}"
    return 0
}

configure_local_postgres_security() {
    local pg_port="$1"
    local requested_port="$1"
    local pg_conf=""
    local pg_hba=""
    local cluster_ver=""
    local cluster_name=""
    local cluster_info=""

    XUI_EFFECTIVE_PG_PORT="${pg_port}"

    cluster_info=$(get_primary_postgres_cluster)
    if [[ -n "${cluster_info}" ]]; then
        cluster_ver=$(echo "${cluster_info}" | awk '{print $1}')
        cluster_name=$(echo "${cluster_info}" | awk '{print $2}')
        if [[ -d "/etc/postgresql/${cluster_ver}/${cluster_name}" ]]; then
            pg_conf="/etc/postgresql/${cluster_ver}/${cluster_name}/postgresql.conf"
            pg_hba="/etc/postgresql/${cluster_ver}/${cluster_name}/pg_hba.conf"
        fi
    fi

    if [[ -z "${pg_conf}" ]]; then
        pg_conf=$(find /etc/postgresql -type f -name postgresql.conf 2>/dev/null | head -n 1)
    fi
    if [[ -z "${pg_hba}" ]]; then
        pg_hba=$(find /etc/postgresql -type f -name pg_hba.conf 2>/dev/null | head -n 1)
    fi

    if [[ -z "${pg_conf}" ]]; then
        pg_conf=$(find /var/lib/pgsql -type f -name postgresql.conf 2>/dev/null | head -n 1)
    fi
    if [[ -z "${pg_hba}" ]]; then
        pg_hba=$(find /var/lib/pgsql -type f -name pg_hba.conf 2>/dev/null | head -n 1)
    fi
    if [[ -z "${pg_conf}" ]]; then
        pg_conf=$(find /var/lib/postgres -type f -name postgresql.conf 2>/dev/null | head -n 1)
    fi
    if [[ -z "${pg_hba}" ]]; then
        pg_hba=$(find /var/lib/postgres -type f -name pg_hba.conf 2>/dev/null | head -n 1)
    fi

    if [[ -n "${pg_conf}" ]]; then
        sed -i "s/^#\?listen_addresses *=.*/listen_addresses = '127.0.0.1'/" "${pg_conf}" 2>/dev/null || true
        if [[ -n "${pg_port}" ]]; then
            sed -i "s/^#\?port *=.*/port = ${pg_port}/" "${pg_conf}" 2>/dev/null || true
        fi
        if ! grep -q "^password_encryption *= *scram-sha-256" "${pg_conf}" 2>/dev/null; then
            echo "password_encryption = scram-sha-256" >> "${pg_conf}"
        fi
    fi

    if [[ -n "${pg_hba}" ]]; then
        cat > "${pg_hba}" <<'EOF'
# TYPE  DATABASE        USER            ADDRESS                 METHOD
local   all             postgres                                peer
local   all             all                                     scram-sha-256
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256
EOF
    fi

    if [[ -n "${cluster_ver}" && -n "${cluster_name}" ]] && command -v pg_ctlcluster >/dev/null 2>&1; then
        pg_ctlcluster "${cluster_ver}" "${cluster_name}" restart >/dev/null 2>&1 || pg_ctlcluster "${cluster_ver}" "${cluster_name}" start >/dev/null 2>&1 || true
    else
        systemctl restart postgresql >/dev/null 2>&1 || rc-service postgresql restart >/dev/null 2>&1 || true
    fi
    if ensure_postgres_running "${pg_port}"; then
        XUI_EFFECTIVE_PG_PORT="${pg_port}"
        return 0
    fi

    local fallback_port=""
    fallback_port=$(find_free_port 1024 65535) || return 1
    if [[ "${fallback_port}" == "${requested_port}" ]]; then
        return 1
    fi

    echo -e "${yellow}PostgreSQL cluster did not start on port ${requested_port}. Retrying with port ${fallback_port}.${plain}"

    if [[ -n "${pg_conf}" ]]; then
        sed -i "s/^#\?port *=.*/port = ${fallback_port}/" "${pg_conf}" 2>/dev/null || true
    fi

    if [[ -n "${cluster_ver}" && -n "${cluster_name}" ]] && command -v pg_ctlcluster >/dev/null 2>&1; then
        pg_ctlcluster "${cluster_ver}" "${cluster_name}" restart >/dev/null 2>&1 || pg_ctlcluster "${cluster_ver}" "${cluster_name}" start >/dev/null 2>&1 || true
    else
        systemctl restart postgresql >/dev/null 2>&1 || rc-service postgresql restart >/dev/null 2>&1 || true
    fi

    ensure_postgres_running "${fallback_port}" || return 1
    XUI_EFFECTIVE_PG_PORT="${fallback_port}"
    return 0
}

bootstrap_local_postgres() {
    local db_name="$1"
    local db_user="$2"
    local db_password="$3"
    local pg_port="${4:-5432}"
    local recreate_db="${5:-0}"

    ensure_postgres_running "${pg_port}" || return 1

    if id postgres >/dev/null 2>&1; then
        su - postgres -c "psql -p ${pg_port} -v ON_ERROR_STOP=1 -d postgres" <<SQL || return 1
DO \$dbsetup\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${db_user}') THEN
      CREATE ROLE ${db_user} LOGIN PASSWORD '${db_password}';
   ELSE
      ALTER ROLE ${db_user} WITH LOGIN PASSWORD '${db_password}';
   END IF;
END
\$dbsetup\$;
SQL

        local db_exists
        db_exists=$(su - postgres -c "psql -p ${pg_port} -tAc \"SELECT 1 FROM pg_database WHERE datname='${db_name}'\"")
        if [[ "${db_exists}" == "1" && "${recreate_db}" == "1" ]]; then
            su - postgres -c "psql -p ${pg_port} -d postgres -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${db_name}' AND pid <> pg_backend_pid();\"" || return 1
            su - postgres -c "dropdb -p ${pg_port} --if-exists ${db_name}" || return 1
            su - postgres -c "createdb -p ${pg_port} -O ${db_user} ${db_name}" || return 1
        elif [[ "${db_exists}" != "1" ]]; then
            su - postgres -c "createdb -p ${pg_port} -O ${db_user} ${db_name}" || return 1
        fi
    else
        psql -p "${pg_port}" -U postgres -v ON_ERROR_STOP=1 -d postgres <<SQL || return 1
DO \$dbsetup\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${db_user}') THEN
      CREATE ROLE ${db_user} LOGIN PASSWORD '${db_password}';
   ELSE
      ALTER ROLE ${db_user} WITH LOGIN PASSWORD '${db_password}';
   END IF;
END
\$dbsetup\$;
SQL

        local db_exists
        db_exists=$(psql -p "${pg_port}" -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='${db_name}'")
        if [[ "${db_exists}" == "1" && "${recreate_db}" == "1" ]]; then
            psql -p "${pg_port}" -U postgres -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='${db_name}' AND pid <> pg_backend_pid();" || return 1
            dropdb -p "${pg_port}" -U postgres --if-exists "${db_name}" || return 1
            createdb -p "${pg_port}" -U postgres -O "${db_user}" "${db_name}" || return 1
        elif [[ "${db_exists}" != "1" ]]; then
            createdb -p "${pg_port}" -U postgres -O "${db_user}" "${db_name}" || return 1
        fi
    fi

    return 0
}

configure_database_env() {
    local env_file
    env_file=$(get_xui_env_file)

    local existing_driver=""
    if [[ -f "${env_file}" ]]; then
        existing_driver=$(grep '^XUI_DB_DRIVER=' "${env_file}" | tail -n1 | cut -d= -f2)
    fi
    [[ -z "${existing_driver}" ]] && existing_driver="sqlite"

    echo ""
    echo -e "${green}Database backend setup${plain}"
    echo -e "${green}1.${plain} SQLite (default, old behavior)"
    echo -e "${green}2.${plain} PostgreSQL"

    local default_choice="1"
    [[ "${existing_driver}" == "postgres" ]] && default_choice="2"

    local db_choice=""
    read -rp "Choose database backend [default ${default_choice}]: " db_choice
    db_choice="${db_choice:-$default_choice}"

    if [[ "${db_choice}" != "2" ]]; then
        upsert_env_var "${env_file}" "XUI_DB_DRIVER" "sqlite"
        upsert_env_var "${env_file}" "XUI_POSTGRES_DSN" ""
        export XUI_DB_DRIVER="sqlite"
        unset XUI_POSTGRES_DSN
        echo -e "${green}SQLite selected.${plain}"
        return 0
    fi

    local pg_mode=""
    echo -e "${green}1.${plain} Install PostgreSQL on this server"
    echo -e "${green}2.${plain} Use external PostgreSQL"
    read -rp "Choose PostgreSQL mode [default 1]: " pg_mode
    pg_mode="${pg_mode:-1}"

    local pg_host="127.0.0.1"
    local pg_port="5432"
    local pg_db="xui"
    local pg_user="xui"
    local pg_password=""
    local pg_sslmode="disable"
    local recreate_db="0"

    if [[ "${pg_mode}" == "1" ]]; then
        pg_port=$(choose_postgres_port "5432") || return 1
        read -rp "Database name [default xui]: " pg_db
        pg_db="${pg_db:-xui}"
        read -rp "Database user [default xui]: " pg_user
        pg_user="${pg_user:-xui}"
        read -rp "Database password [leave empty to generate]: " pg_password
        if [[ -z "${pg_password}" ]]; then
            pg_password=$(gen_random_string 24)
            echo -e "${yellow}Generated PostgreSQL password: ${pg_password}${plain}"
        fi

        echo -e "${yellow}Installing/configuring local PostgreSQL...${plain}"
        install_postgres_local || return 1
        pg_port=$(prepare_local_postgres_port "${pg_port}") || return 1
        configure_local_postgres_security "${pg_port}" || return 1
        pg_port="${XUI_EFFECTIVE_PG_PORT:-${pg_port}}"
        pg_host="127.0.0.1"
        pg_sslmode="disable"
        if id postgres >/dev/null 2>&1; then
            local existing_db
            existing_db=$(su - postgres -c "psql -p ${pg_port} -tAc \"SELECT 1 FROM pg_database WHERE datname='${pg_db}'\"" 2>/dev/null)
            if [[ "${existing_db}" == "1" ]]; then
                local recreate_choice=""
                read -rp "Database '${pg_db}' already exists. Recreate it and remove old data? [y/N]: " recreate_choice
                if [[ "${recreate_choice}" == "y" || "${recreate_choice}" == "Y" ]]; then
                    recreate_db="1"
                fi
            fi
        fi
        bootstrap_local_postgres "${pg_db}" "${pg_user}" "${pg_password}" "${pg_port}" "${recreate_db}" || return 1
    else
        read -rp "PostgreSQL host [default 127.0.0.1]: " pg_host
        pg_host="${pg_host:-127.0.0.1}"
        read -rp "PostgreSQL port [default 5432]: " pg_port
        pg_port="${pg_port:-5432}"
        read -rp "Database name [default xui]: " pg_db
        pg_db="${pg_db:-xui}"
        read -rp "Database user [default xui]: " pg_user
        pg_user="${pg_user:-xui}"
        read -rp "Database password: " pg_password
        read -rp "SSL mode [default disable]: " pg_sslmode
        pg_sslmode="${pg_sslmode:-disable}"
    fi

    local dsn="host=${pg_host} port=${pg_port} user=${pg_user} password=${pg_password} dbname=${pg_db} sslmode=${pg_sslmode} TimeZone=UTC"

    upsert_env_var "${env_file}" "XUI_DB_DRIVER" "postgres"
    upsert_env_var "${env_file}" "XUI_POSTGRES_DSN" "\"${dsn}\""
    upsert_env_var "${env_file}" "XUI_DB_MAX_IDLE_CONNS" "10"
    upsert_env_var "${env_file}" "XUI_DB_MAX_OPEN_CONNS" "50"

    export XUI_DB_DRIVER="postgres"
    export XUI_POSTGRES_DSN="${dsn}"
    export XUI_DB_MAX_IDLE_CONNS="10"
    export XUI_DB_MAX_OPEN_CONNS="50"

    echo -e "${green}PostgreSQL configuration saved to ${env_file}${plain}"
    echo -e "${green}Database: ${pg_db}${plain}"
    echo -e "${green}User: ${pg_user}${plain}"
    echo -e "${green}Host: ${pg_host}:${pg_port}${plain}"
    if [[ "${pg_mode}" == "1" ]]; then
        echo -e "${yellow}Generated/used DB password: ${pg_password}${plain}"
    fi
    return 0
}

gen_random_string() {
    local length="$1"
    local random_string=$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | fold -w "$length" | head -n 1)
    echo "$random_string"
}

install_acme() {
    echo -e "${green}Installing acme.sh for SSL certificate management...${plain}"
    cd ~ || return 1
    curl -s https://get.acme.sh | sh >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${red}Failed to install acme.sh${plain}"
        return 1
    else
        echo -e "${green}acme.sh installed successfully${plain}"
    fi
    return 0
}

setup_ssl_certificate() {
    local domain="$1"
    local server_ip="$2"
    local existing_port="$3"
    local existing_webBasePath="$4"
    
    echo -e "${green}Setting up SSL certificate...${plain}"
    
    # Check if acme.sh is installed
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
        install_acme
        if [ $? -ne 0 ]; then
            echo -e "${yellow}Failed to install acme.sh, skipping SSL setup${plain}"
            return 1
        fi
    fi
    
    # Create certificate directory
    local certPath="/root/cert/${domain}"
    mkdir -p "$certPath"
    
    # Issue certificate
    echo -e "${green}Issuing SSL certificate for ${domain}...${plain}"
    echo -e "${yellow}Note: Port 80 must be open and accessible from the internet${plain}"
    
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force >/dev/null 2>&1
    ~/.acme.sh/acme.sh --issue -d ${domain} --listen-v6 --standalone --httpport 80 --force
    
    if [ $? -ne 0 ]; then
        echo -e "${yellow}Failed to issue certificate for ${domain}${plain}"
        echo -e "${yellow}Please ensure port 80 is open and try again later with: x-ui${plain}"
        rm -rf ~/.acme.sh/${domain} 2>/dev/null
        rm -rf "$certPath" 2>/dev/null
        return 1
    fi
    
    # Install certificate
    ~/.acme.sh/acme.sh --installcert -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem \
        --reloadcmd "systemctl restart x-ui" >/dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        echo -e "${yellow}Failed to install certificate${plain}"
        return 1
    fi
    
    # Enable auto-renew
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1
    # Secure permissions: private key readable only by owner
    chmod 600 $certPath/privkey.pem 2>/dev/null
    chmod 644 $certPath/fullchain.pem 2>/dev/null
    
    # Set certificate for panel
    local webCertFile="/root/cert/${domain}/fullchain.pem"
    local webKeyFile="/root/cert/${domain}/privkey.pem"
    
    if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
        ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile" >/dev/null 2>&1
        echo -e "${green}SSL certificate installed and configured successfully!${plain}"
        return 0
    else
        echo -e "${yellow}Certificate files not found${plain}"
        return 1
    fi
}

# Issue Let's Encrypt IP certificate with shortlived profile (~6 days validity)
# Requires acme.sh and port 80 open for HTTP-01 challenge
setup_ip_certificate() {
    local ipv4="$1"
    local ipv6="$2"  # optional

    echo -e "${green}Setting up Let's Encrypt IP certificate (shortlived profile)...${plain}"
    echo -e "${yellow}Note: IP certificates are valid for ~6 days and will auto-renew.${plain}"
    echo -e "${yellow}Default listener is port 80. If you choose another port, ensure external port 80 forwards to it.${plain}"

    # Check for acme.sh
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
        install_acme
        if [ $? -ne 0 ]; then
            echo -e "${red}Failed to install acme.sh${plain}"
            return 1
        fi
    fi

    # Validate IP address
    if [[ -z "$ipv4" ]]; then
        echo -e "${red}IPv4 address is required${plain}"
        return 1
    fi

    if ! is_ipv4 "$ipv4"; then
        echo -e "${red}Invalid IPv4 address: $ipv4${plain}"
        return 1
    fi

    # Create certificate directory
    local certDir="/root/cert/ip"
    mkdir -p "$certDir"

    # Build domain arguments
    local domain_args="-d ${ipv4}"
    if [[ -n "$ipv6" ]] && is_ipv6 "$ipv6"; then
        domain_args="${domain_args} -d ${ipv6}"
        echo -e "${green}Including IPv6 address: ${ipv6}${plain}"
    fi

    # Set reload command for auto-renewal (add || true so it doesn't fail during first install)
    local reloadCmd="systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null || true"

    # Choose port for HTTP-01 listener (default 80, prompt override)
    local WebPort=""
    read -rp "Port to use for ACME HTTP-01 listener (default 80): " WebPort
    WebPort="${WebPort:-80}"
    if ! [[ "${WebPort}" =~ ^[0-9]+$ ]] || ((WebPort < 1 || WebPort > 65535)); then
        echo -e "${red}Invalid port provided. Falling back to 80.${plain}"
        WebPort=80
    fi
    echo -e "${green}Using port ${WebPort} for standalone validation.${plain}"
    if [[ "${WebPort}" -ne 80 ]]; then
        echo -e "${yellow}Reminder: Let's Encrypt still connects on port 80; forward external port 80 to ${WebPort}.${plain}"
    fi

    # Ensure chosen port is available
    while true; do
        if is_port_in_use "${WebPort}"; then
            echo -e "${yellow}Port ${WebPort} is in use.${plain}"

            local alt_port=""
            read -rp "Enter another port for acme.sh standalone listener (leave empty to abort): " alt_port
            alt_port="${alt_port// /}"
            if [[ -z "${alt_port}" ]]; then
                echo -e "${red}Port ${WebPort} is busy; cannot proceed.${plain}"
                return 1
            fi
            if ! [[ "${alt_port}" =~ ^[0-9]+$ ]] || ((alt_port < 1 || alt_port > 65535)); then
                echo -e "${red}Invalid port provided.${plain}"
                return 1
            fi
            WebPort="${alt_port}"
            continue
        else
            echo -e "${green}Port ${WebPort} is free and ready for standalone validation.${plain}"
            break
        fi
    done

    # Issue certificate with shortlived profile
    echo -e "${green}Issuing IP certificate for ${ipv4}...${plain}"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force >/dev/null 2>&1
    
    ~/.acme.sh/acme.sh --issue \
        ${domain_args} \
        --standalone \
        --server letsencrypt \
        --certificate-profile shortlived \
        --days 6 \
        --httpport ${WebPort} \
        --force

    if [ $? -ne 0 ]; then
        echo -e "${red}Failed to issue IP certificate${plain}"
        echo -e "${yellow}Please ensure port ${WebPort} is reachable (or forwarded from external port 80)${plain}"
        # Cleanup acme.sh data for both IPv4 and IPv6 if specified
        rm -rf ~/.acme.sh/${ipv4} 2>/dev/null
        [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} 2>/dev/null
        rm -rf ${certDir} 2>/dev/null
        return 1
    fi

    echo -e "${green}Certificate issued successfully, installing...${plain}"

    # Install certificate
    # Note: acme.sh may report "Reload error" and exit non-zero if reloadcmd fails,
    # but the cert files are still installed. We check for files instead of exit code.
    ~/.acme.sh/acme.sh --installcert -d ${ipv4} \
        --key-file "${certDir}/privkey.pem" \
        --fullchain-file "${certDir}/fullchain.pem" \
        --reloadcmd "${reloadCmd}" 2>&1 || true

    # Verify certificate files exist (don't rely on exit code - reloadcmd failure causes non-zero)
    if [[ ! -f "${certDir}/fullchain.pem" || ! -f "${certDir}/privkey.pem" ]]; then
        echo -e "${red}Certificate files not found after installation${plain}"
        # Cleanup acme.sh data for both IPv4 and IPv6 if specified
        rm -rf ~/.acme.sh/${ipv4} 2>/dev/null
        [[ -n "$ipv6" ]] && rm -rf ~/.acme.sh/${ipv6} 2>/dev/null
        rm -rf ${certDir} 2>/dev/null
        return 1
    fi
    
    echo -e "${green}Certificate files installed successfully${plain}"

    # Enable auto-upgrade for acme.sh (ensures cron job runs)
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1

    # Secure permissions: private key readable only by owner
    chmod 600 ${certDir}/privkey.pem 2>/dev/null
    chmod 644 ${certDir}/fullchain.pem 2>/dev/null

    # Configure panel to use the certificate
    echo -e "${green}Setting certificate paths for the panel...${plain}"
    ${xui_folder}/x-ui cert -webCert "${certDir}/fullchain.pem" -webCertKey "${certDir}/privkey.pem"
    
    if [ $? -ne 0 ]; then
        echo -e "${yellow}Warning: Could not set certificate paths automatically${plain}"
        echo -e "${yellow}Certificate files are at:${plain}"
        echo -e "  Cert: ${certDir}/fullchain.pem"
        echo -e "  Key:  ${certDir}/privkey.pem"
    else
        echo -e "${green}Certificate paths configured successfully${plain}"
    fi

    echo -e "${green}IP certificate installed and configured successfully!${plain}"
    echo -e "${green}Certificate valid for ~6 days, auto-renews via acme.sh cron job.${plain}"
    echo -e "${yellow}acme.sh will automatically renew and reload x-ui before expiry.${plain}"
    return 0
}

# Comprehensive manual SSL certificate issuance via acme.sh
ssl_cert_issue() {
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep 'webBasePath:' | awk -F': ' '{print $2}' | tr -d '[:space:]' | sed 's#^/##')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep 'port:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
    
    # check for acme.sh first
    if ! command -v ~/.acme.sh/acme.sh &>/dev/null; then
        echo "acme.sh could not be found. Installing now..."
        cd ~ || return 1
        curl -s https://get.acme.sh | sh
        if [ $? -ne 0 ]; then
            echo -e "${red}Failed to install acme.sh${plain}"
            return 1
        else
            echo -e "${green}acme.sh installed successfully${plain}"
        fi
    fi

    # get the domain here, and we need to verify it
    local domain=""
    while true; do
        read -rp "Please enter your domain name: " domain
        domain="${domain// /}"  # Trim whitespace
        
        if [[ -z "$domain" ]]; then
            echo -e "${red}Domain name cannot be empty. Please try again.${plain}"
            continue
        fi
        
        if ! is_domain "$domain"; then
            echo -e "${red}Invalid domain format: ${domain}. Please enter a valid domain name.${plain}"
            continue
        fi
        
        break
    done
    echo -e "${green}Your domain is: ${domain}, checking it...${plain}"

    # check if there already exists a certificate
    local currentCert=$(~/.acme.sh/acme.sh --list | tail -1 | awk '{print $1}')
    if [ "${currentCert}" == "${domain}" ]; then
        local certInfo=$(~/.acme.sh/acme.sh --list)
        echo -e "${red}System already has certificates for this domain. Cannot issue again.${plain}"
        echo -e "${yellow}Current certificate details:${plain}"
        echo "$certInfo"
        return 1
    else
        echo -e "${green}Your domain is ready for issuing certificates now...${plain}"
    fi

    # create a directory for the certificate
    certPath="/root/cert/${domain}"
    if [ ! -d "$certPath" ]; then
        mkdir -p "$certPath"
    else
        rm -rf "$certPath"
        mkdir -p "$certPath"
    fi

    # get the port number for the standalone server
    local WebPort=80
    read -rp "Please choose which port to use (default is 80): " WebPort
    if [[ ${WebPort} -gt 65535 || ${WebPort} -lt 1 ]]; then
        echo -e "${yellow}Your input ${WebPort} is invalid, will use default port 80.${plain}"
        WebPort=80
    fi
    echo -e "${green}Will use port: ${WebPort} to issue certificates. Please make sure this port is open.${plain}"

    # Stop panel temporarily
    echo -e "${yellow}Stopping panel temporarily...${plain}"
    systemctl stop x-ui 2>/dev/null || rc-service x-ui stop 2>/dev/null

    # issue the certificate
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt --force
    ~/.acme.sh/acme.sh --issue -d ${domain} --listen-v6 --standalone --httpport ${WebPort} --force
    if [ $? -ne 0 ]; then
        echo -e "${red}Issuing certificate failed, please check logs.${plain}"
        rm -rf ~/.acme.sh/${domain}
        systemctl start x-ui 2>/dev/null || rc-service x-ui start 2>/dev/null
        return 1
    else
        echo -e "${green}Issuing certificate succeeded, installing certificates...${plain}"
    fi

    # Setup reload command
    reloadCmd="systemctl restart x-ui || rc-service x-ui restart"
    echo -e "${green}Default --reloadcmd for ACME is: ${yellow}systemctl restart x-ui || rc-service x-ui restart${plain}"
    echo -e "${green}This command will run on every certificate issue and renew.${plain}"
    read -rp "Would you like to modify --reloadcmd for ACME? (y/n): " setReloadcmd
    if [[ "$setReloadcmd" == "y" || "$setReloadcmd" == "Y" ]]; then
        echo -e "\n${green}\t1.${plain} Preset: systemctl reload nginx ; systemctl restart x-ui"
        echo -e "${green}\t2.${plain} Input your own command"
        echo -e "${green}\t0.${plain} Keep default reloadcmd"
        read -rp "Choose an option: " choice
        case "$choice" in
        1)
            echo -e "${green}Reloadcmd is: systemctl reload nginx ; systemctl restart x-ui${plain}"
            reloadCmd="systemctl reload nginx ; systemctl restart x-ui"
            ;;
        2)
            echo -e "${yellow}It's recommended to put x-ui restart at the end${plain}"
            read -rp "Please enter your custom reloadcmd: " reloadCmd
            echo -e "${green}Reloadcmd is: ${reloadCmd}${plain}"
            ;;
        *)
            echo -e "${green}Keeping default reloadcmd${plain}"
            ;;
        esac
    fi

    # install the certificate
    ~/.acme.sh/acme.sh --installcert -d ${domain} \
        --key-file /root/cert/${domain}/privkey.pem \
        --fullchain-file /root/cert/${domain}/fullchain.pem --reloadcmd "${reloadCmd}"

    if [ $? -ne 0 ]; then
        echo -e "${red}Installing certificate failed, exiting.${plain}"
        rm -rf ~/.acme.sh/${domain}
        systemctl start x-ui 2>/dev/null || rc-service x-ui start 2>/dev/null
        return 1
    else
        echo -e "${green}Installing certificate succeeded, enabling auto renew...${plain}"
    fi

    # enable auto-renew
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
    if [ $? -ne 0 ]; then
        echo -e "${yellow}Auto renew setup had issues, certificate details:${plain}"
        ls -lah /root/cert/${domain}/
        # Secure permissions: private key readable only by owner
        chmod 600 $certPath/privkey.pem 2>/dev/null
        chmod 644 $certPath/fullchain.pem 2>/dev/null
    else
        echo -e "${green}Auto renew succeeded, certificate details:${plain}"
        ls -lah /root/cert/${domain}/
        # Secure permissions: private key readable only by owner
        chmod 600 $certPath/privkey.pem 2>/dev/null
        chmod 644 $certPath/fullchain.pem 2>/dev/null
    fi

    # start panel
    systemctl start x-ui 2>/dev/null || rc-service x-ui start 2>/dev/null

    # Prompt user to set panel paths after successful certificate installation
    read -rp "Would you like to set this certificate for the panel? (y/n): " setPanel
    if [[ "$setPanel" == "y" || "$setPanel" == "Y" ]]; then
        local webCertFile="/root/cert/${domain}/fullchain.pem"
        local webKeyFile="/root/cert/${domain}/privkey.pem"

        if [[ -f "$webCertFile" && -f "$webKeyFile" ]]; then
            ${xui_folder}/x-ui cert -webCert "$webCertFile" -webCertKey "$webKeyFile"
            echo -e "${green}Certificate paths set for the panel${plain}"
            echo -e "${green}Certificate File: $webCertFile${plain}"
            echo -e "${green}Private Key File: $webKeyFile${plain}"
            echo ""
            echo -e "${green}Access URL: https://${domain}:${existing_port}/${existing_webBasePath}${plain}"
            echo -e "${yellow}Panel will restart to apply SSL certificate...${plain}"
            systemctl restart x-ui 2>/dev/null || rc-service x-ui restart 2>/dev/null
        else
            echo -e "${red}Error: Certificate or private key file not found for domain: $domain.${plain}"
        fi
    else
        echo -e "${yellow}Skipping panel path setting.${plain}"
    fi
    
    return 0
}

# Reusable interactive SSL setup (domain or IP)
# Sets global `SSL_HOST` to the chosen domain/IP for Access URL usage
prompt_and_setup_ssl() {
    local panel_port="$1"
    local web_base_path="$2"   # expected without leading slash
    local server_ip="$3"

    local ssl_choice=""

    echo -e "${yellow}Choose SSL certificate setup method:${plain}"
    echo -e "${green}1.${plain} Let's Encrypt for Domain (90-day validity, auto-renews)"
    echo -e "${green}2.${plain} Let's Encrypt for IP Address (6-day validity, auto-renews)"
    echo -e "${green}3.${plain} Custom SSL Certificate (Path to existing files)"
    echo -e "${blue}Note:${plain} Options 1 & 2 require port 80 open. Option 3 requires manual paths."
    read -rp "Choose an option (default 2 for IP): " ssl_choice
    ssl_choice="${ssl_choice// /}"  # Trim whitespace
    
    # Default to 2 (IP cert) if input is empty or invalid (not 1 or 3)
    if [[ "$ssl_choice" != "1" && "$ssl_choice" != "3" ]]; then
        ssl_choice="2"
    fi

    case "$ssl_choice" in
    1)
        # User chose Let's Encrypt domain option
        echo -e "${green}Using Let's Encrypt for domain certificate...${plain}"
        ssl_cert_issue
        # Extract the domain that was used from the certificate
        local cert_domain=$(~/.acme.sh/acme.sh --list 2>/dev/null | tail -1 | awk '{print $1}')
        if [[ -n "${cert_domain}" ]]; then
            SSL_HOST="${cert_domain}"
            echo -e "${green}✓ SSL certificate configured successfully with domain: ${cert_domain}${plain}"
        else
            echo -e "${yellow}SSL setup may have completed, but domain extraction failed${plain}"
            SSL_HOST="${server_ip}"
        fi
        ;;
    2)
        # User chose Let's Encrypt IP certificate option
        echo -e "${green}Using Let's Encrypt for IP certificate (shortlived profile)...${plain}"
        
        # Ask for optional IPv6
        local ipv6_addr=""
        read -rp "Do you have an IPv6 address to include? (leave empty to skip): " ipv6_addr
        ipv6_addr="${ipv6_addr// /}"  # Trim whitespace
        
        # Stop panel if running (port 80 needed)
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop >/dev/null 2>&1
        else
            systemctl stop x-ui >/dev/null 2>&1
        fi
        
        setup_ip_certificate "${server_ip}" "${ipv6_addr}"
        if [ $? -eq 0 ]; then
            SSL_HOST="${server_ip}"
            echo -e "${green}✓ Let's Encrypt IP certificate configured successfully${plain}"
        else
            echo -e "${red}✗ IP certificate setup failed. Please check port 80 is open.${plain}"
            SSL_HOST="${server_ip}"
        fi
        ;;
    3)
        # User chose Custom Paths (User Provided) option
        echo -e "${green}Using custom existing certificate...${plain}"
        local custom_cert=""
        local custom_key=""
        local custom_domain=""

        # 3.1 Request Domain to compose Panel URL later
        read -rp "Please enter domain name certificate issued for: " custom_domain
        custom_domain="${custom_domain// /}" # Убираем пробелы

        # 3.2 Loop for Certificate Path
        while true; do
            read -rp "Input certificate path (keywords: .crt / fullchain): " custom_cert
            # Strip quotes if present
            custom_cert=$(echo "$custom_cert" | tr -d '"' | tr -d "'")

            if [[ -f "$custom_cert" && -r "$custom_cert" && -s "$custom_cert" ]]; then
                break
            elif [[ ! -f "$custom_cert" ]]; then
                echo -e "${red}Error: File does not exist! Try again.${plain}"
            elif [[ ! -r "$custom_cert" ]]; then
                echo -e "${red}Error: File exists but is not readable (check permissions)!${plain}"
            else
                echo -e "${red}Error: File is empty!${plain}"
            fi
        done

        # 3.3 Loop for Private Key Path
        while true; do
            read -rp "Input private key path (keywords: .key / privatekey): " custom_key
            # Strip quotes if present
            custom_key=$(echo "$custom_key" | tr -d '"' | tr -d "'")

            if [[ -f "$custom_key" && -r "$custom_key" && -s "$custom_key" ]]; then
                break
            elif [[ ! -f "$custom_key" ]]; then
                echo -e "${red}Error: File does not exist! Try again.${plain}"
            elif [[ ! -r "$custom_key" ]]; then
                echo -e "${red}Error: File exists but is not readable (check permissions)!${plain}"
            else
                echo -e "${red}Error: File is empty!${plain}"
            fi
        done

        # 3.4 Apply Settings via x-ui binary
        ${xui_folder}/x-ui cert -webCert "$custom_cert" -webCertKey "$custom_key" >/dev/null 2>&1
        
        # Set SSL_HOST for composing Panel URL
        if [[ -n "$custom_domain" ]]; then
            SSL_HOST="$custom_domain"
        else
            SSL_HOST="${server_ip}"
        fi

        echo -e "${green}✓ Custom certificate paths applied.${plain}"
        echo -e "${yellow}Note: You are responsible for renewing these files externally.${plain}"

        systemctl restart x-ui >/dev/null 2>&1 || rc-service x-ui restart >/dev/null 2>&1
        ;;
    *)
        echo -e "${red}Invalid option. Skipping SSL setup.${plain}"
        SSL_HOST="${server_ip}"
        ;;
    esac
}

config_after_install() {
    local existing_hasDefaultCredential=$(${xui_folder}/x-ui setting -show true | grep -Eo 'hasDefaultCredential: .+' | awk '{print $2}')
    local existing_webBasePath=$(${xui_folder}/x-ui setting -show true | grep -Eo 'webBasePath: .+' | awk '{print $2}' | sed 's#^/##')
    local existing_port=$(${xui_folder}/x-ui setting -show true | grep -Eo 'port: .+' | awk '{print $2}')
    # Properly detect empty cert by checking if cert: line exists and has content after it
    local existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')

    # ── NEW: offer to keep existing DB settings as-is ──────────────────────────
    # If the database already has custom credentials AND a proper webBasePath we
    # assume it was previously configured and ask the user what they want to do.
    if [[ "$existing_hasDefaultCredential" == "false" && ${#existing_webBasePath} -ge 4 ]]; then
        echo ""
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${green}   Existing configuration found in DB      ${plain}"
        echo -e "${green}═══════════════════════════════════════════${plain}"
        echo -e "${yellow}Port:        ${existing_port}${plain}"
        echo -e "${yellow}WebBasePath: /${existing_webBasePath}${plain}"
        if [[ -n "${existing_cert}" ]]; then
            echo -e "${yellow}SSL cert:    ${existing_cert}${plain}"
        else
            echo -e "${yellow}SSL cert:    not configured${plain}"
        fi
        echo ""
        read -rp "Use existing settings from the database without changes? [y/n]: " use_existing
        if [[ "${use_existing}" == "y" || "${use_existing}" == "Y" ]]; then
            echo -e "${green}Keeping existing database settings.${plain}"
            # Determine access URL
            local URL_lists_tmp=(
                "https://api4.ipify.org"
                "https://ipv4.icanhazip.com"
                "https://v4.api.ipinfo.io/ip"
            )
            local server_ip_tmp=""
            for ip_address in "${URL_lists_tmp[@]}"; do
                local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2>/dev/null)
                local http_code=$(echo "$response" | tail -n1)
                local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]')
                if [[ "${http_code}" == "200" && -n "${ip_result}" ]]; then
                    server_ip_tmp="${ip_result}"
                    break
                fi
            done
            local proto="https"
            [[ -z "${existing_cert}" ]] && proto="http"
            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     Panel is ready!                       ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}Access URL:  ${proto}://${server_ip_tmp}:${existing_port}/${existing_webBasePath}${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            ${xui_folder}/x-ui migrate
            return 0
        fi
        echo -e "${yellow}Proceeding with new configuration...${plain}"
    fi
    # ── end NEW ─────────────────────────────────────────────────────────────────

    local URL_lists=(
        "https://api4.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://v4.api.ipinfo.io/ip"
        "https://ipv4.myexternalip.com/raw"
        "https://4.ident.me"
        "https://check-host.net/ip"
    )
    local server_ip=""
    for ip_address in "${URL_lists[@]}"; do
        local response=$(curl -s -w "\n%{http_code}" --max-time 3 "${ip_address}" 2>/dev/null)
        local http_code=$(echo "$response" | tail -n1)
        local ip_result=$(echo "$response" | head -n-1 | tr -d '[:space:]')
        if [[ "${http_code}" == "200" && -n "${ip_result}" ]]; then
            server_ip="${ip_result}"
            break
        fi
    done
    
    if [[ ${#existing_webBasePath} -lt 4 ]]; then
        if [[ "$existing_hasDefaultCredential" == "true" ]]; then
            local config_webBasePath=$(gen_random_string 18)
            local config_username=$(gen_random_string 10)
            local config_password=$(gen_random_string 10)
            
            read -rp "Would you like to customize the Panel Port settings? (If not, a random port will be applied) [y/n]: " config_confirm
            if [[ "${config_confirm}" == "y" || "${config_confirm}" == "Y" ]]; then
                read -rp "Please set up the panel port: " config_port
                echo -e "${yellow}Your Panel Port is: ${config_port}${plain}"
            else
                local config_port=$(shuf -i 1024-62000 -n 1)
                echo -e "${yellow}Generated random port: ${config_port}${plain}"
            fi
            
            ${xui_folder}/x-ui setting -username "${config_username}" -password "${config_password}" -port "${config_port}" -webBasePath "${config_webBasePath}"
            
            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     SSL Certificate Setup (MANDATORY)     ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${yellow}For security, SSL certificate is required for all panels.${plain}"
            echo -e "${yellow}Let's Encrypt now supports both domains and IP addresses!${plain}"
            echo ""

            prompt_and_setup_ssl "${config_port}" "${config_webBasePath}" "${server_ip}"
            
            # Display final credentials and access information
            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     Panel Installation Complete!         ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}Username:    ${config_username}${plain}"
            echo -e "${green}Password:    ${config_password}${plain}"
            echo -e "${green}Port:        ${config_port}${plain}"
            echo -e "${green}WebBasePath: ${config_webBasePath}${plain}"
            echo -e "${green}Access URL:  https://${SSL_HOST}:${config_port}/${config_webBasePath}${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${yellow}⚠ IMPORTANT: Save these credentials securely!${plain}"
            echo -e "${yellow}⚠ SSL Certificate: Enabled and configured${plain}"
        else
            local config_webBasePath=$(gen_random_string 18)
            echo -e "${yellow}WebBasePath is missing or too short. Generating a new one...${plain}"
            ${xui_folder}/x-ui setting -webBasePath "${config_webBasePath}"
            echo -e "${green}New WebBasePath: ${config_webBasePath}${plain}"

            # If the panel is already installed but no certificate is configured, prompt for SSL now
            if [[ -z "${existing_cert}" ]]; then
                echo ""
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${green}     SSL Certificate Setup (RECOMMENDED)   ${plain}"
                echo -e "${green}═══════════════════════════════════════════${plain}"
                echo -e "${yellow}Let's Encrypt now supports both domains and IP addresses!${plain}"
                echo ""
                prompt_and_setup_ssl "${existing_port}" "${config_webBasePath}" "${server_ip}"
                echo -e "${green}Access URL:  https://${SSL_HOST}:${existing_port}/${config_webBasePath}${plain}"
            else
                # If a cert already exists, just show the access URL
                echo -e "${green}Access URL: https://${server_ip}:${existing_port}/${config_webBasePath}${plain}"
            fi
        fi
    else
        if [[ "$existing_hasDefaultCredential" == "true" ]]; then
            local config_username=$(gen_random_string 10)
            local config_password=$(gen_random_string 10)
            
            echo -e "${yellow}Default credentials detected. Security update required...${plain}"
            ${xui_folder}/x-ui setting -username "${config_username}" -password "${config_password}"
            echo -e "Generated new random login credentials:"
            echo -e "###############################################"
            echo -e "${green}Username: ${config_username}${plain}"
            echo -e "${green}Password: ${config_password}${plain}"
            echo -e "###############################################"
        else
            echo -e "${green}Username, Password, and WebBasePath are properly set.${plain}"
        fi

        # Existing install: if no cert configured, prompt user for SSL setup
        # Properly detect empty cert by checking if cert: line exists and has content after it
        existing_cert=$(${xui_folder}/x-ui setting -getCert true | grep 'cert:' | awk -F': ' '{print $2}' | tr -d '[:space:]')
        if [[ -z "$existing_cert" ]]; then
            echo ""
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${green}     SSL Certificate Setup (RECOMMENDED)   ${plain}"
            echo -e "${green}═══════════════════════════════════════════${plain}"
            echo -e "${yellow}Let's Encrypt now supports both domains and IP addresses!${plain}"
            echo ""
            prompt_and_setup_ssl "${existing_port}" "${existing_webBasePath}" "${server_ip}"
            echo -e "${green}Access URL:  https://${SSL_HOST}:${existing_port}/${existing_webBasePath}${plain}"
        else
            echo -e "${green}SSL certificate already configured. No action needed.${plain}"
        fi
    fi
    
    ${xui_folder}/x-ui migrate
}

_install_go() {
    echo -e "${yellow}Go not found, installing...${plain}"
    case "${release}" in
        ubuntu | debian | armbian)
            apt-get install -y -q golang
        ;;
        fedora | amzn | virtuozzo | rhel | almalinux | rocky | ol | centos)
            dnf install -y -q golang 2>/dev/null || yum install -y golang
        ;;
        arch | manjaro | parch)
            pacman -Sy --noconfirm go
        ;;
        alpine)
            apk add --no-cache go
        ;;
        *)
            apt-get install -y -q golang
        ;;
    esac
    if ! command -v go &>/dev/null; then
        echo -e "${red}Failed to install Go. Please install it manually and re-run.${plain}"
        exit 1
    fi
}

# download_with_retry <url> <dest> [max_attempts]
# Downloads a file with automatic retry on failure.
download_with_retry() {
    local url="$1"
    local dest="$2"
    local max_attempts="${3:-5}"
    local attempt=1
    while [[ ${attempt} -le ${max_attempts} ]]; do
        echo -e "${yellow}Downloading (attempt ${attempt}/${max_attempts}): ${url}${plain}"
        if curl -fLRo "${dest}" --connect-timeout 15 --retry 3 --retry-delay 3 "${url}"; then
            return 0
        fi
        echo -e "${red}Attempt ${attempt} failed, retrying...${plain}"
        sleep 3
        ((attempt++))
    done
    echo -e "${red}Failed to download after ${max_attempts} attempts: ${url}${plain}"
    return 1
}

_download_xray() {
    local xray_version="${1:-v26.2.6}"
    local xray_arch xray_fname
    case "$(arch)" in
        amd64)  xray_arch="64";        xray_fname="amd64" ;;
        386)    xray_arch="32";        xray_fname="i386"  ;;
        arm64)  xray_arch="arm64-v8a"; xray_fname="arm64" ;;
        armv7)  xray_arch="arm32-v7a"; xray_fname="arm32" ;;
        armv6)  xray_arch="arm32-v6";  xray_fname="armv6" ;;
        *)      xray_arch="64";        xray_fname="amd64" ;;
    esac

    local dest_dir="${1:+${xui_folder}/bin}"
    [[ -z "${dest_dir}" ]] && dest_dir="${xui_folder}/bin"
    # Allow caller to override dest via second arg
    [[ -n "$2" ]] && dest_dir="$2"

    echo -e "${green}Downloading xray-core ${xray_version} (${xray_fname})...${plain}"
    mkdir -p "${dest_dir}"

    download_with_retry \
        "https://github.com/XTLS/Xray-core/releases/download/${xray_version}/Xray-linux-${xray_arch}.zip" \
        /tmp/xray.zip || return 1

    unzip -o /tmp/xray.zip xray -d /tmp/xray-bin/ >/dev/null
    mv -f /tmp/xray-bin/xray "${dest_dir}/xray-linux-${xray_fname}"
    chmod +x "${dest_dir}/xray-linux-${xray_fname}"
    rm -rf /tmp/xray.zip /tmp/xray-bin/

    echo -e "${green}xray-core downloaded: ${dest_dir}/xray-linux-${xray_fname}${plain}"
    XUI_XRAY_FNAME="${xray_fname}"
    return 0
}

_ensure_xray() {
    # Checks if xray binary is present in xui_folder/bin; downloads if missing.
    local xray_version="${XRAY_VERSION:-v26.2.6}"
    local xray_fname
    case "$(arch)" in
        amd64)  xray_fname="amd64" ;;
        386)    xray_fname="i386"  ;;
        arm64)  xray_fname="arm64" ;;
        armv7)  xray_fname="arm32" ;;
        armv6)  xray_fname="armv6" ;;
        *)      xray_fname="amd64" ;;
    esac

    local xray_bin="${xui_folder}/bin/xray-linux-${xray_fname}"
    if [[ -x "${xray_bin}" ]]; then
        echo -e "${green}xray-core already present: ${xray_bin}${plain}"
        XUI_XRAY_FNAME="${xray_fname}"
        return 0
    fi

    echo -e "${yellow}xray-core not found, downloading automatically...${plain}"
    _download_xray "${xray_version}" "${xui_folder}/bin" || {
        echo -e "${red}Failed to download xray-core. Please check your internet connection.${plain}"
        return 1
    }
}

_build_x-ui() {
    echo -e "${green}Building x-ui from source: ${SCRIPT_DIR}${plain}"

    command -v go &>/dev/null || _install_go

    cd "${SCRIPT_DIR}"
    CGO_ENABLED=1 CGO_CFLAGS="-D_LARGEFILE64_SOURCE" \
        go build -ldflags "-w -s" -o build/x-ui main.go
    if [[ $? -ne 0 ]]; then
        echo -e "${red}Build failed. Check Go errors above.${plain}"
        exit 1
    fi

    local XRAY_VERSION="v26.2.6"
    local xray_arch xray_fname
    case "$(arch)" in
        amd64)  xray_arch="64";        xray_fname="amd64" ;;
        386)    xray_arch="32";        xray_fname="i386"  ;;
        arm64)  xray_arch="arm64-v8a"; xray_fname="arm64" ;;
        armv7)  xray_arch="arm32-v7a"; xray_fname="arm32" ;;
        armv6)  xray_arch="arm32-v6";  xray_fname="armv6" ;;
        *)      xray_arch="64";        xray_fname="amd64" ;;
    esac

    mkdir -p "${SCRIPT_DIR}/build/bin"

    download_with_retry \
        "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${xray_arch}.zip" \
        /tmp/xray.zip || { echo -e "${red}Failed to download xray-core${plain}"; exit 1; }

    unzip -o /tmp/xray.zip xray -d /tmp/xray-bin/ >/dev/null
    mv -f /tmp/xray-bin/xray "${SCRIPT_DIR}/build/bin/xray-linux-${xray_fname}"
    chmod +x "${SCRIPT_DIR}/build/bin/xray-linux-${xray_fname}"
    rm -rf /tmp/xray.zip /tmp/xray-bin/
    echo -e "${green}xray-core ${XRAY_VERSION} downloaded successfully.${plain}"

    echo -e "${green}Downloading geo data...${plain}"
    cd "${SCRIPT_DIR}/build/bin"
    download_with_retry https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat      geoip.dat
    download_with_retry https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat    geosite.dat
    download_with_retry https://github.com/chocolate4u/Iran-v2ray-rules/releases/latest/download/geoip.dat      geoip_IR.dat
    download_with_retry https://github.com/chocolate4u/Iran-v2ray-rules/releases/latest/download/geosite.dat    geosite_IR.dat
    download_with_retry https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat   geoip_RU.dat
    download_with_retry https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat geosite_RU.dat

    # export fname so caller can use it
    XUI_XRAY_FNAME="${xray_fname}"
    cd "${SCRIPT_DIR}"
}

install_x-ui() {
    _build_x-ui

    cd ${xui_folder%/x-ui}/

    # Stop x-ui service and remove old resources
    if [[ -e ${xui_folder}/ ]]; then
        if [[ $release == "alpine" ]]; then
            rc-service x-ui stop
        else
            systemctl stop x-ui
        fi
        rm ${xui_folder}/ -rf
    fi
    
    # Install built artifacts to xui_folder
    echo -e "${green}Installing x-ui to ${xui_folder}...${plain}"
    mkdir -p "${xui_folder}/bin"
    cp -f "${SCRIPT_DIR}/build/x-ui"                                "${xui_folder}/x-ui"
    cp -f "${SCRIPT_DIR}/build/bin/xray-linux-${XUI_XRAY_FNAME}"   "${xui_folder}/bin/"
    cp -f "${SCRIPT_DIR}/build/bin/"*.dat                           "${xui_folder}/bin/" 2>/dev/null || true
    cp -f "${SCRIPT_DIR}/x-ui.sh"                                   "${xui_folder}/x-ui.sh"
    cp -f "${SCRIPT_DIR}/x-ui.service.debian"                       "${xui_folder}/" 2>/dev/null || true
    cp -f "${SCRIPT_DIR}/x-ui.service.arch"                         "${xui_folder}/" 2>/dev/null || true
    cp -f "${SCRIPT_DIR}/x-ui.service.rhel"                         "${xui_folder}/" 2>/dev/null || true
    cp -f "${SCRIPT_DIR}/x-ui.rc"                                   "${xui_folder}/" 2>/dev/null || true

    cd "${xui_folder}"

    # Rename xray binary for arm variants
    if [[ $(arch) == "armv5" || $(arch) == "armv6" || $(arch) == "armv7" ]]; then
        mv "bin/xray-linux-${XUI_XRAY_FNAME}" bin/xray-linux-arm
        chmod +x bin/xray-linux-arm
    fi
    chmod +x x-ui x-ui.sh "bin/xray-linux-${XUI_XRAY_FNAME}" 2>/dev/null || true

    # Verify xray binary is present; auto-download if missing (e.g. connection dropped during build)
    _ensure_xray || {
        echo -e "${red}xray-core could not be installed. Panel will start but xray will not run.${plain}"
    }

    # Install x-ui management CLI
    cp -f "${SCRIPT_DIR}/x-ui.sh" /usr/bin/x-ui
    chmod +x /usr/bin/x-ui
    mkdir -p /var/log/x-ui
    configure_database_env
    if [[ $? -ne 0 ]]; then
        echo -e "${red}Database configuration failed.${plain}"
        exit 1
    fi
    config_after_install

    # Etckeeper compatibility
    if [ -d "/etc/.git" ]; then
        if [ -f "/etc/.gitignore" ]; then
            if ! grep -q "x-ui/x-ui.db" "/etc/.gitignore"; then
                echo "" >> "/etc/.gitignore"
                echo "x-ui/x-ui.db" >> "/etc/.gitignore"
                echo -e "${green}Added x-ui.db to /etc/.gitignore for etckeeper${plain}"
            fi
        else
            echo "x-ui/x-ui.db" > "/etc/.gitignore"
            echo -e "${green}Created /etc/.gitignore and added x-ui.db for etckeeper${plain}"
        fi
    fi
    
    if [[ $release == "alpine" ]]; then
        cp -f "${SCRIPT_DIR}/x-ui.rc" /etc/init.d/x-ui
        if [[ $? -ne 0 ]]; then
            echo -e "${red}Failed to install x-ui.rc from source${plain}"
            exit 1
        fi
        chmod +x /etc/init.d/x-ui
        rc-update add x-ui
        rc-service x-ui start
    else
        # Install systemd service file
        service_installed=false
        
        if [ -f "x-ui.service" ]; then
            echo -e "${green}Found x-ui.service in extracted files, installing...${plain}"
            cp -f x-ui.service ${xui_service}/ >/dev/null 2>&1
            if [[ $? -eq 0 ]]; then
                service_installed=true
            fi
        fi
        
        if [ "$service_installed" = false ]; then
            case "${release}" in
                ubuntu | debian | armbian)
                    if [ -f "x-ui.service.debian" ]; then
                        echo -e "${green}Found x-ui.service.debian in extracted files, installing...${plain}"
                        cp -f x-ui.service.debian ${xui_service}/x-ui.service >/dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                ;;
                arch | manjaro | parch)
                    if [ -f "x-ui.service.arch" ]; then
                        echo -e "${green}Found x-ui.service.arch in extracted files, installing...${plain}"
                        cp -f x-ui.service.arch ${xui_service}/x-ui.service >/dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                ;;
                *)
                    if [ -f "x-ui.service.rhel" ]; then
                        echo -e "${green}Found x-ui.service.rhel in extracted files, installing...${plain}"
                        cp -f x-ui.service.rhel ${xui_service}/x-ui.service >/dev/null 2>&1
                        if [[ $? -eq 0 ]]; then
                            service_installed=true
                        fi
                    fi
                ;;
            esac
        fi
        
        # If service file not found in install dir, copy from source
        if [ "$service_installed" = false ]; then
            echo -e "${yellow}Copying service file from source...${plain}"
            case "${release}" in
                ubuntu | debian | armbian)
                    cp -f "${SCRIPT_DIR}/x-ui.service.debian" ${xui_service}/x-ui.service >/dev/null 2>&1
                ;;
                arch | manjaro | parch)
                    cp -f "${SCRIPT_DIR}/x-ui.service.arch" ${xui_service}/x-ui.service >/dev/null 2>&1
                ;;
                *)
                    cp -f "${SCRIPT_DIR}/x-ui.service.rhel" ${xui_service}/x-ui.service >/dev/null 2>&1
                ;;
            esac

            if [[ $? -ne 0 ]]; then
                echo -e "${red}Failed to install x-ui.service from source${plain}"
                exit 1
            fi
            service_installed=true
        fi
        
        if [ "$service_installed" = true ]; then
            echo -e "${green}Setting up systemd unit...${plain}"
            chown root:root ${xui_service}/x-ui.service >/dev/null 2>&1
            chmod 644 ${xui_service}/x-ui.service >/dev/null 2>&1
            systemctl daemon-reload
            systemctl enable x-ui
            systemctl start x-ui
        else
            echo -e "${red}Failed to install x-ui.service file${plain}"
            exit 1
        fi
    fi
    
    echo -e "${green}x-ui${plain} installation finished, it is running now..."
    echo -e ""
    echo -e "┌───────────────────────────────────────────────────────┐
│  ${blue}x-ui control menu usages (subcommands):${plain}              │
│                                                       │
│  ${blue}x-ui${plain}              - Admin Management Script          │
│  ${blue}x-ui start${plain}        - Start                            │
│  ${blue}x-ui stop${plain}         - Stop                             │
│  ${blue}x-ui restart${plain}      - Restart                          │
│  ${blue}x-ui status${plain}       - Current Status                   │
│  ${blue}x-ui settings${plain}     - Current Settings                 │
│  ${blue}x-ui enable${plain}       - Enable Autostart on OS Startup   │
│  ${blue}x-ui disable${plain}      - Disable Autostart on OS Startup  │
│  ${blue}x-ui log${plain}          - Check logs                       │
│  ${blue}x-ui banlog${plain}       - Check Fail2ban ban logs          │
│  ${blue}x-ui update${plain}       - Update                           │
│  ${blue}x-ui legacy${plain}       - Legacy version                   │
│  ${blue}x-ui install${plain}      - Install                          │
│  ${blue}x-ui uninstall${plain}    - Uninstall                        │
└───────────────────────────────────────────────────────┘"
}

echo -e "${green}Running...${plain}"
install_base
install_x-ui $1
