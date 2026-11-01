#!/bin/sh
# Monta o site em dist/: página, demo (protótipo), pacote do ReaPack e zip.
# Rode da raiz do repositório:  sh tools/build_site.sh [URL do site] [versão]
# Publicar:  wrangler deploy   (wrangler.jsonc serve dist/ como arquivos estáticos)
set -e
URL="${1:-https://live-sections.igor-jacauna-cloudflare.workers.dev}"
VERSION="${2:-$(cat VERSION)}"
LUA="${LUA:-lua}"
command -v "$LUA" >/dev/null 2>&1 || LUA=/opt/homebrew/opt/lua@5.4/bin/lua

rm -rf dist
mkdir -p dist/demo
sed -e "s#__SITE_URL__#$URL#g" -e "s#__VERSION__#$VERSION#g" site/index.html > dist/index.html
# o protótipo é um fragmento (feito para o Artifact): ganha doctype e charset
{
  printf '<!doctype html>\n<html lang="pt-BR">\n<meta charset="utf-8">\n'
  printf '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
  cat prototype/index.html
} > dist/demo/index.html
cp -R LiveSections dist/LiveSections
# cópias .txt das páginas da Web Interface, para o ReaPack baixar sem redirecionamento
for f in dist/LiveSections/www/*.html; do cp "$f" "$f.txt"; done
"$LUA" tools/gerar_index.lua "$URL" "$VERSION" dist/index.xml
(cd dist && zip -qr live-sections.zip LiveSections)
echo "dist/ pronto para $URL"
