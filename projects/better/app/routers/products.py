from fastapi import APIRouter, HTTPException, Query
from database import get_pool

router = APIRouter()

VALID_CATEGORIES = {"electronics", "clothing", "books", "home", "sports"}


@router.get("/products")
async def list_products(
    page: int = Query(1, ge=1),
    limit: int = Query(20, ge=1, le=100),
    category: str | None = Query(None),
):
    pool = await get_pool()
    offset = (page - 1) * limit

    if category and category not in VALID_CATEGORIES:
        raise HTTPException(status_code=400, detail="Invalid category")

    if category:
        rows = await pool.fetch(
            """
            SELECT id, name, category, price, stock
            FROM products
            WHERE category = $1
            ORDER BY created_at DESC
            LIMIT $2 OFFSET $3
            """,
            category, limit, offset,
        )
        total = await pool.fetchval(
            "SELECT COUNT(*) FROM products WHERE category = $1", category
        )
    else:
        rows = await pool.fetch(
            """
            SELECT id, name, category, price, stock
            FROM products
            ORDER BY created_at DESC
            LIMIT $1 OFFSET $2
            """,
            limit, offset,
        )
        total = await pool.fetchval("SELECT COUNT(*) FROM products")

    return {
        "page": page,
        "limit": limit,
        "total": total,
        "items": [dict(r) for r in rows],
    }


@router.get("/products/{product_id}")
async def get_product(product_id: int):
    pool = await get_pool()
    row = await pool.fetchrow(
        "SELECT id, name, category, price, stock, created_at FROM products WHERE id = $1",
        product_id,
    )
    if not row:
        raise HTTPException(status_code=404, detail="Product not found")
    return dict(row)
