#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

: "${CSWAPBAR_VERSION:?CSWAPBAR_VERSION is required}"
: "${CSWAPBAR_BUILD:?CSWAPBAR_BUILD is required}"
: "${CSWAPBAR_UPDATE_CHANNEL:?CSWAPBAR_UPDATE_CHANNEL is required}"
: "${CSWAPBAR_SPARKLE_PRIVATE_KEY:?CSWAPBAR_SPARKLE_PRIVATE_KEY is required}"
: "${CSWAPBAR_SPARKLE_DOWNLOAD_PREFIX:?CSWAPBAR_SPARKLE_DOWNLOAD_PREFIX is required}"

case "$CSWAPBAR_UPDATE_CHANNEL" in
  stable|beta) ;;
  *) echo "error: update channel must be stable or beta" >&2; exit 2 ;;
esac

APP="dist/ClaudeSwapBar.app"
if [[ ! -d "$APP" ]]; then
  echo "error: $APP not found" >&2
  exit 1
fi

mkdir -p dist/sparkle
ZIP="dist/sparkle/ClaudeSwapBar-${CSWAPBAR_VERSION}.zip"
rm -f "$ZIP"
(cd dist && /usr/bin/ditto -c -k --sequesterRsrc --keepParent ClaudeSwapBar.app \
  "sparkle/ClaudeSwapBar-${CSWAPBAR_VERSION}.zip")

find_sign_update() {
  local root sign
  for root in "$PWD/.build/artifacts" "$HOME/Library/Caches/org.swift.swiftpm/artifacts"; do
    [[ -d "$root" ]] || continue
    sign="$(find "$root" -type f -name sign_update 2>/dev/null \
      | grep -v old_dsa_scripts | head -n 1 || true)"
    if [[ -n "$sign" ]]; then
      printf '%s' "$sign"
      return 0
    fi
  done
  return 1
}

SIGN_UPDATE="$(find_sign_update || true)"
if [[ -z "$SIGN_UPDATE" ]]; then
  echo "error: Sparkle EdDSA sign_update tool not found" >&2
  exit 1
fi

KEY_FILE="$(mktemp)"
trap 'unlink "$KEY_FILE" 2>/dev/null || true' EXIT
printf '%s' "$CSWAPBAR_SPARKLE_PRIVATE_KEY" > "$KEY_FILE"
chmod 600 "$KEY_FILE"

SIGNATURE_LINE="$("$SIGN_UPDATE" "$ZIP" -f "$KEY_FILE")"
ED_SIGNATURE="$(printf '%s' "$SIGNATURE_LINE" \
  | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
if [[ -z "$ED_SIGNATURE" ]]; then
  echo "error: Sparkle did not produce an EdDSA signature" >&2
  exit 1
fi
"$SIGN_UPDATE" --verify -f "$KEY_FILE" "$ZIP" "$ED_SIGNATURE"

LENGTH="$(stat -f%z "$ZIP")"
PUBDATE="$(LC_ALL=en_US date -u '+%a, %d %b %Y %H:%M:%S +0000')"
DOWNLOAD_URL="${CSWAPBAR_SPARKLE_DOWNLOAD_PREFIX%/}/ClaudeSwapBar-${CSWAPBAR_VERSION}.zip"
NOTES_FILE="release-notes/v${CSWAPBAR_VERSION}.md"

DESCRIPTION_HTML=""
if [[ -f "$NOTES_FILE" ]]; then
  DESCRIPTION_HTML="$(perl -0777 -ne '
    my @out; my $inlist = 0;
    for my $line (split /\n/) {
      if ($line =~ /^##\s+(.+?)\s*$/) {
        push @out, "</ul>" if $inlist; $inlist = 0;
        my $h = $1; $h =~ s/&/&amp;/g; $h =~ s/</&lt;/g; $h =~ s/>/&gt;/g;
        push @out, "<h3>$h</h3>";
      } elsif ($line =~ /^[-*]\s+(.+?)\s*$/) {
        my $t = $1; $t =~ s/&/&amp;/g; $t =~ s/</&lt;/g; $t =~ s/>/&gt;/g;
        $t =~ s/`(.+?)`/<code>$1<\/code>/g;
        push @out, "<ul>" unless $inlist; $inlist = 1;
        push @out, "<li>$t</li>";
      }
    }
    push @out, "</ul>" if $inlist;
    print join("", @out);
  ' "$NOTES_FILE")"
fi

DESCRIPTION_BLOCK=""
if [[ -n "$DESCRIPTION_HTML" ]]; then
  DESCRIPTION_BLOCK="      <description><![CDATA[${DESCRIPTION_HTML}]]></description>"
fi

CHANNEL_BLOCK=""
if [[ "$CSWAPBAR_UPDATE_CHANNEL" == "beta" ]]; then
  CHANNEL_BLOCK="      <sparkle:channel>beta</sparkle:channel>"
fi

cat > dist/sparkle/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Claude Swap Bar</title>
    <link>https://github.com/jx-grxf/claude-swap-bar</link>
    <description>Claude Swap Bar ${CSWAPBAR_UPDATE_CHANNEL} update feed</description>
    <language>en</language>
    <item>
      <title>Claude Swap Bar ${CSWAPBAR_VERSION}</title>
${DESCRIPTION_BLOCK}
${CHANNEL_BLOCK}
      <sparkle:version>${CSWAPBAR_BUILD}</sparkle:version>
      <sparkle:shortVersionString>${CSWAPBAR_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <pubDate>${PUBDATE}</pubDate>
      <enclosure
        url="${DOWNLOAD_URL}"
        length="${LENGTH}"
        type="application/octet-stream"
        sparkle:edSignature="${ED_SIGNATURE}" />
    </item>
  </channel>
</rss>
EOF

echo "Wrote $ZIP"
echo "Wrote dist/sparkle/appcast.xml"
