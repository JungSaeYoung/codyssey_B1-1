# Codyssey B1-1 — 리눅스 서버 보안 & 시스템 관제 자동화

> 다중 사용자 환경의 권한 관리와 네트워크 보안 설정부터 시스템 리소스 관제와 로그 관리 자동화까지, 실제 서버 운영 흐름을 직접 구축한다.
> 실행 환경: **macOS + OrbStack Ubuntu 24.04 머신**

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

## 2. 디렉토리 구조

```
codyssey_B1-1/
├── README.md                       ← 이 파일 (루트 유지)
│
├── docs/
│   ├── md/                                ← 원본 .md 문서들
│   │   ├── 요구사항_수행_내역서.md       ← 제출용 문서 (필수)
│   │   ├── 문제_설명.md                  ← 평가문항 답변 정리
│   │   ├── 스크립트_설명.md              ← bash 입문자용 해설
│   │   └── agent-app_리버스엔지니어링.md ← 바이너리 정적 분석 학습용 (선택)
│   └── html/
│       └── index.html                    ← tools/build_docs.py 가 생성한 정적 사이트
│
├── bin/
│   └── agent-app                   ← 운영 측 제공 Linux 바이너리 (Ubuntu 24.04 전용)
├── src/
│   ├── monitor.sh                  ← 시스템 상태 수집·로깅 (필수 산출물)
│   ├── report.sh                   ← 로그 분석 리포트 (보너스 1)
│   ├── archive_logs.sh             ← 시간 기반 로그 보존 (보너스 2)
│   │
│   ├── 00_run_all.sh               ← 01~07 setup 단계를 한 번에 실행 (wrapper)
│   ├── 01_ssh_hardening.sh         ← SSH 포트 20022 + Root 차단
│   ├── 02_firewall_allowlist.sh    ← UFW 화이트리스트 (20022/15034)
│   ├── 03_users_and_groups.sh      ← 계정 3종 + 그룹 2종
│   ├── 04_directories_and_acl.sh   ← 디렉토리 + ACL (default 상속 포함)
│   ├── 05_env_and_keyfile.sh       ← 환경변수 5종 + API 키 파일
│   ├── 06_deploy_app_and_scripts.sh ← agent-app + *.sh 배포
│   └── 07_cron_schedule.sh         ← cron 매분/매일 등록
│
├── demo.sh                         ← 시연 자동화 (시연 모드)
├── verify_orbstack.sh              ← OrbStack 기반 자동 검증
│
├── tools/                          ← 분석 / 문서 빌드 도구 (학습용)
│   ├── build_docs.py               ← docs/md/*.md + README.md → docs/html/index.html
│   ├── analyze_binary.py           ← agent-app ELF / PyInstaller 정적 분석
│   ├── extract_pyinstaller.py      ← PyInstaller 번들 추출
│   ├── decompile_metadata.py       ← .pyc code object 메타데이터 재귀 덤프
│   └── disasm_pyc.py               ← dis 모듈 기반 바이트코드 분해
│
└── .github/workflows/verify.yml    ← GitHub Actions 자동 검증
```

## 3. 최종 산출물

| # | 산출물 | 비고 |
| - | ------ | ---- |
| 1 | [요구사항_수행_내역서.md](docs/md/요구사항_수행_내역서.md) | 설정/명령어/검증 출력을 모은 제출 문서 |
| 2 | [src/monitor.sh](src/monitor.sh) | 시스템 상태 수집 + 로깅 (필수) |
| 3 | [src/report.sh](src/report.sh) | 로그 분석 리포트 (보너스 1) |
| 4 | [src/archive_logs.sh](src/archive_logs.sh) | 시간 기반 로그 보존 정책 (보너스 2) |
| 5 | [src/00_run_all.sh](src/00_run_all.sh) ~ [src/07_cron_schedule.sh](src/07_cron_schedule.sh) | 환경 구축 7단계 스크립트 (각 단계 분리, 번호 순서대로 실행) |
| 6 | `bin/agent-app` | 미션 측이 제공하는 Linux 바이너리 (Ubuntu 24.04 전용). 학습자가 만들지 않음 |
| 7 | [스크립트_설명.md](docs/md/스크립트_설명.md) | bash 입문자용 스크립트 해설 |

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
   - 프로세스 `agent-app` 실행 여부
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
orb create ubuntu:24.04 codyssey
orb push -m codyssey src/*.sh bin/agent-app /tmp/   # 01~07 + monitor/report/archive + 바이너리
orb shell -m codyssey

# 머신 내부 (Windows 작성 파일이면 CRLF 정리)
sudo apt-get install -y dos2unix
dos2unix /tmp/*.sh && chmod +x /tmp/*.sh

# 이후 01~07 setup 스크립트를 순서대로 실행
bash /tmp/00_run_all.sh           # 한 번에 (권장)
# 또는 단계별로 직접 확인하며:
bash /tmp/01_ssh_hardening.sh
bash /tmp/02_firewall_allowlist.sh
# ...
bash /tmp/07_cron_schedule.sh
```

검증 체크리스트는 [요구사항_수행_내역서.md](docs/md/요구사항_수행_내역서.md) 마지막 절 참고.

### OrbStack 업데이트 알림 끄기 (선택)

`orb` 명령마다 "OrbStack X.Y.Z 업데이트 가능" 안내가 떠 시연에 거슬리는 경우 한 가지 이상의 방법으로 비활성화 가능.

**A) macOS 셸 프로파일에 영구 등록 (권장)**

```bash
# zsh 사용자
echo 'export ORBSTACK_NO_UPDATE_CHECK=1' >> ~/.zshrc
echo 'export ORB_NO_UPDATE_CHECK=1'      >> ~/.zshrc

# bash 사용자
echo 'export ORBSTACK_NO_UPDATE_CHECK=1' >> ~/.bashrc

source ~/.zshrc   # 또는 새 터미널 열기
```

**B) OrbStack 앱 자체 설정**

OrbStack 메뉴바 아이콘 → **Settings** → **System** → **Software Update** 에서 "Check for updates automatically" 체크 해제.

**C) 본 저장소 스크립트 사용 시**

`demo.sh` / `verify_orbstack.sh` 안에서 위 환경변수를 자동 set 하고, 새는 안내 줄은 `sed` 필터로 제거하도록 처리해 두었음 → 별도 작업 불필요.

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

- Ubuntu 24.04 LTS (OrbStack 머신 권장)
- bash, ss/netstat, ufw 또는 firewalld, acl(`setfacl`/`getfacl`), cron, python3
