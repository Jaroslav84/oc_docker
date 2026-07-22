#!/bin/bash
# install-git-hooks.sh — wires scripts/git-hooks/* into .git/hooks/. Idempotent.
#
# Filename convention: scripts/git-hooks/<hookname>_<slug>.sh
#   (underscore separator — git hook names never contain underscores)
#   → installed as symlink at .git/hooks/<hookname>
# Multiple hooks of the same type would collide; only one <hookname>_*.sh per
# hook type is supported. If a real (non-symlink) hook already exists at the
# target, we skip rather than clobber user-authored hooks.
set -u

REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "install-git-hooks: not inside a git repo — nothing to install" >&2
    exit 1
}
HOOKS_SRC="$REPO/scripts/git-hooks"
HOOKS_DST="$REPO/.git/hooks"

[ -d "$HOOKS_SRC" ] || {
    echo "install-git-hooks: $HOOKS_SRC not found" >&2
    exit 1
}
mkdir -p "$HOOKS_DST"

_linked=0 _skipped=0
for src in "$HOOKS_SRC"/*.sh; do
    [ -f "$src" ] || continue
    hook_name="$(basename "$src" .sh | cut -d_ -f1)"
    dst="$HOOKS_DST/$hook_name"
    if [ -e "$dst" ] && [ ! -L "$dst" ]; then
        echo "  skip: $dst exists (not a symlink) — remove it first if you want ours"
        _skipped=$((_skipped + 1))
        continue
    fi
    # Guard against clobbering symlinks that point elsewhere (e.g. husky).
    if [ -L "$dst" ]; then
        _existing_target="$(readlink "$dst")"
        case "$_existing_target" in
            "$HOOKS_SRC"/*) : ;;   # ours — safe to update
            *)
                echo "  skip: $dst → $_existing_target (foreign symlink, not touching)"
                _skipped=$((_skipped + 1))
                continue
                ;;
        esac
    fi
    ln -sf "$src" "$dst"
    chmod +x "$src"
    echo "  linked: $hook_name → $(basename "$src")"
    _linked=$((_linked + 1))
done
echo "install-git-hooks: $_linked linked, $_skipped skipped"
