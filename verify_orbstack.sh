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
#   - 이 디렉토리에 monitor.sh / report.sh / archive_logs.sh / agent-app (바이너리) 존재
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

section() { printf "\n${c_cyan}▸ %s${c_reset}\n" "$*" | tee -a "$LOG"; }
ok()      { printf "  ${c_green}✓${c_reset} %s\n" "$*" | tee -a "$LOG"; }
warn()    { printf "  ${c_yellow}!${c_reset} %s\n" "$*" | tee -a "$LOG"; }
die()     { printf "  ${c_red}✗${c_reset} %s\n" "$*" | tee -a "$LOG"; exit 1; }

# ── 머신 명령 실행 ────────────────────────────────────────────────────────────
mrun()  { orb -m "$MACHINE" "$@" 2>&1 | tee -a "$LOG"; }
msh()   { orb -m "$MACHINE" bash -lc "$1" 2>&1 | tee -a "$LOG"; }
msh_q() { orb -m "$MACHINE" bash -lc "$1"; }      # 출력 캡처 (조용)

# ── 사전 점검 ────────────────────────────────────────────────────────────────
preflight() {
    section "Preflight"
    command -v orb >/dev/null 2>&1 || die "orb CLI not found. Install OrbStack first."
    for f in monitor.sh report.sh archive_logs.sh agent-app; do
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
    section "Install base packages"
    msh 'export DEBIAN_FRONTEND=noninteractive
         sudo apt-get update -qq
         sudo apt-get install -y -qq \
            openssh-server ufw acl cron python3 dos2unix procps iproute2'
    ok "base packages installed"
}

# ── §1 SSH ───────────────────────────────────────────────────────────────────
s1_ssh() {
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
    section "§2  UFW — allow 20022/15034 only"
    msh "sudo ufw default deny  incoming
         sudo ufw default allow outgoing
         sudo ufw allow 20022/tcp comment 'SSH'
         sudo ufw allow 15034/tcp comment 'AGENT APP'
         sudo ufw --force enable"
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
    msh "sudo dos2unix '$WORKDIR/monitor.sh' '$WORKDIR/report.sh' '$WORKDIR/archive_logs.sh' 2>/dev/null || true
         sudo install -m 0750 -o agent-admin -g agent-common '$WORKDIR/agent-app'      /home/agent-admin/agent-app/agent-app
         sudo install -m 0750 -o agent-dev   -g agent-core   '$WORKDIR/monitor.sh'     /home/agent-admin/agent-app/bin/monitor.sh
         sudo install -m 0750 -o agent-dev   -g agent-core   '$WORKDIR/report.sh'      /home/agent-admin/agent-app/bin/report.sh
         sudo install -m 0750 -o agent-dev   -g agent-core   '$WORKDIR/archive_logs.sh' /home/agent-admin/agent-app/bin/archive_logs.sh"
}

s5_app_run() {
    section "§5  Run agent-app & wait for 'Agent READY'"
    # 이전 인스턴스 정리
    msh "sudo pkill -x agent-app 2>/dev/null || true; sleep 1"
    # 백그라운드 실행
    msh "sudo -iu agent-admin bash -c 'cd \$AGENT_HOME && nohup ./agent-app > /tmp/agent.out 2>&1 &'"
    # 부트 완료 대기
    for i in {1..20}; do
        if msh_q 'grep -q "Agent READY" /tmp/agent.out 2>/dev/null'; then
            break
        fi
        sleep 1
    done
    cp_artifact /tmp/agent.out agent.out
}

v5_app() {
    out="$(msh_q 'cat /tmp/agent.out')"
    for n in 1 2 3 4 5; do
        echo "$out" | grep -q "\[$n/5\].*\[OK\]" || die "boot step $n/5 not OK"
    done
    echo "$out" | grep -q 'Agent READY' || die "'Agent READY' not printed"
    msh_q 'sudo ss -tlnH | awk "\$4 ~ /:15034$/ {f=1} END{exit !f}"' \
        || die "port 15034 not LISTEN"
    ok "5/5 boot OK + Agent READY + LISTEN 15034"
}

# ── §6 monitor.sh ────────────────────────────────────────────────────────────
s6_monitor() {
    section "§6  monitor.sh — manual run"
    msh 'sudo -iu agent-admin bash -lc "/home/agent-admin/agent-app/bin/monitor.sh"' | tee /tmp/_mon.out >/dev/null || true
    msh_q 'sudo -iu agent-admin bash -lc "/home/agent-admin/agent-app/bin/monitor.sh"' > "$ART/monitor.out" 2>&1 || true
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
    before="$(msh_q 'sudo wc -l < /var/log/agent-app/monitor.log' | tr -d '[:space:]')"
    echo "  ${c_dim}lines before = $before, sleeping 70s ...${c_reset}"
    sleep 70
    after="$(msh_q 'sudo wc -l < /var/log/agent-app/monitor.log' | tr -d '[:space:]')"
    echo "  ${c_dim}lines after  = $after${c_reset}"
    [[ "$after" -gt "$before" ]] || die "log lines did not grow (before=$before, after=$after)"
    ok "cron appended new line (${before} → ${after})"
}

# ── 증거 수집 ────────────────────────────────────────────────────────────────
cp_artifact() {
    local src="$1" dst="$2"
    msh_q "sudo cat $src" > "$ART/$dst" 2>/dev/null || true
}
collect_evidence() {
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
