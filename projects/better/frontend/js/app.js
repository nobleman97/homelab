const API = '/api';

// ── State ──────────────────────────────────────────────
let currentPage = 1;
let currentCategory = '';
let searchQuery = '';
let categoriesChart = null;

// ── Bootstrap ──────────────────────────────────────────
document.addEventListener('DOMContentLoaded', () => {
  loadProducts();
  loadOrders();
  refreshStats();

  setInterval(refreshStats, 3000);
  setInterval(loadOrders, 5000);

  document.getElementById('category-filter').addEventListener('change', (e) => {
    currentCategory = e.target.value;
    currentPage = 1;
    loadProducts();
  });

  let searchTimer;
  document.getElementById('search-input').addEventListener('input', (e) => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => {
      searchQuery = e.target.value.trim();
      currentPage = 1;
      loadProducts();
    }, 300);
  });

  document.getElementById('order-form').addEventListener('submit', submitOrder);
});

// ── Products ───────────────────────────────────────────
async function loadProducts() {
  const grid = document.getElementById('product-grid');
  grid.innerHTML = '<div class="skeleton-grid">' + '<div class="skeleton-card"></div>'.repeat(6) + '</div>';

  const params = new URLSearchParams({ page: currentPage, limit: 18 });
  if (currentCategory) params.set('category', currentCategory);

  try {
    const res = await fetch(`${API}/products?${params}`);
    const data = await res.json();

    let items = data.items;
    if (searchQuery) {
      const q = searchQuery.toLowerCase();
      items = items.filter(p => p.name.toLowerCase().includes(q) || p.category.includes(q));
    }

    grid.innerHTML = items.length
      ? items.map(productCard).join('')
      : '<p style="color:var(--text-muted);padding:16px">No products found.</p>';

    renderPagination(data.page, Math.ceil(data.total / data.limit));
  } catch {
    grid.innerHTML = '<p style="color:var(--red);padding:16px">Failed to load products.</p>';
  }
}

function productCard(p) {
  const lowStock = p.stock < 20;
  return `
    <div class="product-card" onclick="fillOrderForm(${p.id})">
      <div class="product-name" title="${esc(p.name)}">${esc(p.name)}</div>
      <div class="product-category">${p.category}</div>
      <div class="product-footer">
        <span class="product-price">$${Number(p.price).toFixed(2)}</span>
        <span class="product-stock${lowStock ? ' low' : ''}">${p.stock} in stock</span>
      </div>
    </div>`;
}

function fillOrderForm(productId) {
  document.getElementById('order-product-id').value = productId;
  document.getElementById('order-quantity').focus();
}

function renderPagination(page, total) {
  const el = document.getElementById('pagination');
  if (total <= 1) { el.innerHTML = ''; return; }

  const pages = [];
  const range = 2;
  for (let i = 1; i <= total; i++) {
    if (i === 1 || i === total || (i >= page - range && i <= page + range)) {
      pages.push(i);
    } else if (pages[pages.length - 1] !== '…') {
      pages.push('…');
    }
  }

  el.innerHTML = pages.map(p =>
    p === '…'
      ? `<span class="page-btn" disabled>…</span>`
      : `<button class="page-btn${p === page ? ' active' : ''}" onclick="goPage(${p})">${p}</button>`
  ).join('');
}

function goPage(p) {
  currentPage = p;
  loadProducts();
  window.scrollTo({ top: 0, behavior: 'smooth' });
}

// ── Stats ──────────────────────────────────────────────
async function refreshStats() {
  try {
    const res = await fetch(`${API}/stats`);
    const s = await res.json();

    document.getElementById('stat-products').textContent    = fmt(s.total_products);
    document.getElementById('stat-orders-today').textContent = fmt(s.orders_today);
    document.getElementById('stat-opm').textContent         = s.orders_per_min.toFixed(1);
    document.getElementById('stat-avg-value').textContent   = '$' + s.avg_order_value.toFixed(2);

    renderCategoriesChart(s.top_categories);

    // Update version badge from response header
    const version = res.headers.get('X-App-Version');
    if (version) updateVersionBadge(version);
  } catch { /* silent — metrics are non-critical */ }
}

function renderCategoriesChart(categories) {
  const labels = categories.map(c => c.category);
  const values = categories.map(c => c.order_count);

  if (!categoriesChart) {
    const ctx = document.getElementById('categories-chart').getContext('2d');
    categoriesChart = new Chart(ctx, {
      type: 'bar',
      data: {
        labels,
        datasets: [{
          data: values,
          backgroundColor: '#6c7bff99',
          borderColor: '#6c7bff',
          borderWidth: 1,
          borderRadius: 4,
        }],
      },
      options: {
        plugins: { legend: { display: false } },
        scales: {
          x: { ticks: { color: '#7c849e' }, grid: { color: '#2e3350' } },
          y: { ticks: { color: '#7c849e' }, grid: { color: '#2e3350' } },
        },
      },
    });
  } else {
    categoriesChart.data.labels = labels;
    categoriesChart.data.datasets[0].data = values;
    categoriesChart.update('none');
  }
}

function updateVersionBadge(version) {
  const badge = document.getElementById('version-badge');
  badge.textContent = version;
  badge.className = 'version-badge ' + (['blue', 'green'].includes(version) ? version : '');
}

// ── Orders ─────────────────────────────────────────────
async function loadOrders() {
  try {
    const res = await fetch(`${API}/orders`);
    const orders = await res.json();
    const tbody = document.getElementById('orders-body');

    tbody.innerHTML = orders.slice(0, 10).map(o => `
      <tr>
        <td>#${o.id}</td>
        <td title="${esc(o.product_name)}">${esc(o.product_name)}</td>
        <td>${o.quantity}</td>
        <td>$${Number(o.total).toFixed(2)}</td>
      </tr>`).join('');
  } catch { /* silent */ }
}

async function submitOrder(e) {
  e.preventDefault();
  const btn = e.target.querySelector('button');
  const feedback = document.getElementById('order-feedback');
  const productId = parseInt(document.getElementById('order-product-id').value);
  const quantity  = parseInt(document.getElementById('order-quantity').value);

  btn.disabled = true;
  feedback.textContent = 'Placing order…';
  feedback.className = 'order-feedback';

  try {
    const res = await fetch(`${API}/orders`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ product_id: productId, quantity }),
    });
    const data = await res.json();

    if (res.ok) {
      feedback.textContent = `Order #${data.id} placed — $${Number(data.total).toFixed(2)}`;
      feedback.className = 'order-feedback success';
      loadOrders();
      loadProducts();
    } else {
      feedback.textContent = data.detail || 'Order failed.';
      feedback.className = 'order-feedback error';
    }
  } catch {
    feedback.textContent = 'Network error.';
    feedback.className = 'order-feedback error';
  } finally {
    btn.disabled = false;
  }
}

// ── Helpers ────────────────────────────────────────────
function fmt(n) {
  return Number(n).toLocaleString();
}

function esc(str) {
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}
