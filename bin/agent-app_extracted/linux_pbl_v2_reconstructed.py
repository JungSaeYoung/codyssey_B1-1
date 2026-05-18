"""
linux_pbl_v2.py — agent-app PyInstaller 번들의 진입 스크립트 재구성본
================================================================
※ 본 파일은 bin/agent-app 의 linux_pbl_v2.pyc 를 두 단계로 분석해 복원한 결과다.

  Step A) tools/extract_pyinstaller.py      → linux_pbl_v2.pyc 추출
  Step B) tools/decompile_metadata.py        → code object 메타데이터 재귀 덤프
         + tools/disasm_pyc.py               → 부분 바이트코드 분해

  uncompyle6 / decompyle3 가 Python 3.12 를 미지원해 정통 디컴파일 대신
  메타데이터 추출을 사용. 그 결과로 다음 정보를 회복했다:

  - 함수 시그니처 / 매개변수 이름   : 100% 정확 (co_varnames + co_argcount)
  - 외부 호출 대상 (모듈/속성)      : 100% 정확 (co_names)
  - 리터럴 (문자열·숫자)            : 100% 정확 (co_consts)
  - 클래스 / 메서드 구조             : 100% 정확 (co_qualname 계층)
  - 제어 흐름 (if/for/try)           : 70~85% 추정 (위 리터럴/이름의 등장 순서로 재구성)
  - 변수 대입 순서                  : 추정 (locals 수와 사용된 이름으로 추론)

  → 즉 "**의미·구조**는 정확, **세부 흐름 제어**는 합리적 추정" 인 hybrid 결과.
  실행 가능한 코드를 만드는 것이 목적이 아니라, agent-app 이 무엇을 하는지
  사람이 한 화면에서 읽을 수 있도록 정리한 것.

분석 도구: tools/extract_pyinstaller.py, tools/decompile_metadata.py
원본:     bin/agent-app_extracted/linux_pbl_v2.pyc (19,286 bytes)
"""

import os
import sys
import pwd
import time
import math
import socket
import logging
from logging.handlers import RotatingFileHandler


# =============================================================================
# BootValidator — 부트 시퀀스 5단계 검증
# =============================================================================
class BootValidator:
    """Boot 시퀀스 단계별 검증기. 각 check_* 메서드가 한 단계씩 수행."""

    def __init__(self):
        self.all_passed = True
        self.config = {}                  # 검증 중 모은 설정값
        self.step_current = 0
        self.steps_name = (
            "Checking User Account",
            "Verifying Environment Variables",
            "Checking Required Files",
            "Checking Port Availability",
            "Verifying Log Permission",
        )
        self.step_total = len(self.steps_name)

        # 현재 사용자 정보 수집
        self.current_uid = os.getuid()
        try:
            self.current_user = pwd.getpwuid(self.current_uid).pw_name
        except KeyError:
            self.current_user = str(self.current_uid)

    def print_progress(self, step_name, status, detail):
        """ [1/5] Checking User Account              [OK]  형식의 진행 출력. """
        mark = "[OK]" if status else "[FAIL]"
        # 원본은 step_name 을 35자리로 좌정렬해 출력
        print(f"[{self.step_current}/{self.step_total}] {step_name:<35} {mark}")
        if detail:
            print(f" >>> {detail}")
        # ... 출력 형식은 약간의 추정 포함

    # ── [1/5] 사용자 계정 ────────────────────────────────────────────────
    def check_root_user(self):
        self.step_current = 1
        step = self.steps_name[0]
        fail_reasons = []

        if self.current_uid == 0:
            fail_reasons.append(
                "Error: Running as 'root' is forbidden. Use a service account."
            )

        success_msg = f"Running as service user '{self.current_user}' (uid={self.current_uid})"
        self.decision_step(step, fail_reasons, success_msg)

    # ── [2/5] 환경 변수 ─────────────────────────────────────────────────
    def check_env_config(self):
        self.step_current = 2
        step = self.steps_name[1]
        fail_reasons = []

        agent_home = os.getenv("AGENT_HOME")
        if not agent_home:
            fail_reasons.append("Critical Env 'AGENT_HOME' is missing.")
        else:
            # 기대값 — AGENT_HOME 하위에 upload_files, api_keys/t_secret.key
            expected_upload = os.path.normpath(os.path.join(agent_home, "upload_files"))
            expected_key    = os.path.normpath(os.path.join(agent_home, "api_keys", "t_secret.key"))

            # PORT
            port_env = os.getenv("AGENT_PORT")
            if port_env:
                try:
                    port = int(port_env)
                    if port != 15034:
                        fail_reasons.append(f"Port mismatch (Expected 15034, Got {port})")
                    self.config["PORT"] = port
                except ValueError:
                    fail_reasons.append(f"Invalid AGENT_PORT value: '{port_env}'")
            else:
                fail_reasons.append("AGENT_PORT is missing")

            # UPLOAD_DIR
            upload_env = os.getenv("AGENT_UPLOAD_DIR")
            if upload_env:
                if os.path.normpath(upload_env) != expected_upload:
                    fail_reasons.append(f"Upload dir mismatch (Expected {expected_upload})")
                self.config["UPLOAD_DIR"] = upload_env
            else:
                fail_reasons.append("AGENT_UPLOAD_DIR is missing")

            # KEY_PATH
            key_env = os.getenv("AGENT_KEY_PATH")
            if key_env:
                if os.path.normpath(key_env) != expected_key:
                    fail_reasons.append(f"Key path mismatch (Expected {expected_key})")
                self.config["KEY_PATH"] = key_env
            else:
                fail_reasons.append("AGENT_KEY_PATH is missing")

        success_msg = "All required Envs correct"
        self.decision_step(step, fail_reasons, success_msg)

    # ── [3/5] 필수 파일 (키 파일 내용 검증) ────────────────────────────
    def check_required_files(self):
        self.step_current = 3
        step = self.steps_name[2]
        fail_reasons = []

        key_path = self.config.get("KEY_PATH")
        if not key_path:
            fail_reasons.append("KEY_PATH not configured")
        elif not os.path.isfile(key_path):
            fail_reasons.append(f"Key file not found: {key_path}")
        else:
            try:
                with open(key_path, "r") as f:
                    content = f.read().strip()
                if content != "agent_api_key_test":
                    fail_reasons.append("Key file content mismatch")
            except Exception as e:
                fail_reasons.append(f"Cannot read key file: {e}")

        success_msg = "Verified 'secret.key' with correct key string."
        self.decision_step(step, fail_reasons, success_msg)

    # ── [4/5] 포트 사용 가능 여부 ───────────────────────────────────────
    def check_port_availability(self):
        self.step_current = 4
        step = self.steps_name[3]
        fail_reasons = []
        port = self.config.get("PORT", 15034)

        s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        s.settimeout(1)
        try:
            # connect_ex == 0 이면 누군가 이미 LISTEN 중 → 포트 점유
            if s.connect_ex(("127.0.0.1", port)) == 0:
                fail_reasons.append(f"Port {port} is already in use")
        except Exception as e:
            fail_reasons.append(f"Port check failed: {e}")
        finally:
            s.close()

        success_msg = f"Port {port} is available."
        self.decision_step(step, fail_reasons, success_msg)

    # ── [5/5] 로그 디렉토리 쓰기 권한 ───────────────────────────────────
    def check_log_permission(self):
        self.step_current = 5
        step = self.steps_name[4]
        fail_reasons = []
        log_dir = os.getenv("AGENT_LOG_DIR", "/var/log/agent-app")

        if not os.path.exists(log_dir):
            fail_reasons.append(f"Log directory not found: {log_dir}")
        elif not os.path.isdir(log_dir):
            fail_reasons.append(f"Path is not a directory: {log_dir}")
        elif not os.access(log_dir, os.W_OK):
            fail_reasons.append(
                f"Permission Denied: User '{self.current_user}' cannot write to {log_dir}"
            )

        success_msg = f"Log directory is writable: {log_dir}"
        self.decision_step(step, fail_reasons, success_msg)

    # ── 공통 — 한 단계 종료 처리 ────────────────────────────────────────
    def decision_step(self, step_name, fail_reasons, success_msg):
        if fail_reasons:
            self.print_progress(step_name, False, "")
            for r in fail_reasons:
                print(f"\n >>> {r}")
            # 이전 단계 실패 표시 + 이후 단계 건너뛰기 안내
            for i in range(self.step_current, self.step_total):
                self.print_progress(self.steps_name[i], False,
                                    "Skipped due to previous critical failure.")
            print("-" * 50)
            print("System Boot Failed. Process Terminated.")
            self.all_passed = False
            sys.exit(1)
        else:
            self.print_progress(step_name, True, success_msg)


# =============================================================================
# ResourceStressor — Agent 메인 루프 (CPU/메모리 스트레스 발생기)
# =============================================================================
class ResourceStressor:
    """
    Boot 완료 후 동작하는 본체. 메모리·CPU 사용량을 사이클로 올렸다 내렸다
    하며 monitor.sh 가 수집할 데이터를 적극적으로 만들어준다.
    """

    def __init__(self, logger, port=15034):
        self.logger = logger
        self.port = port
        self.server_socket = None
        self.memory_store = []          # 'x' * 1MB chunk 들이 쌓이는 자리
        self.level = 0                  # 현재 CPU level
        self.running = True
        self.increasing = True
        self.LIMIT_MEMORY_MB = 256      # 메모리 상한 (MB)
        self.CHUNK_SIZE_MB = 25         # 한 번에 늘리는 단위
        self.LIMIT_CPU_SEC = 5          # 한 level 의 CPU 점유 시간
        self.LIMIT_CPU_LEVEL = 10       # CPU level 상한

        # 시스템 우선순위 낮추기 — 다른 프로세스에 영향 최소화
        if hasattr(os, "nice"):
            try:
                os.nice(10)
                self.logger.info("[SafetyGuard] Process priority lowered (nice=10).")
            except Exception:
                pass

    def open_socket(self):
        """0.0.0.0:port 에 listen — Boot Sequence 의 'LISTEN' 상태 만들기."""
        self.server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server_socket.bind(("0.0.0.0", self.port))
        self.server_socket.listen(1)
        self.logger.info(f"Agent listening at port {self.port}")

    def increase_memory(self):
        """CHUNK_SIZE_MB 만큼 메모리 추가 할당. LIMIT 도달 시 ramp-down 전환."""
        chunk = "x" * (1048576)  # 1MB 문자열
        try:
            for _ in range(self.CHUNK_SIZE_MB):
                self.memory_store.append(chunk)
            current = len(self.memory_store)
            self.logger.info(
                f"[Memory] Increasing... (+{self.CHUNK_SIZE_MB} MB) Total: {current} MB"
            )
            if current >= self.LIMIT_MEMORY_MB:
                self.increasing = False
        except MemoryError:
            self.logger.critical("[Memory] OOM Detected during ramp-up!")
            self.increasing = False

    def decrease_memory(self):
        """ramp-down — pop 으로 메모리 해제."""
        for _ in range(self.CHUNK_SIZE_MB):
            if self.memory_store:
                self.memory_store.pop()
        current = len(self.memory_store)
        self.logger.info(f"[Memory] Decreasing... (-{self.CHUNK_SIZE_MB} MB) Total: {current} MB")

    def occupy_cpu(self, level):
        """level 만큼 강도로 sin/cos 계산을 LIMIT_CPU_SEC 동안 돌림."""
        start = time.time()
        while time.time() - start < self.LIMIT_CPU_SEC:
            for _ in range(100000 * level):
                math.sin(0.0)
                math.cos(0.0)
        duration = time.time() - start
        self.logger.info(f"[CPU] Level {level} workload completed. Duration: {duration:.2f}s")

    def rotate_cycle(self):
        """본 메인 루프 — 메모리/CPU 를 사이클로 올렸다 내렸다."""
        self.open_socket()
        self.logger.info("=== Agent Started. Beginning resource cycle. ===")
        while self.running:
            try:
                mode = "UP" if self.increasing else "DOWN"
                current_mem = len(self.memory_store)
                self.logger.info(
                    f"--- Step Info: Mode={mode}, CPU Lv={self.level}, "
                    f"Mem={current_mem}MB ---"
                )

                if self.increasing:
                    self.increase_memory()
                    if self.level < self.LIMIT_CPU_LEVEL:
                        self.level += 1
                    else:
                        self.logger.info(">>> PEAK REACHED. Switching to RAMP DOWN. <<<")
                        self.increasing = False
                else:
                    self.decrease_memory()
                    if self.level > 0:
                        self.level -= 1
                    else:
                        self.logger.info(">>> BOTTOM REACHED (Idle). Switching to RAMP UP. <<<")
                        self.increasing = True

                if self.level > 0:
                    self.occupy_cpu(self.level)

                time.sleep(1)

            except KeyboardInterrupt:
                self.logger.warning("Stop signal received. Terminating now...")
                self.running = False
            except Exception as e:
                self.logger.error(f"Unexpected error: {e}")

        self.logger.info("=== Agent Shutdown. Releasing resources. ===")


# =============================================================================
# 로깅 설정
# =============================================================================
def set_logger(log_dir):
    """RotatingFileHandler 로 agent_app.log 누적 (1MB × 3 보관)."""
    logger = logging.getLogger("AgentLogger")
    logger.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")

    try:
        log_file = os.path.join(log_dir, "agent_app.log")
        fh = RotatingFileHandler(log_file, maxBytes=1048576, backupCount=3, encoding="utf-8")
        fh.setFormatter(fmt)
        logger.addHandler(fh)
    except Exception as e:
        print(f"!!! [CRITICAL] Failed to create log file at {log_dir}: {e}")
        print("!!! Proceeding with Console Logging only.")

    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(fmt)
    logger.addHandler(sh)
    return logger


# =============================================================================
# 메인
# =============================================================================
if __name__ == "__main__":
    print(">>> Starting Agent Boot Sequence...")

    validator = BootValidator()
    validator.check_root_user()
    validator.check_env_config()
    validator.check_required_files()
    validator.check_port_availability()
    validator.check_log_permission()

    if not validator.all_passed:
        print("Agent Boot Check Failed. Process Terminated.")
        sys.exit(1)

    print("-" * 60)
    print("All Boot Checks Passed!")
    print("Agent READY")

    log_dir = validator.config.get("AGENT_LOG_DIR") or os.getenv("AGENT_LOG_DIR", "/var/log/agent-app")
    app_logger = set_logger(log_dir)

    stressor = ResourceStressor(app_logger, validator.config.get("PORT", 15034))
    try:
        stressor.rotate_cycle()
    except KeyboardInterrupt:
        app_logger.info("User interrupted process. Shutting down gracefully...")
