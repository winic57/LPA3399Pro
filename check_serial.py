import sys
try:
    import serial
    print("Serial found")
except ImportError:
    print("Serial not found")
    sys.exit(1)
