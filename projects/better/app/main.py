import os
from contextlib import asynccontextmanager
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from starlette.requests import Request
from starlette.responses import Response

from database import get_pool, close_pool
from routers import products, orders, stats

APP_VERSION = os.environ.get("APP_VERSION", "blue")


@asynccontextmanager
async def lifespan(app: FastAPI):
    await get_pool()
    yield
    await close_pool()


app = FastAPI(title="Better Demo API", lifespan=lifespan)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
    expose_headers=["X-App-Version"],
)


@app.middleware("http")
async def inject_version_header(request: Request, call_next) -> Response:
    response = await call_next(request)
    response.headers["X-App-Version"] = APP_VERSION
    return response


@app.get("/health")
async def health():
    return {"status": "ok", "version": APP_VERSION}


app.include_router(products.router, prefix="/api")
app.include_router(orders.router, prefix="/api")
app.include_router(stats.router, prefix="/api")
