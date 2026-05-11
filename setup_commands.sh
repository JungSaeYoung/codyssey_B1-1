#!/usr/bin/env bash
# setup_commands.sh — 미션 환경 구축을 위한 명령어 모음
# 대상: macOS + OrbStack 의 Ubuntu 22.04 머신 (orbstack "machine" = full Linux VM, systemd 사용 가능)
#
# ※ 일괄 실행보다 "각 섹션을 이해하며 순서대로" 실행 권장.
# ※ 대부분 sudo 권한 필요.

set -eu

# ============================================================================
# [0] OrbStack 사전 작업 (macOS 호스트에서 1회)
# ============================================================================
# macOS 호스트 터미널에서:
#   brew install orbstack
#   orb create ubuntu codyssey         # "codyssey" 라는 Ubuntu 22.04 머신 생성
#   orb shell -m codyssey              # 또는: ssh codyssey@orb
#
# 머신에 진입한 뒤 이 스크립트를 옮겨와 실행:
#   # macOS 측에서 (이 디렉토리에서)
#   orb push -m codyssey ./monitor.sh ./report.sh ./archive_logs.sh ./setup_commands.sh /tmp/
#
# ※ Windows 환경에서 작성된 파일은 CRLF 줄바꿈일 수 있다. 머신 내부에서:
#   sudo apt-get install -y dos2unix
#   dos2unix /tmp/*.sh
#   chmod +x /tmp/*.sh
#
# 이후 아래 섹션을 머신 내부에서 실행한다.

# ============================================================================
# [1] SSH 포트 변경 (20022) + Root 원격 로그인 차단
# ============================================================================
# OrbStack 머신은 기본적으로 openssh-server 가 설치/구동 중이다.
sudo cp -a /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d)
sudo sed -i -E \
    -e 's/^#?Port .*/Port 20022/' \
    -e 's/^#?PermitRootLogin .*/PermitRootLogin no/' \
    /etc/ssh/sshd_config

# Ubuntu 22.04 는 socket-activated ssh.socket 을 사용할 수 있다.
# Port 변경이 sshd_config 만으로 적용되도록 socket 을 비활성화 후 service 재기동:
sudo systemctl disable --now ssh.socket 2>/dev/null || true
sudo systemctl restart ssh

# 확인
sudo grep -E '^(Port|PermitRootLogin)\b' /etc/ssh/sshd_config
sudo ss -tulnp | grep -E ':(20022)\b'

# OrbStack 자체 SSH 단축(orb shell, ssh ...@orb) 은 별도 경로라 본 미션과 무관.
# macOS 호스트에서 머신에 20022 로 직접 접속해 검증하려면:
#   IP=$(orb info codyssey | awk '/IP/ {print $2; exit}')
#   ssh -p 20022 <linuxUser>@$IP

# ============================================================================
# [2] 방화벽 (UFW) — 20022/tcp, 15034/tcp 만 허용
# ============================================================================
sudo apt-get update && sudo apt-get install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 20022/tcp comment 'SSH'
sudo ufw allow 15034/tcp comment 'AGENT APP'
sudo ufw --force enable
sudo ufw status verbose

# 참고: OrbStack 호스트(macOS)와 머신 사이의 포트 노출은 OrbStack 이 자동 처리한다.
#       머신 내 UFW 는 머신으로 들어오는 트래픽을 제어한다.

# ============================================================================
# [3] 계정/그룹 생성
# ============================================================================
sudo groupadd -f agent-common
sudo groupadd -f agent-core

for u in agent-admin agent-dev agent-test; do
    if ! id "$u" >/dev/null 2>&1; then
        sudo useradd -m -s /bin/bash "$u"
        echo "[+] created user: $u"
    fi
done

sudo usermod -aG agent-common agent-admin
sudo usermod -aG agent-common agent-dev
sudo usermod -aG agent-common agent-test
sudo usermod -aG agent-core   agent-admin
sudo usermod -aG agent-core   agent-dev

id agent-admin
id agent-dev
id agent-test

# ============================================================================
# [4] 디렉토리 구조 + 권한 (ACL 포함)
# ============================================================================
sudo apt-get install -y acl

AGENT_HOME="/home/agent-admin/agent-app"
LOG_DIR="/var/log/agent-app"

sudo -u agent-admin mkdir -p "${AGENT_HOME}/upload_files" \
                             "${AGENT_HOME}/api_keys" \
                             "${AGENT_HOME}/bin"
sudo mkdir -p "${LOG_DIR}"

sudo chown -R agent-admin:agent-common "${AGENT_HOME}"
sudo chgrp -R agent-core "${AGENT_HOME}/api_keys"
sudo chown root:agent-core "${LOG_DIR}"

sudo chmod 750 "${AGENT_HOME}"
sudo chmod 770 "${AGENT_HOME}/upload_files"   # agent-common R/W
sudo chmod 770 "${AGENT_HOME}/api_keys"       # agent-core ONLY
sudo chmod 770 "${LOG_DIR}"                   # agent-core ONLY
sudo chmod 750 "${AGENT_HOME}/bin"

# ACL: upload_files (agent-common R/W) — 신규 파일도 동일 권한 상속
sudo setfacl -m  g:agent-common:rwx "${AGENT_HOME}/upload_files"
sudo setfacl -dm g:agent-common:rwx "${AGENT_HOME}/upload_files"

# ACL: api_keys, /var/log/agent-app → agent-core ONLY
sudo setfacl -m  g:agent-core:rwx "${AGENT_HOME}/api_keys"
sudo setfacl -dm g:agent-core:rwx "${AGENT_HOME}/api_keys"
sudo setfacl -m  g:agent-core:rwx "${LOG_DIR}"
sudo setfacl -dm g:agent-core:rwx "${LOG_DIR}"

ls -ld "${AGENT_HOME}" "${AGENT_HOME}/upload_files" "${AGENT_HOME}/api_keys" "${LOG_DIR}"
getfacl "${AGENT_HOME}/upload_files"
getfacl "${AGENT_HOME}/api_keys"
getfacl "${LOG_DIR}"

# ============================================================================
# [5] 환경 변수 + 키 파일
# ============================================================================
sudo -u agent-admin tee -a /home/agent-admin/.bashrc >/dev/null <<'EOF'

# ----- Agent App ENV -----
export AGENT_HOME="/home/agent-admin/agent-app"
export AGENT_PORT="15034"
export AGENT_UPLOAD_DIR="$AGENT_HOME/upload_files"
export AGENT_KEY_PATH="$AGENT_HOME/api_keys/t_secret.key"
export AGENT_LOG_DIR="/var/log/agent-app"
EOF

# 키 파일
echo "agent_api_key_test" | sudo -u agent-admin tee \
    /home/agent-admin/agent-app/api_keys/t_secret.key >/dev/null
sudo chown agent-admin:agent-core /home/agent-admin/agent-app/api_keys/t_secret.key
sudo chmod 640 /home/agent-admin/agent-app/api_keys/t_secret.key

# 확인
sudo -u agent-admin bash -lc 'env | grep ^AGENT_'

# ============================================================================
# [6] 스크립트 배포 (이 디렉토리에서 실행 가정)
# ============================================================================
# CRLF 정리 (Windows → Linux 이동 후 1회)
sudo apt-get install -y dos2unix
dos2unix ./monitor.sh ./report.sh ./archive_logs.sh 2>/dev/null || true

sudo install -m 0750 -o agent-dev -g agent-core \
    ./monitor.sh "/home/agent-admin/agent-app/bin/monitor.sh"
sudo install -m 0750 -o agent-dev -g agent-core \
    ./report.sh "/home/agent-admin/agent-app/bin/report.sh"
sudo install -m 0750 -o agent-dev -g agent-core \
    ./archive_logs.sh "/home/agent-admin/agent-app/bin/archive_logs.sh"

ls -l /home/agent-admin/agent-app/bin/

# ============================================================================
# [7] cron 설정 (agent-admin)
# ============================================================================
# OrbStack Ubuntu 머신에는 cron 이 기본 포함되어 있다. 미실행 시:
sudo apt-get install -y cron
sudo systemctl enable --now cron

sudo -u agent-admin bash -c '
( crontab -l 2>/dev/null | grep -v "monitor.sh" | grep -v "archive_logs.sh" ;
  echo "* * * * * AGENT_HOME=/home/agent-admin/agent-app AGENT_PORT=15034 AGENT_LOG_DIR=/var/log/agent-app /home/agent-admin/agent-app/bin/monitor.sh >> /home/agent-admin/monitor.cron.log 2>&1"
  echo "10 3 * * * /home/agent-admin/agent-app/bin/archive_logs.sh >> /home/agent-admin/archive.cron.log 2>&1"
) | crontab -
'
sudo -u agent-admin crontab -l

# 1~2분 뒤 확인:
#   sudo tail -f /var/log/agent-app/monitor.log

echo "[DONE] Setup commands completed."
