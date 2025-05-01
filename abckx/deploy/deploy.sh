#!/bin/bash
# Script de deploy do PgBouncer para o ecossistema ABCKX
# Compatível com o sistema deploy-standalone

set -e

# Cores para saída
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Diretórios
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
ROOT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
CONFIG_DIR="$ROOT_DIR/abckx/config"
DOCKER_DIR="$ROOT_DIR/docker"

# Arquivo de configuração deploy-standalone
if [ -f "/etc/deploy-standalone/config.env" ]; then
    source /etc/deploy-standalone/config.env
fi

# Variáveis com valores padrão
PGBOUNCER_PORT=${PGBOUNCER_PORT:-6432}
PGBOUNCER_ADMIN_PORT=${PGBOUNCER_ADMIN_PORT:-8080}
PGBOUNCER_NETWORK=${PGBOUNCER_NETWORK:-abckx-network}
PGBOUNCER_CONTAINER_NAME=${PGBOUNCER_CONTAINER_NAME:-pgbouncer}
PGBOUNCER_API_CONTAINER_NAME=${PGBOUNCER_API_CONTAINER_NAME:-pgbouncer-api}
PGBOUNCER_DATA_DIR=${PGBOUNCER_DATA_DIR:-/opt/abckx/data/pgbouncer}
PGBOUNCER_LOG_DIR=${PGBOUNCER_LOG_DIR:-/opt/abckx/logs/pgbouncer}

# Verificar se rodando como root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Por favor, execute como root ou com sudo${NC}"
  exit 1
fi

# Banner
echo -e "${BLUE}=================================================${NC}"
echo -e "${BLUE}      ABCKX PgBouncer - Script de Deploy         ${NC}"
echo -e "${BLUE}=================================================${NC}"
echo ""

# Verificar se Docker está instalado
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Docker não está instalado. Por favor, instale o Docker primeiro.${NC}"
    exit 1
fi

# Verificar se Docker Compose está instalado
if ! command -v docker-compose &> /dev/null; then
    echo -e "${RED}Docker Compose não está instalado. Por favor, instale o Docker Compose primeiro.${NC}"
    exit 1
fi

# Criar diretórios necessários
echo -e "${YELLOW}Criando diretórios...${NC}"
mkdir -p $PGBOUNCER_DATA_DIR/config
mkdir -p $PGBOUNCER_LOG_DIR
mkdir -p $PGBOUNCER_DATA_DIR/api

# Copiar arquivos de configuração
echo -e "${YELLOW}Copiando arquivos de configuração...${NC}"
cp -f $CONFIG_DIR/pgbouncer.ini $PGBOUNCER_DATA_DIR/config/
cp -f $CONFIG_DIR/users.txt $PGBOUNCER_DATA_DIR/config/ 2>/dev/null || echo -e "${YELLOW}Arquivo users.txt não encontrado, criando padrão...${NC}"

# Criar users.txt se não existir
if [ ! -f "$PGBOUNCER_DATA_DIR/config/users.txt" ]; then
    echo '"admin" "md5d528e1f80534e0bad292cc39e637d191"' > $PGBOUNCER_DATA_DIR/config/users.txt
    echo '"stats" "md5aa77ac647d3d66cd5596ce238fca40e9"' >> $PGBOUNCER_DATA_DIR/config/users.txt
    echo -e "${GREEN}Arquivo users.txt criado com usuários padrão.${NC}"
    echo -e "${YELLOW}ATENÇÃO: Altere as senhas padrão assim que possível!${NC}"
fi

# Verificar se a rede Docker existe
if ! docker network inspect $PGBOUNCER_NETWORK >/dev/null 2>&1; then
    echo -e "${YELLOW}Criando rede Docker $PGBOUNCER_NETWORK...${NC}"
    docker network create $PGBOUNCER_NETWORK
fi

# Criar arquivo docker-compose.yml
cat > $PGBOUNCER_DATA_DIR/docker-compose.yml <<EOL
version: '3.8'

services:
  pgbouncer:
    image: edoburu/pgbouncer:1.18.0
    container_name: ${PGBOUNCER_CONTAINER_NAME}
    restart: unless-stopped
    ports:
      - "${PGBOUNCER_PORT}:6432"
    volumes:
      - ${PGBOUNCER_DATA_DIR}/config/pgbouncer.ini:/etc/pgbouncer/pgbouncer.ini
      - ${PGBOUNCER_DATA_DIR}/config/users.txt:/etc/pgbouncer/users.txt
      - ${PGBOUNCER_LOG_DIR}:/var/log/pgbouncer
    networks:
      - pgbouncer-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h 127.0.0.1 -p 6432 -U admin -d pgbouncer || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 5s

  pgbouncer-api:
    image: python:3.9-slim
    container_name: ${PGBOUNCER_API_CONTAINER_NAME}
    restart: unless-stopped
    depends_on:
      - pgbouncer
    ports:
      - "${PGBOUNCER_ADMIN_PORT}:8080"
    volumes:
      - ${PGBOUNCER_DATA_DIR}/api:/app
    networks:
      - pgbouncer-network
    command: >
      bash -c "apt-get update && 
      apt-get install -y --no-install-recommends procps postgresql-client &&
      pip install --no-cache-dir fastapi uvicorn psycopg2-binary pydantic &&
      cd /app && python app.py"
    healthcheck:
      test: ["CMD-SHELL", "curl -s http://localhost:8080/ || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 10s

networks:
  pgbouncer-network:
    external: true
    name: ${PGBOUNCER_NETWORK}
EOL

# Copiar a API
echo -e "${YELLOW}Copiando API...${NC}"
cp -f $ROOT_DIR/abckx/api/app.py $PGBOUNCER_DATA_DIR/api/
chmod +x $PGBOUNCER_DATA_DIR/api/app.py

# Iniciar os serviços
echo -e "${YELLOW}Iniciando serviços...${NC}"
cd $PGBOUNCER_DATA_DIR
docker-compose down || true
docker-compose up -d

# Verificar se os contêineres estão em execução
sleep 5
if docker ps | grep -q $PGBOUNCER_CONTAINER_NAME; then
    echo -e "${GREEN}PgBouncer iniciado com sucesso!${NC}"
    echo -e "${GREEN}Porta: ${PGBOUNCER_PORT}${NC}"
else
    echo -e "${RED}Falha ao iniciar PgBouncer. Verifique os logs.${NC}"
    docker logs $PGBOUNCER_CONTAINER_NAME
    exit 1
fi

if docker ps | grep -q $PGBOUNCER_API_CONTAINER_NAME; then
    echo -e "${GREEN}API de gerenciamento iniciada com sucesso!${NC}"
    echo -e "${GREEN}Porta: ${PGBOUNCER_ADMIN_PORT}${NC}"
else
    echo -e "${RED}Falha ao iniciar API. Verifique os logs.${NC}"
    docker logs $PGBOUNCER_API_CONTAINER_NAME
    exit 1
fi

# Criar script de service para o systemd
cat > /etc/systemd/system/pgbouncer.service <<EOL
[Unit]
Description=PgBouncer Container
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=${PGBOUNCER_DATA_DIR}
ExecStart=/usr/bin/docker-compose up -d
ExecStop=/usr/bin/docker-compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOL

# Habilitar o serviço
systemctl daemon-reload
systemctl enable pgbouncer.service

# Configurar integração com Traefik (se disponível)
if [ -d "/opt/traefik" ]; then
    echo -e "${YELLOW}Configurando integração com Traefik...${NC}"
    
    # Criar arquivo de configuração para Traefik
    mkdir -p /opt/traefik/conf.d
    cat > /opt/traefik/conf.d/pgbouncer.toml <<EOL
[http.routers.pgbouncer-api]
  rule = "Host(\`pgbouncer-api.${DEPLOY_DOMAIN:-localhost}\`)"
  service = "pgbouncer-api"
  middlewares = ["auth"]
  [http.routers.pgbouncer-api.tls]
    certResolver = "letsencrypt"

[http.services.pgbouncer-api.loadBalancer]
  [[http.services.pgbouncer-api.loadBalancer.servers]]
    url = "http://pgbouncer-api:8080"
EOL

    # Reiniciar Traefik
    docker restart traefik || true
    echo -e "${GREEN}Integração com Traefik configurada!${NC}"
    echo -e "${GREEN}API disponível em: https://pgbouncer-api.${DEPLOY_DOMAIN:-localhost}${NC}"
fi

echo ""
echo -e "${GREEN}Instalação do PgBouncer concluída com sucesso!${NC}"
echo -e "${BLUE}=================================================${NC}"
echo -e "${YELLOW}PgBouncer URL: postgresql://admin:password@localhost:${PGBOUNCER_PORT}/pgbouncer${NC}"
echo -e "${YELLOW}API URL: http://localhost:${PGBOUNCER_ADMIN_PORT}${NC}"
echo -e "${BLUE}=================================================${NC}"
echo ""
echo -e "${YELLOW}Próximos passos:${NC}"
echo -e "1. Altere as senhas padrão em ${PGBOUNCER_DATA_DIR}/config/users.txt"
echo -e "2. Atualize as configurações em ${PGBOUNCER_DATA_DIR}/config/pgbouncer.ini"
echo -e "3. Configure seus módulos para usar o PgBouncer"
echo ""

exit 0