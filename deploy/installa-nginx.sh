#!/bin/sh
# Mette Jarvis sulle porte 80/443 tramite nginx (vedi nginx-jarvis.conf). Va lanciato con sudo.
# Sostituisce il sito "default" di nginx, che mostrava solo la pagina di benvenuto.
set -e
cd "$(dirname "$0")"
cp nginx-jarvis.conf /etc/nginx/sites-available/jarvis
ln -sf /etc/nginx/sites-available/jarvis /etc/nginx/sites-enabled/jarvis
rm -f /etc/nginx/sites-enabled/default   # resta in sites-available: per tornare indietro basta ricollegarlo
if nginx -t; then
  systemctl reload nginx
  echo "Fatto: apri http://192.168.2.26"
else
  rm -f /etc/nginx/sites-enabled/jarvis
  ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
  echo "Configurazione non valida: rimesso tutto com'era." >&2
  exit 1
fi
