#!/usr/bin/env bash
# 06_deploy_app_and_scripts.sh
# -----------------------------------------------------------------------------
# 단계 6 / 7 — agent-app 바이너리 + 자동화 스크립트 배포
#
#   배포 대상:
#     bin/agent-app           → /home/agent-admin/agent-app/agent-app    (0750)
#     src/monitor.sh          → $AGENT_HOME/bin/monitor.sh               (0750)
#     src/report.sh           → $AGENT_HOME/bin/report.sh                (0750)
#     src/archive_logs.sh     → $AGENT_HOME/bin/archive_logs.sh          (0750)
#
#   소유/그룹:
#     agent-app  → agent-admin:agent-common (실행자가 admin)
#     *.sh        → agent-dev:agent-core    (작성자=dev, 운영자=admin 그룹 권한으로 실행)
#
# 가정: 머신 안에 원본 파일들이 한 디렉토리에 모여 있다.
#       기본값: SOURCE_DIR=/tmp (orb push 의 기본 도착지)
#       다른 위치면 SOURCE_DIR 환경변수로 지정:
#         SOURCE_DIR=/home/me/codyssey_B1-1/src bash 06_deploy_app_and_scripts.sh
#       (이때 agent-app 도 같은 디렉토리에 있어야 함)
#
# 실행 위치: 머신 안 (단계 4 이후)
# 권한:      sudo 가능한 계정
# -----------------------------------------------------------------------------

set -eu
step() { printf "  ▶ %s\n" "$*"; }

SOURCE_DIR="${SOURCE_DIR:-/tmp}"
AGENT_HOME="/home/agent-admin/agent-app"

step "원본 위치(SOURCE_DIR) = ${SOURCE_DIR}"

step "원본 파일 4종 존재 확인"
for f in monitor.sh report.sh archive_logs.sh agent-app; do
    if [[ ! -f "${SOURCE_DIR}/${f}" ]]; then
        echo "[ERROR] ${SOURCE_DIR}/${f} 가 없습니다. 'orb push' 가 끝났는지 확인하세요." >&2
        exit 1
    fi
    printf "      ✓ %s\n" "${SOURCE_DIR}/${f}"
done

step "CRLF → LF 정리 (Windows 작성 파일 대비)"
sudo apt-get install -y dos2unix
sudo dos2unix "${SOURCE_DIR}"/monitor.sh "${SOURCE_DIR}"/report.sh \
              "${SOURCE_DIR}"/archive_logs.sh 2>&1 | sed 's/^/      /' || true

step "monitor.sh → \$AGENT_HOME/bin/monitor.sh  (agent-dev:agent-core, 0750)"
sudo install -m 0750 -o agent-dev -g agent-core \
    "${SOURCE_DIR}/monitor.sh"      "${AGENT_HOME}/bin/monitor.sh"

step "report.sh → \$AGENT_HOME/bin/report.sh  (agent-dev:agent-core, 0750)"
sudo install -m 0750 -o agent-dev -g agent-core \
    "${SOURCE_DIR}/report.sh"       "${AGENT_HOME}/bin/report.sh"

step "archive_logs.sh → \$AGENT_HOME/bin/archive_logs.sh  (agent-dev:agent-core, 0750)"
sudo install -m 0750 -o agent-dev -g agent-core \
    "${SOURCE_DIR}/archive_logs.sh" "${AGENT_HOME}/bin/archive_logs.sh"

step "agent-app → \$AGENT_HOME/agent-app  (agent-admin:agent-common, 0750)"
# ※ Ubuntu 24.04 전용 빌드. 22.04 머신에서는 GLIBC 에러로 실행 안 됨.
sudo install -m 0750 -o agent-admin -g agent-common \
    "${SOURCE_DIR}/agent-app"       "${AGENT_HOME}/agent-app"

# ─── 시연·테스트 편의: report.sh 를 admin / dev 의 홈에도 복사 ───────────────
# 정식 배포 위치는 $AGENT_HOME/bin/report.sh 이지만, 시연 중 'sudo -iu agent-dev'
# 직후 '~/report.sh' 한 줄로 즉시 통계를 볼 수 있도록 두 홈 디렉토리에도 복제.
# 각 계정이 자기 홈 안 파일의 owner 가 되도록 설치.
step "report.sh → /home/agent-admin/report.sh  (시연용 사본, agent-admin 소유)"
sudo install -m 0750 -o agent-admin -g agent-admin \
    "${SOURCE_DIR}/report.sh" "/home/agent-admin/report.sh"

step "report.sh → /home/agent-dev/report.sh  (시연용 사본, agent-dev 소유)"
sudo install -m 0750 -o agent-dev -g agent-dev \
    "${SOURCE_DIR}/report.sh" "/home/agent-dev/report.sh"

# 검증
echo
echo "─── 검증 ────────────────────────────"
echo "--- 정식 배포 위치 ---"
sudo ls -l "${AGENT_HOME}/bin/" "${AGENT_HOME}/agent-app"
echo
echo "--- 시연용 사본 (admin/dev 홈) ---"
sudo ls -l /home/agent-admin/report.sh /home/agent-dev/report.sh
echo "─────────────────────────────────────"
echo "[06] Deployment 완료"
echo
echo "▶ 시연 시 빠른 호출 예시:"
echo "    sudo -iu agent-admin ~/report.sh"
echo "    sudo -iu agent-dev   ~/report.sh"
