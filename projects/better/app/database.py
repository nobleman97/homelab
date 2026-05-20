import os
import asyncpg

_pool: asyncpg.Pool | None = None

DATABASE_URL = os.environ["DATABASE_URL"]


async def get_pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(DATABASE_URL, min_size=5, max_size=20)
    return _pool


async def close_pool():
    global _pool
    if _pool:
        await _pool.close()
        _pool = None
