import asyncio
import math
import os
import socket
import time

from fastapi import FastAPI, HTTPException, Query
from prometheus_client import Gauge
from prometheus_fastapi_instrumentator import Instrumentator

POD_NAME = os.getenv("POD_NAME", socket.gethostname())
MAX_HELD_MB = int(os.getenv("MAX_HELD_MB", "300"))

app = FastAPI(title="Demo HPA", version="1.0")

Instrumentator().instrument(app).expose(app, include_in_schema=False)

held_mb_gauge = Gauge("demo_memory_held_megabytes", "Pamięć zajęta przez /load/memory")
_held_mb = 0


@app.get("/")
async def root():
    return {"pod": POD_NAME, "held_mb": _held_mb, "max_held_mb": MAX_HELD_MB}


@app.get("/healthz")
async def healthz():
    return {"status": "ok"}


@app.get("/load/cpu")
def load_cpu(ms: int = Query(100, ge=1, le=5000, description="Czas procesora do zużycia [ms]")):
    start = time.thread_time()
    target = ms / 1000
    n = 0
    x = 0.0
    while time.thread_time() - start < target:
        for _ in range(1000):
            x += math.sqrt(n)
            n += 1
    return {"pod": POD_NAME, "cpu_ms": ms, "iterations": n}


@app.get("/load/memory")
async def load_memory(
    mb: int = Query(20, ge=1, le=200, description="Ilość pamięci do zajęcia [MB]"),
    seconds: float = Query(10, gt=0, le=120, description="Jak długo trzymać pamięć [s]"),
):
    global _held_mb
    if _held_mb + mb > MAX_HELD_MB:
        raise HTTPException(
            status_code=503,
            detail=f"Pod {POD_NAME} trzyma już {_held_mb} MB (limit {MAX_HELD_MB} MB)",
        )
    buf = b"\x01" * (mb * 1024 * 1024)
    _held_mb += mb
    held_mb_gauge.set(_held_mb)
    try:
        await asyncio.sleep(seconds)
    finally:
        del buf
        _held_mb -= mb
        held_mb_gauge.set(_held_mb)
    return {"pod": POD_NAME, "mb": mb, "seconds": seconds}
