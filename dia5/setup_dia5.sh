#!/usr/bin/env bash
# =============================================================================
# setup_dia5.sh — Infraestructura completa Día 5
# Curso: Introducción a Herramientas de Cómputo en la Nube · Azure
#
# Uso:
#   bash setup_dia5.sh <RESOURCE_GROUP> <LOCATION>
#
# Ejemplo:
#   bash setup_dia5.sh rg-curso-dia5 eastus
#
# Prerequisitos:
#   - Azure CLI instalado y sesion activa (az login)
#   - Permisos de Contributor en la suscripcion
# =============================================================================

set -euo pipefail

# ── Argumentos ──────────────────────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
  echo "Uso: bash setup_dia5.sh <RESOURCE_GROUP> <LOCATION>"
  echo "Ejemplo: bash setup_dia5.sh rg-curso-dia5 eastus"
  exit 1
fi

RG="$1"
LOC="$2"

# ── Nombres de recursos (derivados del RG para evitar colisiones) ────────────
SUFFIX="${RG//[^a-z0-9]/}"          # solo letras y numeros
STORAGE_ACCOUNT="sa${SUFFIX:0:18}"  # max 24 chars, lowercase
BLOB_CONTAINER="enigh-datos"
DATALAKE_CONTAINER="datalake-dia5"
PG_SERVER="pg-${SUFFIX:0:40}-dia5"
PG_ADMIN="cursoazure"
PG_PASSWORD="CursoAzure2026!"       # cambia esto antes de usar en produccion
PG_DB="cursodb"
AML_WORKSPACE="aml-workspace-dia5"
DBR_WORKSPACE="dbr-workspace-dia5"

# ── Colores para output ──────────────────────────────────────────────────────
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${CYAN}[$(date +%H:%M:%S)]${NC} $1"; }
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
fail() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo "================================================================"
echo "  Infraestructura Día 5 — Curso Azure"
echo "  Resource Group : $RG"
echo "  Location       : $LOC"
echo "  Storage Account: $STORAGE_ACCOUNT"
echo "  PostgreSQL     : $PG_SERVER"
echo "  Azure ML       : $AML_WORKSPACE"
echo "================================================================"
echo ""

# Verificar que az cli esta autenticado
az account show > /dev/null 2>&1 || fail "No hay sesion activa. Ejecuta: az login"
SUB=$(az account show --query id -o tsv)
log "Suscripcion activa: $SUB"

# ── 1. Resource Group ────────────────────────────────────────────────────────
log "1/7 Creando Resource Group..."
az group create \
  --name "$RG" \
  --location "$LOC" \
  --tags "proyecto=curso-azure" "dia=5" \
  --output none
ok "Resource Group: $RG"

# ── 2. Storage Account + Blob + Data Lake ────────────────────────────────────
log "2/7 Creando Storage Account con jerarquia habilitada (Data Lake Gen2)..."
az storage account create \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RG" \
  --location "$LOC" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --enable-hierarchical-namespace true \
  --access-tier Hot \
  --output none
ok "Storage Account: $STORAGE_ACCOUNT"

# Obtener connection string
CONN_STR=$(az storage account show-connection-string \
  --name "$STORAGE_ACCOUNT" \
  --resource-group "$RG" \
  --query connectionString -o tsv)

# Contenedor Blob para datos raw (ENIGH)
az storage container create \
  --name "$BLOB_CONTAINER" \
  --connection-string "$CONN_STR" \
  --output none
ok "Blob container: $BLOB_CONTAINER"

# Contenedor Data Lake para datos procesados
az storage container create \
  --name "$DATALAKE_CONTAINER" \
  --connection-string "$CONN_STR" \
  --output none
ok "Data Lake container: $DATALAKE_CONTAINER"

# ── 3. PostgreSQL Flexible Server ────────────────────────────────────────────
log "3/7 Creando PostgreSQL Flexible Server (esto tarda ~3 minutos)..."
az postgres flexible-server create \
  --name "$PG_SERVER" \
  --resource-group "$RG" \
  --location "$LOC" \
  --admin-user "$PG_ADMIN" \
  --admin-password "$PG_PASSWORD" \
  --sku-name Standard_B1ms \
  --tier Burstable \
  --storage-size 32 \
  --version 16 \
  --public-access 0.0.0.0 \
  --output none
ok "PostgreSQL: $PG_SERVER"

# Crear base de datos
az postgres flexible-server db create \
  --server-name "$PG_SERVER" \
  --resource-group "$RG" \
  --database-name "$PG_DB" \
  --output none
ok "Base de datos: $PG_DB"

# Habilitar extension PostGIS
az postgres flexible-server parameter set \
  --server-name "$PG_SERVER" \
  --resource-group "$RG" \
  --name "azure.extensions" \
  --value "POSTGIS" \
  --output none
ok "Extension PostGIS habilitada"

# Agregar IP local al firewall de PostgreSQL
MY_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "0.0.0.0")
az postgres flexible-server firewall-rule create \
  --name "AllowLocalIP" \
  --server-name "$PG_SERVER" \
  --resource-group "$RG" \
  --start-ip-address "$MY_IP" \
  --end-ip-address "$MY_IP" \
  --output none
ok "Firewall: IP $MY_IP autorizada"

# ── 4. Azure ML Workspace ────────────────────────────────────────────────────
log "4/7 Creando Azure ML Workspace..."
az ml workspace create \
  --name "$AML_WORKSPACE" \
  --resource-group "$RG" \
  --location "$LOC" \
  --storage-account "$STORAGE_ACCOUNT" \
  --output none 2>/dev/null || \
az extension add --name ml --only-show-errors && \
az ml workspace create \
  --name "$AML_WORKSPACE" \
  --resource-group "$RG" \
  --location "$LOC" \
  --output none
ok "Azure ML Workspace: $AML_WORKSPACE"

# ── 5. Compute Cluster en Azure ML ───────────────────────────────────────────
log "5/7 Creando Compute Cluster en Azure ML..."
az ml compute create \
  --name "cluster-dia5" \
  --type AmlCompute \
  --resource-group "$RG" \
  --workspace-name "$AML_WORKSPACE" \
  --size Standard_DS2_v2 \
  --min-instances 0 \
  --max-instances 2 \
  --idle-time-before-scale-down 120 \
  --output none
ok "Compute Cluster: cluster-dia5"

# ── 6. Databricks Workspace ──────────────────────────────────────────────────
log "6/7 Creando Databricks Workspace (tier Standard)..."
az databricks workspace create \
  --name "$DBR_WORKSPACE" \
  --resource-group "$RG" \
  --location "$LOC" \
  --sku standard \
  --output none
ok "Databricks Workspace: $DBR_WORKSPACE"

# ── 7. Output final con credenciales ─────────────────────────────────────────
log "7/7 Recopilando credenciales..."

STORAGE_KEY=$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RG" \
  --query "[0].value" -o tsv)

PG_HOST="${PG_SERVER}.postgres.database.azure.com"

AML_SUB=$(az account show --query id -o tsv)

echo ""
echo "================================================================"
echo "  INFRAESTRUCTURA CREADA EXITOSAMENTE"
echo "================================================================"
echo ""
echo "  STORAGE"
echo "    Account name    : $STORAGE_ACCOUNT"
echo "    Account key     : ${STORAGE_KEY:0:20}...  (ver completo abajo)"
echo "    Blob container  : $BLOB_CONTAINER"
echo "    DLake container : $DATALAKE_CONTAINER"
echo "    Connection str  : guardado en credenciales.env"
echo ""
echo "  POSTGRESQL"
echo "    Host     : $PG_HOST"
echo "    Port     : 5432"
echo "    Database : $PG_DB"
echo "    User     : $PG_ADMIN"
echo "    Password : $PG_PASSWORD"
echo ""
echo "  AZURE ML"
echo "    Workspace   : $AML_WORKSPACE"
echo "    Resource Grp: $RG"
echo "    Subscription: $AML_SUB"
echo ""
echo "  DATABRICKS"
echo "    Workspace: $DBR_WORKSPACE"
echo "    URL      : $(az databricks workspace show --name $DBR_WORKSPACE --resource-group $RG --query 'workspaceUrl' -o tsv 2>/dev/null || echo 'ver portal.azure.com')"
echo ""

# Guardar credenciales en archivo .env para usar en los notebooks
cat > credenciales.env << ENVEOF
# Credenciales generadas por setup_dia5.sh
# NO subas este archivo a Git

STORAGE_ACCOUNT_NAME=${STORAGE_ACCOUNT}
STORAGE_ACCOUNT_KEY=${STORAGE_KEY}
BLOB_CONTAINER=${BLOB_CONTAINER}
DATALAKE_CONTAINER=${DATALAKE_CONTAINER}

PG_HOST=${PG_HOST}
PG_PORT=5432
PG_DATABASE=${PG_DB}
PG_USER=${PG_ADMIN}
PG_PASSWORD=${PG_PASSWORD}

AML_SUBSCRIPTION=${AML_SUB}
AML_RESOURCE_GROUP=${RG}
AML_WORKSPACE=${AML_WORKSPACE}
ENVEOF

ok "Credenciales guardadas en: credenciales.env"
echo ""
echo "  Siguiente paso:"
echo "    1. Abre el notebook: dia5_taller.ipynb"
echo "    2. Copia los valores de credenciales.env a la Seccion 0"
echo "================================================================"
echo ""
