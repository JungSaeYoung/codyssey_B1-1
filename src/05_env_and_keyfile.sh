#!/usr/bin/env bash
# 05_env_and_keyfile.sh
# -----------------------------------------------------------------------------
# 단계 5 / 7 — 환경변수 + API 키 파일
#
#   환경변수 5종을 agent-admin 의 ~/.bashrc 에 영구 등록.
#     AGENT_HOME / AGENT_PORT / AGENT_UPLOAD_DIR / AGENT_KEY_PATH / AGENT_LOG_DIR
#
#   API 키 파일 생성: $AGENT_HOME/api_keys/t_secret.key
#     내용: "agent_api_key_test"  (Boot Sequence 3단계에서 검증)
#     권한: 640 (owner=agent-admin rw, group=agent-core r, others=0)
#
# 실행 위치: 머신 안 (단계 4 이후)
# 권한:      sudo 가능한 계정
# -----------------------------------------------------------------------------

set -eu
step() { printf "  ▶ %s\n" "$*"; }

AGENT_BASHRC="/home/agent-admin/.bashrc"
KEY_PATH="/home/agent-admin/agent-app/api_keys/t_secret.key"

if ! sudo grep -q '^export AGENT_HOME=' "${AGENT_BASHRC}" 2>/dev/null; then
    step "$AGENT_BASHRC 에 AGENT_* export 5줄 추가"
    sudo -u agent-admin tee -a "${AGENT_BASHRC}" >/dev/null <<'EOF'

# ----- Agent App ENV -----
export AGENT_HOME="/home/agent-admin/agent-app"
export AGENT_PORT="15034"
export AGENT_UPLOAD_DIR="$AGENT_HOME/upload_files"
export AGENT_KEY_PATH="$AGENT_HOME/api_keys/t_secret.key"
export AGENT_LOG_DIR="/var/log/agent-app"
EOF
else
    step "$AGENT_BASHRC 에 AGENT_* 이미 등록돼 있음 (skip)"
fi

step "키 파일 생성: $KEY_PATH (내용 = 'agent_api_key_test')"
echo "agent_api_key_test" | sudo -u agent-admin tee "${KEY_PATH}" >/dev/null

step "키 파일 소유/권한: agent-admin:agent-core, 640"
sudo chown agent-admin:agent-core "${KEY_PATH}"
sudo chmod 640 "${KEY_PATH}"

# 검증
echo
echo "─── 검증 ────────────────────────────"
echo "--- AGENT_* 환경변수 (agent-admin 의 login shell 에서) ---"
sudo -u agent-admin bash -lc 'env | grep ^AGENT_'
echo
echo "--- 키 파일 ---"
sudo ls -l "${KEY_PATH}"
sudo cat "${KEY_PATH}"
echo "─────────────────────────────────────"
echo "[05] Env vars & key file 완료"
