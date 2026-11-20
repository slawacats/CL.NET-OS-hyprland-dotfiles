#!/usr/bin/env bash

SINK_FILE="$HOME/.local/state/audio-selected-sink"
MAX_VOLUME="1.0"   # volume limit: 1.0 = 100%, 1.5 = 150%

# Icons
iDIR="$HOME/.config/swaync/icons"

# Ensure state dir exists
mkdir -p "$(dirname "$SINK_FILE")"

# ---------------------------------------------------------------------------
# wpctl helpers
# ---------------------------------------------------------------------------

# node_prop <id|@ALIAS@> <property>  ->  value of a node property
node_prop() {
    wpctl inspect "$1" 2>/dev/null | awk -F'"' -v p="$2" '
        index($0, " " p " = ") { print $2; exit }'
}

# list_sinks  ->  "<id><TAB><description>" per line
list_sinks() {
    wpctl status | awk '
        /├─ Sinks:/ { s = 1; next }
        s && /├─|└─/ { exit }
        s && match($0, /[0-9]+\./) {
            id   = substr($0, RSTART, RLENGTH - 1)
            name = substr($0, RSTART + RLENGTH)
            sub(/^ +/, "", name)
            sub(/ +\[vol:.*$/, "", name)
            print id "\t" name
        }'
}

default_sink_id() {
    wpctl inspect @DEFAULT_AUDIO_SINK@ 2>/dev/null |
        awk 'NR==1 { gsub(/,/, "", $2); print $2 }'
}

# sink_id_by_name <node.name>  ->  current id (ids change between restarts)
sink_id_by_name() {
    local id
    while IFS=$'\t' read -r id _; do
        if [[ "$(node_prop "$id" node.name)" == "$1" ]]; then
            echo "$id"
            return 0
        fi
    done < <(list_sinks)
    return 1
}

friendly_name() {
    local n
    n=$(node_prop "$1" node.description)
    [[ -z "$n" ]] && n=$(node_prop "$1" node.name)
    echo "$n"
}

# Returns the id of the selected sink (falls back to the default sink)
get_selected_sink() {
    local name id
    if [[ -f "$SINK_FILE" ]]; then
        name=$(<"$SINK_FILE")
        id=$(sink_id_by_name "$name")
        if [[ -n "$id" ]]; then
            echo "$id"
            return
        fi
    fi
    default_sink_id
}

# Stores node.name (stable), not the id (changes after reboot)
save_selected_sink() {
    node_prop "$1" node.name > "$SINK_FILE"
}

# ---------------------------------------------------------------------------
# launcher detection
# ---------------------------------------------------------------------------
detect_launcher() {
    if command -v fuzzel &>/dev/null; then
        echo "fuzzel --dmenu"
        return
    fi
    if command -v wofi &>/dev/null; then
        echo "wofi --dmenu -p 'Select Audio Sink'"
        return
    fi
    if command -v rofi &>/dev/null; then
        echo "rofi -dmenu -p 'Select Audio Sink'"
        return
    fi
    echo ""
}

LAUNCHER=$(detect_launcher)

# ---------------------------------------------------------------------------
# volume / notifications
# ---------------------------------------------------------------------------
get_volume() {
    wpctl get-volume "$1" | awk '{ printf "%d", $2 * 100 + 0.5 }'
}

is_muted() {
    wpctl get-volume "$1" | grep -q MUTED
}

get_icon() {
    local v
    v=$(get_volume "$1")

    if is_muted "$1" || (( v == 0 )); then
        echo "$iDIR/volume-mute.png"
    elif (( v <= 30 )); then
        echo "$iDIR/volume-low.png"
    elif (( v <= 60 )); then
        echo "$iDIR/volume-mid.png"
    else
        echo "$iDIR/volume-high.png"
    fi
}

# notify_custom <sink id> <message>
notify_custom() {
    local id="$1"
    local message="$2"
    local volume icon sink_name

    volume=$(get_volume "$id")
    icon=$(get_icon "$id")
    sink_name=$(friendly_name "$id")

    notify-send -e -h int:value:"$volume" \
        -h string:x-canonical-private-synchronous:volume_notif \
        -u low -i "$icon" \
        " $sink_name:" " $message: $volume%"
}

# ---------------------------------------------------------------------------
# actions
# ---------------------------------------------------------------------------
select_sink() {
    [[ -z "$LAUNCHER" ]] && { notify-send "No launcher found"; exit 1; }

    declare -A sink_map
    local friendly_list="" current chosen sink_id id name

    current=$(get_selected_sink)

    while IFS=$'\t' read -r id name; do
        [[ -z "$id" ]] && continue
        sink_map["$name"]="$id"

        if [[ "$id" == "$current" ]]; then
            friendly_list+="* $name\n"
        else
            friendly_list+="  $name\n"
        fi
    done < <(list_sinks)

    chosen=$(printf "%b" "$friendly_list" | eval "$LAUNCHER" | sed 's/^[* ]*//')

    [[ -z "$chosen" ]] && exit 0

    sink_id="${sink_map[$chosen]}"
    [[ -z "$sink_id" ]] && exit 1

    save_selected_sink "$sink_id"
    notify_custom "$sink_id" "Selected"
}

cycle_sink() {
    local direction="$1"
    local ids current index=-1 new_index new_id i

    mapfile -t ids < <(list_sinks | cut -f1)
    (( ${#ids[@]} )) || exit 1

    current=$(default_sink_id)

    for i in "${!ids[@]}"; do
        [[ "${ids[$i]}" == "$current" ]] && index=$i
    done

    (( index < 0 )) && exit 1

    if [[ "$direction" == "next" ]]; then
        new_index=$(( (index + 1) % ${#ids[@]} ))
    else
        new_index=$(( (index - 1 + ${#ids[@]}) % ${#ids[@]} ))
    fi

    new_id="${ids[$new_index]}"
    wpctl set-default "$new_id"

    notify_custom "$new_id" "Default Sink Set"
}

# change_volume "+5%" | "-5%"  (converted to wpctl syntax: 5%+ / 5%-)
change_volume() {
    local arg="$1" sink
    sink=$(get_selected_sink)

    wpctl set-volume -l "$MAX_VOLUME" "$sink" "${arg:1}${arg:0:1}"
    notify_custom "$sink" "Volume"
}

toggle_mute() {
    local sink
    sink=$(get_selected_sink)

    wpctl set-mute "$sink" toggle
    notify_custom "$sink" "Toggle"
}

# wpctl has no "subscribe", so events still come from pactl (pipewire-pulse)
watch_sink_changes() {
    local last cur
    last=$(default_sink_id)

    pactl subscribe | while read -r line; do
        [[ "$line" == *"on server"* ]] || continue
        cur=$(default_sink_id)
        [[ -z "$cur" || "$cur" == "$last" ]] && continue
        last="$cur"
        notify_custom "$cur" "Output Changed"
    done
}

case "$1" in
    select) select_sink ;;
    next) cycle_sink next ;;
    prev) cycle_sink prev ;;
    mute) toggle_mute ;;
    [+-][0-9]*%) change_volume "$1" ;;
    watch) watch_sink_changes ;;
    *) echo "Usage: $0 {select|next|prev|mute|+5%|-5%|watch}" ;;
esac
