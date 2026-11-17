#!/usr/bin/env bash
# Install the Persian menu and VPK while preserving the original game files.
set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
DEFAULT_GAME="$HOME/.local/share/Steam/steamapps/common/Deadlock/game/citadel"
GAME=${1:-$DEFAULT_GAME}
if (( $# > 1 )); then echo "Usage: $0 [path-to-game/citadel]" >&2; exit 2; fi
for command in python3 sha256sum mktemp; do command -v "$command" >/dev/null || { echo "Missing dependency: $command" >&2; exit 1; }; done
[[ -d $GAME ]] || { echo "Game directory not found: $GAME" >&2; exit 1; }
GAME=$(cd -- "$GAME" && pwd -P)
MENU_REL='resource/localization/citadel_main/citadel_main_english.txt'
VPK_REL='pak82_dir.vpk'
FONTS_REL='panorama/fonts'
# The engine-wide fontconfig lives in game/core/panorama/fonts (next to the
# citadel folder). Earlier installer versions wrongly used citadel/core/... .
CORE_FONTS_REL='../core/panorama/fonts'
LEGACY_CORE_REL='core/panorama/fonts'
BACKUP="$GAME/.deadlock-persian-backup"
LOCK="$GAME/.deadlock-persian.lock"
SOURCE_MENU="$ROOT/data/citadel_main_english.txt"
SOURCE_VPK="$ROOT/data/$VPK_REL"
SOURCE_FONTS="$ROOT/data/fonts"
TRANSLATOR="$ROOT/tools/translate_common.py"
[[ -f $SOURCE_MENU && -f $SOURCE_VPK && -d $SOURCE_FONTS && -f $TRANSLATOR ]] || { echo 'Missing translation files, fonts, or tools/translate_common.py in the installer directory.' >&2; exit 1; }
# Do not silently install into an unrelated folder.
[[ -f "$GAME/$MENU_REL" || -f "$GAME/pak01_dir.vpk" || -f "$GAME/$VPK_REL" ]] || { echo "This does not appear to be the Deadlock citadel folder: $GAME" >&2; exit 1; }
mkdir -- "$LOCK" 2>/dev/null || { echo "Another install/uninstall is running, or a stale lock exists: $LOCK" >&2; exit 1; }
STAGE=''
cleanup() { [[ -z $STAGE ]] || rm -rf -- "$STAGE"; rmdir -- "$LOCK" 2>/dev/null || true; }
trap cleanup EXIT
STAGE=$(mktemp -d "$GAME/.deadlock-persian-stage.XXXXXXXX")
STAGE_FONTS="$STAGE/fonts"

# Work on a private copy so the repository source is never modified.
cp -- "$SOURCE_VPK" "$STAGE/$VPK_REL"
cp -- "$SOURCE_MENU" "$STAGE/menu.txt"
cp -R -- "$SOURCE_FONTS/." "$STAGE_FONTS/"
python3 "$TRANSLATOR" "$STAGE/$VPK_REL"

# Font deploy targets. corefonts is only used when the game's core folder
# exists next to citadel (the real Deadlock layout).
FONT_ITEMS=(fonts)
declare -A FONT_TARGET=([fonts]="$GAME/$FONTS_REL")
if [[ -d $GAME/../core/panorama ]]; then
    FONT_ITEMS+=(corefonts)
    FONT_TARGET[corefonts]="$GAME/$CORE_FONTS_REL"
fi
ALL_ITEMS=(menu vpk "${FONT_ITEMS[@]}")

# Preserve the very first pre-install state. Never replace a previous backup.
if [[ -e $BACKUP ]]; then
    [[ -d $BACKUP && -f "$BACKUP/format" && $(<"$BACKUP/format") == 'deadlock-persian-v1' && -f "$BACKUP/menu.state" && -f "$BACKUP/vpk.state" ]] || { echo "Invalid backup directory; refusing to overwrite it: $BACKUP" >&2; exit 1; }
    for item in menu vpk fonts corefonts; do
        # Backwards compatibility: older backups only have menu.state / vpk.state;
        # treat missing entries as absent.
        if [[ -f "$BACKUP/$item.state" ]]; then
            state=$(<"$BACKUP/$item.state")
        else
            state='absent'
        fi
        if [[ $item == fonts || $item == corefonts ]]; then
            [[ $state == absent || ( $state == present && -d "$BACKUP/$item.original" ) ]] || { echo "Backup for $item is incomplete." >&2; exit 1; }
        else
            [[ $state == absent || ( $state == present && -f "$BACKUP/$item.original" ) ]] || { echo "Backup for $item is incomplete." >&2; exit 1; }
        fi
    done
    if [[ -f "$BACKUP/installed.sha256" ]]; then
        (cd -- "$GAME" && sha256sum --status -c "$BACKUP/installed.sha256") || { echo 'Installed files changed since the previous install. Restore or inspect them before reinstalling.' >&2; exit 1; }
    else
        echo 'Incomplete previous installation; run uninstall.sh to restore the original files.' >&2
        exit 1
    fi
else
    TEMP_BACKUP="$STAGE/backup"
    mkdir -- "$TEMP_BACKUP"
    printf '%s\n' 'deadlock-persian-v1' > "$TEMP_BACKUP/format"
    for item in menu vpk fonts corefonts; do
        case "$item" in
            menu) target="$GAME/$MENU_REL"; kind='f' ;;
            vpk)  target="$GAME/$VPK_REL";  kind='f' ;;
            *)    target="${FONT_TARGET[$item]:-}"; kind='d' ;;
        esac
        if [[ $item == corefonts && -z $target ]]; then
            printf 'absent\n' > "$TEMP_BACKUP/$item.state"
            continue
        fi
        if [[ -L $target || ( -e $target && ( ( $kind == d && ! -d $target ) || ( $kind == f && ! -f $target ) ) ) ]]; then echo "Refusing to replace non-$kind file or symlink: $target" >&2; exit 1; fi
        if [[ -e $target ]]; then
            cp -pR -- "$target" "$TEMP_BACKUP/$item.original"
            printf 'present\n' > "$TEMP_BACKUP/$item.state"
        else
            printf 'absent\n' > "$TEMP_BACKUP/$item.state"
        fi
    done
    mv -- "$TEMP_BACKUP" "$BACKUP"
fi

# Remove files placed in the wrong citadel/core path by earlier versions.
cleanup_legacy_core() {
    local wrong="$GAME/$LEGACY_CORE_REL"
    [[ -d $wrong ]] || return 0
    rm -f -- "$wrong/Vazirmatn-Regular.ttf" "$wrong/Vazirmatn-Bold.ttf" \
             "$wrong/conf.d/99-deadlock-persian.conf" "$wrong/fonts.conf.patched" 2>/dev/null || true
    rm -rf -- "$wrong/vazirmatn" 2>/dev/null || true
    find "$wrong" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    rmdir -p -- "$wrong" 2>/dev/null || true
}
cleanup_legacy_core

# Record intended hashes before replacing either file, so a failed install can
# still be recovered using uninstall.sh --force.
# The manifest lists installed font files (relative to each font dir).
while IFS= read -r font; do
    rel="${font#$STAGE_FONTS/}"
    case "$rel" in
        vazirmatn/*.ttf) basename -- "$rel" ;;
        *) printf '%s\n' "$rel" ;;
    esac
done < <(find "$STAGE_FONTS" -type f | sort) > "$STAGE/fonts.installed"
mv -f -- "$STAGE/fonts.installed" "$BACKUP/fonts.installed"
{
    printf '%s  %s\n' "$(sha256sum "$STAGE/menu.txt" | cut -d' ' -f1)" "$MENU_REL"
    printf '%s  %s\n' "$(sha256sum "$STAGE/$VPK_REL" | cut -d' ' -f1)" "$VPK_REL"
    # Record every font file we are about to install (both font dirs).
    while IFS= read -r font; do
        rel="${font#$STAGE_FONTS/}"
        case "$rel" in
            vazirmatn/*.ttf) dest_rel="$(basename -- "$rel")" ;;
            *) dest_rel="$rel" ;;
        esac
        for item in "${FONT_ITEMS[@]}"; do
            dir_rel=$([[ $item == fonts ]] && printf '%s' "$FONTS_REL" || printf '%s' "$CORE_FONTS_REL")
            printf '%s  %s\n' "$(sha256sum "$font" | cut -d' ' -f1)" "$dir_rel/$dest_rel"
        done
    done < <(find "$STAGE_FONTS" -type f | sort)
} > "$STAGE/installed.sha256"
mv -f -- "$STAGE/installed.sha256" "$BACKUP/installed.sha256"
mkdir -p -- "$(dirname -- "$GAME/$MENU_REL")"
# Staging and destination are on the same filesystem; renames are atomic.
mv -f -- "$STAGE/menu.txt" "$GAME/$MENU_REL"
mv -f -- "$STAGE/$VPK_REL" "$GAME/$VPK_REL"
# Merge the Vazirmatn font files into the game's font folders.
# TTFs belong at the folder root so fonts.conf can scan them; conf.d rules
# keep their subdirectory.
for item in "${FONT_ITEMS[@]}"; do
    target="${FONT_TARGET[$item]}"
    mkdir -p -- "$target"
    while IFS= read -r font; do
        rel="${font#$STAGE_FONTS/}"
        case "$rel" in
            vazirmatn/*.ttf) dest_rel="$(basename -- "$rel")" ;;
            *) dest_rel="$rel" ;;
        esac
        mkdir -p -- "$target/$(dirname -- "$dest_rel")"
        cp -f -- "$font" "$target/$dest_rel"
    done < <(find "$STAGE_FONTS" -type f | sort)
done

# Patch fonts.conf so Panorama uses Vazirmatn for Persian (Arabic-script) UI
# text. Two self-delimiting blocks are inserted: fontpattern entries right
# after the game's own fontpattern list (the engine only loads font files
# whose name matches a listed pattern), and family rules before
# </fontconfig>. Any earlier deadlock-persian blocks are replaced first so
# rule updates take effect on reinstall.
patch_fonts_conf() {
    local conf="$1"
    [[ -f $conf && ! -L $conf ]] || return 0
    python3 - "$conf" <<'PY'
import sys
path = sys.argv[1]
PATTERNS = (
    '    <!-- deadlock-persian:fonts -->\n'
    '    <fontpattern>Vazirmatn</fontpattern>\n'
    '    <fontpattern>vazirmatn</fontpattern>\n'
    '    <fontpattern>Vazirmatn-Regular</fontpattern>\n'
    '    <fontpattern>Vazirmatn-Bold</fontpattern>\n'
    '    <fontpattern>vazirmatn-regular</fontpattern>\n'
    '    <fontpattern>vazirmatn-bold</fontpattern>\n'
    '    <fontpattern>Vazirmatn-Regular.ttf</fontpattern>\n'
    '    <fontpattern>Vazirmatn-Bold.ttf</fontpattern>\n'
    '    <!-- /deadlock-persian:fonts -->'
)
# The game's text font families, matched by substring (the game's own family
# names are quirky: "BlackHanSans", "07TetsubinGothic", "notosans", ...).
# Each gets the proven 42-repl-global.conf pair: target="font" reassigns the
# family in the font cache, target="pattern" prepends Vazirmatn with strong
# binding so it wins the family match. Marlett and *.uifont symbol fonts are
# intentionally left alone.
FAMILIES = ['Radiance', 'Reaver', 'Oracle', 'Pulp', 'Jost', 'Hahmlet',
            'HanSans', 'Rockn', 'Tetsubin', 'Retail', 'Hypatia', 'Noto',
            'noto', 'Creepster', 'Rajdhani', 'Quantico', 'VT323', 'Raju',
            'avenhook', 'Early', 'roadcast', 'Market', 'Unifraktur',
            'Grenze', 'Bangers', 'DIN', 'Arial', 'Tahoma', 'Verdana',
            'DejaVu', 'Liberation', 'Courier', 'Lucida', 'Gulim', 'MingLiU']
rule_parts = [
    '    <!-- deadlock-persian:rules -->\n',
    '    <!-- Vazirmatn replaces the game text fonts (42-repl-global style). -->\n',
]
for fam in FAMILIES:
    rule_parts.append(
        '    <match target="font">\n'
        f'        <test name="family" compare="contains" qual="any"><string>{fam}</string></test>\n'
        '        <edit name="family" mode="assign"><string>Vazirmatn</string></edit>\n'
        '    </match>\n'
        '    <match target="pattern">\n'
        f'        <test name="family" compare="contains" qual="any"><string>{fam}</string></test>\n'
        '        <edit name="family" mode="prepend" binding="strong"><string>Vazirmatn</string></edit>\n'
        '    </match>\n')
rule_parts.append(
    '    <match target="pattern">\n'
    '        <test qual="any" name="charset" compare="contains"><string>Arabic</string></test>\n'
    '        <edit name="family" mode="prepend" binding="strong"><string>Vazirmatn</string></edit>\n'
    '    </match>\n')
rule_parts.append(
    '    <match target="pattern">\n'
    '        <edit name="family" mode="append"><string>Vazirmatn</string></edit>\n'
    '    </match>\n'
    '    <!-- /deadlock-persian:rules -->\n')
RULES = ''.join(rule_parts)

def strip_regions(data):
    for start, end in (('<!-- deadlock-persian:fonts -->', '<!-- /deadlock-persian:fonts -->'),
                       ('<!-- deadlock-persian:rules -->', '<!-- /deadlock-persian:rules -->')):
        while True:
            i = data.find(start)
            if i < 0:
                break
            j = data.find(end, i)
            if j < 0:
                break
            data = data[:i] + data[j + len(end):]
    # Legacy single-block format: marker directly before </fontconfig>.
    i = data.find('<!-- deadlock-persian')
    j = data.rfind('</fontconfig>')
    if i >= 0 and j > i:
        data = data[:i] + data[j:]
    return data

with open(path, encoding='utf-8') as f:
    data = f.read()
data = strip_regions(data)
p = data.rfind('</fontpattern>')
if p >= 0:
    p += len('</fontpattern>')
    data = data[:p] + '\n' + PATTERNS + data[p:]
idx = data.rfind('</fontconfig>')
if idx < 0:
    raise SystemExit('fonts.conf: </fontconfig> not found; not patching')
data = data[:idx] + RULES + data[idx:]
with open(path, 'w', encoding='utf-8') as f:
    f.write(data)
PY
}
for item in "${FONT_ITEMS[@]}"; do
    dir_rel=$([[ $item == fonts ]] && printf '%s' "$FONTS_REL" || printf '%s' "$CORE_FONTS_REL")
    patch_fonts_conf "$GAME/$dir_rel/fonts.conf"
done
# Record which fonts.conf files carry our rule so uninstall can strip it even
# when no directory backup exists (backups from before this feature).
{
    for item in "${FONT_ITEMS[@]}"; do
        dir_rel=$([[ $item == fonts ]] && printf '%s' "$FONTS_REL" || printf '%s' "$CORE_FONTS_REL")
        if [[ -f "$GAME/$dir_rel/fonts.conf" ]] && grep -q 'deadlock-persian' "$GAME/$dir_rel/fonts.conf" 2>/dev/null; then
            printf '%s\n' "$dir_rel/fonts.conf"
        fi
    done
} > "$STAGE/fonts.conf.patched"
mv -f -- "$STAGE/fonts.conf.patched" "$BACKUP/fonts.conf.patched"

# Replace the game's own font files with renamed Vazirmatn copies: the file
# replacement method confirmed working for Deadlock/CS2/Dota font mods (rename
# the custom font to the original file name and paste it in). The originals are
# backed up and restored by uninstall.sh. Symbol fonts (Marlett, *.uifont) and
# our own Vazirmatn copies stay untouched. Set DEADLOCK_PERSIAN_NO_REPLACE=1
# to skip this step.
if [ -z "${DEADLOCK_PERSIAN_NO_REPLACE:-}" ]; then
python3 - "$ROOT/data/fonts/vazirmatn" "$GAME" "$BACKUP" <<'PYEOF'
import hashlib, os, shutil, sys
src_dir, game, backup = (os.path.abspath(p) for p in sys.argv[1:4])
manifest = os.path.join(backup, 'fonts.replaced')
repl_dir = os.path.join(backup, 'replaced')
os.makedirs(repl_dir, exist_ok=True)

def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def rel_fs(rel):
    return rel.replace('..', 'up').lstrip('/')

done = set()
if os.path.exists(manifest):
    with open(manifest, encoding='utf-8') as f:
        done = {line.split('\t', 1)[0] for line in f if line.strip()}

bold = os.path.join(src_dir, 'Vazirmatn-Bold.ttf')
regular = os.path.join(src_dir, 'Vazirmatn-Regular.ttf')
entries = []
for font_dir in (os.path.join(game, 'panorama', 'fonts'),
                 os.path.join(os.path.dirname(game), 'core', 'panorama', 'fonts')):
    if not os.path.isdir(font_dir):
        continue
    for name in sorted(os.listdir(font_dir)):
        low = name.lower()
        if not low.endswith(('.ttf', '.otf', '.ttc')):
            continue
        if low.startswith('marlett') or 'vazirmatn' in low:
            continue
        path = os.path.join(font_dir, name)
        if not os.path.isfile(path):
            continue
        rel = os.path.relpath(path, game)
        if rel in done:
            continue
        orig = sha256(path)
        dest = os.path.join(repl_dir, rel_fs(rel))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copyfile(path, dest)
        tmp = path + '.dp-tmp'
        shutil.copyfile(bold if 'bold' in low else regular, tmp)
        os.replace(tmp, path)
        entries.append((rel, orig, sha256(path)))
        done.add(rel)
if entries:
    with open(manifest, 'a', encoding='utf-8') as f:
        for rel, orig, new in entries:
            f.write('%s\t%s\t%s\n' % (rel, orig, new))
print('Replaced %d game font file(s) with Vazirmatn (originals backed up)' % len(entries))
PYEOF

# Put Vazirmatn in the user font dir (~/.fonts is in the engine's scan list).
python3 - "$ROOT/data/fonts/vazirmatn" <<'PYEOF'
import os, shutil, sys
src = os.path.abspath(sys.argv[1])
dest = os.path.expanduser('~/.fonts')
os.makedirs(dest, exist_ok=True)
for name in ('Vazirmatn-Regular.ttf', 'Vazirmatn-Bold.ttf'):
    shutil.copyfile(os.path.join(src, name), os.path.join(dest, name))
print('Vazirmatn installed in ~/.fonts')
PYEOF
fi

# Clear the fontconfig cache so the engine rescans the fonts on next start
# (the CS2FontStudio tool does this after every font change).
rm -rf -- "${XDG_CACHE_HOME:-$HOME/.cache}/fontconfig" "${TMPDIR:-/tmp}/fontconfig" 2>/dev/null || true

echo "Installed Persian translation in: $GAME"
echo "Original files are backed up in: $BACKUP"
echo 'The menu translation is incomplete and has not been tested in game.'
echo 'Restart Deadlock for the Vazirmatn font to take effect.'
