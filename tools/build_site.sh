#!/bin/sh
# Monta o site em dist/: página, demo (protótipo), pacote do ReaPack e zip.
# Rode da raiz do repositório:  sh tools/build_site.sh [URL do site] [versão]
# Publicar:  wrangler deploy   (wrangler.jsonc serve dist/ como arquivos estáticos)
set -e
URL="${1:-https://live-sections.igor-jacauna-cloudflare.workers.dev}"
VERSION="${2:-0.1.0}"
LUA="${LUA:-lua}"
command -v "$LUA" >/dev/null 2>&1 || LUA=/opt/homebrew/opt/lua@5.4/bin/lua

rm -rf dist
mkdir -p dist/demo
sed "s#__SITE_URL__#$URL#g" site/index.html > dist/index.html
cp prototype/index.html dist/demo/index.html
cp -R LiveSections dist/LiveSections
"$LUA" tools/gerar_index.lua "$URL" "$VERSION" dist/index.xml
(cd dist && zip -qr live-sections.zip LiveSections)
echo "dist/ pronto para $URL"
