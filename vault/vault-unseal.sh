#!/bin/bash

# =====================================================================
# VAULT - UNSEAL AUTOMÁTICO
# =====================================================================

set -e

NAMESPACE="secrets"
POD_NAME="hashicorp-vault-0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CREDS_FILE="${CREDS_FILE:-$SCRIPT_DIR/vault-credentials.txt}"

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}================================${NC}"
echo -e "${BLUE}🔓 VAULT - UNSEAL AUTOMÁTICO${NC}"
echo -e "${BLUE}================================${NC}"
echo ""

# 1. Verificar se arquivo de credenciais existe
echo -e "${YELLOW}1️⃣  Verificando arquivo de credenciais...${NC}"
if [ ! -f "$CREDS_FILE" ]; then
    echo -e "${RED}❌ Arquivo de credenciais não encontrado: $CREDS_FILE${NC}"
    echo ""
    echo -e "${YELLOW}Soluções:${NC}"
    echo "1. Execute primeiro: ./vault-init.sh"
    echo "2. Ou especifique o caminho: CREDS_FILE=/caminho/para/arquivo $0"
    exit 1
fi

echo -e "${GREEN}✅ Arquivo encontrado: $CREDS_FILE${NC}"
echo ""

# 2. Verificar se pod existe e está rodando
echo -e "${YELLOW}2️⃣  Verificando pod do Vault...${NC}"
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

# 3. Verificar status atual do Vault
echo -e "${YELLOW}3️⃣  Verificando status do Vault...${NC}"

# Vault status retorna exit code 2 quando sealed, mas ainda retorna JSON
set +e
VAULT_STATUS=$(kubectl exec $POD_NAME -n $NAMESPACE -- vault status -format=json 2>&1)
VAULT_STATUS_EXIT=$?
set -e

# Extrair initialized e sealed do JSON (mesmo com exit code 2)
IS_INITIALIZED=$(echo "$VAULT_STATUS" | grep -o '"initialized":[^,}]*' | head -1 | cut -d':' -f2 | tr -d ' ')
IS_SEALED=$(echo "$VAULT_STATUS" | grep -o '"sealed":[^,}]*' | head -1 | cut -d':' -f2 | tr -d ' ')

if [ "$IS_INITIALIZED" != "true" ]; then
    echo -e "${RED}❌ Vault não está inicializado!${NC}"
    echo -e "${YELLOW}Execute primeiro: ./vault-init.sh${NC}"
    exit 1
fi

if [ "$IS_SEALED" != "true" ]; then
    echo -e "${GREEN}✅ Vault já está UNSEALED!${NC}"
    echo ""
    echo -e "${BLUE}Status atual:${NC}"
    kubectl exec $POD_NAME -n $NAMESPACE -- vault status
    exit 0
fi

echo -e "${YELLOW}⚠️  Vault está SEALED${NC}"
echo ""

# 4. Carregar unseal keys do arquivo
echo -e "${YELLOW}4️⃣  Carregando unseal keys...${NC}"

# Detectar quantas unseal keys existem no arquivo
UNSEAL_KEYS_COUNT=$(grep -c "^UNSEAL_KEY_" "$CREDS_FILE" || echo "0")

if [ "$UNSEAL_KEYS_COUNT" -eq 0 ]; then
    echo -e "${RED}❌ Nenhuma unseal key encontrada no arquivo${NC}"
    echo -e "${YELLOW}Verifique o formato do arquivo: $CREDS_FILE${NC}"
    exit 1
fi

echo -e "${GREEN}✅ $UNSEAL_KEYS_COUNT unseal key(s) encontrada(s)${NC}"

# Calcular threshold necessário do status atual
THRESHOLD=$(echo "$VAULT_STATUS" | grep -o '"t":[0-9]*' | head -1 | cut -d':' -f2 | tr -d ' ')

if [ -z "$THRESHOLD" ]; then
    THRESHOLD=3  # Default para 5 keys padrão
fi

echo -e "${BLUE}   Threshold necessário: $THRESHOLD${NC}"

# Carregar keys conforme disponíveis no arquivo
KEYS_TO_USE=$THRESHOLD
if [ "$UNSEAL_KEYS_COUNT" -lt "$THRESHOLD" ]; then
    echo -e "${RED}❌ Arquivo tem apenas $UNSEAL_KEYS_COUNT key(s), mas threshold é $THRESHOLD${NC}"
    exit 1
fi

# Carregar as keys necessárias
UNSEAL_KEYS=()
for i in $(seq 1 $KEYS_TO_USE); do
    KEY=$(grep "^UNSEAL_KEY_$i=" "$CREDS_FILE" | cut -d'=' -f2-)
    if [ -z "$KEY" ]; then
        echo -e "${RED}❌ UNSEAL_KEY_$i não encontrada no arquivo${NC}"
        exit 1
    fi
    UNSEAL_KEYS+=("$KEY")
done

echo -e "${GREEN}✅ $KEYS_TO_USE key(s) carregada(s) para unseal${NC}"
echo ""

# 5. Aplicar unseal keys
echo -e "${YELLOW}5️⃣  Aplicando unseal keys...${NC}"
echo ""

# Desabilitar set -e temporariamente para capturar exit codes
set +e

# Aplicar cada key sequencialmente
KEY_NUM=1
for KEY in "${UNSEAL_KEYS[@]}"; do
    echo -e "${BLUE}   Aplicando unseal key $KEY_NUM/$KEYS_TO_USE...${NC}"

    UNSEAL_OUTPUT=$(kubectl exec $POD_NAME -n $NAMESPACE -- vault operator unseal "$KEY" 2>&1)
    UNSEAL_EXIT=$?

    if echo "$UNSEAL_OUTPUT" | grep -q "Sealed.*false"; then
        echo -e "${GREEN}   ✅ Key $KEY_NUM aplicada (Vault UNSEALED!)${NC}"
        break
    elif echo "$UNSEAL_OUTPUT" | grep -q "Sealed.*true"; then
        echo -e "${GREEN}   ✅ Key $KEY_NUM aplicada (Vault ainda sealed)${NC}"
    else
        echo -e "${RED}   ❌ Erro ao aplicar key $KEY_NUM (exit code: $UNSEAL_EXIT)${NC}"
        echo "$UNSEAL_OUTPUT"
        set -e
        exit 1
    fi

    KEY_NUM=$((KEY_NUM + 1))
done

# Reabilitar set -e
set -e

echo ""

# 6. Verificar status final
echo -e "${YELLOW}6️⃣  Verificando status final...${NC}"
sleep 2

FINAL_STATUS=$(kubectl exec $POD_NAME -n $NAMESPACE -- vault status 2>&1 || true)

if echo "$FINAL_STATUS" | grep -q "Sealed.*false"; then
    echo -e "${GREEN}✅ Vault está UNSEALED e pronto para uso!${NC}"
    echo ""
    echo -e "${BLUE}================================${NC}"
    echo -e "${GREEN}🎉 UNSEAL CONCLUÍDO COM SUCESSO!${NC}"
    echo -e "${BLUE}================================${NC}"
    echo ""

    # Exibir root token
    ROOT_TOKEN=$(grep "^ROOT_TOKEN=" "$CREDS_FILE" | cut -d'=' -f2)
    echo -e "${YELLOW}🔐 Para fazer login, use:${NC}"
    echo "kubectl exec vault-0 -n vault -- vault login $ROOT_TOKEN"
    echo ""

    echo -e "${BLUE}Status completo:${NC}"
    echo "$FINAL_STATUS"
    echo ""
else
    echo -e "${RED}❌ Vault ainda está sealed após aplicar 3 keys${NC}"
    echo ""
    echo -e "${YELLOW}Status:${NC}"
    echo "$FINAL_STATUS"
    echo ""
    echo -e "${YELLOW}Possíveis causas:${NC}"
    echo "1. Keys incorretas no arquivo $CREDS_FILE"
    echo "2. Vault foi reinicializado (necessário vault operator init novamente)"
    echo "3. Threshold mudou (necessário mais keys)"
    exit 1
fi

echo -e "${BLUE}================================${NC}"