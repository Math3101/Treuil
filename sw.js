// Cache de l'application (pas des données) : ouverture rapide et plans disponibles hors réseau.
const V = 'treuil-v19';
const SHELL = ['./', './index.html', './config.js', './data.js?v=19', './lib/supabase.js', './lib/planning.js?v=19', './lib/jspdf.umd.min.js',
  './manifest.webmanifest', './icons/icon-192.png', './icons/icon-512.png', './logo.png', './logo-h.png',
  ...['A','B','C','D'].flatMap(t => [`./plans/${t}_rdc.png`, `./plans/${t}_courant.png`])];
self.addEventListener('install', e => { e.waitUntil(caches.open(V).then(c => c.addAll(SHELL))); self.skipWaiting(); });
self.addEventListener('activate', e => { e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== V).map(k => caches.delete(k))))); self.clients.claim(); });
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== location.origin) return; // Supabase : toujours en direct
  e.respondWith(fetch(e.request, {cache: 'no-cache'}).then(r => { const cp = r.clone(); caches.open(V).then(c => c.put(e.request, cp)); return r; })
    .catch(() => caches.match(e.request)));
});
