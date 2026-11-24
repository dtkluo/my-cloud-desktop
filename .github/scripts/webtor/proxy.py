"""AgentDock 云桌面 - Webtor 端口转发

把 Windows 主机的 0.0.0.0:8081 转给 WSL 里 Docker 已发布的 8081。
目标优先走 127.0.0.1（WSL localhost forwarding），失败再回退到发行版 IP。

由计划任务 WebtorProxy 以 rdpadmin/S4U 身份常驻运行。
"""

import socket
import subprocess
import threading

LISTEN_ADDR = ("0.0.0.0", 8081)
PORT = 8081
DISTRO = "webtor"
CREATE_NO_WINDOW = 0x08000000

_lock = threading.Lock()
_state = {"ip": None}


def wsl_ip():
    """取发行版当前 IP（WSL 重启后会变，故失败时重新取）。"""
    with _lock:
        if _state["ip"]:
            return _state["ip"]
    ip = None
    try:
        r = subprocess.run(
            ["wsl", "-d", DISTRO, "-u", "root", "--", "hostname", "-I"],
            capture_output=True, text=True, timeout=20,
            creationflags=CREATE_NO_WINDOW,
        )
        parts = (r.stdout or "").split()
        if parts:
            ip = parts[0]
    except Exception:
        ip = None
    with _lock:
        _state["ip"] = ip
    return ip


def connect_target():
    """优先直连发行版 IP —— 实测比 wslrelay 的 127.0.0.1 映射更可靠。

    wslrelay 在 VM 重启后有时不再重建转发表，表现为主机 127.0.0.1:PORT
    连接被接受但无响应；而直连发行版 IP 一直可用。
    """
    for _ in range(2):
        ip = wsl_ip()
        if not ip:
            break
        try:
            return socket.create_connection((ip, PORT), timeout=5)
        except OSError:
            with _lock:
                _state["ip"] = None
    try:
        return socket.create_connection(("127.0.0.1", PORT), timeout=5)
    except OSError:
        return None


def pump(src, dst):
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        try:
            dst.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle(client):
    server = connect_target()
    if server is None:
        client.close()
        return
    server.settimeout(None)
    client.settimeout(None)
    threading.Thread(target=pump, args=(client, server), daemon=True).start()
    threading.Thread(target=pump, args=(server, client), daemon=True).start()


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(LISTEN_ADDR)
    srv.listen(128)
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn,), daemon=True).start()


if __name__ == "__main__":
    main()
