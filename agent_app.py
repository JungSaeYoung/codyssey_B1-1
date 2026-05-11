#!/usr/bin/env python3
"""
agent_app.py — 미션 실행 대상 (Agent App)

요건:
  - 일반 계정으로 실행 (root 금지)
  - Boot Sequence 5단계, 모두 [OK] 출력 후 "Agent READY"
  - 0.0.0.0:15034 LISTEN
  - Ctrl+C 로 종료
환경 변수:
  AGENT_HOME, AGENT_PORT, AGENT_UPLOAD_DIR, AGENT_KEY_PATH, AGENT_LOG_DIR
"""

import os
import sys
import socket
import signal
from pathlib import Path

REQUIRED_ENVS = [
    "AGENT_HOME",
    "AGENT_PORT",
    "AGENT_UPLOAD_DIR",
    "AGENT_KEY_PATH",
    "AGENT_LOG_DIR",
]
EXPECTED_KEY_STRING = "agent_api_key_test"
LINE = "-" * 60


def step(idx: int, title: str, ok: bool, detail: str = "") -> None:
    status = "[OK]" if ok else "[FAIL]"
    print(f"[{idx}/5] {title:<35} {status}")
    if detail:
        print(f"... {detail}")
    if not ok:
        print(LINE)
        print("Boot sequence failed. Exiting.")
        sys.exit(1)


def check_user_account() -> tuple[bool, str]:
    uid = os.getuid()
    if uid == 0:
        return False, "Running as root is not allowed."
    try:
        import pwd
        name = pwd.getpwuid(uid).pw_name
    except Exception:
        name = "unknown"
    return True, f"Running as service user '{name}' (uid={uid})"


def check_envs() -> tuple[bool, str]:
    missing = [k for k in REQUIRED_ENVS if not os.environ.get(k)]
    if missing:
        return False, f"Missing env(s): {', '.join(missing)}"
    return True, "All required Envs correct"


def check_required_files() -> tuple[bool, str]:
    key_path = os.environ.get("AGENT_KEY_PATH", "")
    p = Path(key_path)
    if not p.is_file():
        return False, f"Key file not found: {key_path}"
    try:
        content = p.read_text(encoding="utf-8").strip()
    except PermissionError:
        return False, f"Cannot read key file: {key_path}"
    if content != EXPECTED_KEY_STRING:
        return False, "Key string mismatch."
    return True, "Verified key file with correct key string."


def check_port_available(port: int) -> tuple[bool, str]:
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        s.bind(("0.0.0.0", port))
    except OSError as e:
        s.close()
        return False, f"Port {port} not available: {e}"
    s.close()
    return True, f"Port {port} is available."


def check_log_permission() -> tuple[bool, str]:
    log_dir = os.environ.get("AGENT_LOG_DIR", "/var/log/agent-app")
    p = Path(log_dir)
    if not p.is_dir():
        return False, f"Log directory missing: {log_dir}"
    if not os.access(log_dir, os.W_OK):
        return False, f"Log directory not writable: {log_dir}"
    return True, f"Log directory is writable: {log_dir}"


def boot_sequence() -> int:
    print("> Starting Agent Boot Sequence...")

    ok, detail = check_user_account()
    step(1, "Checking User Account", ok, detail)

    ok, detail = check_envs()
    step(2, "Verifying Environment Variables", ok, detail)

    ok, detail = check_required_files()
    step(3, "Checking Required Files", ok, detail)

    port = int(os.environ.get("AGENT_PORT", "15034"))
    ok, detail = check_port_available(port)
    step(4, "Checking Port Availability", ok, detail)

    ok, detail = check_log_permission()
    step(5, "Verifying Log Permission", ok, detail)

    print(LINE)
    print("All Boot Checks Passed!")
    print("Agent READY")
    return port


def serve(port: int) -> None:
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(16)
    print(f"[INFO] Listening on 0.0.0.0:{port} (Ctrl+C to stop)")

    def _shutdown(signum, frame):
        print("\n[INFO] Caught signal, shutting down.")
        try:
            srv.close()
        finally:
            sys.exit(0)

    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    while True:
        try:
            conn, addr = srv.accept()
        except OSError:
            break
        try:
            conn.sendall(b"Agent OK\n")
        finally:
            conn.close()


def main() -> None:
    port = boot_sequence()
    serve(port)


if __name__ == "__main__":
    main()
