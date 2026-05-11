# Codyssey B1-1 — 리눅스 서버 보안 & 시스템 관제 자동화

> 다중 사용자 환경의 권한 관리와 네트워크 보안 설정부터 시스템 리소스 관제와 로그 관리 자동화까지, 실제 서버 운영 흐름을 직접 구축한다.
> 실행 환경: **macOS + OrbStack Ubuntu 22.04 머신**

---

## 1. 미션 개요

서버 장애가 났을 때 로그가 없으면 원인 분석은 '감'에 의존하게 된다. 단순히 리눅스 명령어를 암기하는 게 아니라, **권한 관리 → 네트워크 보안 → 리소스 관제 → 로그 자동화** 까지 서버 운영자 시점에서 직접 설계해 본다.

학습 목표 (수료 후 스스로 설명할 수 있어야 한다):

- SSH 포트 변경과 root 원격 접속 차단이 왜 기본 보안에 해당하는가
- "필요 포트만 허용"하는 방화벽 정책을 구성·검증하는 방법
- 역할 기반 계정/그룹과 ACL로 공유/보안 디렉토리를 분리하는 이유
- 환경 변수로 실행 환경을 고정하는 이유와 검증 방법
- 쉘 스크립트로 프로세스/포트/리소스 상태를 수집·로깅해 운영 문제를 추적하는 흐름
- crontab 주기 실행과 로그 보존 정책(압축/삭제)이 왜 필요한가

---

## 2. 최종 산출물

| # | 산출물 | 비고 |
| - | ------ | ---- |
| 1 | [요구사항_수행_내역서.md](요구사항_수행_내역서.md) | 설정/명령어/검증 출력을 모은 제출 문서 |
| 2 | [monitor.sh](monitor.sh) | 시스템 상태 수집 + 로깅 (필수) |
| 3 | [report.sh](report.sh) | 로그 분석 리포트 (보너스 1) |
| 4 | [archive_logs.sh](archive_logs.sh) | 시간 기반 로그 보존 정책 (보너스 2) |
| 5 | [setup_commands.sh](setup_commands.sh) | 환경 구축 명령어 모음 (OrbStack 절차 포함) |
| 6 | [agent_app.py](agent_app.py) | 미션 §4 스펙대로 만든 실행 대상 앱 (운영 측 제공이 원칙) |
| 7 | [스크립트_설명.md](스크립트_설명.md) | bash 입문자용 스크립트 해설 |

---

## 3. 기능 요구 사항

### 3.1 SSH

- 포트를 **20022** 로 변경
- **root 원격 로그인 차단** (`PermitRootLogin no`)
- 검증: `grep -E '^(Port|PermitRootLogin)' /etc/ssh/sshd_config` / `ss -tulnp`

### 3.2 방화벽 (UFW 또는 firewalld 택1)

- 활성화 후 **인바운드는 `20022/tcp`(SSH), `15034/tcp`(APP) 만 허용**
- 검증: `ufw status` 또는 `firewall-cmd --list-all`

### 3.3 계정 / 그룹

| 계정 | 역할 | 소속 그룹 |
| ---- | ---- | --------- |
| `agent-admin` | 운영/관리, cron 실행자 | `agent-common`, `agent-core` |
| `agent-dev`   | 개발/운영, monitor.sh 작성자 | `agent-common`, `agent-core` |
| `agent-test`  | QA/테스트 | `agent-common` |

| 그룹 | 멤버 |
| ---- | ---- |
| `agent-common` | admin, dev, test |
| `agent-core`   | admin, dev |

### 3.4 디렉토리 구조 & ACL

```
$AGENT_HOME                          (= /home/agent-admin/agent-app)
├── upload_files/   ← group=agent-common, R/W
├── api_keys/       ← group=agent-core ONLY, R/W
└── bin/            ← monitor.sh 등 자동화 스크립트
/var/log/agent-app/ ← group=agent-core ONLY, R/W
```

- ACL `-d`(default) 옵션으로 신규 파일도 동일 권한 자동 상속

### 3.5 애플리케이션 실행 환경

환경 변수:

| 변수 | 값 |
| ---- | -- |
| `AGENT_HOME` | `/home/agent-admin/agent-app` |
| `AGENT_PORT` | `15034` |
| `AGENT_UPLOAD_DIR` | `$AGENT_HOME/upload_files` |
| `AGENT_KEY_PATH` | `$AGENT_HOME/api_keys/t_secret.key` |
| `AGENT_LOG_DIR` | `/var/log/agent-app` |

키 파일: `$AGENT_HOME/api_keys/t_secret.key` 내용 = `agent_api_key_test` (1줄)

성공 기준:

- 일반 계정으로 실행 (루트 금지)
- Boot Sequence **5단계 모두 `[OK]`** + `Agent READY` 출력
- `0.0.0.0:15034` LISTEN
- 종료는 `Ctrl+C`

### 3.6 monitor.sh

| 항목 | 정책 |
| ---- | ---- |
| 위치 | `$AGENT_HOME/bin/monitor.sh` |
| 소유 | `agent-dev:agent-core` |
| 권한 | `750` (`rwxr-x---`) |
| 실행 계정 | `agent-admin` (cron) |

동작:

1. **Health Check (실패 시 `exit 1`)**
   - 프로세스 `agent_app.py` 실행 여부
   - TCP `15034` LISTEN 여부
2. **상태 점검 (경고만)**
   - 방화벽 활성 상태 → 비활성 시 `[WARNING]`
3. **자원 수집**
   - CPU 사용률(%) / MEM 사용률(%) / 디스크 사용률(/, Used %)
4. **임계값 경고 (경고만)**
   - CPU `> 20%`, MEM `> 10%`, DISK `> 80%` → `[WARNING]`
5. **로그 기록**
   - 파일: `/var/log/agent-app/monitor.log`
   - 포맷: `[YYYY-MM-DD HH:MM:SS] PID:... CPU:..% MEM:..% DISK_USED:..%`
6. **로그 용량 관리**
   - 최대 **10MB / 10개 파일** 유지 (logrotate 또는 스크립트 자체 로직)

### 3.7 cron

- `agent-admin` 계정 crontab 에 `monitor.sh` **매분 실행** 등록
- 1~2분 내 `monitor.log` 신규 라인 누적 확인

---

## 4. 보너스 과제

### 보너스 1 — `report.sh`

`monitor.log` 분석:

- CPU/MEM/DISK 의 **평균/최대/최소 + 샘플 수** 콘솔 출력
- (선택) 시작/종료 시간 인자로 받아 구간 분석

### 보너스 2 — 시간 기반 로그 보존 정책 (`archive_logs.sh`)

- **7일 경과** `/var/log/agent-app/*.log` → `gzip` 압축
- 아카이브 이동: `/var/log/monitor/agent-app/archive/`
- **30일 경과** `*.gz` 삭제
- 디렉토리 미존재 / 권한 부족 / 대상 0개 → 안전 종료(WARNING)

---

## 5. 제약 사항

- 자동화 스크립트는 **Bash 로만** (Python 등으로 대체 금지)
- 필요한 경우에만 `sudo` 사용 (일반 계정 작업 권장)
- 제공된 Python 앱은 **실행 대상**일 뿐, 과제 핵심은 관제/자동화 스크립트 구현

---

## 6. 빠른 실행 가이드 (OrbStack)

```bash
# macOS 호스트
brew install orbstack
orb create ubuntu codyssey
orb push -m codyssey ./*.sh ./*.py /tmp/
orb shell -m codyssey

# 머신 내부 (Windows 작성 파일이면 CRLF 정리)
sudo apt-get install -y dos2unix
dos2unix /tmp/*.sh && chmod +x /tmp/*.sh

# 이후 setup_commands.sh 의 [1]~[7] 섹션을 순서대로 실행
bash /tmp/setup_commands.sh   # 또는 섹션별로 발췌 실행
```

검증 체크리스트는 [요구사항_수행_내역서.md](요구사항_수행_내역서.md) 마지막 절 참고.

---

## 7. 필수 증거 자료 체크리스트

- [ ] SSH `Port 20022` / `PermitRootLogin no` 적용 + `ss -tulnp` LISTEN 확인
- [ ] `ufw status` (또는 `firewall-cmd --list-all`) — `20022/tcp`, `15034/tcp` 만 ALLOW
- [ ] `id agent-admin / agent-dev / agent-test` 출력
- [ ] `ls -ld` + `getfacl` 로 디렉토리 권한 & ACL 확인
- [ ] 앱 Boot Sequence 5/5 `[OK]` + `Agent READY` 출력
- [ ] `0.0.0.0:15034` LISTEN 확인 (`ss -tlnp`)
- [ ] `monitor.sh` 수동 실행 결과 (HEALTH / RESOURCE / WARNING)
- [ ] `/var/log/agent-app/monitor.log` 최근 라인
- [ ] `crontab -l` 등록 + 1분 후 로그 라인 증가 확인

---

## 8. 개발 환경

- Ubuntu 22.04 LTS (OrbStack 머신 권장)
- bash, ss/netstat, ufw 또는 firewalld, acl(`setfacl`/`getfacl`), cron, python3
