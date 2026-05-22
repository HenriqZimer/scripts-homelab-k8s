#!/bin/bash

# Talos OS - Script Unificado Completo
# Menu interativo para: Setup, Atualização e Upgrade de clusters
# Autor: SRE Script - Versão Unificada
# Versão: 3.0 - Menu Interativo com Extensions

set -e

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Funções de print
print_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
print_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_step() { echo -e "${CYAN}[STEP]${NC} $1"; }
print_menu() { echo -e "${MAGENTA}$1${NC}"; }

# Backoff por etapa (base/cap em segundos)
BACKOFF_CONNECT_BASE=3
BACKOFF_CONNECT_CAP=15
BACKOFF_APPLY_BASE=5
BACKOFF_APPLY_CAP=30
BACKOFF_WAIT_NODE_BASE=5
BACKOFF_WAIT_NODE_CAP=20
BACKOFF_BOOTSTRAP_CONNECT_BASE=5
BACKOFF_BOOTSTRAP_CONNECT_CAP=30
BACKOFF_BOOTSTRAP_RETRY_BASE=10
BACKOFF_BOOTSTRAP_RETRY_CAP=60
BACKOFF_KUBEAPI_BASE=5
BACKOFF_KUBEAPI_CAP=45
BACKOFF_ROLE_BASE=5
BACKOFF_ROLE_CAP=30
BACKOFF_PLUGIN_BASE=2
BACKOFF_PLUGIN_CAP=10
BACKOFF_PLUGIN_INIT_BASE=20
BACKOFF_PLUGIN_INIT_CAP=20
BACKOFF_STEP_BASE=3
BACKOFF_STEP_CAP=20
BACKOFF_UPGRADE_BASE=5
BACKOFF_UPGRADE_CAP=30
BACKOFF_MENU_BASE=2
BACKOFF_MENU_CAP=2
BACKOFF_PING_BASE=3
BACKOFF_PING_CAP=15
BACKOFF_HEALTH_BASE=10
BACKOFF_HEALTH_CAP=60
BACKOFF_K8S_APPEAR_BASE=5
BACKOFF_K8S_APPEAR_CAP=45

STEP_TOTAL=0
STEP_INDEX=0

# Backoff exponencial simples (segundos)
backoff_delay() {
    local attempt=$1
    local base=${2:-5}
    local cap=${3:-60}
    local delay=$((base * (2 ** (attempt - 1))))
    if [[ $delay -gt $cap ]]; then
        delay=$cap
    fi
    echo "$delay"
}

sleep_backoff() {
    local attempt=$1
    local base=${2:-2}
    local cap=${3:-20}
    local delay
    delay=$(backoff_delay "$attempt" "$base" "$cap")
    sleep "$delay"
}

normalize_yes_no() {
    local value
    value=$(echo "$1" | tr '[:upper:]' '[:lower:]')
    case "$value" in
        y|yes) echo "y" ;;
        n|no) echo "n" ;;
        *) return 1 ;;
    esac
}

is_yes() {
    local normalized
    normalized=$(normalize_yes_no "$1") || return 1
    [[ "$normalized" == "y" ]]
}

ask_yes_no() {
    local prompt=$1
    local default=${2:-""}
    local reply

    while true; do
        read -p "$prompt" reply
        if [[ -z "$reply" && -n "$default" ]]; then
            reply="$default"
        fi

        if reply=$(normalize_yes_no "$reply"); then
            echo "$reply"
            return 0
        fi

        print_error "Responda com y ou n."
    done
}

ask_required() {
    local prompt=$1
    local -n out=$2
    local value=""

    while [[ -z "$value" ]]; do
        read -p "$prompt" value
        if [[ -z "$value" ]]; then
            print_error "Campo obrigatório."
        fi
    done

    out="$value"
}

start_steps() {
    STEP_TOTAL=$1
    STEP_INDEX=0
}

next_step() {
    local message=$1
    STEP_INDEX=$((STEP_INDEX + 1))
    print_step "Etapa ${STEP_INDEX}/${STEP_TOTAL} - ${message}"
}

print_flow_steps() {
    local title=$1
    shift
    local steps=("$@")
    local total=${#steps[@]}
    local i=1

    print_info "$title"
    for step in "${steps[@]}"; do
        print_info "Etapa ${i}/${total}: $step"
        i=$((i + 1))
    done
    echo
}

find_original_config() {
    local kind=$1
    local cluster_name=$2
    local endpoint=$3
    local config_file="${kind}.yaml"
    local cluster_dir=""
    local config_path=""

    for potential_dir in "$cluster_name" "k8s-$cluster_name" "${cluster_name}-cluster"; do
        if [[ -d "$potential_dir" ]] && [[ -f "$potential_dir/$config_file" ]]; then
            cluster_dir="$potential_dir"
            config_path="$potential_dir/$config_file"
            break
        fi
    done

    if [[ -z "$config_path" ]]; then
        local endpoint_dir=""
        endpoint_dir=$(find_cluster_dir_by_endpoint "$endpoint") || true
        if [[ -n "$endpoint_dir" ]] && [[ -f "$endpoint_dir/$config_file" ]]; then
            cluster_dir="$endpoint_dir"
            config_path="$endpoint_dir/$config_file"
        fi
    fi

    if [[ -n "$config_path" ]]; then
        echo "$cluster_dir|$config_path"
        return 0
    fi

    return 1
}

apply_plugins_for_node() {
    local node_ip=$1
    local cluster_dir=$2
    local node_label=$3
    local talosconfig_path=""
    local plugin_files=()

    if [[ -f "$cluster_dir/talosconfig" ]]; then
        talosconfig_path="$cluster_dir/talosconfig"
    fi

    [[ -f "$cluster_dir/tailscale.yaml" ]] && plugin_files+=("tailscale:$cluster_dir/tailscale.yaml")
    [[ -f "$cluster_dir/cloudflare.yaml" ]] && plugin_files+=("cloudflared:$cluster_dir/cloudflare.yaml")

    if [[ ${#plugin_files[@]} -eq 0 ]]; then
        return 0
    fi

    echo
    local apply_plugins
    apply_plugins=$(ask_yes_no "Aplicar configuracoes de plugins no novo no? (y/n) [n]: " "n")

    if [[ "$apply_plugins" != "y" ]]; then
        return 0
    fi

    print_step "Aplicando plugins no novo ${node_label}..."
    for item in "${plugin_files[@]}"; do
        local name="${item%%:*}"
        local file="${item#*:}"
        apply_plugin_to_node "$name" "$file" "$node_ip" "$talosconfig_path"
    done
}

wait_node_health() {
    local node_ip=$1
    local node_label=$2
    local max_attempts=6
    local attempt=1

    print_info "Verificando status do novo ${node_label}..."
    while [[ $attempt -le $max_attempts ]]; do
        if timeout 30 talosctl --nodes "$node_ip" health --server=false >/dev/null 2>&1; then
            print_success "✅ ${node_label} $node_ip está saudável!"
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            local delay
            delay=$(backoff_delay "$attempt" "$BACKOFF_HEALTH_BASE" "$BACKOFF_HEALTH_CAP")
            print_info "Nó ainda está inicializando... aguardando ${delay}s"
            sleep "$delay"
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

wait_node_in_k8s() {
    local node_ip=$1
    local max_attempts=6
    local attempt=1

    print_info "Aguardando o nó aparecer no Kubernetes..."
    while [[ $attempt -le $max_attempts ]]; do
        if kubectl get nodes -o wide 2>/dev/null | grep -q "$node_ip"; then
            return 0
        fi
        if [[ $attempt -lt $max_attempts ]]; then
            local delay
            delay=$(backoff_delay "$attempt" "$BACKOFF_K8S_APPEAR_BASE" "$BACKOFF_K8S_APPEAR_CAP")
            sleep "$delay"
        fi
        attempt=$((attempt + 1))
    done

    return 1
}

# Função para validar IP
validate_ip() {
    local ip=$1
    if [[ ! $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 1
    fi
    IFS='.' read -ra octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if [[ $octet -lt 0 || $octet -gt 255 ]]; then
            return 1
        fi
    done
    return 0
}

# Função para processar lista de IPs
process_ips() {
    local input=$1
    local -n result_array=$2
    local processed=$(echo "$input" | sed 's/[,]/ /g' | tr -s ' ')
    IFS=' ' read -ra temp_array <<< "$processed"
    for ip in "${temp_array[@]}"; do
        if validate_ip "$ip"; then
            result_array+=("$ip")
        else
            print_error "IP inválido: $ip"
            return 1
        fi
    done
    return 0
}

# Função para verificar se talosctl está instalado
check_talosctl() {
    if ! command -v talosctl &> /dev/null; then
        print_error "talosctl não está instalado ou não está no PATH"
        print_info "Para instalar o talosctl, visite: https://docs.siderolabs.com/talos/v1.12/talos-guides/install/talosctl/"
        exit 1
    fi
    local version=$(talosctl version --client --short)
    print_success "talosctl encontrado: $version"
}

# Função para testar conectividade com um nó
test_node_connectivity() {
    local ip=$1
    local timeout=5
    local max_attempts=3
    local attempt=1
    print_info "Testando conectividade com $ip..."
    while [[ $attempt -le $max_attempts ]]; do
        if timeout $timeout bash -c "cat < /dev/null > /dev/tcp/$ip/22" 2>/dev/null; then
            print_success "Conectividade SSH OK para $ip"
            return 0
        elif timeout $timeout bash -c "cat < /dev/null > /dev/tcp/$ip/50000" 2>/dev/null; then
            print_success "Conectividade Talos OK para $ip"
            return 0
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            local delay
            delay=$(backoff_delay "$attempt" "$BACKOFF_CONNECT_BASE" "$BACKOFF_CONNECT_CAP")
            print_warning "Sem conectividade para $ip. Tentando novamente em ${delay}s..."
            sleep "$delay"
        fi

        attempt=$((attempt + 1))
    done

    print_warning "Sem conectividade para $ip (isso é normal se o nó ainda não estiver configurado)"
    return 1
}

# Função para aplicar configuração em um nó
apply_config_to_node() {
    local node_ip=$1
    local config_file=$2
    local node_type=$3
    local max_attempts=3

    print_step "Aplicando configuração $node_type no nó $node_ip..."

    for attempt in $(seq 1 $max_attempts); do
        print_info "Tentativa $attempt/$max_attempts para $node_ip"
        if talosctl apply-config --insecure --nodes "$node_ip" --file "$config_file" --timeout=30s; then
            print_success "Configuração aplicada com sucesso no nó $node_ip"
            return 0
        else
            if [[ $attempt -lt $max_attempts ]]; then
                local delay
                delay=$(backoff_delay "$attempt" "$BACKOFF_APPLY_BASE" "$BACKOFF_APPLY_CAP")
                print_warning "Falha na tentativa $attempt, tentando novamente em ${delay}s..."
                sleep "$delay"
            else
                print_error "Falha ao aplicar configuração no nó $node_ip após $max_attempts tentativas"
                return 1
            fi
        fi
    done
}

# Função para aguardar nó ficar disponível
wait_for_node() {
    local node_ip=$1
    local timeout=120
    local elapsed=0
    local attempt=1

    print_step "Aguardando nó $node_ip ficar disponível (${timeout}s)..."
    talosctl config endpoint "$node_ip" >/dev/null 2>&1

    while [[ $elapsed -lt $timeout ]]; do
        # Tentar sem --insecure primeiro (após apply-config)
        if talosctl version --nodes "$node_ip" --client=false >/dev/null 2>&1; then
            print_success "Nó $node_ip está disponível!"
            return 0
        fi

        if [[ $((elapsed % 20)) -eq 0 ]] && [[ $elapsed -gt 0 ]]; then
            print_info "Aguardando... ($elapsed/${timeout}s)"
        fi
        local delay
        delay=$(backoff_delay "$attempt" "$BACKOFF_WAIT_NODE_BASE" "$BACKOFF_WAIT_NODE_CAP")
        sleep "$delay"
        elapsed=$((elapsed + delay))
        attempt=$((attempt + 1))
    done

    print_warning "Timeout aguardando nó $node_ip (${timeout}s)"
    print_info "O nó pode ainda estar inicializando - prosseguindo..."
    return 1
}

# Função para executar bootstrap
bootstrap_cluster() {
    local first_cp=$1
    local max_attempts=8
    local attempt=1

    print_step "Executando bootstrap do cluster no Control Plane $first_cp..."
    print_info "Configurando endpoint: $first_cp"
    talosctl config endpoint "$first_cp"
    talosctl config node "$first_cp"

    print_info "Verificando conectividade antes do bootstrap..."
    while [[ $attempt -le $max_attempts ]]; do
        if talosctl version --nodes "$first_cp" --client=false >/dev/null 2>&1; then
            break
        fi

        print_warning "Conexao ainda nao disponivel. Tentando novamente..."
        local delay
        delay=$(backoff_delay "$attempt" "$BACKOFF_BOOTSTRAP_CONNECT_BASE" "$BACKOFF_BOOTSTRAP_CONNECT_CAP")
        sleep "$delay"
        attempt=$((attempt + 1))
    done

    if [[ $attempt -gt $max_attempts ]]; then
        print_error "Não foi possível conectar ao nó $first_cp para bootstrap"
        return 1
    fi

    attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        print_info "Executando bootstrap (tentativa ${attempt}/${max_attempts})..."
        if talosctl bootstrap --nodes "$first_cp"; then
            print_success "Bootstrap executado com sucesso!"
            return 0
        fi

        print_warning "Bootstrap ainda nao disponivel. Aguardando servicos iniciarem..."
        print_info "Status basico de servicos (kubelet/apiserver/etcd):"
        talosctl services --nodes "$first_cp" 2>/dev/null | grep -E "etcd|kubelet|apiserver" || true

        if [[ $attempt -lt $max_attempts ]]; then
            local delay
            delay=$(backoff_delay "$attempt" "$BACKOFF_BOOTSTRAP_RETRY_BASE" "$BACKOFF_BOOTSTRAP_RETRY_CAP")
            print_info "Aguardando ${delay}s para nova tentativa..."
            sleep "$delay"
        fi

        attempt=$((attempt + 1))
    done

    print_error "Falha no bootstrap do cluster"
    print_info "Tentando diagnostico do problema..."
    print_info "Logs do kubelet:"
    talosctl logs kubelet --nodes "$first_cp" 2>&1 | tail -20 || true
    print_info "Logs do machined:"
    talosctl logs machined --nodes "$first_cp" 2>&1 | tail -20 || true
    return 1
}

# Função para aguardar cluster ficar saudável
wait_for_cluster_health() {
    local timeout=60
    local check_interval=10

    print_step "Verificando saúde do cluster..."
    print_info "Aguardando serviços do Talos iniciarem (pode levar alguns minutos)..."

    # Fazer health check em background sem mostrar logs detalhados
    local temp_log="/tmp/talos-health-$$.log"

    (
        timeout $timeout talosctl health --wait-timeout=${timeout}s > "$temp_log" 2>&1
        echo $? > "${temp_log}.exit"
    ) &
    local health_pid=$!

    # Monitorar progresso de forma mais limpa
    local elapsed=0
    while kill -0 $health_pid 2>/dev/null; do
        if [[ $((elapsed % 30)) -eq 0 ]] && [[ $elapsed -gt 0 ]]; then
            print_info "Aguardando cluster ficar saudável... (${elapsed}s/${timeout}s)"
        fi
        sleep $check_interval
        elapsed=$((elapsed + check_interval))
    done

    # Verificar resultado
    wait $health_pid
    local exit_code=$?

    if [[ -f "${temp_log}.exit" ]]; then
        exit_code=$(cat "${temp_log}.exit")
    fi

    # Limpar arquivos temporários
    rm -f "$temp_log" "${temp_log}.exit"

    if [[ $exit_code -eq 0 ]]; then
        print_success "Cluster está saudável!"
        return 0
    else
        print_info "Cluster ainda está inicializando, mas prosseguindo..."
        print_info "Você pode verificar o status com: talosctl health"
        return 0
    fi
}

# Função para aplicar configuração de plugin em todos os nós
apply_plugin_to_all_nodes() {
    local plugin_name=$1
    local yaml_file=$2
    local talosconfig=$3

    print_step "Aplicando $plugin_name em todos os nós do cluster..."

    local success_count=0
    local total_nodes=0

    # Aplicar nos Control Planes
    print_info "Aplicando nos Control Planes..."
    local cp_attempt=1
    for cp_ip in "${CONTROLPLANE_IPS[@]}"; do
        total_nodes=$((total_nodes + 1))
        print_info "  → $cp_ip (Control Plane)"

        if talosctl --talosconfig "$talosconfig" \
            --endpoints "$cp_ip" \
            --nodes "$cp_ip" \
            patch mc --patch @"$yaml_file" >/dev/null 2>&1; then
            print_success "    ✅ $plugin_name aplicado com sucesso em $cp_ip"
            success_count=$((success_count + 1))
        else
            print_warning "    ❌ Erro ao aplicar $plugin_name em $cp_ip"
        fi
        sleep_backoff "$cp_attempt" "$BACKOFF_PLUGIN_BASE" "$BACKOFF_PLUGIN_CAP"
        cp_attempt=$((cp_attempt + 1))
    done

    # Aplicar nos Workers (se houver)
    if [[ ${#WORKER_IPS[@]} -gt 0 ]]; then
        print_info "Aplicando nos Workers..."
        local worker_attempt=1
        for worker_ip in "${WORKER_IPS[@]}"; do
            total_nodes=$((total_nodes + 1))
            print_info "  → $worker_ip (Worker)"

            if talosctl --talosconfig "$talosconfig" \
                --endpoints "$worker_ip" \
                --nodes "$worker_ip" \
                patch mc --patch @"$yaml_file" >/dev/null 2>&1; then
                print_success "    ✅ $plugin_name aplicado com sucesso em $worker_ip"
                success_count=$((success_count + 1))
            else
                print_warning "    ❌ Erro ao aplicar $plugin_name em $worker_ip"
            fi
            sleep_backoff "$worker_attempt" "$BACKOFF_PLUGIN_BASE" "$BACKOFF_PLUGIN_CAP"
            worker_attempt=$((worker_attempt + 1))
        done
    fi

    echo
    print_info "Resultado: $success_count/$total_nodes nós configurados com $plugin_name"

    if [[ $success_count -eq $total_nodes ]]; then
        print_success "$plugin_name configurado com sucesso em todo o cluster!"
        return 0
    elif [[ $success_count -gt 0 ]]; then
        print_warning "$plugin_name configurado parcialmente no cluster"
        return 1
    else
        print_error "Falha ao configurar $plugin_name em qualquer nó"
        return 1
    fi
}

# Função para aplicar configuração de plugin em um nó
apply_plugin_to_node() {
    local plugin_name=$1
    local yaml_file=$2
    local node_ip=$3
    local talosconfig=$4

    if [[ -n "$talosconfig" ]]; then
        if talosctl --talosconfig "$talosconfig" \
            --endpoints "$node_ip" \
            --nodes "$node_ip" \
            patch mc --patch @"$yaml_file" >/dev/null 2>&1; then
            print_success "    ✅ $plugin_name aplicado com sucesso em $node_ip"
            return 0
        fi
    else
        if talosctl --endpoints "$node_ip" \
            --nodes "$node_ip" \
            patch mc --patch @"$yaml_file" >/dev/null 2>&1; then
            print_success "    ✅ $plugin_name aplicado com sucesso em $node_ip"
            return 0
        fi
    fi

    print_warning "    ❌ Erro ao aplicar $plugin_name em $node_ip"
    return 1
}

# Função para aplicar role label aos nós
apply_node_role_label() {
    local node_name=$1
    local role=$2
    local max_attempts=30
    local attempt=1

    print_info "Aplicando role '$role' ao nó..."

    while [[ $attempt -le $max_attempts ]]; do
        # Tentar encontrar o nó pelo IP primeiro, depois pelo nome
        local node_found=""

        # Buscar nó por IP em qualquer endereco
        node_found=$(kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name} {range .status.addresses[*]}{.address} {end}{"\n"}{end}' 2>/dev/null | awk -v ip="$node_name" '$0 ~ ip {print $1}' | head -1)

        if [[ -z "$node_found" ]]; then
            # Se não encontrou por IP, tentar por nome diretamente
            if kubectl get node "$node_name" >/dev/null 2>&1; then
                node_found="$node_name"
            fi
        fi

        if [[ -n "$node_found" ]]; then
            if kubectl label node "$node_found" node-role.kubernetes.io/$role=worker >/dev/null 2>&1; then
                print_success "Role '$role' aplicado ao nó $node_found"
                return 0
            else
                print_info "Tentativa $attempt/$max_attempts - aguardando nó ficar ready..."
            fi
        else
            print_info "Tentativa $attempt/$max_attempts - aguardando nó aparecer no cluster..."
        fi

        local delay
        delay=$(backoff_delay "$attempt" "$BACKOFF_ROLE_BASE" "$BACKOFF_ROLE_CAP")
        sleep "$delay"
        attempt=$((attempt + 1))
    done

    print_warning "Não foi possível aplicar role automaticamente"
    print_info "Aplique manualmente com: kubectl label node <node-name> node-role.kubernetes.io/$role=worker"
    print_info "Se o nó nao aparece no Kubernetes, verifique se a configuracao foi gerada com os mesmos secrets do cluster."
    return 1
}

# Função para localizar diretório do cluster pelo endpoint
find_cluster_dir_by_endpoint() {
    local endpoint=$1
    local endpoint_host="$endpoint"
    local dir

    if [[ "$endpoint_host" =~ ^https?:// ]]; then
        endpoint_host=${endpoint_host#*://}
        endpoint_host=${endpoint_host%%:*}
    fi

    shopt -s nullglob
    for dir in */; do
        [[ -f "${dir}talosconfig" ]] || continue
        if grep -q "$endpoint" "${dir}talosconfig" || grep -q "$endpoint_host" "${dir}talosconfig"; then
            echo "${dir%/}"
            shopt -u nullglob
            return 0
        fi
    done
    shopt -u nullglob
    return 1
}

# Função para gerar YAML de configuração do Tailscale
generate_tailscale_config() {
    local authkey=$1
    local output_file=$2

    if [[ -z "$authkey" ]]; then
        return 1
    fi

    cat > "$output_file" << EOF
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: tailscale
environment:
  - TS_AUTHKEY=$authkey
EOF

    print_success "Configuração do Tailscale salva: $output_file"
    return 0
}

# Função para gerar YAML de configuração do Cloudflare
generate_cloudflare_config() {
    local token=$1
    local output_file=$2

    if [[ -z "$token" ]]; then
        return 1
    fi

    cat > "$output_file" << EOF
apiVersion: v1alpha1
kind: ExtensionServiceConfig
name: cloudflared
environment:
  - TUNNEL_TOKEN=$token
EOF

    print_success "Configuração do Cloudflared salva: $output_file"
    return 0
}

# Função para configurar kubeconfig e talosconfig
setup_configs() {
    local merge_config=$1
    local cluster_dir=$2
    local talosconfig_path="$cluster_dir/talosconfig"

    print_step "Configurando kubeconfig e talosconfig..."

    if is_yes "$merge_config"; then
        # Backup do kubeconfig existente
        if [[ -f "$HOME/.kube/config" ]]; then
            local backup_file="$HOME/.kube/config.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$HOME/.kube/config" "$backup_file"
            print_info "Backup do kubeconfig criado: $backup_file"
        fi

        # Backup do talosconfig existente
        if [[ -f "$HOME/.talos/config" ]]; then
            local talos_backup="$HOME/.talos/config.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$HOME/.talos/config" "$talos_backup"
            print_info "Backup do talosconfig criado: $talos_backup"
        fi

        mkdir -p "$HOME/.kube"
        mkdir -p "$HOME/.talos"

        # Merge talosconfig primeiro para garantir contexto correto
        if [[ -f "$talosconfig_path" ]]; then
            print_info "Fazendo merge do talosconfig..."
            talosctl config merge "$talosconfig_path"
            print_success "Talosconfig merged com sucesso em ~/.talos/config!"
        fi

        # Merge kubeconfig usando o talosconfig do cluster
        if [[ -f "$talosconfig_path" ]]; then
            if talosctl --talosconfig "$talosconfig_path" kubeconfig --merge=true --force; then
                print_success "Kubeconfig merged com sucesso em ~/.kube/config!"
            else
                print_error "Erro ao fazer merge do kubeconfig"
                return 1
            fi
        else
            if talosctl kubeconfig --merge=true --force; then
                print_success "Kubeconfig merged com sucesso em ~/.kube/config!"
            else
                print_error "Erro ao fazer merge do kubeconfig"
                return 1
            fi
        fi

        print_info "Testando acesso ao cluster Kubernetes..."
        local max_attempts=10
        local attempt=1

        while [[ $attempt -le $max_attempts ]]; do
            if kubectl get nodes >/dev/null 2>&1; then
                print_success "Acesso ao cluster Kubernetes confirmado!"
                return 0
            else
                if [[ $attempt -lt $max_attempts ]]; then
                    local delay
                    delay=$(backoff_delay "$attempt" "$BACKOFF_KUBEAPI_BASE" "$BACKOFF_KUBEAPI_CAP")
                    print_info "Tentativa $attempt/$max_attempts - aguardando mais ${delay}s..."
                    sleep "$delay"
                fi
            fi
            attempt=$((attempt + 1))
        done

        print_warning "Não foi possível confirmar acesso ao cluster, mas as configurações foram aplicadas"
        return 0
    else
        print_info "Merge de configs não solicitado. Gerando arquivos de configuração na pasta..."
        
        # Gerar kubeconfig na pasta do cluster (talosctl usa caminho posicional, não -o)
        if [[ -f "$talosconfig_path" ]]; then
            if talosctl --talosconfig "$talosconfig_path" kubeconfig "$cluster_dir/kubeconfig" --force; then
                print_success "Kubeconfig salvo em: $cluster_dir/kubeconfig"
            else
                print_warning "Erro ao gerar kubeconfig, mas as configurações básicas foram criadas"
            fi
        else
            if talosctl kubeconfig "$cluster_dir/kubeconfig" --force; then
                print_success "Kubeconfig salvo em: $cluster_dir/kubeconfig"
            else
                print_warning "Erro ao gerar kubeconfig, mas as configurações básicas foram criadas"
            fi
        fi
        
        print_info "Arquivos estão em: $cluster_dir/"
        print_info "Para usar este cluster manualmente:"
        print_info "  export KUBECONFIG=$cluster_dir/kubeconfig"
        print_info "  export TALOSCONFIG=$cluster_dir/talosconfig"
        return 0
    fi
}

# Função para configurar kubeconfig (mantida para compatibilidade)

setup_kubeconfig() {
    local merge_config=$1

    print_step "Configurando kubeconfig..."

    if is_yes "$merge_config"; then
        if [[ -f "$HOME/.kube/config" ]]; then
            local backup_file="$HOME/.kube/config.backup.$(date +%Y%m%d_%H%M%S)"
            cp "$HOME/.kube/config" "$backup_file"
            print_info "Backup do kubeconfig criado: $backup_file"
        fi

        mkdir -p "$HOME/.kube"

        if talosctl kubeconfig --merge=true --force; then
            print_success "Kubeconfig merged com sucesso em ~/.kube/config!"

            print_info "Testando acesso ao cluster Kubernetes..."
            local max_attempts=10
            local attempt=1

            while [[ $attempt -le $max_attempts ]]; do
                if kubectl get nodes >/dev/null 2>&1; then
                    print_success "Acesso ao cluster Kubernetes confirmado!"
                    return 0
                else
                    if [[ $attempt -lt $max_attempts ]]; then
                        local delay
                        delay=$(backoff_delay "$attempt" "$BACKOFF_KUBEAPI_BASE" "$BACKOFF_KUBEAPI_CAP")
                        print_info "Tentativa $attempt/$max_attempts - aguardando mais ${delay}s..."
                        sleep "$delay"
                    fi
                fi
                attempt=$((attempt + 1))
            done

            print_warning "Kubeconfig configurado, mas API ainda não está respondendo"
            print_info "Aguarde alguns minutos e teste: kubectl get nodes"
            return 0
        else
            print_error "Falha no merge do kubeconfig"
            return 1
        fi
    else
        if talosctl kubeconfig kubeconfig --force; then
            print_success "Kubeconfig salvo em: $(pwd)/kubeconfig"
            print_info "Execute: export KUBECONFIG=$(pwd)/kubeconfig"
            return 0
        else
            print_error "Falha ao obter kubeconfig"
            return 1
        fi
    fi
}

# Função para exibir status final
show_cluster_status() {
    print_success "=== STATUS FINAL DO CLUSTER ==="
    echo

    print_info "Status dos nós Talos:"
    if talosctl get members >/dev/null 2>&1; then
        talosctl get members
    else
        print_warning "Não foi possível obter membros Talos (normal logo após bootstrap)"
    fi
    echo

    print_info "Status dos nós Kubernetes:"
    kubectl get nodes -o wide 2>/dev/null || print_warning "Cluster Kubernetes ainda não está pronto"
    echo

    print_info "Status dos pods do sistema:"
    kubectl get pods -n kube-system 2>/dev/null || print_warning "Pods do sistema ainda não estão prontos"
    echo
}

# Função para gerar schematic ID (Factory Image) para extensions
generate_factory_schematic() {
    print_step "Gerando Talos Factory Image com extensions..."

    local schematic_file="/tmp/schematic-$(date +%s).yaml"

    cat > "$schematic_file" << 'EOF'
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/qemu-guest-agent
      - siderolabs/tailscale
      - siderolabs/cloudflared
EOF

    print_info "Extensions que serão incluídas:"
    echo "  - qemu-guest-agent (QEMU/KVM guest tools)"
    echo "  - tailscale (VPN mesh network)"
    echo "  - cloudflared (Cloudflare tunnel)"
    echo

    # Verificar se curl e jq estão disponíveis
    if ! command -v curl &> /dev/null || ! command -v jq &> /dev/null; then
        print_warning "curl ou jq não disponíveis, usando método de patch alternativo"
        return 1
    fi

    print_info "Consultando Talos Factory API..."
    local schematic_response=$(curl -s -X POST --data-binary @"$schematic_file" https://factory.talos.dev/schematics 2>/dev/null)

    if [[ $? -ne 0 ]]; then
        print_warning "Falha ao conectar na Factory API, usando método de patch alternativo"
        return 1
    fi

    local schematic_id=$(echo "$schematic_response" | jq -r '.id' 2>/dev/null)

    if [[ -z "$schematic_id" || "$schematic_id" == "null" ]]; then
        print_warning "Não foi possível gerar Schematic ID, usando método de patch alternativo"
        return 1
    fi

    print_success "Schematic ID gerado: $schematic_id"

    # Exportar para uso global
    FACTORY_SCHEMATIC_ID="$schematic_id"
    return 0
}

# Função para criar patch de extensions
create_extensions_patch() {
    local patch_file=$1
    local use_factory=${2:-false}

    if [[ "$use_factory" == "true" ]] && [[ -n "$FACTORY_SCHEMATIC_ID" ]]; then
        # Usar Factory Image
        local talos_version=$(talosctl version --client | grep "Tag:" | awk '{print $2}' | tr -d '\n')

        # Fallback se não conseguir obter a versão
        if [[ -z "$talos_version" ]]; then
            talos_version="v1.12.6"
            print_warning "Não foi possível detectar versão do talosctl, usando v1.12.6"
        fi

        print_info "Usando Talos versão: $talos_version"

        cat > "$patch_file" << EOF
machine:
  install:
    image: factory.talos.dev/installer/${FACTORY_SCHEMATIC_ID}:${talos_version}
EOF
        print_success "Patch criado usando Factory Image: $patch_file"
    else
        # Usar patch tradicional com downloads
        cat > "$patch_file" << 'EOF'
machine:
  install:
    extensions:
      - image: ghcr.io/siderolabs/qemu-guest-agent:9.2.0
      - image: ghcr.io/siderolabs/tailscale:1.84.3
      - image: ghcr.io/siderolabs/cloudflared:2025.1.3
EOF
        print_success "Patch criado com extensions tradicionais: $patch_file"
    fi

    echo
    print_info "Conteúdo do patch:"
    cat "$patch_file"
    echo
}

# ========================================
# MENU 1: CRIAR NOVO CLUSTER
# ========================================
menu_create_cluster() {
    print_menu "╔════════════════════════════════════════════════╗"
    print_menu "║     CRIAR NOVO CLUSTER TALOS                   ║"
    print_menu "╚════════════════════════════════════════════════╝"
    echo

    check_talosctl
    echo

    print_flow_steps "Fluxo do processo:" \
        "Coleta de dados" \
        "Gerar configuracoes" \
        "Aplicar configuracoes" \
        "Bootstrap" \
        "Pos-configuracao"

    # Entrada de dados
    print_info "Coletando informações do cluster..."
    echo

    # Nome do cluster
    ask_required "Nome do cluster: " CLUSTER_NAME

    # IPs dos Control Planes
    echo
    print_info "Digite os IPs dos Control Planes (separados por espaço ou vírgula):"
    read -p "Control Planes: " CONTROLPLANE_INPUT

    CONTROLPLANE_IPS=()
    if ! process_ips "$CONTROLPLANE_INPUT" CONTROLPLANE_IPS; then
        return 1
    fi

    if [[ ${#CONTROLPLANE_IPS[@]} -eq 0 ]]; then
        print_error "Pelo menos um Control Plane é necessário!"
        return 1
    fi

    # IPs dos Workers
    echo
    print_info "Digite os IPs dos Workers (separados por espaço ou vírgula, ou pressione ENTER para pular):"
    read -p "Workers: " WORKER_INPUT

    WORKER_IPS=()
    if [[ -n "$WORKER_INPUT" ]]; then
        if ! process_ips "$WORKER_INPUT" WORKER_IPS; then
            return 1
        fi
    fi

    # *** PERGUNTA SOBRE EXTENSIONS ***
    echo
    print_menu "╔════════════════════════════════════════════════╗"
    print_menu "║     SYSTEM EXTENSIONS                          ║"
    print_menu "╚════════════════════════════════════════════════╝"
    echo
    print_info "Deseja instalar as extensions recomendadas?"
    echo "  - qemu-guest-agent (QEMU/KVM VM tools)"
    echo "  - tailscale (VPN mesh network)"
    echo "  - cloudflared (Cloudflare tunnel)"
    echo
    INSTALL_EXTENSIONS=$(ask_yes_no "Instalar extensions recomendadas? (y/n) [n]: " "n")

    # Configuração de plugins se extensions forem instaladas
    TAILSCALE_AUTHKEY=""
    CLOUDFLARE_TOKEN=""
    if [[ "$INSTALL_EXTENSIONS" == "y" ]]; then
        echo
        print_info "╔════════════════════════════════════════════════╗"
        print_info "║     CONFIGURAÇÃO DE PLUGINS                    ║"
        print_info "╚════════════════════════════════════════════════╝"
        echo
        print_info "Para ativar os plugins, você precisa fornecer as credenciais."
        print_info "Deixe em branco para pular a configuração (pode configurar depois)."
        echo

        read -p "Tailscale Auth Key (tskey-auth-...): " TAILSCALE_AUTHKEY
        echo
        read -p "Cloudflare Tunnel Token: " CLOUDFLARE_TOKEN
        echo
    fi

    # Merge kubeconfig e talosconfig
    echo
    MERGE_CONFIGS=$(ask_yes_no "Realizar merge do kubeconfig e talosconfig? (y/n) [n]: " "n")

    # Aplicação automática
    echo
    AUTO_APPLY=$(ask_yes_no "Aplicar configurações automaticamente nos nós? (y/n) [n]: " "n")

    # Endpoint do cluster (primeiro IP do Control Plane)
    CLUSTER_ENDPOINT="${CONTROLPLANE_IPS[0]}"

    echo
    print_info "=== RESUMO DA CONFIGURAÇÃO ==="
    print_info "Cluster: $CLUSTER_NAME"
    print_info "Endpoint: $CLUSTER_ENDPOINT"
    print_info "Control Planes: ${CONTROLPLANE_IPS[*]}"
    if [[ ${#WORKER_IPS[@]} -gt 0 ]]; then
        print_info "Workers: ${WORKER_IPS[*]}"
    else
        print_info "Workers: Nenhum"
    fi
    print_info "Extensions: $INSTALL_EXTENSIONS"
    if [[ "$INSTALL_EXTENSIONS" == "y" ]]; then
        if [[ -n "$TAILSCALE_AUTHKEY" ]]; then
            print_info "  └─ Tailscale: Configurado"
        fi
        if [[ -n "$CLOUDFLARE_TOKEN" ]]; then
            print_info "  └─ Cloudflare: Configurado"
        fi
    fi
    print_info "Merge configs: $MERGE_CONFIGS"
    print_info "Aplicação automática: $AUTO_APPLY"
    echo

    CONFIRM=$(ask_yes_no "Continuar com a criação e configuração completa do cluster? (y/n) [n]: " "n")

    if [[ "$CONFIRM" != "y" ]]; then
        print_warning "Operação cancelada pelo usuário."
        return 0
    fi

    # Testar conectividade com os nós
    print_step "Testando conectividade com os nós..."
    for ip in "${CONTROLPLANE_IPS[@]}" "${WORKER_IPS[@]}"; do
        test_node_connectivity "$ip"
    done
    echo

    # Criar diretório do cluster
    CLUSTER_DIR="$PWD/${CLUSTER_NAME}"
    if [[ -d "$CLUSTER_DIR" ]]; then
        print_warning "Diretório $CLUSTER_DIR já existe. Removendo..."
        rm -rf "$CLUSTER_DIR"
    fi

    mkdir -p "$CLUSTER_DIR"
    cd "$CLUSTER_DIR"

    print_success "Diretório criado: $CLUSTER_DIR"

    # Configurar talosconfig
    export TALOSCONFIG="$PWD/talosconfig"

    # Processar extensions se solicitado
    EXTENSIONS_PATCH=""
    if [[ "$INSTALL_EXTENSIONS" == "y" ]]; then
        echo
        # Tentar gerar Factory Image
        if generate_factory_schematic; then
            create_extensions_patch "extensions-patch.yaml" true
            EXTENSIONS_PATCH="extensions-patch.yaml"
        else
            # Fallback para patch tradicional
            print_info "Usando método tradicional de extensions..."
            create_extensions_patch "extensions-patch.yaml" false
            EXTENSIONS_PATCH="extensions-patch.yaml"
        fi
    fi

    # Gerar configurações
    print_step "Gerando configurações do Talos..."
    if [[ -n "$EXTENSIONS_PATCH" ]]; then
        talosctl gen config "$CLUSTER_NAME" "https://$CLUSTER_ENDPOINT:6443" \
            --config-patch @"$EXTENSIONS_PATCH"
    else
        talosctl gen config "$CLUSTER_NAME" "https://$CLUSTER_ENDPOINT:6443"
    fi

    if [[ $? -eq 0 ]]; then
        print_success "Configurações geradas com sucesso!"

        # Gerar YAMLs de configuração dos plugins se foram configurados
        if [[ "$INSTALL_EXTENSIONS" == "y" ]]; then
            echo
            print_step "Gerando configurações dos plugins..."

            if [[ -n "$TAILSCALE_AUTHKEY" ]]; then
                generate_tailscale_config "$TAILSCALE_AUTHKEY" "$CLUSTER_DIR/tailscale.yaml"
            fi

            if [[ -n "$CLOUDFLARE_TOKEN" ]]; then
                generate_cloudflare_config "$CLOUDFLARE_TOKEN" "$CLUSTER_DIR/cloudflare.yaml"
            fi

            # Informar sobre configuração manual se necessário
            if [[ -z "$TAILSCALE_AUTHKEY" ]] || [[ -z "$CLOUDFLARE_TOKEN" ]]; then
                echo
                print_info "Para configurar os plugins posteriormente, edite os arquivos:"
                [[ -z "$TAILSCALE_AUTHKEY" ]] && echo "  - $CLUSTER_DIR/tailscale.yaml"
                [[ -z "$CLOUDFLARE_TOKEN" ]] && echo "  - $CLUSTER_DIR/cloudflare.yaml"
                echo
                print_info "E aplique com:"
                echo "  talosctl apply-config --file <yaml>"
                echo
            fi
        fi
    else
        print_error "Falha ao gerar configurações do Talos"
        return 1
    fi

    # Se aplicação automática foi solicitada
    if [[ "$AUTO_APPLY" == "y" ]]; then
        echo
        print_step "=== INICIANDO APLICAÇÃO AUTOMÁTICA ==="

        # Aplicar configurações nos Control Planes
        print_step "Configurando Control Planes..."
        local cp_apply_attempt=1
        for ip in "${CONTROLPLANE_IPS[@]}"; do
            if ! apply_config_to_node "$ip" "controlplane.yaml" "Control Plane"; then
                print_error "Falha crítica na configuração do Control Plane $ip"
                return 1
            fi
            sleep_backoff "$cp_apply_attempt" "$BACKOFF_STEP_BASE" "$BACKOFF_STEP_CAP"
            cp_apply_attempt=$((cp_apply_attempt + 1))
        done

        # Aplicar configurações nos Workers (se houver)
        if [[ ${#WORKER_IPS[@]} -gt 0 ]]; then
            print_step "Configurando Workers..."
            local worker_apply_attempt=1
            for ip in "${WORKER_IPS[@]}"; do
                if ! apply_config_to_node "$ip" "worker.yaml" "Worker"; then
                    print_warning "Falha na configuração do Worker $ip, mas continuando..."
                fi
                sleep_backoff "$worker_apply_attempt" "$BACKOFF_STEP_BASE" "$BACKOFF_STEP_CAP"
                worker_apply_attempt=$((worker_apply_attempt + 1))
            done
        fi

        # Aguardar primeiro Control Plane ficar disponível
        FIRST_CP="${CONTROLPLANE_IPS[0]}"
        if wait_for_node "$FIRST_CP"; then
            print_success "Control Plane $FIRST_CP está disponível!"
        else
            print_info "Prosseguindo com bootstrap do cluster..."
        fi

        # Executar bootstrap (independente do resultado do wait)
        if bootstrap_cluster "$FIRST_CP"; then
            # Aguardar cluster ficar saudável (skip se extensions foram instaladas sem configuração)
            local skip_health_check=false
            if [[ "$INSTALL_EXTENSIONS" == "y" ]]; then
                if [[ -n "$TAILSCALE_AUTHKEY" ]] || [[ -n "$CLOUDFLARE_TOKEN" ]]; then
                    print_info "Extensions com configuração detectadas - pulando health check completo"
                    print_info "Configure os plugins antes de fazer health check completo"
                    skip_health_check=true
                fi
            fi

            if [[ "$skip_health_check" == "false" ]]; then
                wait_for_cluster_health
            fi

            # Configurar kubeconfig e talosconfig
            setup_configs "$MERGE_CONFIGS" "$CLUSTER_DIR"

            # Aplicar configurações dos plugins automaticamente
            if [[ "$INSTALL_EXTENSIONS" == "y" ]]; then
                echo
                print_step "📦 Aplicando configurações dos plugins em todo o cluster..."
                echo

                local plugin_applied=false

                if [[ -n "$TAILSCALE_AUTHKEY" ]]; then
                    apply_plugin_to_all_nodes "Tailscale" "$CLUSTER_DIR/tailscale.yaml" "$CLUSTER_DIR/talosconfig"
                    plugin_applied=true
                    echo
                fi

                if [[ -n "$CLOUDFLARE_TOKEN" ]]; then
                    apply_plugin_to_all_nodes "Cloudflare" "$CLUSTER_DIR/cloudflare.yaml" "$CLUSTER_DIR/talosconfig"
                    plugin_applied=true
                    echo
                fi

                if [[ "$plugin_applied" == "true" ]]; then
                    print_info "Aguardando plugins inicializarem em todos os nós..."
                    sleep_backoff 1 "$BACKOFF_PLUGIN_INIT_BASE" "$BACKOFF_PLUGIN_INIT_CAP"

                    print_info "Verificando serviços dos plugins no cluster:"
                    echo "📍 Control Plane(s):"
                    for cp_ip in "${CONTROLPLANE_IPS[@]}"; do
                        echo "  → $cp_ip:"
                        talosctl --talosconfig "$CLUSTER_DIR/talosconfig" --nodes "$cp_ip" services | grep -E "ext-|tailscale|cloudflared" | sed 's/^/    /' || echo "    (plugins ainda inicializando...)"
                    done

                    if [[ ${#WORKER_IPS[@]} -gt 0 ]]; then
                        echo "📍 Worker(s):"
                        for worker_ip in "${WORKER_IPS[@]}"; do
                            echo "  → $worker_ip:"
                            talosctl --talosconfig "$CLUSTER_DIR/talosconfig" --nodes "$worker_ip" services | grep -E "ext-|tailscale|cloudflared" | sed 's/^/    /' || echo "    (plugins ainda inicializando...)"
                        done
                    fi
                    echo
                fi
            fi

            # Exibir status final
            show_cluster_status

            print_success "🎉 CLUSTER TALOS CONFIGURADO E FUNCIONANDO COM SUCESSO! 🎉"
            echo

            if is_yes "$INSTALL_EXTENSIONS"; then
                print_info "📦 EXTENSIONS & PLUGINS:"
                echo
                print_info "Verificar extensions instaladas:"
                echo "  talosctl get extensions --nodes $FIRST_CP"
                echo
                print_info "Verificar status dos plugins:"
                echo "  talosctl services --nodes $FIRST_CP | grep -E 'ext-|tailscale|cloudflared'"
                echo
            fi

            print_info "Próximos passos recomendados:"
            echo "1. Verificar nós: kubectl get nodes -o wide"
            echo "2. Verificar pods: kubectl get pods -A"
        else
            print_error "Falha no bootstrap. Verifique os logs."
            return 1
        fi
    else
        # Apenas mostrar comandos manuais
        echo
        print_success "=== CONFIGURAÇÃO DOS ARQUIVOS COMPLETA ==="
        print_info "Arquivos gerados em: $CLUSTER_DIR"
        print_info "- controlplane.yaml: Configuração dos Control Planes"
        print_info "- worker.yaml: Configuração dos Workers"
        print_info "- talosconfig: Configuração do cliente talosctl"
        if [[ -n "$EXTENSIONS_PATCH" ]]; then
            print_info "- extensions-patch.yaml: Patch das Extensions"
        fi

        echo
        print_info "=== COMANDOS PARA APLICAÇÃO MANUAL ==="
        echo "export TALOSCONFIG=$CLUSTER_DIR/talosconfig"
        echo

        # Comandos para Control Planes
        print_info "# Control Planes:"
        for i in "${!CONTROLPLANE_IPS[@]}"; do
            ip="${CONTROLPLANE_IPS[$i]}"
            echo "talosctl apply-config --insecure --nodes $ip --file controlplane.yaml"
            if [[ $i -eq 0 ]]; then
                echo "talosctl config endpoint $ip"
                echo "talosctl config node $ip"
                echo "talosctl bootstrap --nodes $ip"
            fi
        done

        # Comandos para Workers
        if [[ ${#WORKER_IPS[@]} -gt 0 ]]; then
            echo
            print_info "# Workers:"
            for ip in "${WORKER_IPS[@]}"; do
                echo "talosctl apply-config --insecure --nodes $ip --file worker.yaml"
            done
        fi

        echo
        print_info "# Aguardar cluster ficar pronto e configurar kubeconfig:"
        echo "talosctl health --wait-timeout=10m"
        if [[ "$MERGE_CONFIGS" == "y" ]]; then
            echo "talosctl kubeconfig --merge=true"
        else
            echo "talosctl kubeconfig"
        fi
    fi

    print_success "Script concluído!"
}

# ========================================
# MENU 2: ATUALIZAR TALOSCTL
# ========================================
menu_update_talosctl() {
    print_menu "╔════════════════════════════════════════════════╗"
    print_menu "║     ATUALIZAR TALOSCTL                         ║"
    print_menu "╚════════════════════════════════════════════════╝"
    echo

    print_flow_steps "Fluxo do processo:" \
        "Validar versao atual" \
        "Baixar nova versao" \
        "Instalar" \
        "Validar instalacao"

    # Verificar versão atual
    print_info "Versão atual do talosctl:"
    talosctl version --client || true
    echo

    # Perguntar versão desejada
    read -p "Digite a versão desejada (ex: v1.12.6) ou ENTER para última: " TARGET_VERSION

    if [[ -z "$TARGET_VERSION" ]]; then
        TARGET_VERSION="latest"
        print_info "Buscando última versão disponível..."

        if command -v curl &> /dev/null; then
            LATEST_VERSION=$(curl -s https://api.github.com/repos/siderolabs/talos/releases/latest | grep '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
            if [[ -n "$LATEST_VERSION" ]]; then
                TARGET_VERSION="$LATEST_VERSION"
                print_success "Última versão: $TARGET_VERSION"
            else
                print_error "Não foi possível determinar a última versão"
                return 1
            fi
        else
            print_error "curl não disponível para buscar última versão"
            return 1
        fi
    fi

    print_step "Atualizando talosctl para $TARGET_VERSION..."

    # Baixar nova versão
    DOWNLOAD_URL="https://github.com/siderolabs/talos/releases/download/${TARGET_VERSION}/talosctl-linux-amd64"

    print_info "Baixando de: $DOWNLOAD_URL"

    if curl -fsSL "$DOWNLOAD_URL" -o /tmp/talosctl.new; then
        print_success "Download concluído!"
    else
        print_error "Falha no download. Verifique se a versão $TARGET_VERSION existe"
        print_info "Releases disponíveis: https://github.com/siderolabs/talos/releases"
        return 1
    fi

    # Tornar executável
    chmod +x /tmp/talosctl.new

    # Verificar se funciona
    print_info "Verificando nova versão..."
    if /tmp/talosctl.new version --client 2>&1 | grep -q "$TARGET_VERSION"; then
        print_success "Verificação OK!"
    else
        print_error "A versão baixada não corresponde à esperada"
        rm /tmp/talosctl.new
        return 1
    fi

    # Fazer backup da versão atual
    if command -v talosctl &> /dev/null; then
        CURRENT_LOCATION=$(which talosctl)
        print_info "Fazendo backup da versão atual..."
        sudo cp "$CURRENT_LOCATION" "${CURRENT_LOCATION}.backup.$(date +%Y%m%d_%H%M%S)"
        print_success "Backup criado"
    fi

    # Instalar nova versão
    print_info "Instalando nova versão..."
    if sudo mv /tmp/talosctl.new /usr/local/bin/talosctl; then
        print_success "talosctl instalado em /usr/local/bin/talosctl"
    else
        print_error "Falha na instalação"
        return 1
    fi

    # Verificar instalação
    echo
    print_success "=== INSTALAÇÃO CONCLUÍDA ==="
    print_info "Nova versão do talosctl:"
    talosctl version --client

    echo
    print_success "Atualização concluída com sucesso! ✓"
}

# ========================================
# MENU 3: UPGRADE CLUSTER EXISTENTE
# ========================================
menu_upgrade_cluster() {
    print_menu "╔════════════════════════════════════════════════╗"
    print_menu "║     UPGRADE DE CLUSTER EXISTENTE               ║"
    print_menu "╚════════════════════════════════════════════════╝"
    echo

    check_talosctl
    echo

    print_flow_steps "Fluxo do processo:" \
        "Validar conectividade" \
        "Aplicar configuracao" \
        "Health check" \
        "Plugins" \
        "Rotulos"

    # Selecionar cluster/contexto
    if ! select_cluster_context; then
        return
    fi
    echo

    cd "$CLUSTER_DIR"
    export TALOSCONFIG="$PWD/talosconfig"

    print_success "Usando cluster: $CLUSTER_DIR"
    echo

    # Verificar versão desejada
    read -p "Digite a versão alvo do Talos (ex: v1.12.6): " TARGET_VERSION

    if [[ -z "$TARGET_VERSION" ]]; then
        print_error "Versão é obrigatória!"
        return 1
    fi

    # Detectar nós
    print_info "Detectando nós do cluster..."

    if ! talosctl get members >/dev/null 2>&1; then
        print_error "Não foi possível conectar ao cluster"
        print_info "Verifique se TALOSCONFIG está correto e cluster está funcionando"
        return 1
    fi

    # Listar nós
    print_info "Nós do cluster:"
    talosctl get members
    echo

    CONFIRM=$(ask_yes_no "Deseja continuar com o upgrade para $TARGET_VERSION? (y/n) [n]: " "n")

    if [[ "$CONFIRM" != "y" ]]; then
        print_warning "Upgrade cancelado"
        return 0
    fi

    # Perguntar nós para upgrade
    read -p "IPs dos Control Planes (separados por espaço): " cp_ips
    read -p "IPs dos Workers (separados por espaço ou ENTER se nenhum): " worker_ips

    CONTROLPLANE_IPS=($cp_ips)
    WORKER_IPS=($worker_ips)

    # Função para upgrade de nó
    upgrade_node() {
        local node=$1
        local node_type=$2

        print_step "Fazendo upgrade do $node_type: $node"

        if talosctl upgrade --nodes "$node" \
            --image "ghcr.io/siderolabs/installer:${TARGET_VERSION}" \
            --preserve \
            --timeout=10m; then

            print_success "Comando de upgrade enviado para $node"
            print_info "Aguardando nó reiniciar..."

            local max_wait=300
            local elapsed=0
            local attempt=1

            while [[ $elapsed -lt $max_wait ]]; do
                if talosctl version --nodes "$node" --client=false >/dev/null 2>&1; then
                    print_success "Nó $node está disponível!"
                    return 0
                fi
                if [[ $((elapsed % 30)) -eq 0 ]]; then
                    print_info "Aguardando... ($elapsed/${max_wait}s)"
                fi
                local delay
                delay=$(backoff_delay "$attempt" "$BACKOFF_UPGRADE_BASE" "$BACKOFF_UPGRADE_CAP")
                sleep "$delay"
                elapsed=$((elapsed + delay))
                attempt=$((attempt + 1))
            done

            print_warning "Timeout aguardando nó $node, mas ele pode estar OK"
            return 0
        else
            print_error "Falha no upgrade do nó $node"
            return 1
        fi
    }

    # Upgrade Control Planes
    print_step "=== UPGRADE DOS CONTROL PLANES ==="
    local upgrade_cp_attempt=1
    for node in "${CONTROLPLANE_IPS[@]}"; do
        upgrade_node "$node" "Control Plane"

        print_info "Verificando saúde do cluster..."
        talosctl health --wait-timeout=3m >/dev/null 2>&1 || print_warning "Health check parcial"

        echo
        sleep_backoff "$upgrade_cp_attempt" "$BACKOFF_UPGRADE_BASE" "$BACKOFF_UPGRADE_CAP"
        upgrade_cp_attempt=$((upgrade_cp_attempt + 1))
    done

    # Upgrade Workers
    if [[ ${#WORKER_IPS[@]} -gt 0 ]]; then
        print_step "=== UPGRADE DOS WORKERS ==="
        local upgrade_worker_attempt=1
        for node in "${WORKER_IPS[@]}"; do
            upgrade_node "$node" "Worker"
            echo
            sleep_backoff "$upgrade_worker_attempt" "$BACKOFF_UPGRADE_BASE" "$BACKOFF_UPGRADE_CAP"
            upgrade_worker_attempt=$((upgrade_worker_attempt + 1))
        done
    fi

    # Verificação final
    print_step "=== VERIFICAÇÃO FINAL ==="
    echo

    print_info "Versões dos nós:"
    for node in "${CONTROLPLANE_IPS[@]}" "${WORKER_IPS[@]}"; do
        echo "Nó $node:"
        talosctl version --nodes "$node" --short 2>/dev/null || echo "  Erro ao obter versão"
    done

    echo
    print_info "Status do cluster Kubernetes:"
    kubectl get nodes -o wide 2>/dev/null || print_warning "Erro ao obter nós"

    echo
    print_success "🎉 UPGRADE DO CLUSTER CONCLUÍDO!"
}

# ========================================
# FUNÇÃO AUXILIAR: SELEÇÃO DE CLUSTER
# ========================================

# Tenta carregar TALOSCONFIG local quando nao ha contextos globais
load_local_talosconfig() {
    if [[ -n "$TALOSCONFIG" ]] && [[ -f "$TALOSCONFIG" ]]; then
        return 0
    fi

    if [[ -f "$PWD/talosconfig" ]]; then
        export TALOSCONFIG="$PWD/talosconfig"
        print_info "Usando TALOSCONFIG local: $TALOSCONFIG"
        return 0
    fi

    local configs=(./*/talosconfig)
    local found=()

    for cfg in "${configs[@]}"; do
        [[ -f "$cfg" ]] && found+=("$cfg")
    done

    if [[ ${#found[@]} -eq 1 ]]; then
        export TALOSCONFIG="${found[0]}"
        print_info "Usando TALOSCONFIG encontrado: $TALOSCONFIG"
        return 0
    fi

    if [[ ${#found[@]} -gt 1 ]]; then
        print_info "Foram encontrados TALOSCONFIGs locais:" 
        for i in "${!found[@]}"; do
            echo "  $((i+1))) ${found[$i]}"
        done
        echo
        while true; do
            read -p "Escolha [1-${#found[@]}]: " choice
            if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#found[@]}" ]]; then
                export TALOSCONFIG="${found[$((choice-1))]}"
                print_info "Usando TALOSCONFIG selecionado: $TALOSCONFIG"
                return 0
            else
                print_error "Opcao invalida! Escolha entre 1-${#found[@]}"
            fi
        done
    fi

    return 1
}

# Função para listar e selecionar cluster/contexto
select_cluster_context() {
    print_step "Seleção de Cluster"
    echo

    # Verificar se existem contextos configurados
    local contexts=$(talosctl config contexts 2>/dev/null)
    if [[ $? -ne 0 ]] || [[ -z "$contexts" ]]; then
        if load_local_talosconfig; then
            contexts=$(talosctl config contexts 2>/dev/null)
        fi
        if [[ -z "$contexts" ]]; then
            print_error "Nenhum cluster Talos configurado encontrado!"
            print_info "Use a opção 1 do menu para criar um cluster primeiro."
            return 1
        fi
    fi

    print_info "Clusters/Contextos disponíveis:"
    echo
    echo "$contexts"
    echo

    # Obter lista de nomes dos contextos (excluindo header)
    local context_names=($(echo "$contexts" | awk 'NR > 1 && $2 != "" {print $2}'))

    if [[ ${#context_names[@]} -eq 0 ]]; then
        print_error "Nenhuma configuração de cluster encontrada!"
        print_info "Clusters disponíveis estão vazios."
        print_info "Crie um novo cluster usando a opção 1 do menu principal."
        echo
        print_info "💡 Dica: Se você tem clusters Talos existentes:"
        echo "   1. Certifique-se que estão configurados no talosctl"
        echo "   2. Execute: talosctl config merge <arquivo-talosconfig>"
        return 1
    fi

    # Se há apenas um contexto, usar automaticamente
    if [[ ${#context_names[@]} -eq 1 ]]; then
        local selected_context="${context_names[0]}"
        print_info "Usando o único contexto disponível: $selected_context"
        talosctl config context "$selected_context" >/dev/null 2>&1
        return 0
    fi

    # Múltiplos contextos - permitir seleção
    print_info "Selecione o cluster/contexto:"
    for i in "${!context_names[@]}"; do
        local current_marker=""
        if echo "$contexts" | grep -q "^\*.*${context_names[$i]}"; then
            current_marker=" (atual)"
        fi
        echo "  $((i+1))) ${context_names[$i]}$current_marker"
    done
    echo

    while true; do
        read -p "Escolha [1-${#context_names[@]}]: " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "${#context_names[@]}" ]]; then
            local selected_context="${context_names[$((choice-1))]}"
            print_info "Mudando para contexto: $selected_context"

            if talosctl config context "$selected_context" >/dev/null 2>&1; then
                print_success "✅ Contexto alterado para: $selected_context"
                return 0
            else
                print_error "Erro ao mudar para contexto $selected_context"
                return 1
            fi
        else
            print_error "Opção inválida! Escolha entre 1-${#context_names[@]}"
        fi
    done
}

# Função para obter informações do cluster atual
get_current_cluster_info() {
    local current_cluster=$(talosctl config info | grep "Current context:" | awk '{print $3}')
    local endpoint=$(talosctl config info | grep "Endpoints:" | awk '{print $2}')

    # Corrigir formato do endpoint para incluir scheme e porta
    if [[ -n "$endpoint" ]] && [[ ! "$endpoint" =~ ^https?:// ]]; then
        endpoint="https://${endpoint}:6443"
    fi

    echo "$current_cluster|$endpoint"
}

# ========================================
# MENU 2: EXPANDIR CLUSTER
# ========================================
menu_expand_cluster() {
    print_menu "╔════════════════════════════════════════════════╗"
    print_menu "║     EXPANDIR CLUSTER EXISTENTE                 ║"
    print_menu "╚════════════════════════════════════════════════╝"
    echo

    check_talosctl
    echo

    print_flow_steps "Fluxo do processo:" \
        "Validar cluster" \
        "Upgrade Control Planes" \
        "Upgrade Workers" \
        "Verificacao final"

    # Selecionar cluster/contexto
    if ! select_cluster_context; then
        return
    fi
    echo

    print_info "Selecione o tipo de nó a adicionar:"
    echo "  1) Control Plane"
    echo "  2) Worker"
    echo
    read -p "Escolha [1-2]: " node_type

    case $node_type in
        1)
            add_control_plane
            ;;
        2)
            add_worker_node
            ;;
        *)
            print_error "Opção inválida!"
            return
            ;;
    esac
}

# Função para adicionar Control Plane
add_control_plane() {
    print_step "Adicionando novo Control Plane..."
    echo

    read -p "Digite o IP do novo Control Plane: " new_cp_ip

    if [[ ! "$new_cp_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        print_error "IP inválido!"
        return
    fi

    print_info "Testando conectividade com $new_cp_ip..."
    local ping_ok=false
    for attempt in $(seq 1 3); do
        if ping -c 1 "$new_cp_ip" >/dev/null 2>&1; then
            ping_ok=true
            break
        fi

        if [[ $attempt -lt 3 ]]; then
            local delay
            delay=$(backoff_delay "$attempt" "$BACKOFF_PING_BASE" "$BACKOFF_PING_CAP")
            sleep "$delay"
        fi
    done

    if [[ "$ping_ok" != "true" ]]; then
        print_warning "Não foi possível fazer ping para $new_cp_ip"
        continue_anyway=$(ask_yes_no "Continuar mesmo assim? (y/n) [n]: " "n")
        [[ "$continue_anyway" != "y" ]] && return
    fi

    # Obter informações do cluster atual
    local cluster_info=$(get_current_cluster_info)
    local current_cluster=$(echo "$cluster_info" | cut -d'|' -f1)
    local endpoint=$(echo "$cluster_info" | cut -d'|' -f2)

    if [[ -z "$current_cluster" ]]; then
        print_error "Não foi possível determinar o cluster atual"
        return
    fi

    print_info "Cluster: $current_cluster"
    print_info "Endpoint: $endpoint"

    # Tentar encontrar a pasta do cluster original
    local cluster_dir=""
    local original_cp_config=""
    local config_result=""

    if config_result=$(find_original_config "controlplane" "$current_cluster" "$endpoint"); then
        cluster_dir="${config_result%%|*}"
        original_cp_config="${config_result#*|}"
        print_success "Encontrada configuração original do cluster em: $cluster_dir"
    fi

    local used_generated_config=false

    if [[ -n "$original_cp_config" ]]; then
        # Usar configuração original existente
        print_info "Usando configuração Control Plane original do cluster..."

        print_info "Aplicando configuração no novo Control Plane $new_cp_ip..."
        if talosctl apply-config --insecure --nodes "$new_cp_ip" --file "$original_cp_config"; then
            print_success "Configuração aplicada com sucesso!"
        else
            print_error "Falha ao aplicar configuração no novo Control Plane"
            return
        fi
    else
        # Método alternativo: gerar nova configuração
        print_info "Configuração original não encontrada. Gerando nova configuração..."
        print_warning "ATENÇÃO: Este método pode não funcionar se o cluster foi criado com certificados diferentes"
        continue_anyway=$(ask_yes_no "Deseja continuar mesmo assim? (y/n) [n]: " "n")
        if [[ "$continue_anyway" != "y" ]]; then
            print_info "Operacao cancelada. Use o controlplane.yaml original do cluster para garantir o join."
            return
        fi

        local config_dir="/tmp/new-cp-$(date +%s)"
        mkdir -p "$config_dir"

        # Gerar nova configuração
        print_info "Gerando configuração compatível..."
        talosctl gen config "$current_cluster" "$endpoint" --output-dir "$config_dir" --force
        used_generated_config=true

        print_info "Aplicando configuração no novo Control Plane $new_cp_ip..."
        if talosctl apply-config --insecure --nodes "$new_cp_ip" --file "$config_dir/controlplane.yaml"; then
            print_success "Configuração aplicada com sucesso!"
        else
            print_error "Falha ao aplicar configuração no novo Control Plane"
            print_info "💡 Solução recomendada:"
            echo "  1. Certifique-se que o nó $new_cp_ip está executando Talos OS"
            echo "  2. Se o cluster foi criado externamente, use as configurações originais"
            echo "  3. Ou use: talosctl apply-config --insecure --nodes $new_cp_ip --file <controlplane-original.yaml>"
            rm -rf "$config_dir"
            return
        fi

        # Limpeza
        rm -rf "$config_dir"
    fi

    # Aguardar e verificar o nó
    print_info "Verificando status do novo Control Plane..."
    local max_attempts=6
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if timeout 30 talosctl --nodes "$new_cp_ip" health --server=false >/dev/null 2>&1; then
            print_success "✅ Control Plane $new_cp_ip está saudável!"
            break
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            local delay
            delay=$(backoff_delay "$attempt" "$BACKOFF_HEALTH_BASE" "$BACKOFF_HEALTH_CAP")
            print_info "Nó ainda está inicializando... aguardando ${delay}s"
            sleep "$delay"
        fi
        attempt=$((attempt + 1))
    done

    print_info "Aguardando o nó aparecer no Kubernetes..."
    attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        if kubectl get nodes -o wide 2>/dev/null | grep -q "$new_cp_ip"; then
            break
        fi
        if [[ $attempt -lt $max_attempts ]]; then
            local delay
            delay=$(backoff_delay "$attempt" "$BACKOFF_K8S_APPEAR_BASE" "$BACKOFF_K8S_APPEAR_CAP")
            sleep "$delay"
        fi
        attempt=$((attempt + 1))
    done

    print_info "Status do cluster:"
    kubectl get nodes -o wide || print_warning "Erro ao obter nós do Kubernetes"

    # Aplicar plugins no novo nó (se existirem configs)
    if [[ -n "$cluster_dir" ]]; then
        local talosconfig_path=""
        local plugin_files=()

        if [[ -f "$cluster_dir/talosconfig" ]]; then
            talosconfig_path="$cluster_dir/talosconfig"
        fi

        [[ -f "$cluster_dir/tailscale.yaml" ]] && plugin_files+=("tailscale:$cluster_dir/tailscale.yaml")
        [[ -f "$cluster_dir/cloudflare.yaml" ]] && plugin_files+=("cloudflared:$cluster_dir/cloudflare.yaml")

        if [[ ${#plugin_files[@]} -gt 0 ]]; then
            echo
            apply_plugins=$(ask_yes_no "Aplicar configuracoes de plugins no novo no? (y/n) [n]: " "n")

            if [[ "$apply_plugins" == "y" ]]; then
                print_step "Aplicando plugins no novo Control Plane..."
                for item in "${plugin_files[@]}"; do
                    local name="${item%%:*}"
                    local file="${item#*:}"
                    apply_plugin_to_node "$name" "$file" "$new_cp_ip" "$talosconfig_path"
                done
            fi
        fi
    fi

    # Control Planes já recebem o role automaticamente, mas vamos garantir
    echo
    if [[ "$used_generated_config" == "true" ]]; then
        print_warning "O Control Plane pode nao ingressar no cluster se os secrets forem diferentes."
        print_info "Se nao aparecer no Kubernetes, use o controlplane.yaml original do cluster."
    else
        apply_node_role_label "$new_cp_ip" "control-plane"
    fi

    print_success "✅ Control Plane $new_cp_ip adicionado ao cluster!"
    print_info "Control Planes podem levar vários minutos para sincronizar completamente."
    print_info "Lembre-se de atualizar o endpoint do talosconfig para incluir o novo CP se necessário."
}

# Função para adicionar Worker
add_worker_node() {
    print_step "Adicionando novo Worker Node..."
    echo

    read -p "Digite o IP do novo Worker: " new_worker_ip

    if [[ ! "$new_worker_ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        print_error "IP inválido!"
        return
    fi

    print_info "Testando conectividade com $new_worker_ip..."
    local ping_ok=false
    for attempt in $(seq 1 3); do
        if ping -c 1 "$new_worker_ip" >/dev/null 2>&1; then
            ping_ok=true
            break
        fi

        if [[ $attempt -lt 3 ]]; then
            local delay
            delay=$(backoff_delay "$attempt" "$BACKOFF_PING_BASE" "$BACKOFF_PING_CAP")
            sleep "$delay"
        fi
    done

    if [[ "$ping_ok" != "true" ]]; then
        print_warning "Não foi possível fazer ping para $new_worker_ip"
        continue_anyway=$(ask_yes_no "Continuar mesmo assim? (y/n) [n]: " "n")
        [[ "$continue_anyway" != "y" ]] && return
    fi

    # Obter informações do cluster atual
    local cluster_info=$(get_current_cluster_info)
    local current_cluster=$(echo "$cluster_info" | cut -d'|' -f1)
    local endpoint=$(echo "$cluster_info" | cut -d'|' -f2)

    if [[ -z "$current_cluster" ]]; then
        print_error "Não foi possível determinar o cluster atual"
        return
    fi

    print_info "Cluster: $current_cluster"
    print_info "Endpoint: $endpoint"

    # Tentar encontrar a pasta do cluster original
    local cluster_dir=""
    local original_worker_config=""
    local config_result=""

    if config_result=$(find_original_config "worker" "$current_cluster" "$endpoint"); then
        cluster_dir="${config_result%%|*}"
        original_worker_config="${config_result#*|}"
        print_success "Encontrada configuração original do cluster em: $cluster_dir"
    fi

    local used_generated_config=false

    if [[ -n "$original_worker_config" ]]; then
        # Usar configuração original existente
        print_info "Usando configuração worker original do cluster..."

        print_info "Aplicando configuração no novo Worker $new_worker_ip..."
        if talosctl apply-config --insecure --nodes "$new_worker_ip" --file "$original_worker_config"; then
            print_success "Configuração aplicada com sucesso!"
        else
            print_error "Falha ao aplicar configuração no novo Worker"
            return
        fi
    else
        # Método alternativo: usar machineconfig patch
        print_info "Configuração original não encontrada. Gerando nova configuração..."
        print_warning "ATENÇÃO: Este método pode nao funcionar se o cluster foi criado com certificados diferentes"
        continue_anyway=$(ask_yes_no "Deseja continuar mesmo assim? (y/n) [n]: " "n")
        if [[ "$continue_anyway" != "y" ]]; then
            print_info "Operacao cancelada. Use o worker.yaml original do cluster para garantir o join."
            return
        fi

        local config_dir="/tmp/new-worker-$(date +%s)"
        mkdir -p "$config_dir"

        # Gerar nova configuração (pode haver incompatibilidade de certificados)
        print_info "Gerando configuração compatível..."
        talosctl gen config "$current_cluster" "$endpoint" --output-dir "$config_dir" --force
        used_generated_config=true

        print_info "Aplicando configuração no novo Worker $new_worker_ip..."
        if talosctl apply-config --insecure --nodes "$new_worker_ip" --file "$config_dir/worker.yaml"; then
            print_success "Configuração aplicada com sucesso!"
        else
            print_error "Falha ao aplicar configuração no novo Worker"
            print_info "💡 Solução recomendada:"
            echo "  1. Certifique-se que o nó $new_worker_ip está executando Talos OS"
            echo "  2. Se o cluster foi criado externamente, use as configurações originais"
            echo "  3. Ou use: talosctl apply-config --insecure --nodes $new_worker_ip --file <worker-original.yaml>"
            rm -rf "$config_dir"
            return
        fi

        # Limpeza
        rm -rf "$config_dir"
    fi

    # Aguardar e verificar o nó
    print_info "Verificando status do novo Worker..."
    local max_attempts=6
    local attempt=1

    while [[ $attempt -le $max_attempts ]]; do
        if timeout 30 talosctl --nodes "$new_worker_ip" health --server=false >/dev/null 2>&1; then
            print_success "✅ Worker $new_worker_ip está saudável!"
            break
        fi

        if [[ $attempt -lt $max_attempts ]]; then
            local delay
            delay=$(backoff_delay "$attempt" "$BACKOFF_HEALTH_BASE" "$BACKOFF_HEALTH_CAP")
            print_info "Nó ainda está inicializando... aguardando ${delay}s"
            sleep "$delay"
        fi
        attempt=$((attempt + 1))
    done

    print_info "Aguardando o nó aparecer no Kubernetes..."
    attempt=1
    while [[ $attempt -le $max_attempts ]]; do
        if kubectl get nodes -o wide 2>/dev/null | grep -q "$new_worker_ip"; then
            break
        fi
        if [[ $attempt -lt $max_attempts ]]; then
            local delay
            delay=$(backoff_delay "$attempt" "$BACKOFF_K8S_APPEAR_BASE" "$BACKOFF_K8S_APPEAR_CAP")
            sleep "$delay"
        fi
        attempt=$((attempt + 1))
    done

    print_info "Status do cluster:"
    kubectl get nodes -o wide || print_warning "Erro ao obter nós do Kubernetes"

    # Aplicar plugins no novo nó (se existirem configs)
    if [[ -n "$cluster_dir" ]]; then
        local talosconfig_path=""
        local plugin_files=()

        if [[ -f "$cluster_dir/talosconfig" ]]; then
            talosconfig_path="$cluster_dir/talosconfig"
        fi

        [[ -f "$cluster_dir/tailscale.yaml" ]] && plugin_files+=("tailscale:$cluster_dir/tailscale.yaml")
        [[ -f "$cluster_dir/cloudflare.yaml" ]] && plugin_files+=("cloudflared:$cluster_dir/cloudflare.yaml")

        if [[ ${#plugin_files[@]} -gt 0 ]]; then
            echo
            apply_plugins=$(ask_yes_no "Aplicar configuracoes de plugins no novo no? (y/n) [n]: " "n")

            if [[ "$apply_plugins" == "y" ]]; then
                print_step "Aplicando plugins no novo Worker..."
                for item in "${plugin_files[@]}"; do
                    local name="${item%%:*}"
                    local file="${item#*:}"
                    apply_plugin_to_node "$name" "$file" "$new_worker_ip" "$talosconfig_path"
                done
            fi
        fi
    fi

    # Aplicar role label ao worker
    echo
    if [[ "$used_generated_config" == "true" ]]; then
        print_warning "O Worker pode nao ingressar no Kubernetes se os secrets forem diferentes."
        print_info "Se nao aparecer no cluster, use o worker.yaml original do cluster."
    else
        apply_node_role_label "$new_worker_ip" "worker"
    fi

    print_success "✅ Worker $new_worker_ip adicionado ao cluster!"
    print_info "Verificar role do nó: kubectl get nodes"
}

# ========================================
# MENU 5: GERENCIAR CLUSTER
# ========================================
menu_manage_cluster() {
    print_menu "╔════════════════════════════════════════════════╗"
    print_menu "║     GERENCIAR CLUSTER                          ║"
    print_menu "╚════════════════════════════════════════════════╝"
    echo

    check_talosctl
    echo

    print_flow_steps "Fluxo do processo:" \
        "Selecionar cluster" \
        "Executar acao" \
        "Validar resultado"

    # Selecionar cluster/contexto
    if ! select_cluster_context; then
        return
    fi
    echo

    print_menu "Escolha uma ação:"
    echo "  1) 🔄 Reiniciar nós (reboot)"
    echo "  2) 🔌 Desligar nós (shutdown)"
    echo "  3) 🔧 Gerenciar serviços"
    echo "  4) ♻️  Reset de nó"
    echo "  5) 📋 Listar nós do cluster"
    echo "  6) 📥 Baixar kubeconfig"
    echo "  7) ⬅️  Voltar"
    echo

    read -p "Escolha [1-7]: " manage_choice

    case $manage_choice in
        1) manage_reboot_nodes ;;
        2) manage_shutdown_nodes ;;
        3) manage_services ;;
        4) manage_reset_node ;;
        5) list_cluster_nodes ;;
        6) manage_download_kubeconfig ;;
        7) return ;;
        *) print_error "Opção inválida!" ;;
    esac
}

# Função para baixar kubeconfig
manage_download_kubeconfig() {
    print_step "Baixar kubeconfig"
    echo

    local current_context
    current_context=$(talosctl config info 2>/dev/null | awk -F': ' '/Current context:/ {print $2}')
    if [[ -z "$current_context" ]]; then
        print_error "Nao foi possivel detectar o contexto atual"
        return 1
    fi

    merge_choice=$(ask_yes_no "Fazer merge em ~/.kube/config? (y/n) [n]: " "n")

    if [[ "$merge_choice" == "y" ]]; then
        if [[ -f "$HOME/.kube/config" ]]; then
            local backup_file="$HOME/.kube/config.backup.$(date +%Y%m%d_%H%M%S)"
            mkdir -p "$HOME/.kube"
            cp "$HOME/.kube/config" "$backup_file"
            print_info "Backup do kubeconfig criado: $backup_file"
        else
            mkdir -p "$HOME/.kube"
        fi

        if talosctl kubeconfig --merge=true --force; then
            print_success "Kubeconfig merged com sucesso em ~/.kube/config!"
        else
            print_error "Falha ao fazer merge do kubeconfig"
            return 1
        fi
    else
        local default_path="$PWD/kubeconfig-${current_context}"
        read -p "Salvar kubeconfig em (ENTER para $default_path): " out_path
        if [[ -z "$out_path" ]]; then
            out_path="$default_path"
        fi

        if talosctl kubeconfig "$out_path" --force; then
            print_success "Kubeconfig salvo em: $out_path"
            print_info "Use: export KUBECONFIG=$out_path"
        else
            print_error "Falha ao obter kubeconfig"
            return 1
        fi
    fi
}

# Função para gerenciar reboot
manage_reboot_nodes() {
    print_step "Reiniciar Nós do Cluster"
    echo

    read -p "Digite os IPs dos nós para reiniciar (separados por espaço): " nodes_input
    IFS=' ' read -ra NODES <<< "$nodes_input"

    if [[ ${#NODES[@]} -eq 0 ]]; then
        print_error "Nenhum nó especificado!"
        return
    fi

    print_warning "⚠️  ATENÇÃO: Esta operação irá reiniciar os nós especificados!"
    echo "Nós a serem reiniciados: ${NODES[*]}"
    confirm=$(ask_yes_no "Confirma a operação? (y/n) [n]: " "n")

    if [[ "$confirm" == "y" ]]; then
        local reboot_attempt=1
        for node in "${NODES[@]}"; do
            print_info "Reiniciando nó $node..."
            talosctl reboot --nodes "$node" --wait=false
            sleep_backoff "$reboot_attempt" "$BACKOFF_PLUGIN_BASE" "$BACKOFF_PLUGIN_CAP"
            reboot_attempt=$((reboot_attempt + 1))
        done
        print_success "Comando de reboot enviado para todos os nós!"
        print_info "Os nós levarão alguns minutos para reiniciar."
    else
        print_info "Operação cancelada."
    fi
}

# Função para gerenciar shutdown
manage_shutdown_nodes() {
    print_step "Desligar Nós do Cluster"
    echo

    read -p "Digite os IPs dos nós para desligar (separados por espaço): " nodes_input
    IFS=' ' read -ra NODES <<< "$nodes_input"

    if [[ ${#NODES[@]} -eq 0 ]]; then
        print_error "Nenhum nó especificado!"
        return
    fi

    print_warning "⚠️  ATENÇÃO: Esta operação irá desligar os nós especificados!"
    echo "Nós a serem desligados: ${NODES[*]}"
    confirm=$(ask_yes_no "Confirma a operação? (y/n) [n]: " "n")

    if [[ "$confirm" == "y" ]]; then
        local shutdown_attempt=1
        for node in "${NODES[@]}"; do
            print_info "Desligando nó $node..."
            talosctl shutdown --nodes "$node" --wait=false
            sleep_backoff "$shutdown_attempt" "$BACKOFF_PLUGIN_BASE" "$BACKOFF_PLUGIN_CAP"
            shutdown_attempt=$((shutdown_attempt + 1))
        done
        print_success "Comando de shutdown enviado para todos os nós!"
    else
        print_info "Operação cancelada."
    fi
}

# Função para gerenciar serviços
manage_services() {
    print_step "Gerenciar Serviços do Talos"
    echo

    read -p "Digite o IP do nó: " node_ip
    if [[ -z "$node_ip" ]]; then
        print_error "IP do nó é obrigatório!"
        return
    fi

    print_info "Listando serviços do nó $node_ip:"
    talosctl services --nodes "$node_ip"
    echo

    print_info "Ações disponíveis:"
    echo "  1) Restart um serviço"
    echo "  2) Stop um serviço"
    echo "  3) Start um serviço"
    echo "  4) Status detalhado de um serviço"
    echo

    read -p "Escolha [1-4]: " service_action
    read -p "Nome do serviço: " service_name

    case $service_action in
        1) talosctl restart "$service_name" --nodes "$node_ip" ;;
        2) talosctl service stop "$service_name" --nodes "$node_ip" ;;
        3) talosctl service start "$service_name" --nodes "$node_ip" ;;
        4) talosctl service "$service_name" --nodes "$node_ip" ;;
        *) print_error "Opção inválida!" ;;
    esac
}

# Função para reset de nó
manage_reset_node() {
    print_step "Reset de Nó"
    echo

    read -p "Digite o IP do nó para fazer reset: " node_ip
    if [[ -z "$node_ip" ]]; then
        print_error "IP do nó é obrigatório!"
        return
    fi

    print_warning "⚠️  PERIGO: Esta operação irá RESETAR COMPLETAMENTE o nó $node_ip!"
    print_warning "Todos os dados serão perdidos e o nó será restaurado ao estado inicial."
    echo
    read -p "Digite 'CONFIRMO' para prosseguir: " confirm

    if [[ "$confirm" == "CONFIRMO" ]]; then
        print_info "Executando reset do nó $node_ip..."
        talosctl reset --nodes "$node_ip" --graceful=false --wait=false
        print_success "Reset iniciado no nó $node_ip"
    else
        print_info "Operação cancelada."
    fi
}

# Função para listar nós
list_cluster_nodes() {
    print_step "Nós do Cluster"
    echo

    print_info "Nós Talos:"
    talosctl get members
    echo

    print_info "Nós Kubernetes:"
    kubectl get nodes -o wide || print_warning "Falha ao obter nós do Kubernetes"
    echo
}

# ========================================
# MENU 6: DIAGNÓSTICO & LOGS
# ========================================
menu_diagnostics() {
    print_menu "╔════════════════════════════════════════════════╗"
    print_menu "║     DIAGNÓSTICO & LOGS                         ║"
    print_menu "╚════════════════════════════════════════════════╝"
    echo

    check_talosctl
    echo

    print_flow_steps "Fluxo do processo:" \
        "Selecionar cluster" \
        "Coletar diagnosticos" \
        "Exibir resultados"

    # Selecionar cluster/contexto
    if ! select_cluster_context; then
        return
    fi
    echo

    print_menu "Escolha uma opção de diagnóstico:"
    echo "  1) 🏥 Health Check do Cluster"
    echo "  2) 📋 Logs de Serviços"
    echo "  3) 🔍 Eventos do Sistema"
    echo "  4) 💾 Logs do Kernel (dmesg)"
    echo "  5) 🐛 Support Bundle (debug completo)"
    echo "  6) 📊 Informações do Sistema"
    echo "  7) ⬅️  Voltar"
    echo

    read -p "Escolha [1-7]: " diag_choice

    case $diag_choice in
        1) cluster_health_check ;;
        2) view_service_logs ;;
        3) view_system_events ;;
        4) view_kernel_logs ;;
        5) generate_support_bundle ;;
        6) system_information ;;
        7) return ;;
        *) print_error "Opção inválida!" ;;
    esac
}

# Health Check do cluster
cluster_health_check() {
    print_step "Health Check do Cluster"
    echo

    print_info "Verificando saúde do cluster Talos..."
    talosctl health || print_warning "Health check do Talos retornou erro"
    echo

    print_info "Status dos nós Kubernetes:"
    kubectl get nodes || print_warning "Falha ao obter nós do Kubernetes"
    echo

    print_info "Status dos pods críticos:"
    kubectl get pods -n kube-system --field-selector=status.phase!=Running,status.phase!=Succeeded || print_warning "Falha ao obter pods críticos"
    echo

    print_info "Uso de recursos dos nós:"
    kubectl top nodes 2>/dev/null || print_warning "Metrics server não disponível"
}

# Visualizar logs de serviços
view_service_logs() {
    print_step "Logs de Serviços"
    echo

    read -p "Digite o IP do nó: " node_ip
    if [[ -z "$node_ip" ]]; then
        print_error "IP do nó é obrigatório!"
        return
    fi

    print_info "Serviços disponíveis no nó $node_ip:"
    talosctl services --nodes "$node_ip"
    echo

    read -p "Nome do serviço: " service_name
    if [[ -z "$service_name" ]]; then
        print_error "Nome do serviço é obrigatório!"
        return
    fi

    read -p "Número de linhas (padrão 50): " lines
    lines=${lines:-50}

    print_info "📋 Logs do serviço $service_name (últimas $lines linhas):"
    talosctl logs "$service_name" --nodes "$node_ip" --tail="$lines"
}

# Visualizar eventos do sistema
view_system_events() {
    print_step "Eventos do Sistema"
    echo

    read -p "Digite o IP do nó: " node_ip
    if [[ -z "$node_ip" ]]; then
        print_error "IP do nó é obrigatório!"
        return
    fi

    print_info "🔍 Eventos em tempo real do nó $node_ip:"
    print_info "Pressione Ctrl+C para parar..."
    echo

    talosctl events --nodes "$node_ip"
}

# Visualizar logs do kernel
view_kernel_logs() {
    print_step "Logs do Kernel (dmesg)"
    echo

    read -p "Digite o IP do nó: " node_ip
    if [[ -z "$node_ip" ]]; then
        print_error "IP do nó é obrigatório!"
        return
    fi

    read -p "Número de linhas (padrão 100): " lines
    lines=${lines:-100}

    print_info "💾 Logs do kernel do nó $node_ip (últimas $lines linhas):"
    talosctl dmesg --nodes "$node_ip" --tail="$lines"
}

# Gerar support bundle
generate_support_bundle() {
    print_step "Gerando Support Bundle"
    echo

    local bundle_dir="/tmp/talos-support-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$bundle_dir"

    print_info "Coletando informações de debug..."
    print_info "Diretório: $bundle_dir"
    echo

    if talosctl support --output "$bundle_dir"; then
        print_success "✅ Support bundle gerado com sucesso!"
        print_info "📁 Localização: $bundle_dir"
        echo
        print_info "Conteúdo:"
        ls -la "$bundle_dir"
    else
        print_error "Falha ao gerar support bundle"
    fi
}

# Informações do sistema
system_information() {
    print_step "Informações do Sistema"
    echo

    read -p "Digite o IP do nó: " node_ip
    if [[ -z "$node_ip" ]]; then
        print_error "IP do nó é obrigatório!"
        return
    fi

    print_info "📊 Informações do nó $node_ip:"
    echo

    print_info "Versão do Talos:"
    talosctl version --nodes "$node_ip"
    echo

    print_info "Uso de memória:"
    talosctl memory --nodes "$node_ip"
    echo

    print_info "Processos em execução:"
    talosctl processes --nodes "$node_ip"
    echo

    print_info "Uso de disco:"
    talosctl usage --nodes "$node_ip"
    echo

    print_info "Conexões de rede:"
    talosctl netstat --nodes "$node_ip"
}

# ========================================
# MENU 7: DASHBOARD & MONITORAMENTO
# ========================================
menu_dashboard() {
    print_menu "╔════════════════════════════════════════════════╗"
    print_menu "║     DASHBOARD & MONITORAMENTO                  ║"
    print_menu "╚════════════════════════════════════════════════╝"
    echo

    check_talosctl
    echo

    print_flow_steps "Fluxo do processo:" \
        "Selecionar cluster" \
        "Selecionar ferramenta" \
        "Visualizar saida"

    # Selecionar cluster/contexto
    if ! select_cluster_context; then
        return
    fi
    echo

    print_menu "Escolha uma opção:"
    echo "  1) 🖥️  Dashboard do Cluster (interativo)"
    echo "  2) 📈 Estatísticas de Containers"
    echo "  3) 🔍 Monitorar Logs em Tempo Real"
    echo "  4) 📊 Informações de Rede"
    echo "  5) 💾 Monitorar Uso de Recursos"
    echo "  6) ⬅️  Voltar"
    echo

    read -p "Escolha [1-6]: " dashboard_choice

    case $dashboard_choice in
        1) launch_dashboard ;;
        2) container_stats ;;
        3) monitor_logs_realtime ;;
        4) network_information ;;
        5) resource_monitoring ;;
        6) return ;;
        *) print_error "Opção inválida!" ;;
    esac
}

# Lançar dashboard interativo
launch_dashboard() {
    print_step "Lançando Dashboard do Cluster"
    echo

    print_info "🖥️  Iniciando dashboard interativo do Talos..."
    print_info "Use Ctrl+C para sair do dashboard"
    echo

    talosctl dashboard
}

# Estatísticas de containers
container_stats() {
    print_step "Estatísticas de Containers"
    echo

    read -p "Digite o IP do nó: " node_ip
    if [[ -z "$node_ip" ]]; then
        print_error "IP do nó é obrigatório!"
        return
    fi

    print_info "📈 Estatísticas de containers do nó $node_ip:"
    echo

    # Listar containers
    print_info "Containers em execução:"
    talosctl containers --nodes "$node_ip"
    echo

    # Stats de containers
    print_info "Estatísticas de uso:"
    talosctl stats --nodes "$node_ip"
}

# Monitorar logs em tempo real
monitor_logs_realtime() {
    print_step "Monitoramento de Logs em Tempo Real"
    echo

    read -p "Digite o IP do nó: " node_ip
    if [[ -z "$node_ip" ]]; then
        print_error "IP do nó é obrigatório!"
        return
    fi

    print_info "Serviços disponíveis:"
    talosctl services --nodes "$node_ip"
    echo

    read -p "Nome do serviço (ou ENTER para todos): " service_name

    print_info "🔍 Monitorando logs em tempo real..."
    print_info "Pressione Ctrl+C para parar"
    echo

    if [[ -z "$service_name" ]]; then
        # Monitorar todos os serviços principais
        talosctl logs --nodes "$node_ip" --follow
    else
        talosctl logs "$service_name" --nodes "$node_ip" --follow
    fi
}

# Informações de rede
network_information() {
    print_step "Informações de Rede"
    echo

    read -p "Digite o IP do nó: " node_ip
    if [[ -z "$node_ip" ]]; then
        print_error "IP do nó é obrigatório!"
        return
    fi

    print_info "📊 Informações de rede do nó $node_ip:"
    echo

    print_info "Interfaces de rede:"
    talosctl get links --nodes "$node_ip"
    echo

    print_info "Rotas de rede:"
    talosctl get routes --nodes "$node_ip"
    echo

    print_info "Conexões ativas:"
    talosctl netstat --nodes "$node_ip"
}

# Monitoramento de recursos
resource_monitoring() {
    print_step "Monitoramento de Recursos"
    echo

    print_info "🔄 Monitoramento contínuo do cluster..."
    print_info "Pressione Ctrl+C para parar"
    echo

    local attempt=1
    while true; do
        clear
        print_menu "╔════════════════════════════════════════════════╗"
        print_menu "║     RECURSOS DO CLUSTER - $(date '+%H:%M:%S')        ║"
        print_menu "╚════════════════════════════════════════════════╝"
        echo

        print_info "Nós Kubernetes:"
        kubectl get nodes || true
        echo

        print_info "Pods críticos:"
        kubectl get pods -n kube-system --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | head -10 || true
        echo

        print_info "Uso de recursos (se disponível):"
        kubectl top nodes 2>/dev/null || echo "Metrics server não disponível"
        echo

        sleep_backoff "$attempt" "$BACKOFF_UPGRADE_BASE" "$BACKOFF_UPGRADE_CAP"
        attempt=$((attempt + 1))
    done
}

# ========================================
# MENU PRINCIPAL
# ========================================
show_main_menu() {
    clear
    print_menu "╔════════════════════════════════════════════════╗"
    print_menu "║                                                ║"
    print_menu "║       TALOS OS - MENU UNIFICADO                ║"
    print_menu "║                                                ║"
    print_menu "╚════════════════════════════════════════════════╝"
    echo
    print_menu "  1) 🚀 Criar Novo Cluster Talos"
    print_menu "  2) ➕ Expandir Cluster Existente"
    print_menu "  3) 📦 Atualizar talosctl"
    print_menu "  4) ⬆️  Upgrade de Cluster Existente"
    print_menu "  5) 🔧 Gerenciar Cluster"
    print_menu "  6) 🩺 Diagnóstico & Logs"
    print_menu "  7) 📊 Dashboard & Monitoramento"
    print_menu "  8) 🚪 Sair"
    echo
    print_menu "╚════════════════════════════════════════════════╝"
    echo
}

# Main loop
main() {
    while true; do
        show_main_menu
        read -p "Escolha uma opção [1-8]: " choice
        echo

        case $choice in
            1)
                menu_create_cluster
                echo
                read -p "Pressione ENTER para voltar ao menu..."
                ;;
            2)
                menu_expand_cluster
                echo
                read -p "Pressione ENTER para voltar ao menu..."
                ;;
            3)
                menu_update_talosctl
                echo
                read -p "Pressione ENTER para voltar ao menu..."
                ;;
            4)
                menu_upgrade_cluster
                echo
                read -p "Pressione ENTER para voltar ao menu..."
                ;;
            5)
                menu_manage_cluster
                echo
                read -p "Pressione ENTER para voltar ao menu..."
                ;;
            6)
                menu_diagnostics
                echo
                read -p "Pressione ENTER para voltar ao menu..."
                ;;
            7)
                menu_dashboard
                echo
                read -p "Pressione ENTER para voltar ao menu..."
                ;;
            8)
                print_success "Saindo... Até logo!"
                exit 0
                ;;
            *)
                print_error "Opção inválida! Escolha entre 1-8"
                sleep_backoff 1 "$BACKOFF_MENU_BASE" "$BACKOFF_MENU_CAP"
                ;;
        esac
    done
}

# Executar menu principal
main "$@"
