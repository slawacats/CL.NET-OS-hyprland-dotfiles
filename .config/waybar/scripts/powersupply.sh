#!/usr/bin/env bash
capacity=$(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null)
echo "{\"text\":\"${capacity}%\"}"
