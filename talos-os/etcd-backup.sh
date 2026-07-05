#!/usr/bin/env bash
set -euo pipefail

# =====================================================================
# ETCD - BACKUP DE SNAPSHOT
# =====================================================================
# Tira um snapshot do etcd via talosctl, mantem retencao local e
# opcionalmente envia uma copia para um destino remoto via rsync.
#
# Variaveis de ambiente:
#   TALOSCONFIG        - default: ../terraform-homelab/configs/talosconfig
#   CONTROLPLANE_IP    - IP do control plane. Se vazio, descobre via
#                        terraform output no diretorio terraform-homelab.
#   BACKUP_DIR         - default: ./etcd-backups (relativo a este script)
#   RETENTION_DAYS     - default: 14
#   ETCD_BACKUP_REMOTE - destino rsync opcional, ex:
#                        user@slowbro.henriqzimer.com.br:/mnt/slowbro/kubernetes/etcd-backups/
#                        Requer autenticacao SSH por chave ja configurada.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
terraform_dir="${script_dir}/../../terraform-homelab"

: "${TALOSCONFIG:=${terraform_dir}/configs/talosconfig}"
: "${BACKUP_DIR:=${script_dir}/etcd-backups}"
: "${RETENTION_DAYS:=14}"

if [[ ! -f "${TALOSCONFIG}" ]]; then
  echo "TALOSCONFIG nao encontrado em ${TALOSCONFIG}." >&2
  echo "Rode o terraform apply em terraform-homelab primeiro, ou aponte TALOSCONFIG manualmente." >&2
  exit 1
fi

if [[ -z "${CONTROLPLANE_IP:-}" ]]; then
  CONTROLPLANE_IP="$(
    cd "${terraform_dir}" && terraform output -json controlplane_nodes 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(next(iter(d.values()))['ip'])" 2>/dev/null
  )" || true
fi

if [[ -z "${CONTROLPLANE_IP:-}" ]]; then
  echo "Nao foi possivel descobrir o IP do control plane via terraform output." >&2
  echo "Defina CONTROLPLANE_IP manualmente, ex: CONTROLPLANE_IP=192.168.1.200 $0" >&2
  exit 1
fi

mkdir -p "${BACKUP_DIR}"

timestamp="$(date +%Y%m%d-%H%M%S)"
snapshot_file="${BACKUP_DIR}/etcd-${timestamp}.snapshot"

echo "Tirando snapshot do etcd via ${CONTROLPLANE_IP}..."
talosctl --talosconfig "${TALOSCONFIG}" -e "${CONTROLPLANE_IP}" -n "${CONTROLPLANE_IP}" \
  etcd snapshot "${snapshot_file}"

if [[ ! -s "${snapshot_file}" ]]; then
  echo "Snapshot ${snapshot_file} nao foi criado ou esta vazio." >&2
  exit 1
fi

echo "Snapshot salvo em ${snapshot_file} ($(du -h "${snapshot_file}" | cut -f1))."

echo "Aplicando retencao de ${RETENTION_DAYS} dias em ${BACKUP_DIR}..."
find "${BACKUP_DIR}" -maxdepth 1 -name 'etcd-*.snapshot' -mtime "+${RETENTION_DAYS}" -print -delete

if [[ -n "${ETCD_BACKUP_REMOTE:-}" ]]; then
  echo "Enviando copia para ${ETCD_BACKUP_REMOTE}..."
  rsync -a "${snapshot_file}" "${ETCD_BACKUP_REMOTE}"
  echo "Copia remota concluida."
else
  echo "ETCD_BACKUP_REMOTE nao definido; mantendo so a copia local."
  echo "Considere configurar copia offsite (ex: ETCD_BACKUP_REMOTE=user@host:/caminho/)."
fi
