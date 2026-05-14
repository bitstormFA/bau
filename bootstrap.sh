#!/bin/sh
# Bootstrap: build bau from source using nim directly
set -e
NIM=${NIM:-nim}
PARSE_TOML_PATH="$HOME/.nimble/pkgs2/parsetoml-0.7.2-2a9fb57ef1f6460fd61b1cfab2d83af44f788a25"
mkdir -p bin
$NIM c \
  --path:src \
  --path:"$PARSE_TOML_PATH" \
  --hints:off \
  -d:threads=on \
  -o:bin/bau \
  src/bau.nim
echo "Bootstrap complete: bin/bau"
