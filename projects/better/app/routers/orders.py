from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
from database import get_pool

router = APIRouter()


class OrderCreate(BaseModel):
    product_id: int
    quantity: int = Field(ge=1, le=100)


@router.post("/orders", status_code=201)
async def create_order(body: OrderCreate):
    pool = await get_pool()

    product = await pool.fetchrow(
        "SELECT id, price, stock FROM products WHERE id = $1", body.product_id
    )
    if not product:
        raise HTTPException(status_code=404, detail="Product not found")
    if product["stock"] < body.quantity:
        raise HTTPException(status_code=409, detail="Insufficient stock")

    total = float(product["price"]) * body.quantity

    async with pool.acquire() as conn:
        async with conn.transaction():
            order = await conn.fetchrow(
                """
                INSERT INTO orders (product_id, quantity, total)
                VALUES ($1, $2, $3)
                RETURNING id, product_id, quantity, total, created_at
                """,
                body.product_id, body.quantity, total,
            )
            await conn.execute(
                "UPDATE products SET stock = stock - $1 WHERE id = $2",
                body.quantity, body.product_id,
            )

    return dict(order)


@router.get("/orders")
async def list_orders():
    pool = await get_pool()
    rows = await pool.fetch(
        """
        SELECT o.id, o.product_id, p.name AS product_name, o.quantity, o.total, o.created_at
        FROM orders o
        JOIN products p ON p.id = o.product_id
        ORDER BY o.created_at DESC
        LIMIT 50
        """
    )
    return [dict(r) for r in rows]
