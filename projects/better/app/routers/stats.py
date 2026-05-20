from fastapi import APIRouter
from database import get_pool

router = APIRouter()


@router.get("/stats")
async def get_stats():
    pool = await get_pool()

    total_products, orders_today, orders_per_min, avg_order_value, top_categories = (
        await _fetch_stats(pool)
    )

    return {
        "total_products": total_products,
        "orders_today": orders_today,
        "orders_per_min": round(orders_per_min, 2),
        "avg_order_value": round(float(avg_order_value or 0), 2),
        "top_categories": top_categories,
    }


async def _fetch_stats(pool):
    total_products = await pool.fetchval("SELECT COUNT(*) FROM products")

    orders_today = await pool.fetchval(
        "SELECT COUNT(*) FROM orders WHERE created_at >= CURRENT_DATE"
    )

    orders_per_min = await pool.fetchval(
        """
        SELECT COUNT(*) / 5.0
        FROM orders
        WHERE created_at >= now() - INTERVAL '5 minutes'
        """
    )

    avg_order_value = await pool.fetchval(
        "SELECT AVG(total) FROM orders WHERE created_at >= CURRENT_DATE"
    )

    top_categories = await pool.fetch(
        """
        SELECT p.category, COUNT(o.id) AS order_count
        FROM orders o
        JOIN products p ON p.id = o.product_id
        WHERE o.created_at >= CURRENT_DATE
        GROUP BY p.category
        ORDER BY order_count DESC
        LIMIT 5
        """
    )

    return (
        total_products,
        orders_today,
        orders_per_min or 0,
        avg_order_value,
        [dict(r) for r in top_categories],
    )
