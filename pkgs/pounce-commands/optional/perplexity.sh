#!/bin/bash
# pounce: name = Perplexity
# pounce: description = Ask Perplexity in the browser
# pounce: icon = sparkles
# pounce: submenu = true
# pounce: network = true

# Type a question, get a fresh Perplexity thread in your browser. No API key, no
# app, no CLI — the whole plugin is a URL: perplexity.ai/search?q=… is the same
# endpoint their "set as default search engine" install uses, and hitting it
# opens a NEW thread rather than reusing the last one.
#
# `open` hands the URL to whatever owns https, so this lands in your default
# browser — or in Perplexity.app, if you installed it and let it claim
# perplexity.ai links. Either way nothing here assumes it's there.

# Pure-bash percent-encoding — no python/jq dependency (the daemon inherits
# launchd's bare PATH, so we can't assume either is on it).
urlencode() {
    local s="$1" out="" c i
    for (( i = 0; i < ${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v c '%%%02X' "'$c" ; out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

ask() {
    open "https://www.perplexity.ai/search?q=$(urlencode "$1")"
}

# Clipboard preview for the "ask about what I just copied" row — one line, and
# short enough to read as a subtitle.
clip=$(pbpaste 2>/dev/null | tr '\n\t' '  ')
clip="${clip#"${clip%%[![:space:]]*}"}"
clip="${clip%"${clip##*[![:space:]]}"}"
preview="$clip"
[[ ${#preview} -gt 60 ]] && preview="${preview:0:60}…"

list="New Thread"$'\t'"Open a blank Perplexity chat"$'\t'"bubble.left"
[[ -n "$clip" ]] && list="$list"$'\n'"Ask About Clipboard"$'\t'"$preview"$'\t'"doc.on.clipboard"

# The rows are the shortcuts; the real interface is the text field. Anything
# typed that matches no row comes back as `enter<TAB><text>` and becomes the
# question — same `cut -f2` either way.
selected=$(printf '%s\n' "$list" | pounce -p "Ask Perplexity…" -i "sparkles")
[[ -z "$selected" ]] && exit 0
choice=$(printf '%s' "$selected" | cut -f2)

case "$choice" in
    "New Thread")          open "https://www.perplexity.ai/" ;;
    "Ask About Clipboard") ask "$clip" ;;
    *)                     [[ -n "$choice" ]] && ask "$choice" ;;
esac
exit 0
