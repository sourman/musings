#!/usr/bin/env python3
"""Local unauthenticated forward proxy -> upstream authenticated egress proxy.
Listens on 127.0.0.1:8888. Credentials stay in memory; never logged."""
import asyncio, base64, os, re

UPSTREAM = os.environ.get("https_proxy") or os.environ.get("HTTPS_PROXY")
m = re.match(r"http://([^:]+):([^@]+)@([^:/]+):(\d+)", UPSTREAM or "")
if not m:
    raise SystemExit("no usable upstream proxy in env")
user, pwd, UP_HOST, UP_PORT = m.group(1), m.group(2), m.group(3), int(m.group(4))
AUTH = "Basic " + base64.b64encode(f"{user}:{pwd}".encode()).decode()

async def relay(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except Exception:
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass

async def handle(client_r, client_w):
    try:
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = await asyncio.wait_for(client_r.read(4096), timeout=15)
            if not chunk:
                return
            head += chunk
        header, _, rest = head.partition(b"\r\n\r\n")
        lines = header.decode("latin1").split("\r\n")
        method, target, _ver = lines[0].split(" ", 2)
        up_r, up_w = await asyncio.open_connection(UP_HOST, UP_PORT)
        if method.upper() == "CONNECT":
            up_w.write(f"CONNECT {target} HTTP/1.1\r\nHost: {target}\r\nProxy-Authorization: {AUTH}\r\n\r\n".encode())
            await up_w.drain()
            resp = await asyncio.wait_for(up_r.read(4096), timeout=15)
            if b" 200" not in resp.split(b"\r\n", 1)[0]:
                client_w.write(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
                await client_w.drain()
                client_w.close(); up_w.close()
                return
            client_w.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            await client_w.drain()
            if rest:
                up_w.write(rest); await up_w.drain()
        else:
            new_lines = [lines[0]] + [ln for ln in lines[1:] if not ln.lower().startswith("proxy-authorization:")]
            new_lines.append(f"Proxy-Authorization: {AUTH}")
            up_w.write(("\r\n".join(new_lines) + "\r\n\r\n").encode("latin1") + rest)
            await up_w.drain()
        await asyncio.gather(relay(client_r, up_w), relay(up_r, client_w))
    except Exception:
        try:
            client_w.close()
        except Exception:
            pass

async def main():
    srv = await asyncio.start_server(handle, "127.0.0.1", 8888)
    async with srv:
        await srv.serve_forever()

asyncio.run(main())
