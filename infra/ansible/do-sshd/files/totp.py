#!/usr/bin/env python3
"""Imprime el codigo actual de Google Authenticator (TOTP, RFC 6238) del secreto en
la variable de entorno TOTP_SECRET. Lo usa el pipeline para entrar al droplet cuando
ya esta endurecido (llave + codigo). Solo libreria estandar.

Uso: TOTP_SECRET=... python3 totp.py [segundos_unix]
"""
import base64
import hmac
import os
import struct
import sys
import time

secret = os.environ.get("TOTP_SECRET", "").upper().replace(" ", "").rstrip("=")
if not secret:
    sys.exit("Falta la variable de entorno TOTP_SECRET")

key = base64.b32decode(secret + "=" * (-len(secret) % 8))
now = int(sys.argv[1]) if len(sys.argv) > 1 else int(time.time())
digest = hmac.new(key, struct.pack(">Q", now // 30), "sha1").digest()
offset = digest[-1] & 0x0F
code = (struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF) % 1_000_000
print(f"{code:06d}")
