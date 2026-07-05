# k8s-homelab-scripts

Scripts operacionais que nao se encaixam em `terraform-homelab` (provisionamento)
nem `helm-k8s-homelab` (deploy dos apps): setup interativo do Talos, bootstrap
do Vault e backup do etcd.

## talos-os/talos-complete-setup.sh

Menu interativo para criar, expandir, atualizar e diagnosticar clusters Talos
no Proxmox (Factory Images com extensions, Tailscale/Cloudflare, etc.).

## talos-os/etcd-backup.sh

Tira um snapshot do etcd via `talosctl` e mantem retencao local. O cluster
roda hoje com um unico control plane sem VIP, entao esse snapshot e a unica
forma de recuperar o estado do cluster se a VM do CP for perdida.

```bash
cd talos-os
./etcd-backup.sh
```

Variaveis de ambiente:

- `TALOSCONFIG` (default `../../terraform-homelab/configs/talosconfig`)
- `CONTROLPLANE_IP` (default: descoberto via `terraform output` em `terraform-homelab`)
- `BACKUP_DIR` (default `./etcd-backups`, ja no `.gitignore`)
- `RETENTION_DAYS` (default `14`)
- `ETCD_BACKUP_REMOTE` (opcional): destino `rsync` para copia offsite, ex.
  `user@slowbro.henriqzimer.com.br:/mnt/slowbro/kubernetes/etcd-backups/`.
  Requer autenticacao SSH por chave ja configurada para esse host - o script
  nao configura isso, so usa se a chave ja funcionar sem senha.

### Agendar via crontab

```bash
crontab -e
```

Exemplo de linha para rodar todo dia as 3h da manha:

```cron
0 3 * * * cd /caminho/para/scripts-k8s-homelab/talos-os && ETCD_BACKUP_REMOTE=user@slowbro.henriqzimer.com.br:/mnt/slowbro/kubernetes/etcd-backups/ ./etcd-backup.sh >> /var/log/etcd-backup.log 2>&1
```

Sem `ETCD_BACKUP_REMOTE`, o script mantem so a copia local (util para testes,
mas nao protege contra a perda do disco da VM do CP).

## vault/vault-init.sh e vault/vault-unseal.sh

Inicializacao e unseal do Vault (`secrets/hashicorp-vault-0`). Ver comentarios
nos proprios scripts para detalhes de uso.
