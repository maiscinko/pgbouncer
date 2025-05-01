#!/usr/bin/env python3
"""
API de gerenciamento do PgBouncer para o ecossistema ABCKX.
Fornece endpoints REST para monitoramento e controle do PgBouncer.
"""

import os
import time
import json
import logging
import subprocess
from datetime import datetime
from typing import Dict, List, Optional, Union

import psycopg2
import uvicorn
from fastapi import FastAPI, HTTPException, Depends, Request, Response, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, Field

# Configuração de logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger("pgbouncer-api")

# Configuração da API
app = FastAPI(
    title="PgBouncer Management API",
    description="API para gerenciamento do PgBouncer no ecossistema ABCKX",
    version="1.0.0",
)

# Configuração CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # Em produção, restringir para origens específicas
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Autenticação
security = HTTPBearer()

# Modelo de resposta padronizado
class ApiResponse(BaseModel):
    status: str = "success"
    data: Optional[Dict] = None
    message: str = ""
    timestamp: str = Field(default_factory=lambda: datetime.now().isoformat())

# Modelo para configuração
class ConfigUpdate(BaseModel):
    pool_mode: Optional[str] = None
    max_client_conn: Optional[int] = None
    default_pool_size: Optional[int] = None
    min_pool_size: Optional[int] = None
    reserve_pool_size: Optional[int] = None

# Funções auxiliares
def execute_pgbouncer_command(command: str) -> List:
    """Execute um comando no console administrativo do PgBouncer."""
    try:
        conn = psycopg2.connect(
            "host=localhost port=6432 user=admin password=admin_password dbname=pgbouncer"
        )
        cursor = conn.cursor()
        cursor.execute(command)
        result = cursor.fetchall()
        conn.close()
        return result
    except Exception as e:
        logger.error(f"Erro ao executar comando PgBouncer: {str(e)}")
        raise HTTPException(
            status_code=500, 
            detail=f"Erro ao conectar ao PgBouncer: {str(e)}"
        )

# Middleware para logging
@app.middleware("http")
async def log_requests(request: Request, call_next):
    start_time = time.time()
    response = await call_next(request)
    process_time = time.time() - start_time
    logger.info(f"{request.method} {request.url.path} - {response.status_code} - {process_time:.4f}s")
    return response

# Verificação de token simples (em produção, usar JWT completo)
async def verify_token(credentials: HTTPAuthorizationCredentials = Depends(security)):
    if credentials.credentials != "your-secret-token":
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token inválido",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return credentials.credentials

# Rotas
@app.get("/", response_model=ApiResponse)
async def root():
    return ApiResponse(
        message="PgBouncer Management API",
        data={"version": "1.0.0"}
    )

@app.get("/status", response_model=ApiResponse)
async def get_status(token: str = Depends(verify_token)):
    try:
        # Verificar se o PgBouncer está rodando
        process = subprocess.run(
            ["pgrep", "-f", "pgbouncer"], 
            capture_output=True, 
            text=True
        )
        is_running = process.returncode == 0
        
        # Obter estatísticas básicas se estiver rodando
        stats = {}
        if is_running:
            stats_data = execute_pgbouncer_command("SHOW STATS")
            version_data = execute_pgbouncer_command("SHOW VERSION")
            stats = {
                "version": version_data[0][0] if version_data else "Unknown",
                "total_requests": stats_data[0][3] if stats_data else 0,
                "total_received": stats_data[0][4] if stats_data else 0,
                "total_sent": stats_data[0][5] if stats_data else 0,
            }
        
        return ApiResponse(
            data={
                "running": is_running,
                "stats": stats,
                "uptime": execute_pgbouncer_command("SHOW CONFIG")[0][1] if is_running else 0
            }
        )
    except Exception as e:
        logger.error(f"Erro ao verificar status: {str(e)}")
        return ApiResponse(
            status="error",
            message=f"Erro ao verificar status: {str(e)}"
        )

@app.get("/pools", response_model=ApiResponse)
async def get_pools(token: str = Depends(verify_token)):
    try:
        pools_data = execute_pgbouncer_command("SHOW POOLS")
        databases_data = execute_pgbouncer_command("SHOW DATABASES")
        
        # Processar dados dos pools
        pools = []
        for pool in pools_data:
            pools.append({
                "database": pool[0],
                "user": pool[1],
                "cl_active": pool[2],
                "cl_waiting": pool[3],
                "sv_active": pool[4],
                "sv_idle": pool[5],
                "sv_used": pool[6],
                "sv_tested": pool[7],
                "sv_login": pool[8],
                "maxwait": pool[9],
                "maxwait_us": pool[10],
            })
        
        # Processar dados dos databases
        databases = []
        for db in databases_data:
            databases.append({
                "name": db[0],
                "host": db[1],
                "port": db[2],
                "database": db[3],
                "force_user": db[4],
                "pool_size": db[5],
                "reserve_pool": db[6],
                "pool_mode": db[7],
                "max_connections": db[8],
                "current_connections": db[9],
            })
        
        return ApiResponse(
            data={
                "pools": pools,
                "databases": databases
            }
        )
    except Exception as e:
        logger.error(f"Erro ao obter pools: {str(e)}")
        return ApiResponse(
            status="error",
            message=f"Erro ao obter pools: {str(e)}"
        )

@app.post("/pools/{database}/pause", response_model=ApiResponse)
async def pause_pool(database: str, token: str = Depends(verify_token)):
    try:
        execute_pgbouncer_command(f"PAUSE {database}")
        return ApiResponse(
            message=f"Pool {database} pausado com sucesso"
        )
    except Exception as e:
        logger.error(f"Erro ao pausar pool {database}: {str(e)}")
        return ApiResponse(
            status="error",
            message=f"Erro ao pausar pool {database}: {str(e)}"
        )

@app.post("/pools/{database}/resume", response_model=ApiResponse)
async def resume_pool(database: str, token: str = Depends(verify_token)):
    try:
        execute_pgbouncer_command(f"RESUME {database}")
        return ApiResponse(
            message=f"Pool {database} retomado com sucesso"
        )
    except Exception as e:
        logger.error(f"Erro ao retomar pool {database}: {str(e)}")
        return ApiResponse(
            status="error",
            message=f"Erro ao retomar pool {database}: {str(e)}"
        )

@app.get("/metrics", response_model=ApiResponse)
async def get_metrics(token: str = Depends(verify_token)):
    try:
        stats = execute_pgbouncer_command("SHOW STATS")
        pools = execute_pgbouncer_command("SHOW POOLS")
        
        # Processar métricas
        metrics = {
            "total_requests": sum(stat[3] for stat in stats),
            "total_received": sum(stat[4] for stat in stats),
            "total_sent": sum(stat[5] for stat in stats),
            "total_query_time": sum(stat[6] for stat in stats),
            "avg_query_time": sum(stat[6] for stat in stats) / max(1, sum(stat[3] for stat in stats)),
            "total_client_active": sum(pool[2] for pool in pools),
            "total_client_waiting": sum(pool[3] for pool in pools),
            "total_server_active": sum(pool[4] for pool in pools),
        }
        
        return ApiResponse(data=metrics)
    except Exception as e:
        logger.error(f"Erro ao obter métricas: {str(e)}")
        return ApiResponse(
            status="error",
            message=f"Erro ao obter métricas: {str(e)}"
        )

@app.put("/config", response_model=ApiResponse)
async def update_config(config: ConfigUpdate, token: str = Depends(verify_token)):
    try:
        # Atualizar configurações
        for param, value in config.dict(exclude_none=True).items():
            execute_pgbouncer_command(f"SET {param} = {value}")
            
        # Recarregar configuração
        execute_pgbouncer_command("RELOAD")
        
        return ApiResponse(
            message="Configuração atualizada com sucesso",
            data=config.dict(exclude_none=True)
        )
    except Exception as e:
        logger.error(f"Erro ao atualizar configuração: {str(e)}")
        return ApiResponse(
            status="error",
            message=f"Erro ao atualizar configuração: {str(e)}"
        )

# Iniciar servidor se executado diretamente
if __name__ == "__main__":
    uvicorn.run(
        "app:app", 
        host="0.0.0.0", 
        port=8080, 
        reload=True,
        log_level="info"
    )
