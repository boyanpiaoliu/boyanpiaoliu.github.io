const CACHE_NAME = 'cloud-island-pwa-v1';
const APP_SHELL = ['/', '/manifest.webmanifest', '/cloud-island-icon.jpg'];

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => cache.addAll(APP_SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(key => key.startsWith('cloud-island-pwa-') && key !== CACHE_NAME)
          .map(key => caches.delete(key))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', event => {
  const request = event.request;
  if (request.method !== 'GET') return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  // Keep the app shell fresh when online; use the last successful shell offline.
  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request)
        .then(response => {
          if (response && response.ok) {
            const copy = response.clone();
            caches.open(CACHE_NAME).then(cache => cache.put('/', copy));
          }
          return response;
        })
        .catch(async () => {
          const cached = await caches.match('/');
          return cached || new Response(
            '云朵岛暂时无法连接。请检查网络后重试。',
            { status: 503, headers: { 'Content-Type': 'text/plain; charset=utf-8' } }
          );
        })
    );
    return;
  }

  // Cache only the app icon. Never cache API, account, chat, or private user data.
  if (url.pathname === '/cloud-island-icon.jpg') {
    event.respondWith(
      caches.match(request).then(cached => cached || fetch(request).then(response => {
        if (response && response.ok) {
          const copy = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(request, copy));
        }
        return response;
      }))
    );
  }
});