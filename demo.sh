#!/usr/bin/env bash
# demo.sh — macOS + OrbStack 에서 미션 전체를 시연용으로 한 번에 돌린다.
#
# 사용법:
#   ./demo.sh              # 깨끗한 머신을 새로 만들어 처음부터 시연 (권장)
#   ./demo.sh --keep       # 기존 머신 재사용
#   ./demo.sh --shell      # 시연 끝나고 머신 안 셸로 자동 진입
#
# 전제:
#   - macOS
#   - OrbStack 이미 설치 + 한 번 이상 실행됨 (`brew install orbstack`)
#   - 이 디렉토리에 monitor.sh / report.sh / archive_logs.sh / agent-app 존재

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# ── 옵션 파싱 ────────────────────────────────────────────────────────────────
KEEP=0
ENTER_SHELL=0
for arg in "$@"; do
    case "$arg" in
        --keep)  KEEP=1 ;;
        --shell) ENTER_SHELL=1 ;;
        --help|-h)
            sed -n '2,12p' "$0"
            exit 0 ;;
        *) echo "unknown option: $arg" >&2; exit 1 ;;
    esac
done

# ── 색상 ─────────────────────────────────────────────────────────────────────
B="$(printf '\033[1m')"; D="$(printf '\033[2m')"; R="$(printf '\033[0m')"
C="$(printf '\033[1;36m')"; G="$(printf '\033[1;32m')"; Y="$(printf '\033[1;33m')"

banner() {
    printf "\n${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}\n"
    printf "${C}%s${R}\n" "$1"
    printf "${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${R}\n"
}

# ── 전제 점검 ────────────────────────────────────────────────────────────────
banner "Codyssey B1-1 — 자동 시연 (macOS + OrbStack)"

if [[ "$(uname -s)" != "Darwin" ]]; then
    printf "${Y}⚠ 이 스크립트는 macOS 전용이다. 현재 OS: $(uname -s)${R}\n"
    exit 1
fi
command -v orb >/dev/null 2>&1 || {
    printf "${Y}⚠ 'orb' CLI 가 PATH 에 없다. OrbStack 을 설치/실행했는지 확인:${R}\n"
    printf "    brew install orbstack && open -a OrbStack\n"
    exit 1
}
for f in monitor.sh report.sh archive_logs.sh agent-app verify_orbstack.sh; do
    if [[ ! -f "$f" ]]; then
        printf "${Y}⚠ 필요한 파일이 없다: %s${R}\n" "$f"
        exit 1
    fi
done

# Windows/zip 경유로 옮긴 경우 실행 비트(x)가 빠져 있을 수 있다.
# 셸 스크립트와 바이너리에 실행 권한을 보장한다.
chmod +x verify_orbstack.sh monitor.sh report.sh archive_logs.sh agent-app 2>/dev/null || true

printf "${G}✓ macOS + orb CLI + 소스 파일 모두 준비됨${R}\n"

# ── 시연 안내 ────────────────────────────────────────────────────────────────
cat <<EOF

${B}시연 흐름${R}
  ${D}1.${R} ${C}codyssey-demo${R} 라는 Ubuntu 24.04 머신을 띄운다 (없으면 자동 생성)
  ${D}2.${R} §1~§7 단계의 setup + 검증을 차례로 실행한다
     SSH(20022) · UFW · 계정·그룹 · ACL · agent-app 실행 ·
     monitor.sh · cron 매분 동작
  ${D}3.${R} 70초 cron 대기 후 로그 라인 증가 확인 → 최종 ${G}ALL CHECKS PASSED${R}
  ${D}4.${R} 결과 산출물(.verify-artifacts/) 을 Finder 로 자동 오픈
  ${D}5.${R} (옵션) --shell 이면 머신 셸로 들어가서 직접 둘러볼 수 있다

${D}예상 소요 시간: 약 2~3분 (대부분 cron 70초 대기)${R}

EOF

read -p "엔터로 시작 (Ctrl+C 로 취소): " _

# ── 본 실행 ──────────────────────────────────────────────────────────────────
export MACHINE_NAME="codyssey-demo"
if [[ "$KEEP" == "0" ]]; then
    export FRESH=1
fi

banner "▶ verify_orbstack.sh 실행 (MACHINE_NAME=$MACHINE_NAME, FRESH=${FRESH:-0})"
./verify_orbstack.sh

# ── 결과 안내 + Finder 열기 ──────────────────────────────────────────────────
ART_DIR="$(pwd)/.verify-artifacts"
banner "✅ 시연 완료 — 산출물 위치"
printf "  %s\n" "$ART_DIR"
printf "\n${D}파일 목록:${R}\n"
ls -l "$ART_DIR" 2>/dev/null | sed 's/^/    /'

# Finder 자동 오픈
if command -v open >/dev/null 2>&1; then
    open "$ART_DIR" 2>/dev/null || true
fi

# ── 다음 단계 안내 ──────────────────────────────────────────────────────────
cat <<EOF

${B}이제 할 수 있는 것들${R}

  ${C}# 머신 안에 들어가 직접 확인${R}
  orb shell -m $MACHINE_NAME

  ${C}# agent-admin 으로 전환 후 monitor.sh 한 번 더 실행${R}
  orb -m $MACHINE_NAME sudo -iu agent-admin /home/agent-admin/agent-app/bin/monitor.sh

  ${C}# cron 로그 실시간 추적${R}
  orb -m $MACHINE_NAME sudo tail -f /var/log/agent-app/monitor.log

  ${C}# 시연 끝나면 머신 정리${R}
  orb delete -f $MACHINE_NAME

EOF

# ── 옵션: 셸 진입 ────────────────────────────────────────────────────────────
if [[ "$ENTER_SHELL" == "1" ]]; then
    banner "▶ 머신 셸로 진입 (exit 으로 빠져나오기)"
    orb shell -m "$MACHINE_NAME"
fi
