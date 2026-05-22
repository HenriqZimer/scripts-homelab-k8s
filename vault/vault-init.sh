#!/bin/bash

# =====================================================================
# VAULT - INICIALIZAÇÃO E SALVAMENTO DE CREDENCIAIS
# =====================================================================

set -e

NAMESPACE="vault"
POD_NAME="vault-0"
OUTPUT_DIR="/home/henriqzimer/projetos/kubernetes/vault-credentials"
CREDS_FILE="$OUTPUT_DIR/vault-credentials.txt"
JSON_FILE="$OUTPUT_DIR/vault-init-output.json"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}🔐 VAULT - INICIALIZAÇÃO${NC}"
echo -e "${BLUE}================================${NC}"
echo ""

# 1. Verificar se pod existe e está rodando
echo -e "${YELLOW}1️⃣  Verificando pod do Vault...${NC}"
if ! kubectl get pod $POD_NAME -n $NAMESPACE &>/dev/null; then
    echo -e "${RED}❌ Pod $POD_NAME não encontrado no namespace $NAMESPACE${NC}"
    exit 1
fi

POD_STATUS=$(kubectl get pod $POD_NAME -n $NAMESPACE -o jsonpath='{.status.phase}')
if [ "$POD_STATUS" != "Running" ]; then
    echo -e "${RED}❌ Pod $POD_NAME não está Running (status: $POD_STATUS)${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Pod $POD_NAME está Running${NC}"
echo ""

# 2. Verificar se Vault já está inicializado
echo -e "${YELLOW}2️⃣  Verificando status do Vault...${NC}"
VAULT_STATUS=$(kubectl exec $POD_NAME -n $NAMESPACE -- vault status -format=json 2>/dev/null || echo '{"initialized":false}')
IS_INITIALIZED=$(echo $VAULT_STATUS | grep -o '"initialized":[^,}]*' | cut -d':' -f2 | tr -d ' ')

if [ "$IS_INITIALIZED" = "true" ]; then
    echo -e "${YELLOW}⚠️  Vault já está inicializado!${NC}"
    echo ""
    echo -e "${BLUE}Opções:${NC}"
    echo "1. Se você tem as credenciais salvas, use: ./vault-unseal.sh"
    echo "2. Se perdeu as credenciais, será necessário reset completo"
    echo ""
    read -p "Deseja continuar mesmo assim? (yes/no): " CONFIRM
    if [ "$CONFIRM" != "yes" ]; then
        echo -e "${YELLOW}Operação cancelada.${NC}"
        exit 0
    fi
fi

echo -e "${GREEN}✅ Vault pronto para inicialização${NC}"
echo ""

# 3. Criar diretório para credenciais
echo -e "${YELLOW}3️⃣  Criando diretório para credenciais...${NC}"
mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"

if [ -f "$CREDS_FILE" ]; then
    BACKUP_FILE="$OUTPUT_DIR/vault-credentials.backup.$(date +%Y%m%d_%H%M%S).txt"
    echo -e "${YELLOW}⚠️  Arquivo de credenciais existente! Criando backup: $BACKUP_FILE${NC}"
    mv "$CREDS_FILE" "$BACKUP_FILE"
fi

echo -e "${GREEN}✅ Diretório criado: $OUTPUT_DIR${NC}"
echo ""

# 4. Inicializar Vault
echo -e "${YELLOW}4️⃣  Inicializando Vault...${NC}"
echo -e "${BLUE}   - Gerando 5 unseal keys (threshold: 3)${NC}"
echo -e "${BLUE}   - Gerando root token${NC}"
echo ""

# Inicializar com 5 key shares e threshold de 3
set +e
INIT_OUTPUT=$(kubectl exec $POD_NAME -n $NAMESPACE -- vault operator init \
    -key-shares=5 \
    -key-threshold=3 \
    -format=json 2>&1)
INIT_EXIT_CODE=$?
set -e

if [ $INIT_EXIT_CODE -ne 0 ]; then
    echo -e "${RED}❌ Erro ao inicializar Vault:${NC}"
    echo "$INIT_OUTPUT"
    echo ""
    echo -e "${YELLOW}Possíveis causas:${NC}"
    echo "  - Vault já está inicializado (use ./vault-unseal.sh)"
    echo "  - Tabela PostgreSQL com constraint incorreta (execute: vault-fix-table-constraint.sql)"
    echo "  - Problema de conectividade com PostgreSQL"
    exit 1
fi

# Verificar se output é JSON válido
if ! echo "$INIT_OUTPUT" | grep -q '"unseal_keys_b64"'; then
    echo -e "${RED}❌ Output da inicialização não é JSON válido:${NC}"
    echo "$INIT_OUTPUT"
    exit 1
fi

echo -e "${GREEN}✅ Vault inicializado com sucesso!${NC}"
echo ""

# 5. Salvar output JSON
echo "$INIT_OUTPUT" > "$JSON_FILE"
chmod 600 "$JSON_FILE"

# 6. Extrair e salvar credenciais em formato legível
echo -e "${YELLOW}5️⃣  Salvando credenciais...${NC}"

cat > "$CREDS_FILE" << EOF
# =====================================================================
# VAULT CREDENTIALS - MANTENHA ESTE ARQUIVO SEGURO!
# =====================================================================
# Data de criação: $(date '+%Y-%m-%d %H:%M:%S')
# Namespace: vault
# Pod: vault-0
# =====================================================================

EOF

# Extrair unseal keys
echo "# UNSEAL KEYS (necessário 3 de 5 para unseal)" >> "$CREDS_FILE"
UNSEAL_KEYS=$(echo "$INIT_OUTPUT" | grep -o '"unseal_keys_b64":\[[^]]*\]' | sed 's/"unseal_keys_b64":\[//;s/\]//;s/"//g')

KEY_NUM=1
IFS=',' read -ra KEYS <<< "$UNSEAL_KEYS"
for KEY in "${KEYS[@]}"; do
    KEY=$(echo $KEY | tr -d ' ')
    echo "UNSEAL_KEY_$KEY_NUM=$KEY" >> "$CREDS_FILE"
    KEY_NUM=$((KEY_NUM + 1))
done

echo "" >> "$CREDS_FILE"

# Extrair root token
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | grep -o '"root_token":"[^"]*"' | cut -d'"' -f4)
echo "# ROOT TOKEN (acesso administrativo total)" >> "$CREDS_FILE"
echo "ROOT_TOKEN=$ROOT_TOKEN" >> "$CREDS_FILE"

echo "" >> "$CREDS_FILE"
echo "# =====================================================================" >> "$CREDS_FILE"
echo "# INSTRUÇÕES DE USO:" >> "$CREDS_FILE"
echo "# 1. Para fazer unseal: ./vault-unseal.sh" >> "$CREDS_FILE"
echo "# 2. Para login: kubectl exec vault-0 -n vault -- vault login \$ROOT_TOKEN" >> "$CREDS_FILE"
echo "# 3. Para verificar status: kubectl exec vault-0 -n vault -- vault status" >> "$CREDS_FILE"
echo "# =====================================================================" >> "$CREDS_FILE"

chmod 600 "$CREDS_FILE"

echo -e "${GREEN}✅ Credenciais salvas em: $CREDS_FILE${NC}"
echo -e "${GREEN}✅ JSON completo salvo em: $JSON_FILE${NC}"
echo ""

# 7. Exibir credenciais
echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}🔑 SUAS CREDENCIAIS VAULT${NC}"
echo -e "${BLUE}================================${NC}"
echo ""

echo -e "${YELLOW}📝 Unseal Keys (guarde 3 de 5):${NC}"
KEY_NUM=1
for KEY in "${KEYS[@]}"; do
    KEY=$(echo $KEY | tr -d ' ')
    echo -e "${GREEN}   Key $KEY_NUM: $KEY${NC}"
    KEY_NUM=$((KEY_NUM + 1))
done

echo ""
echo -e "${YELLOW}🔐 Root Token:${NC}"
echo -e "${GREEN}   $ROOT_TOKEN${NC}"
echo ""

echo -e "${BLUE}================================${NC}"
echo -e "${RED}⚠️  ATENÇÃO - SEGURANÇA:${NC}"
echo -e "${RED}   - Faça BACKUP deste arquivo: $CREDS_FILE${NC}"
echo -e "${RED}   - Guarde em local SEGURO (off-cluster)${NC}"
echo -e "${RED}   - SEM estas keys, NÃO é possível acessar o Vault!${NC}"
echo -e "${BLUE}================================${NC}"
echo ""

# 8. Fazer unseal automático
echo -e "${YELLOW}6️⃣  Fazendo unseal do Vault...${NC}"
echo ""

KEY_COUNT=0
for KEY in "${KEYS[@]}"; do
    KEY=$(echo $KEY | tr -d ' ')
    if [ $KEY_COUNT -lt 3 ]; then
        kubectl exec $POD_NAME -n $NAMESPACE -- vault operator unseal "$KEY" > /dev/null 2>&1
        echo -e "${GREEN}   ✅ Unseal key $((KEY_COUNT + 1))/3 aplicada${NC}"
        KEY_COUNT=$((KEY_COUNT + 1))
    fi
done

echo ""

# 9. Verificar status final
echo -e "${YELLOW}7️⃣  Verificando status final do Vault...${NC}"
FINAL_STATUS=$(kubectl exec $POD_NAME -n $NAMESPACE -- vault status 2>&1 || true)

if echo "$FINAL_STATUS" | grep -q "Sealed.*false"; then
    echo -e "${GREEN}✅ Vault está UNSEALED e pronto para uso!${NC}"
    echo ""
    echo -e "${BLUE}================================${NC}"
    echo -e "${GREEN}🎉 VAULT CONFIGURADO COM SUCESSO!${NC}"
    echo -e "${BLUE}================================${NC}"
    echo ""
    echo -e "${YELLOW}📋 Próximos passos:${NC}"
    echo "1. Fazer login:      kubectl exec vault-0 -n vault -- vault login $ROOT_TOKEN"
    echo "2. Verificar status: kubectl exec vault-0 -n vault -- vault status"
    echo "3. Configurar secrets engines: kubectl exec vault-0 -n vault -- vault secrets enable -path=secret kv-v2"
    echo ""
    echo -e "${YELLOW}📁 Arquivos criados:${NC}"
    echo "   $CREDS_FILE"
    echo "   $JSON_FILE"
    echo ""
else
    echo -e "${RED}❌ Vault ainda está sealed. Status:${NC}"
    echo "$FINAL_STATUS"
    echo ""
    echo -e "${YELLOW}Execute manualmente: ./vault-unseal.sh${NC}"
fi

echo -e "${BLUE}================================${NC}"