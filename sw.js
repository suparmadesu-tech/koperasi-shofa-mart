// =====================================================================
// SERVICE WORKER — Katalog & Cek Harga Koperasi
//
// Strategi cache:
// 1. App shell (index.html, manifest, ikon, file lokal lain)
//    → cache-first, diperbarui di background (stale-while-revalidate ringan).
// 2. Data produk/kategori dari Supabase REST (GET /rest/v1/products, /categories)
//    → network-first: coba online dulu (data selalu terbaru), kalau gagal
//      (offline / koneksi putus) jatuh ke data hasil cache terakhir.
//    → hanya GET yang di-cache; request tulis (POST/PATCH/DELETE) dari
//      admin.html TIDAK pernah disentuh service worker ini, selalu langsung
//      ke network (sesuai batasan PRD: tidak ada write saat offline).
// 3. Library pihak ketiga dari CDN (Tailwind, Alpine, Fuse.js, dll)
//    → stale-while-revalidate: pakai versi cache dulu (cepat), lalu update
//      cache di background untuk kunjungan berikutnya.
//
// Naikkan versi CACHE_VERSION setiap kali file di SHELL_FILES berubah agar
// service worker lama otomatis dibersihkan dan versi baru dipakai.
// =====================================================================

const CACHE_VERSION = "v1";
const SHELL_CACHE = `koperasi-shell-${CACHE_VERSION}`;
const DATA_CACHE = `koperasi-data-${CACHE_VERSION}`;
const LIB_CACHE = `koperasi-libs-${CACHE_VERSION}`;

const ALL_CACHES = [SHELL_CACHE, DATA_CACHE, LIB_CACHE];

// File app-shell yang WAJIB bisa dibuka walau offline total (dibuka dari HP kasir)
const SHELL_FILES = [
  "./",
  "./index.html",
  "./manifest.json",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./icons/icon-512-maskable.png",
];

// ---------------------------------------------------------------------
// INSTALL — precache app shell
// ---------------------------------------------------------------------
self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(SHELL_CACHE).then((cache) =>
      cache.addAll(SHELL_FILES).catch((err) => {
        // Jangan sampai satu file gagal (mis. path berbeda di hosting) membatalkan install total
        console.warn("[SW] Sebagian file shell gagal di-precache:", err);
      })
    )
  );
  self.skipWaiting();
});

// ---------------------------------------------------------------------
// ACTIVATE — bersihkan cache versi lama
// ---------------------------------------------------------------------
self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter((key) => !ALL_CACHES.includes(key))
            .map((key) => caches.delete(key))
        )
      )
      .then(() => self.clients.claim())
  );
});

// ---------------------------------------------------------------------
// FETCH — routing strategi per jenis request
// ---------------------------------------------------------------------
self.addEventListener("fetch", (event) => {
  const req = event.request;
  const url = new URL(req.url);

  // Hanya tangani GET. Request tulis (INSERT/UPDATE/DELETE dari admin.html)
  // dibiarkan lewat apa adanya ke network — tidak pernah di-cache/diintersep.
  if (req.method !== "GET") return;

  const isSupabase = url.hostname.endsWith(".supabase.co");

  // Endpoint auth (login admin) selalu langsung ke network, jangan diintersep sama sekali
  if (isSupabase && url.pathname.startsWith("/auth/")) return;

  // Data katalog (products & categories) — network-first, fallback ke cache
  if (isSupabase && url.pathname.startsWith("/rest/v1/")) {
    event.respondWith(networkFirst(req, DATA_CACHE));
    return;
  }

  // File same-origin (index.html, manifest, ikon, dst) — cache-first
  if (url.origin === self.location.origin) {
    event.respondWith(cacheFirst(req, SHELL_CACHE));
    return;
  }

  // Library CDN pihak ketiga (Tailwind, Alpine.js, Fuse.js, Supabase JS, html5-qrcode)
  event.respondWith(staleWhileRevalidate(req, LIB_CACHE));
});

// ---------------------------------------------------------------------
// STRATEGI CACHE
// ---------------------------------------------------------------------

async function cacheFirst(request, cacheName) {
  const cached = await caches.match(request);
  if (cached) {
    // Perbarui cache di background untuk kunjungan berikutnya (tidak memblokir response ini)
    fetchAndCache(request, cacheName).catch(() => {});
    return cached;
  }
  try {
    return await fetchAndCache(request, cacheName);
  } catch (err) {
    return cached || Response.error();
  }
}

async function staleWhileRevalidate(request, cacheName) {
  const cached = await caches.match(request);
  const networkPromise = fetchAndCache(request, cacheName).catch(() => null);
  return cached || (await networkPromise) || Response.error();
}

async function networkFirst(request, cacheName) {
  try {
    const fresh = await fetch(request);
    if (fresh && fresh.ok) {
      const cache = await caches.open(cacheName);
      cache.put(request, fresh.clone());
    }
    return fresh;
  } catch (err) {
    const cached = await caches.match(request);
    if (cached) return cached;
    // Tidak ada koneksi & tidak ada data cache — beri tahu app secara eksplisit
    return new Response(
      JSON.stringify({ error: "offline_no_cache", message: "Tidak ada koneksi dan belum ada data tersimpan." }),
      { status: 503, headers: { "Content-Type": "application/json" } }
    );
  }
}

async function fetchAndCache(request, cacheName) {
  const response = await fetch(request);
  if (response && response.ok) {
    const cache = await caches.open(cacheName);
    cache.put(request, response.clone());
  }
  return response;
}