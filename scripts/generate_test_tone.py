#!/usr/bin/env python3
"""A quiet, original 440 Hz WAV tone for opt-in system-audio acceptance tests."""
import math
import struct
import sys
import wave
from pathlib import Path

destination = Path(sys.argv[1] if len(sys.argv) > 1 else 'build/LiveCaptures/test-tone.wav')
destination.parent.mkdir(parents=True, exist_ok=True)
rate = 48000
one_second = b''.join(struct.pack('<h', int(4000 * math.sin(2 * math.pi * 440 * i / rate))) for i in range(rate))
with wave.open(str(destination), 'wb') as output:
    output.setnchannels(1)
    output.setsampwidth(2)
    output.setframerate(rate)
    for _ in range(60): output.writeframesraw(one_second)
print(destination)
