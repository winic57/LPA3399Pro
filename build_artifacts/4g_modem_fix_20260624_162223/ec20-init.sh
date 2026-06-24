#!/bin/bash
# EC20/4G Modem Power-On Script for LPA3399Pro
# Controls all three lines: PWREN, RESET, and PWRKEY from user-space.
#
# Pins:
#   PWREN  - gpiochip4 pin 29 (active high, hold HIGH to enable power)
#   RESET  - gpiochip1 pin 2  (active low reset, hold LOW for module to run)
#   PWRKEY - gpiochip4 pin 25 (active low pulse, pulse LOW to boot, then hold HIGH)

set -e

echo "=== EC20 4G Modem Cold Boot Power-On Sequence ==="

# Clean up any existing gpioset processes first
killall gpioset 2>/dev/null || true
sleep 0.5

# Step 1: Ensure clean cold state: PWREN=0, RESET=1 (reset asserted), PWRKEY=1
echo "Driving lines to initial off/reset state..."
gpioset -c gpiochip4 29=0 &
PID_PWREN=$!
gpioset -c gpiochip1 2=1 &
PID_RESET=$!
gpioset -c gpiochip4 25=1 &
PID_PWRKEY=$!

sleep 0.5

# Kill off state controllers
kill $PID_PWREN $PID_RESET $PID_PWRKEY 2>/dev/null || true
wait $PID_PWREN $PID_RESET $PID_PWRKEY 2>/dev/null || true

# Step 2: Power up and release reset: PWREN=1, RESET=0 (daemonize to hold states)
echo "Driving PWREN=1, RESET=0 (powering on and releasing reset)..."
gpioset -z -c gpiochip4 29=1
gpioset -z -c gpiochip1 2=0

sleep 0.5

# Step 3: Pulse PWRKEY LOW for 1.5s
echo "Pulsing PWRKEY LOW (booting)..."
gpioset -c gpiochip4 25=0 &
GP_PID=$!

sleep 1.5

# Release PWRKEY LOW
kill $GP_PID 2>/dev/null || true
wait $GP_PID 2>/dev/null || true

# Step 4: Hold PWRKEY HIGH
echo "Driving PWRKEY HIGH (holding)..."
gpioset -z -c gpiochip4 25=1

echo "Waiting 12s for USB module detection..."
sleep 12

if lsusb | grep -q "2c7c"; then
    echo "SUCCESS: 4G modem detected!"
    lsusb | grep "2c7c"
else
    echo "WARNING: 4G modem not detected yet. Checking USB interface..."
fi

echo "=== Done ==="
