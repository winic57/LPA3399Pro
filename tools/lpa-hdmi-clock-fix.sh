#!/bin/bash
# Re-run an HDMI modeset so RK3399 VPLL/dclk match the active 1024x768 mode.
set -euo pipefail

connector_name=${HDMI_CONNECTOR:-HDMI-A-1}
preferred_mode=${HDMI_PREFERRED_MODE:-1024x768}
kick_mode=${HDMI_KICK_MODE:-1920x1080}

for _ in $(seq 1 60); do
	if [ -e /dev/dri/card0 ] && command -v modetest >/dev/null 2>&1; then
		connector_id=$(modetest -c 2>/dev/null |
			awk -v name="$connector_name" '$4 == name { print $1; exit }')
		[ -n "${connector_id:-}" ] && break
	fi
	sleep 0.5
done

if [ -z "${connector_id:-}" ]; then
	echo "HDMI connector $connector_name did not appear" >&2
	exit 1
fi

# modetest restores the fbcon CRTC when it exits.  The temporary different
# mode makes that restore a real modeset, which reprograms VPLL and dclk.
if grep -qx "$kick_mode" "/sys/class/drm/card0-$connector_name/modes"; then
	modetest -s "$connector_id:$kick_mode" >/dev/null
else
	echo "kick mode $kick_mode is not advertised by $connector_name" >&2
	exit 1
fi

# Confirm the fbcon mode and constrain the link to the panel's 8-bit path.
active_mode=$(cat /sys/class/graphics/fb0/virtual_size 2>/dev/null || true)
if [ "$active_mode" != "${preferred_mode/x/,}" ]; then
	echo "unexpected fb0 mode $active_mode (wanted ${preferred_mode/x/,})" >&2
	exit 1
fi
modetest -w "$connector_id:max bpc:8" >/dev/null
echo 0 > /sys/class/graphics/fb0/blank

if [ -r /sys/kernel/debug/clk/clk_summary ]; then
	dclk_rate=$(awk '$1 == "dclk_vop0" { print $5; exit }' \
		/sys/kernel/debug/clk/clk_summary)
	if [ "$dclk_rate" != "65000000" ]; then
		echo "dclk_vop0 is $dclk_rate, expected 65000000" >&2
		exit 1
	fi
fi

echo "HDMI clock fixed: connector=$connector_name mode=$preferred_mode bpc=8"
