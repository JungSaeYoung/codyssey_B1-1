#!/usr/bin/env bash
# verify_orbstack.sh
# ─────────────────────────────────────────────────────────────────────────────
# OrbStack 의 Linux 머신을 띄워 미션 요구사항(§1~§7)을 자동 setup + 검증한다.
# 검증 결과는 ./.verify-artifacts/ 에 저장되어 채점용 증거로 사용 가능.
#
# 사용법 (macOS 호스트, 이 스크립트의 디렉토리에서):
#   ./verify_orbstack.sh                # 머신 재사용 (없으면 생성)
#   FRESH=1 ./verify_orbstack.sh        # 머신 삭제 후 깨끗하게 재생성
#   ./verify_orbstack.sh --cleanup      # 모든 단계 후 머신 삭제
#
# 사전 요구:
#   - OrbStack 설치 (`brew install orbstack` + 첫 실행)
#   - 이 디렉토리에 src/{monitor,report,archive_logs}.sh 와
#     bin/agent-app 존재
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

MACHINE="${MACHINE_NAME:-codyssey-ci}"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ART="$WORKDIR/.verify-artifacts"
LOG="$ART/run.log"
CLEANUP=0
[[ "${1:-}" == "--cleanup" ]] && CLEANUP=1

mkdir -p "$ART"
: > "$LOG"

# ── 출력 헬퍼 ────────────────────────────────────────────────────────────────
c_reset="$(printf '\033[0m')"
c_cyan="$(printf '\033[1;36m')"
c_green="$(printf '\033[1;32m')"
c_red="$(printf '\033[1;31m')"
c_yellow="$(printf '\033[1;33m')"
c_dim="$(printf '\033[2m')"
B="$(printf '\033[1m')"     # bold (narrate 박스 제목용)
R="$c_reset"                # short alias

section() { printf "\n${c_cyan}▸ %s${c_reset}\n" "$*" | tee -a "$LOG"; }
ok()      { printf "  ${c_green}✓${c_reset} %s\n" "$*" | tee -a "$LOG"; }
warn()    { printf "  ${c_yellow}!${c_reset} %s\n" "$*" | tee -a "$LOG"; }
die()     { printf "  ${c_red}✗${c_reset} %s\n" "$*" | tee -a "$LOG"; exit 1; }

# ── 시연 모드 (NARRATE=1) — 섹션 시작 전 설명 박스 + 엔터 대기 ───────────────
NARRATE="${NARRATE:-0}"
narrate() {
    local title="$1"; shift
    local body="$*"
    local sep_len=70
    local sep
    sep="$(printf '─%.0s' $(seq 1 $sep_len))"
    printf "\n${c_yellow}┌%s${c_reset}\n"  "$sep"
    printf "${c_yellow}│${c_reset}  ${B}%s${c_reset}\n" "$title"
    printf "${c_yellow}│${c_reset}\n"
    printf "%s\n" "$body" | sed "s/^/${c_yellow}│${c_reset}   /"
    printf "${c_yellow}└%s${c_reset}\n" "$sep"
    if [[ "$NARRATE" == "1" ]]; then
        printf "${c_dim}  [엔터를 눌러 명령 실행 — 건너뛰려면 's'+엔터, 종료 'q'+엔터]${c_reset} "
        local key=""
        read -r key || true
        case "$key" in
            s|S) printf "${c_dim}  (이 섹션 건너뜀 — 검증은 그대로 수행됨)${c_reset}\n";;
            q|Q) printf "${c_dim}  (시연 중단)${c_reset}\n"; exit 0 ;;
        esac
    fi
}

# ── OrbStack 업데이트 알림 억제 ────────────────────────────────────────────
# orb CLI 는 호출 시마다 "OrbStack X.Y.Z 업데이트가 있습니다" 같은 안내를 출력해
# 시연 화면을 어지럽힐 수 있다. 알려진 환경변수를 모두 set 해두고, 그래도 새는
# 안내 줄은 sed 필터로 제거한다.
export ORBSTACK_NO_UPDATE_CHECK=1
export ORB_NO_UPDATE_CHECK=1
export ORB_DISABLE_UPDATE_NOTIFY=1
export DO_NOT_TRACK=1

# orb 출력에서 업데이트 안내로 보이는 줄들을 제거하는 필터.
# (대소문자 무시, 'update available' / 'new version' / 'orbstack ... is available' 패턴)
_orb_clean() {
    sed -E '/(update available|new version|orbstack [0-9]+\.[0-9]+\.[0-9]+ is available|run .*to update.*orbstack)/Id'
}

# ── 머신 명령 실행 ────────────────────────────────────────────────────────────
mrun()  { orb -m "$MACHINE" "$@" 2>&1 | _orb_clean | tee -a "$LOG"; }

# NARRATE 모드에서 어떤 명령을 보냈는지 보이도록 미리 출력하는 헬퍼.
# 멀티라인 스크립트도 줄마다 '│' 로 prefix 해서 가독성 ↑.
# 모든 출력은 stderr 로 — msh 의 stdout 을 외부에서 tee/파이프할 때 debug 노이즈가
# artifact 파일에 섞이는 것을 막는다.
_show_cmd() {
    [[ "${NARRATE:-0}" != "1" ]] && return 0
    {
        printf "\n${c_dim}┄ commands ──────────────────────────${c_reset}\n"
        printf "%s\n" "$1" | sed "s/^/  ${c_dim}│${c_reset} /"
        printf "${c_dim}┄ output ────────────────────────────${c_reset}\n"
    } >&2
}

# 머신 안에서 명령 실행. NARRATE 면 명령 자체를 먼저 보여주고, 그 다음 실시간 출력을 흘림.
msh() {
    _show_cmd "$1"
    orb -m "$MACHINE" bash -lc "$1" 2>&1 | _orb_clean | tee -a "$LOG"
}

# 출력 캡처용. NARRATE 면 stderr 로 '무엇을 검사하는지' 만 살짝 보여줌
# (stdout 은 caller 가 $(...) 로 받아야 하므로 절대 오염 X).
msh_q() {
    if [[ "${NARRATE:-0}" == "1" ]]; then
        printf "${c_dim}┄ check\$ %s${c_reset}\n" "$1" >&2
    fi
    orb -m "$MACHINE" bash -lc "$1" | _orb_clean
}

# ── 사전 점검 ────────────────────────────────────────────────────────────────
preflight() {
    section "Preflight"
    command -v orb >/dev/null 2>&1 || die "orb CLI not found. Install OrbStack first."
    for f in src/monitor.sh src/report.sh \
             src/archive_logs.sh bin/agent-app; do
        [[ -f "$WORKDIR/$f" ]] || die "missing $WORKDIR/$f"
    done
    ok "orb CLI present, all source files exist"
}

# ── 머신 준비 ────────────────────────────────────────────────────────────────
ensure_machine() {
    section "Ensure machine '$MACHINE'"
    if [[ "${FRESH:-0}" == "1" ]] && orb list 2>/dev/null | awk '{print $1}' | grep -qx "$MACHINE"; then
        warn "FRESH=1 — deleting existing '$MACHINE'"
        orb delete -f "$MACHINE" 2>&1 | tee -a "$LOG"
    fi
    if ! orb list 2>/dev/null | awk '{print $1}' | grep -qx "$MACHINE"; then
        orb create ubuntu:24.04 "$MACHINE" 2>&1 | tee -a "$LOG"
        ok "created '$MACHINE'"
    else
        ok "reusing existing '$MACHINE'"
    fi

    # systemd 가동 대기
    for i in {1..30}; do
        state="$(msh_q 'systemctl is-system-running 2>/dev/null || true' || true)"
        case "$state" in
            *running*|*degraded*) ok "systemd up ($(echo "$state" | tr -d '[:space:]'))"; return 0 ;;
        esac
        sleep 1
    done
    die "systemd did not come up"
}

install_base() {
    narrate "사전 — 기본 패키지 설치" \
"OrbStack 의 Ubuntu 24.04 머신은 미니멀해 미션에 필요한 도구가 빠져 있다.
  • openssh-server : SSH 서버 데몬(sshd) 과 설정 파일
  • ufw            : 방화벽(netfilter 의 사람 친화 wrapper)
  • acl            : setfacl/getfacl 명령 (POSIX 권한 + 디렉토리 ACL)
  • cron           : 주기 실행 스케줄러
  • dos2unix etc.  : Windows 작성 파일 CRLF → LF 변환 등 보조 도구"
    section "Install base packages"
    msh 'export DEBIAN_FRONTEND=noninteractive
         sudo apt-get update -qq
         sudo apt-get install -y -qq \
            openssh-server ufw acl cron python3 dos2unix procps iproute2'
    ok "base packages installed"
}

# ── §1 SSH ───────────────────────────────────────────────────────────────────
s1_ssh() {
    narrate "§1  SSH — 포트 20022, root 로그인 차단" \
"기본 22번 포트는 인터넷 봇이 끊임없이 brute-force 시도하는 표적이다.
  • 포트를 20022 같은 비표준 번호로 옮기면 자동화된 봇의 99% 노이즈를 회피.
  • PermitRootLogin no — root 직접 로그인 차단. '일반 계정 → sudo' 의 2단계
    인증을 강제해 '누가 무엇을 했는가' 가 로그로 추적 가능해진다.
  • 'security through obscurity is not security' — 첫 방어선일 뿐, fail2ban·
    키 기반 인증 등과 함께 써야 실효성을 가진다는 점은 별도 학습."
    section "§1  SSH — port 20022 + PermitRootLogin no"
    msh "sudo cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d) 2>/dev/null || true
         sudo sed -i -E \
             -e 's/^#?Port .*/Port 20022/' \
             -e 's/^#?PermitRootLogin .*/PermitRootLogin no/' \
             /etc/ssh/sshd_config
         sudo systemctl disable --now ssh.socket 2>/dev/null || true
         sudo systemctl enable --now ssh
         sudo systemctl restart ssh"
}
v1_ssh() {
    msh_q "grep -E '^Port 20022$'         /etc/ssh/sshd_config" >/dev/null \
        || die "sshd_config: Port 20022 missing"
    msh_q "grep -E '^PermitRootLogin no$' /etc/ssh/sshd_config" >/dev/null \
        || die "sshd_config: PermitRootLogin no missing"
    msh_q "sudo ss -tlnH | awk '\$4 ~ /:20022\$/ {f=1} END{exit !f}'" \
        || die "port 20022 not LISTEN"
    ok "Port 20022 set / Root login denied / LISTEN OK"
}

# ── §2 UFW ───────────────────────────────────────────────────────────────────
s2_ufw() {
    narrate "§2  UFW — 화이트리스트 방식 방화벽" \
"리눅스의 진짜 방화벽은 커널 내장 netfilter. ufw 는 그 위의 친화적 인터페이스.
  • 기본 정책: 들어오는 통신 전부 거부 (default deny incoming)
  • 예외만 허용 (allow-list): 20022/tcp (SSH), 15034/tcp (앱)
  • 'iptables -A INPUT -p tcp --dport 20022 -j ACCEPT' 의 ufw 버전이
    'ufw allow 20022/tcp'. 같은 netfilter 룰을 만든다.
  • 결과: 우리가 의도한 두 포트 외 어떤 연결도 막힌다 = 공격 표면 최소화."
    section "§2  UFW — allow 20022/15034 only"
    # systemd unit 까지 명시적으로 enable/start — OrbStack 등 일부 환경에선
    # `ufw enable` 만으로 systemd unit 이 활성화되지 않는 경우가 있어 보강.
    msh "sudo ufw default deny  incoming
         sudo ufw default allow outgoing
         sudo ufw allow 20022/tcp comment 'SSH'
         sudo ufw allow 15034/tcp comment 'AGENT APP'
         sudo ufw --force enable
         sudo systemctl enable --now ufw"
}
v2_ufw() {
    out="$(msh_q 'sudo ufw status verbose')"
    echo "$out" | grep -q 'Status: active'                     || die "ufw not active"
    echo "$out" | grep -qE '20022/tcp\s+ALLOW IN\s+Anywhere'   || die "20022 rule missing"
    echo "$out" | grep -qE '15034/tcp\s+ALLOW IN\s+Anywhere'   || die "15034 rule missing"
    ok "UFW active + only 20022/15034 allowed"
}

# ── §3 계정/그룹 ──────────────────────────────────────────────────────────────
s3_users() {
    narrate "§3  계정·그룹 — 최소 권한 + 직무 분리" \
"한 서버를 root 하나로 쓰면 사고 반경이 무제한. 역할별로 계정을 나눈다.
  계정:
  • agent-admin : 운영자 — 앱 실행 + cron 운영. (단, sudo 권한은 없음)
  • agent-dev   : 개발자 — monitor.sh 등 자동화 스크립트 작성
  • agent-test  : QA     — 업로드/테스트만, 운영 비밀에는 접근 불가
  그룹 (왜 둘? — 자원의 민감도가 다르기 때문):
  • agent-common (admin/dev/test 3명) → 업로드 폴더 공유
  • agent-core   (admin/dev 2명)      → API 키·운영 로그 (test 제외)"
    section "§3  Users & groups"
    msh "sudo groupadd -f agent-common
         sudo groupadd -f agent-core
         for u in agent-admin agent-dev agent-test; do
             id \"\$u\" >/dev/null 2>&1 || sudo useradd -m -s /bin/bash \"\$u\"
         done
         sudo usermod -aG agent-common agent-admin
         sudo usermod -aG agent-common agent-dev
         sudo usermod -aG agent-common agent-test
         sudo usermod -aG agent-core   agent-admin
         sudo usermod -aG agent-core   agent-dev"
}
v3_users() {
    # 'msh_q | grep -q' 패턴은 grep 이 매치 즉시 종료할 때 위쪽이 SIGPIPE 를
    # 받아 pipefail 이 거짓 양성으로 발화한다. 변수에 먼저 캡처해 회피.
    for u in agent-admin agent-dev; do
        info="$(msh_q "id $u")"
        echo "$info" | grep -q 'agent-common' || die "$u not in agent-common"
        echo "$info" | grep -q 'agent-core'   || die "$u not in agent-core"
    done
    test_info="$(msh_q 'id agent-test')"
    echo "$test_info" | grep -q 'agent-common' || die "agent-test not in agent-common"
    if echo "$test_info" | grep -q 'agent-core'; then
        die "agent-test must NOT be in agent-core"
    fi
    ok "group memberships verified"
}

# ── §4 디렉토리 + ACL ────────────────────────────────────────────────────────
s4_acl() {
    narrate "§4  디렉토리 + ACL — 자동 상속되는 정책" \
"§3 의 그룹 구조를 디렉토리 권한으로 물리적으로 실현한다.
  • upload_files/      → 770, agent-common  (셋이 공동 R/W)
  • api_keys/          → 770, agent-core    (admin/dev 만)
  • /var/log/agent-app/→ 770, agent-core    (admin/dev 만)
  ACL 의 핵심은 'default' (-dm):
  • 폴더에 default ACL 을 박으면 그 안에 '새로 생기는 모든 파일' 이 자동으로
    같은 권한을 상속받는다.
  • monitor.sh 가 매분 로그를 새로 쓰는 환경에서 default 가 없으면 시간이
    지날수록 정책이 풀려 다른 사용자가 로그를 읽거나 못 읽게 된다."
    section "§4  Directories + ACL"
    msh 'AH=/home/agent-admin/agent-app; LD=/var/log/agent-app
         sudo -u agent-admin mkdir -p "$AH"/{upload_files,api_keys,bin}
         sudo mkdir -p "$LD"
         sudo chown -R agent-admin:agent-common "$AH"
         sudo chgrp -R agent-core "$AH/api_keys"
         sudo chown root:agent-core "$LD"
         sudo chmod 750 "$AH"
         sudo chmod 770 "$AH/upload_files"
         sudo chmod 770 "$AH/api_keys"
         sudo chmod 770 "$LD"
         sudo chmod 750 "$AH/bin"
         sudo setfacl -m  g:agent-common:rwx "$AH/upload_files"
         sudo setfacl -dm g:agent-common:rwx "$AH/upload_files"
         sudo setfacl -m  g:agent-core:rwx   "$AH/api_keys"
         sudo setfacl -dm g:agent-core:rwx   "$AH/api_keys"
         sudo setfacl -m  g:agent-core:rwx   "$LD"
         sudo setfacl -dm g:agent-core:rwx   "$LD"'
}
v4_acl() {
    # 'msh_q | grep -q' 패턴은 grep 이 매치 즉시 종료할 때 위쪽이 SIGPIPE 를
    # 받아 pipefail 이 거짓 양성으로 발화한다 (getfacl 출력이 12줄로 길어 더 자주 발생).
    # 변수에 먼저 캡처 후 grep 으로 검사.
    ufacl="$(msh_q 'sudo getfacl /home/agent-admin/agent-app/upload_files')"
    echo "$ufacl" | grep -q 'default:group:agent-common:rwx' \
        || die "upload_files default ACL missing"

    kfacl="$(msh_q 'sudo getfacl /home/agent-admin/agent-app/api_keys')"
    echo "$kfacl" | grep -q 'default:group:agent-core:rwx' \
        || die "api_keys default ACL missing"

    lfacl="$(msh_q 'sudo getfacl /var/log/agent-app')"
    echo "$lfacl" | grep -q 'default:group:agent-core:rwx' \
        || die "log dir default ACL missing"

    ok "directories + default ACLs present"
}

# ── §5 환경변수 / 키파일 / 앱 배포 / 실행 / 부트체크 ──────────────────────────
s5_app_setup() {
    narrate "§5-a  앱 실행 환경 — 환경변수·키·바이너리 배포" \
"앱이 동작하려면 '어디에 키가 있나, 어떤 포트 쓰나' 같은 실행 환경 정보가 필요.
  • 환경변수 5개 (AGENT_HOME / PORT / UPLOAD_DIR / KEY_PATH / LOG_DIR) 등록
    - .bashrc 영구 등록 (사람이 들어와 쓸 때를 위함)
    - 실제 실행은 env 명령으로 인라인 주입 (non-interactive 문제 회피)
  • t_secret.key (640, agent-core) — API 키 파일
  • agent-app 바이너리를 \$AGENT_HOME 에 배치 (0750, x 비트 필요)
  ※ 이 바이너리는 Ubuntu 24.04 의 glibc 에 맞춰 빌드 — 22.04 머신은 GLIBC 에러."
    section "§5  Env vars + key file + deploy"
    # 환경변수 영구 등록
    msh "sudo -u agent-admin bash -c 'grep -q AGENT_HOME ~/.bashrc 2>/dev/null || cat >> ~/.bashrc <<EOF

# ----- Agent App ENV -----
export AGENT_HOME=/home/agent-admin/agent-app
export AGENT_PORT=15034
export AGENT_UPLOAD_DIR=\\\$AGENT_HOME/upload_files
export AGENT_KEY_PATH=\\\$AGENT_HOME/api_keys/t_secret.key
export AGENT_LOG_DIR=/var/log/agent-app
EOF'"

    # 키 파일
    msh "echo agent_api_key_test | sudo tee /home/agent-admin/agent-app/api_keys/t_secret.key >/dev/null
         sudo chown agent-admin:agent-core /home/agent-admin/agent-app/api_keys/t_secret.key
         sudo chmod 640 /home/agent-admin/agent-app/api_keys/t_secret.key"

    # CRLF 정리 + 배포 (OrbStack 자동 마운트로 macOS 경로 직접 사용)
    msh "sudo dos2unix '$WORKDIR/src/monitor.sh' '$WORKDIR/src/report.sh' '$WORKDIR/src/archive_logs.sh' 2>/dev/null || true
         sudo install -m 0750 -o agent-admin -g agent-common '$WORKDIR/bin/agent-app'         /home/agent-admin/agent-app/agent-app
         sudo install -m 0750 -o agent-dev   -g agent-core   '$WORKDIR/src/monitor.sh'        /home/agent-admin/agent-app/bin/monitor.sh
         sudo install -m 0750 -o agent-dev   -g agent-core   '$WORKDIR/src/report.sh'         /home/agent-admin/agent-app/bin/report.sh
         sudo install -m 0750 -o agent-dev   -g agent-core   '$WORKDIR/src/archive_logs.sh'   /home/agent-admin/agent-app/bin/archive_logs.sh"
}

s5_app_run() {
    narrate "§5-b  agent-app 실행 → Boot Sequence 5/5 [OK] + 'Agent READY'" \
"백그라운드로 agent-app 을 띄우고 부트 시퀀스 출력이 모두 [OK] 인지 검증한다.
  부트 5단계:
  1) User Account       — root 가 아닌 일반 계정 (UID ≠ 0) 인지
  2) Environment Vars   — AGENT_HOME 등 5개 모두 채워졌는지
  3) Required Files     — t_secret.key 내용이 'agent_api_key_test' 인지
  4) Port Availability  — 15034 가 비어 있는지 (테스트 바인드)
  5) Log Permission     — /var/log/agent-app 에 쓰기 가능한지
  모두 통과 후 'Agent READY' 출력 + 0.0.0.0:15034 LISTEN."
    section "§5  Run agent-app & wait for 'Agent READY'"
    # 이전 인스턴스 정리
    msh "sudo pkill -x agent-app 2>/dev/null || true; sleep 1"

    # 백그라운드 실행 — env 로 환경변수를 명시 주입하고 단일행 명령으로 처리.
    # 멀티라인 + sudo -i + 다중 quote 가 겹치면 줄바꿈이 소실되어 'export
    # ./agent-app' 같은 잘못된 파싱이 일어난다. env 명령을 쓰면 환경변수가 자식
    # 프로세스에만 정확히 주입되며 .bashrc 의 non-interactive return 이슈도 회피.
    msh "sudo -u agent-admin env \
        AGENT_HOME=/home/agent-admin/agent-app \
        AGENT_PORT=15034 \
        AGENT_UPLOAD_DIR=/home/agent-admin/agent-app/upload_files \
        AGENT_KEY_PATH=/home/agent-admin/agent-app/api_keys/t_secret.key \
        AGENT_LOG_DIR=/var/log/agent-app \
        bash -c 'cd \$AGENT_HOME && nohup ./agent-app > /tmp/agent.out 2>&1 &'"

    # 부트 완료 대기 (최대 20s)
    for i in {1..20}; do
        if msh_q 'grep -q "Agent READY" /tmp/agent.out 2>/dev/null'; then
            break
        fi
        sleep 1
    done
    cp_artifact /tmp/agent.out agent.out
}

# 디버깅용: 실패 시 캡처된 agent.out 을 보여주고 die
die_with_agent_out() {
    printf "\n  ${c_dim}── captured /tmp/agent.out ──${c_reset}\n"
    sed 's/^/    /' "$ART/agent.out" 2>/dev/null || true
    printf "  ${c_dim}── end of agent.out ──${c_reset}\n"
    die "$1"
}

v5_app() {
    out="$(msh_q 'cat /tmp/agent.out')"
    for n in 1 2 3 4 5; do
        echo "$out" | grep -q "\[$n/5\].*\[OK\]" || die_with_agent_out "boot step $n/5 not OK"
    done
    echo "$out" | grep -q 'Agent READY' || die_with_agent_out "'Agent READY' not printed"
    msh_q 'sudo ss -tlnH | awk "\$4 ~ /:15034$/ {f=1} END{exit !f}"' \
        || die "port 15034 not LISTEN"
    ok "5/5 boot OK + Agent READY + LISTEN 15034"
}

# ── §6 monitor.sh ────────────────────────────────────────────────────────────
s6_monitor() {
    narrate "§6  monitor.sh 수동 실행 — 상태 수집의 동작 확인" \
"운영 자동화 스크립트 monitor.sh 를 agent-admin 권한으로 1회 실행해 본다.
  • [HEALTH CHECK]      — 프로세스 'agent-app' 살아 있나? 포트 15034 LISTEN?
  • [RESOURCE]          — CPU / MEM / DISK 사용률 수집
  • [WARNING]           — 임계값 초과 시만 출력 (CPU>20%, MEM>10%, DISK>80%)
  • [INFO]              — /var/log/agent-app/monitor.log 에 1줄 누적
  • 자체 로그 로테이션: 10MB × 10개 파일까지 유지
  소유는 agent-dev, 그룹 agent-core, 0750 — admin 이 그룹 권한으로 실행 가능."
    section "§6  monitor.sh — manual run"

    # 한 번만 실행: 사용자에게 결과를 그대로 보여주면서 동시에 artifact 로 캡처.
    # tee 가 stdin 을 monitor.out 에 저장 + 다음 단계(터미널) 로도 흘려보냄.
    msh 'sudo -iu agent-admin bash -lc "/home/agent-admin/agent-app/bin/monitor.sh"' \
        | tee "$ART/monitor.out" || true
}
v6_monitor() {
    grep -q 'Checking process .* \[OK\]'      "$ART/monitor.out" || die "monitor.sh HEALTH process FAIL"
    grep -q 'Checking port 15034\.\.\. \[OK\]' "$ART/monitor.out" || die "monitor.sh HEALTH port FAIL"
    msh_q 'sudo test -s /var/log/agent-app/monitor.log' \
        || die "monitor.log is empty"
    last="$(msh_q 'sudo tail -n1 /var/log/agent-app/monitor.log')"
    echo "$last" | grep -qE '^\[[0-9-]+ [0-9:]+\] PID:[0-9]+ CPU:[0-9.]+% MEM:[0-9.]+% DISK_USED:[0-9]+%$' \
        || die "monitor.log line format mismatch: $last"
    ok "HEALTH=[OK] + valid log line appended"
}

# ── §7 cron ──────────────────────────────────────────────────────────────────
s7_cron_setup() {
    narrate "§7  cron — 매분 자동 실행 등록" \
"운영 상태는 스냅샷이 아니라 시계열이어야 분석 가능. cron 으로 강제한다.
  • crontab 한 줄: '* * * * * monitor.sh ...'
    별표 5개 = 분 / 시 / 일 / 월 / 요일. 다 * 면 '매분(모든 시각)'.
  • cron 은 .bashrc 를 읽지 않으므로 환경변수를 명령줄 앞에 직접 명시
    (AGENT_HOME=... AGENT_PORT=... 형태).
  • 실행 계정은 agent-admin — agent-core 그룹이라 로그 디렉토리 쓰기 가능.
  • 검증: 등록 직후 라인 수 기록 → 70초 대기 → 라인 수 증가 확인."
    section "§7  cron — register every-minute job"
    msh "sudo systemctl enable --now cron
         sudo -u agent-admin bash -c '
             ( crontab -l 2>/dev/null | grep -v monitor.sh ;
               echo \"* * * * * AGENT_HOME=/home/agent-admin/agent-app AGENT_PORT=15034 AGENT_LOG_DIR=/var/log/agent-app /home/agent-admin/agent-app/bin/monitor.sh >> /home/agent-admin/monitor.cron.log 2>&1\"
             ) | crontab -
         '"
    crontab_dump="$(msh_q 'sudo -u agent-admin crontab -l')"
    echo "$crontab_dump" | grep -q monitor.sh \
        || die "crontab not registered"
    ok "crontab registered (waiting 70s for next minute tick)"
}
v7_cron_wait() {
    narrate "§7-b  cron 동작 검증 — 70초 대기 후 로그 증가 확인" \
"방금 cron 에 매분 monitor.sh 를 돌리도록 등록했다. 진짜 동작하는지 확인하려면
다음 cron 틱(매분 0초)을 기다려 보면 된다.
  • 지금의 /var/log/agent-app/monitor.log 라인 수를 기록
  • 70초 대기 (1분 + 여유 10초)
  • 라인 수가 늘었으면 cron 이 monitor.sh 를 자동으로 한 번 더 돌렸다는 증거
  ※ 시연 중 멈춘 듯 보일 수 있어 1초 단위 카운트다운으로 진행 상황을 표시한다."
    section "§7  cron — 70초 대기 후 라인 증가 검증"

    # NOTE: '<' redirect 는 셸이 즉시 처리하므로 default user 권한으로 파일을
    # 연다. /var/log/agent-app 는 770+agent-core 라 default user 가 못 읽어 fail.
    # 'sudo bash -c "wc -l < ..."' 형태로 redirect 자체를 root 셸에서 처리.
    before="$(msh_q "sudo bash -c 'wc -l < /var/log/agent-app/monitor.log'" 2>/dev/null | tr -d '[:space:]' || echo 0)"
    : "${before:=0}"     # 비어 있으면 0 으로
    printf "  ${c_dim}lines before = %s${c_reset}\n" "$before"

    # 1초 단위 카운트다운 (silent sleep 으로 인한 "멈춤" 오해 방지)
    for s in $(seq 70 -1 1); do
        printf "\r  ${c_dim}⏳ cron tick 대기 중...  %2ds 남음   ${c_reset}" "$s"
        sleep 1
    done
    printf "\r  ${c_dim}⏳ 대기 완료, 라인 수 재확인...                   ${c_reset}\n"

    after="$(msh_q "sudo bash -c 'wc -l < /var/log/agent-app/monitor.log'" 2>/dev/null | tr -d '[:space:]' || echo 0)"
    : "${after:=0}"
    printf "  ${c_dim}lines after  = %s${c_reset}\n" "$after"

    [[ "$after" -gt "$before" ]] || die "log lines did not grow (before=$before, after=$after)"
    ok "cron appended new line (${before} → ${after})"

    # 마지막 한 줄 미리보기 (시연용 — '진짜로' 새 라인이 어떻게 생겼는지 보여줌)
    if [[ "${NARRATE:-0}" == "1" ]]; then
        printf "\n  ${c_dim}새로 누적된 마지막 라인:${c_reset}\n"
        msh_q 'sudo tail -n1 /var/log/agent-app/monitor.log' | sed "s/^/    ${c_green}>${c_reset} /"
    fi
}

# ── 증거 수집 ────────────────────────────────────────────────────────────────
cp_artifact() {
    local src="$1" dst="$2"
    msh_q "sudo cat $src" > "$ART/$dst" 2>/dev/null || true
}
collect_evidence() {
    narrate "마무리 — 채점용 증거 자료 수집" \
"여기까지 §1~§7 의 setup + 검증이 모두 통과했다. 마지막으로 채점·제출용 증거를
한 파일(evidence.txt) 로 모아둔다.
  • ss -tulnp            : LISTEN 중인 포트 (20022, 15034)
  • ufw status verbose   : 방화벽 정책
  • id 3계정             : 그룹 멤버십
  • ls -ld + getfacl 3종 : 디렉토리 권한 + ACL
  • crontab -u           : 등록된 cron 항목
  • monitor.log tail -n5 : 최근 누적 로그 라인
모두 .verify-artifacts/ 로 저장되어 시연 종료 후 Finder 로 자동 오픈된다."
    section "Collect evidence into $ART"
    {
        echo '=== ss -tulnp ===';                          msh_q 'sudo ss -tulnp'
        echo; echo '=== ufw status verbose ===';           msh_q 'sudo ufw status verbose'
        echo; echo '=== id (agent-admin/dev/test) ===';    msh_q 'id agent-admin; id agent-dev; id agent-test'
        echo; echo '=== ls -ld (dirs) ===';                msh_q 'sudo ls -ld /home/agent-admin/agent-app /home/agent-admin/agent-app/upload_files /home/agent-admin/agent-app/api_keys /var/log/agent-app'
        echo; echo '=== getfacl upload_files ===';         msh_q 'sudo getfacl /home/agent-admin/agent-app/upload_files'
        echo; echo '=== getfacl api_keys ===';             msh_q 'sudo getfacl /home/agent-admin/agent-app/api_keys'
        echo; echo '=== getfacl /var/log/agent-app ===';   msh_q 'sudo getfacl /var/log/agent-app'
        echo; echo '=== crontab -u agent-admin -l ===';    msh_q 'sudo crontab -u agent-admin -l'
        echo; echo '=== monitor.log tail -n 5 ===';        msh_q 'sudo tail -n 5 /var/log/agent-app/monitor.log'
    } > "$ART/evidence.txt"
    cp_artifact /tmp/agent.out agent.out
    ok "evidence saved to $ART/"
}

# ── 메인 흐름 ────────────────────────────────────────────────────────────────
main() {
    preflight
    ensure_machine
    install_base

    s1_ssh;        v1_ssh
    s2_ufw;        v2_ufw
    s3_users;      v3_users
    s4_acl;        v4_acl
    s5_app_setup
    s5_app_run;    v5_app
    s6_monitor;    v6_monitor
    s7_cron_setup
    v7_cron_wait
    collect_evidence

    # 최종 wrap-up 설명 (NARRATE 모드면 마지막 페이지로 잠시 멈춤)
    narrate "🎉 시연 완료 — 우리가 만든 것" \
"이 한 번의 시연으로 다음을 모두 갖춘 'agent' 운영 환경을 처음부터 구축했다.
  보안:
    1. SSH 포트 비표준화 (20022) + root 직접 로그인 차단
    2. UFW 화이트리스트 — 20022, 15034 외 전부 차단
  권한 모델:
    3. 역할별 계정 3종 (admin/dev/test) + 그룹 2종 (common/core)
    4. 디렉토리 + ACL — '공유 자료' 와 '기밀 자료' 분리, default 로 자동 상속
  앱 운영:
    5. 환경변수 외부 주입 + 키 파일 + 바이너리 배포 + Boot Sequence 5/5
  관제·자동화:
    6. monitor.sh — 프로세스/포트/리소스 수집 + 임계값 경고 + 로그 누적
    7. cron 매분 실행 + 로그 로테이션 (10MB × 10개) 정책 내장
이 모든 단계가 ${c_green}✓${c_yellow} 로 검증되었고, 증거는 .verify-artifacts/ 에 있다."

    printf "\n${c_green}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${c_reset}\n"
    printf "${c_green}  ALL CHECKS PASSED${c_reset}  ─ artifacts in $ART\n"
    printf "${c_green}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${c_reset}\n"

    if [[ "$CLEANUP" == "1" ]]; then
        section "Cleanup — deleting '$MACHINE'"
        orb delete -f "$MACHINE"
        ok "machine deleted"
    else
        printf "${c_dim}  (운영 머신은 보존됨. 다시 검증하려면 그대로 재실행, 완전 재시작은 FRESH=1)${c_reset}\n"
    fi
}

main "$@"
