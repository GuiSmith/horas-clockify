#!/usr/bin/env bash
#
# setup — torna o horas.sh executável e cria o link ~/.local/bin/horas.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly TARGET="$SCRIPT_DIR/horas.sh"
readonly BIN_DIR="$HOME/.local/bin"
readonly LINK="$BIN_DIR/horas"

[[ -f $TARGET ]] || { echo "erro: $TARGET não encontrado" >&2; exit 1; }
# Só substitui links; um arquivo comum em $LINK não é nosso.
[[ -e $LINK && ! -L $LINK ]] && { echo "erro: $LINK já existe e não é um link" >&2; exit 1; }

chmod +x "$TARGET"
mkdir -p "$BIN_DIR"
ln -sfn "$TARGET" "$LINK"

echo "link criado: $LINK -> $TARGET"

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  echo "aviso: $BIN_DIR não está no PATH; adicione-o ao seu ~/.bashrc" >&2
fi
