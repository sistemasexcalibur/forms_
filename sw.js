// Service Worker do Alltech Biomassa
// Estratégia: "network-first, com fallback pro cache".
// Enquanto há internet, sempre busca a versão mais nova (e atualiza o
// cache sozinho). Sem internet, serve a última versão salva — inclusive
// numa aba nova, recém-aberta, sem nunca ter sido carregada antes offline.

const CACHE_NAME = "alltech-biomassa-v2";

const APP_SHELL = [
  "./",
  "./index.html",
  "./manifest.json",
  "./icon-192.png",
  "./icon-512.png"
];

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(CACHE_NAME)
      .then((cache) => cache.addAll(APP_SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((nomes) => Promise.all(nomes.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;

  event.respondWith(
    fetch(req, { cache: "no-store" })
      .then((resposta) => {
        const copia = resposta.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(req, copia)).catch(() => {});
        return resposta;
      })
      .catch(() =>
        caches.match(req).then((emCache) => emCache || caches.match("./index.html"))
      )
  );
});
