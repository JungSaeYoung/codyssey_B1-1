# `agent-app` 리버스 엔지니어링 — 방법론과 단계별 분석

> 본 문서는 미션의 [bin/agent-app](../../bin/agent-app) 바이너리를 **정적 분석** 하면서 "어떤 도구로 무엇을 알아낼 수 있는가" 를 단계별로 정리한 학습용 자료다.
> 분석 도구: [tools/analyze_binary.py](../../tools/analyze_binary.py)

---

## 0. 들어가기 전에 — 윤리·법

### 왜 리버스 엔지니어링을 배우나

- **운영 환경 이해**: "왜 22.04 에선 안 되고 24.04 에선 되나?" 같은 질문에 추측이 아니라 근거로 답하려면.
- **사고 대응**: 누군가 의심스러운 바이너리를 떨궜을 때 안에서 무슨 일이 벌어지는지 빠르게 판단.
- **호환성 디버깅**: 닫힌 소스 도구가 특정 환경에서만 깨질 때 원인 파악.
- **보안 평가**: 우리 제품의 바이너리가 얼마나 분석 저항성이 있나 자가 점검.

### 본 문서가 다루지 않는 것 (선)

- 미션 채점 우회 · 라이센스 위반 · 재배포 — 모두 ❌
- 동적 분석(실행하며 디버거 붙이기) — 본 문서는 **정적 분석만**
- 악의적 패치/재패키징

### 본 미션의 맥락

`bin/agent-app` 은 운영 측이 **이미 제공**한 산출물이고, 미션 학습자의 의무는 그것을 **실행 환경 안에서 구동**시키는 것이다. 따라서 본 분석은 "어떻게 동작하는가 / 왜 24.04 가 필요한가" 같은 **이해 목적** 이며, 본문에서 얻은 정보로 코드를 수정/재배포할 일은 없다.

---

## 1. 단계별 접근법 (Layer 1~7)

리버스 엔지니어링은 양파처럼 **표면 → 깊은 곳** 순서로 까나가야 효율적이다. 한 층이 끝날 때마다 "다음 층까지 가야 하는가?" 를 묻고 충분하면 멈추는 게 정석.

```
Layer 1  파일이 뭐냐               ← file, hexdump
Layer 2  ELF 구조                  ← readelf, pyelftools
Layer 3  의존 라이브러리           ← readelf -d, ldd
Layer 4  안에 든 문자열            ← strings, grep
Layer 5  호출하는 API              ← readelf --dyn-syms, nm
Layer 6  (PyInstaller 면) 아카이브 ← TOC 직접 파싱
Layer 7  바이트코드 디컴파일       ← pyinstxtractor + uncompyle6
```

각 층마다 **어떤 질문에 답하는가** 가 명확해야 시간 낭비가 없다.

---

## 2. Layer 1 — 파일이 무엇인가

### 질문

> 이게 ELF? Python 스크립트? Shell? 압축 파일?

### 도구

- `file` — magic bytes 로 1차 분류[^1]
- `xxd` / `hexdump` / Python `open(...).read(64)` — 헤더 직접 확인

### 실행

```bash
$ file bin/agent-app
bin/agent-app: ELF 64-bit LSB executable, x86-64, version 1 (SYSV),
               dynamically linked, interpreter /lib64/ld-linux-x86-64.so.2,
               for GNU/Linux 3.2.0, BuildID[sha1]=3d4132e6...,
               stripped
```

### 한 줄에 알 수 있는 것

| 항목 | 값 | 의미 |
|------|---|------|
| ELF 64-bit | ✓ | 리눅스용 실행 파일 |
| x86-64 | ✓ | 인텔/AMD 64비트 (Apple Silicon 직접 실행 불가, Rosetta 필요) |
| dynamically linked | ✓ | 라이브러리를 런타임에 동적 로드 (단독 실행 X) |
| interpreter /lib64/ld-linux-x86-64.so.2 | ✓ | glibc 동적 링커 사용[^2] |
| GNU/Linux 3.2.0 | ✓ | 매우 오래된 커널까지 호환 (특이사항 아님) |
| **stripped** | ✓ | **심볼 정보 제거됨** — 함수/변수 이름 안 보임 |

### 이 단계에서 멈출 수 있는 경우

- "이 게 ELF 인지만 확인하고 싶었다" → 끝.
- 의심스러운 파일이 ELF 가 아니라 ZIP/script 면 다른 접근으로 분기.

→ 우리는 다음 층으로.

---

## 3. Layer 2 — ELF 구조

### 질문

> 이 바이너리는 얼마나 크고, 코드와 데이터 비율이 어떻게 되나? 비정상적으로 큰 섹션은 없나?

### 도구

- `readelf -S binary` — 섹션 헤더 목록
- Python `elftools` (`pip install pyelftools`)
- `objdump -h binary` — 비슷한 정보

### 실행

```python
from elftools.elf.elffile import ELFFile
with open('bin/agent-app', 'rb') as f:
    elf = ELFFile(f)
    sections = sorted(elf.iter_sections(), key=lambda s: s.data_size, reverse=True)
    for s in sections[:8]:
        print(f"{s.name:<20}{s.data_size:>10} bytes")
```

### 결과

```
pydata             7,862,008 bytes   ← 7.86 MB! 전체의 99%
.text                 34,946 bytes   ← 실제 기계어 코드는 34 KB 뿐
.bss                  16,560 bytes
.rodata                9,809 bytes
.eh_frame              5,520 bytes
.dynsym                2,064 bytes
.rela.plt              1,944 bytes
.plt                   1,312 bytes
```

### 진단

**비정상적인 신호 두 가지가 동시에 보인다:**

1. `pydata` 라는 **표준 ELF 가 아닌 사용자 정의 섹션[^3]** 이 존재
2. 실제 코드(`.text`)는 35 KB 인데 데이터가 7.86 MB → **데이터가 코드의 220배**

→ "이 바이너리는 평범한 컴파일 결과가 아니다. 뭔가 **묶인 페이로드(packaged payload)** 가 있다." 라는 가설이 선다. `pydata` 이름 자체가 결정적 단서 — **PyInstaller** 가 사용하는 섹션명.

다음 층에서 의심을 확정한다.

---

## 4. Layer 3 — 의존 라이브러리

### 질문

> 이 바이너리가 실행되려면 어떤 .so 파일들이 필요한가? (= 어떤 기능을 쓰는가의 1차 단서)

### 도구

- `ldd binary` — 동적 링커가 해결한 의존 (Linux 위에서만 가능)
- `readelf -d binary` — DT_NEEDED 항목 (모든 OS 에서 가능, 추천)
- pyelftools `DynamicSection.iter_tags()`

### 실행

```python
from elftools.elf.dynamic import DynamicSection
for sec in elf.iter_sections():
    if isinstance(sec, DynamicSection):
        for tag in sec.iter_tags():
            if tag.entry.d_tag == "DT_NEEDED":
                print(tag.needed)
```

### 결과

```
libdl.so.2            ← dlopen/dlsym — 동적 라이브러리 로딩
libz.so.1             ← zlib 압축
libpthread.so.0       ← POSIX 스레드
libc.so.6             ← C 표준 라이브러리
INTERPRETER: /lib64/ld-linux-x86-64.so.2
```

### 진단

- 외부 의존이 4개뿐 — 적다. 그런데 **`libdl` 이 있다** = 런타임에 다른 .so 를 동적으로 불러올 수 있음. PyInstaller bootloader 가 내부 번들 .so 를 dlopen 으로 로드하는 패턴과 정확히 일치.
- libpython, libssl, libcrypto 같은 게 **외부 의존에 안 보임** → 그건 어딘가에 **번들로 들어가 있다**는 뜻.
- 의심 → 확정으로 한 발 더.

---

## 5. Layer 4 — 안에 든 문자열

### 질문

> 사용자에게 보일 메시지, 환경변수 이름, 에러 문구 등이 노출되어 있는가?

### 도구

- `strings binary` — 4 바이트 이상 ASCII 시퀀스 출력[^4]
- `strings -e l binary` — UTF-16LE 도 같이[^5] (Windows 바이너리 분석 시)
- Python 정규식 — 카테고리별 필터링

### 실행

```python
import re
blob = b""
for sname in (".rodata", ".data", ".data.rel.ro", ".text", "pydata"):
    s = elf.get_section_by_name(sname)
    if s: blob += s.data()
strings = re.findall(rb"[\x20-\x7e]{8,}", blob)
```

### 결과 — 흥미로운 발견

| 카테고리 | 발견된 문자열 |
|---------|-------------|
| PyInstaller 단서 | `LOADER:`, `SPLASH:`, `_MEIPASS`, `pyi_rth_*`, `PyInstaller` |
| 번들 .so 이름 | `libpython3.12.so.1.0`, `libssl.so.3`, `libcrypto.so.3`, `libbz2.so.1.0`, `liblzma.so.5` |
| 표준 라이브러리 | `socket`, `subprocess`, `signal`, `threading`, `logging`, `argparse`, `datetime`, `http`, `pathlib`, `json` |
| Python 모듈 추정 | `_ssl`, `_hashlib`, `_lzma`, `_bz2`, `_codecs_kr`, `_decimal` |
| 컴파일러 단서 | `GCC: (Ubuntu 7.5.0-3ubuntu1~18.04) 7.5.0` |

### 진단

이 한 층만으로 다음이 거의 확정된다:

- **Python 3.12** 가 통째로 번들됨 (`libpython3.12.so.1.0`)
- **SSL/TLS 통신 기능 보유** (`libssl`, `libcrypto`, `_ssl`, `_hashlib`)
- **한국어 처리 가능성[^6]** (`_codecs_kr` — Python 의 EUC-KR 코덱)
- **HTTP 서버 또는 클라이언트** (`http` 모듈)
- **subprocess** 로 외부 명령 실행 가능
- bootloader 는 Ubuntu 18.04 GCC 7.5 로 빌드됨

### 핵심 — `LOADER:` 가 의미하는 것

PyInstaller 의 C 부트로더는 다음 단계로 동작한다:

```
[main 시작]
  → LOADER: "Cannot open self %s" 같은 에러 메시지가 .rodata 에 박힘
  → 자기 자신을 열어 pydata 섹션 위치 찾기
  → pydata 안 archive 의 TOC 파싱
  → libpython3.12.so.1.0 을 임시 디렉토리(_MEIPASS)에 풀어 dlopen
  → Python interpreter 초기화
  → 번들된 .pyc 들을 import
  → 진입 스크립트(linux_pbl_v2) 실행
```

이 흐름을 알면 `_MEIPASS`, `LOADER:`, `SPLASH:` 같은 문자열이 보일 때 PyInstaller 라고 즉시 확신할 수 있다[^7].

---

## 6. Layer 5 — 호출하는 API

### 질문

> 이 프로그램이 실제로 어떤 libc 함수를 호출하는가? (= 무엇을 할 수 있는가)

### 도구

- `nm -D binary` — 동적 심볼 테이블 (외부 의존 함수)[^8]
- `readelf --dyn-syms binary`
- pyelftools `SymbolTableSection`

### 실행 결과 — 카테고리별 분류

```
🌐 네트워크
   (없음 — PyInstaller 부트로더는 네트워크 직접 호출 X. 실제 통신은 번들 Python 안에서)

📂 파일 I/O
   open, read, write, close, fopen, fread, fwrite, fclose
   opendir, readdir, closedir, readlink, stat, access

👤 계정/권한
   (없음 — Python uid 체크는 번들 코드 안)

🌎 환경변수
   getenv

🔔 시그널
   signal

📝 출력
   fprintf, perror

🧮 문자열
   strcmp, strncmp, strstr

💾 메모리
   malloc, free

🚀 프로세스
   fork, execvp, waitpid    ← 자식 프로세스 spawn 가능!
```

### 진단

- 직접 노출된 API 는 **PyInstaller bootloader 가 쓰는 것** 들. 실제 비즈니스 로직은 모두 번들된 .pyc 안.
- 그래도 `fork/execvp/waitpid` 가 있다는 건 부트로더가 임시 디렉토리에 .so 풀고 새 프로세스로 다시 실행하는 PyInstaller 패턴과 일치.
- "실제 agent-app 이 무엇을 하는가" 를 알려면 **bundled .pyc 를 추출해야 한다**.

---

## 7. Layer 6 — PyInstaller 아카이브 구조

### 질문

> `pydata` 섹션 안의 PyInstaller archive 를 직접 들여다보자. 어떤 파일들이 들어 있나?

### PyInstaller archive 포맷 (간단히)

```
[ELF .pydata 섹션 시작]
  ┌───────────────────────────────┐
  │ 1) Bundled files (zlib 압축)   │   각 파일이 압축돼 연속 배치
  │ 2) TOC (Table of Contents)     │   파일 목록 + 오프셋/길이
  │ 3) Cookie + Header             │   MEI\x0c\x0b\x0a\x0b\x0e 매직 +
  │                                │   archive 총 길이, TOC offset/length, Python 버전
  └───────────────────────────────┘
[파일 끝]
```

### 도구

- `pyinstxtractor` (pip install pyinstxtractor) — 자동 추출
- Python 직접 파싱 — 학습 목적

### 직접 파싱 예시

```python
import struct
data = open('bin/agent-app','rb').read()
COOKIE = b'MEI\x0c\x0b\x0a\x0b\x0e'
ci = data.rfind(COOKIE)

length     = struct.unpack('>I', data[ci+ 8:ci+12])[0]
toc_offset = struct.unpack('>I', data[ci+12:ci+16])[0]
toc_length = struct.unpack('>I', data[ci+16:ci+20])[0]
py_ver     = struct.unpack('>I', data[ci+20:ci+24])[0]

print(f"Python {py_ver // 100}.{py_ver % 100}")
# → "Python 3.12"
```

### 결과

```
PyInstaller cookie position: 0x78e979
아카이브 길이      : 7,862,008 bytes
TOC offset        : 0x77ee80
TOC length        : 2,080 bytes
Python 버전 인덱스 : 312  →  Python 3.12
```

### TOC 안의 항목들 (스캔)

```
── 진입 스크립트 (typecode 's') ──
  s  linux_pbl_v2        ← 메인 엔트리포인트
  s  pyi_rth_inspect     ← runtime hook
  s  pyiboot01_bootstrap ← PyInstaller 부트스트랩

── 번들 라이브러리 (typecode 'b') ──
  b  libpython3.12.so.1.0
  b  libssl.so.3
  b  libcrypto.so.3
  b  libbz2.so.1.0
  b  liblzma.so.5
  b  libz.so.1
  b  python3.12/lib-dynload/_ssl.cpython-312-x86_64-linux-gnu.so
  b  python3.12/lib-dynload/_hashlib.cpython-312-x86_64-linux-gnu.so
  b  python3.12/lib-dynload/_lzma.cpython-312-x86_64-linux-gnu.so
  b  python3.12/lib-dynload/_bz2.cpython-312-x86_64-linux-gnu.so
  b  python3.12/lib-dynload/_codecs_kr.cpython-312-x86_64-linux-gnu.so
  ... (한국어/일본어/중국어 코덱 다수)
  b  python3.12/lib-dynload/_decimal.cpython-312-x86_64-linux-gnu.so
  b  python3.12/lib-dynload/_contextvars.cpython-312-x86_64-linux-gnu.so

── 데이터 (typecode 'd') ──
  d  base_library.zip   ← Python 표준 라이브러리 압축
  d  pyi-contents-d     ← PyInstaller 메타데이터
```

### 진단 — 핵심 발견

- **`linux_pbl_v2`** 가 메인 진입 스크립트. 이름에서 추측:
  - `linux_` : 리눅스 전용
  - `pbl_` : Platform Boot Loader / Probe / Process Bot Listener 가능성
  - `_v2` : 버전 2
- `_codecs_kr` 가 번들된 건 의외 — 한국어 텍스트 처리 의도가 있다는 신호 (Codyssey 미션이라서 자연스러움)
- `_ssl` + `_hashlib` 가 함께 있는 건 **HTTPS 호출 + 서명/해시 검증** 패턴

---

## 8. Layer 7 — 바이트코드 디컴파일 (가장 깊은 층)

### 질문

> `linux_pbl_v2` 의 실제 Python 소스가 어떻게 생겼나?

### 8-1. 두 단계로 진행

```
[Step A] PyInstaller archive 풀기 → .pyc 파일 32개 추출
              ↓
[Step B] .pyc 디컴파일 또는 메타데이터 추출 → Python 소스 복원
```

### 8-2. Step A — 아카이브 추출

`pyinstxtractor` 가 PyPI 에 없는 경우(2026 기준), 본 저장소의 [tools/extract_pyinstaller.py](../../tools/extract_pyinstaller.py) 사용:

```bash
python tools/extract_pyinstaller.py
```

출력:
```
== agent-app (pydata @ file offset 0xf2d9) ==
  archive 길이 : 7,862,008 bytes
  TOC pos      : 0x77ee80 (archive 내부)
  TOC len      : 2080 bytes
  Python 버전  : 3.12
  python lib   : libpython3.12.so.1.0
  TOC 항목 수  : 32

== 추출 완료 ==
  b (binary): 23      ← libpython, libssl, *.cpython-312-*.so 등
  m (module): 4       ← pyimod01_archive, pyimod02_importers, ...
  o (option): 1
  s (script): 3       ← linux_pbl_v2, pyi_rth_inspect, pyiboot01_bootstrap
  z (PYZ):    1       ← base_library.zip + Python stdlib 컴파일된 모음
```

→ `bin/agent-app_extracted/linux_pbl_v2.pyc` 가 우리가 찾던 파일 (19 KB).

### 8-3. Step B — .pyc 디컴파일 한계

| 디컴파일러 | 지원 Python | 본 미션 적용 가능? |
|----------|------------|------------------|
| `uncompyle6` | 2.7 ~ 3.8 | ❌ |
| `decompyle3` | 3.7 ~ 3.9 | ❌ |
| `pycdc` (C++ binary) | 1.0 ~ 3.12 | ✅ (직접 빌드 필요) |
| `dis` + 수작업 | 모두 | ✅ (시간 듦) |
| **메타데이터 추출 + 재구성** | 모두 | ✅ **본 문서가 택한 방법** |

본 미션의 `linux_pbl_v2.pyc` 는 Python 3.12 → uncompyle6/decompyle3 모두 미지원[^9].
실용적 우회법: **`marshal.load()` 로 code object 를 읽어 들인 뒤[^10], 모든 중첩 code 의 `co_varnames` / `co_names` / `co_consts` / `co_argcount` 를 재귀로 덤프**. 흐름 제어는 추정해야 하지만, 메서드 이름·시그니처·문자열 리터럴은 **100% 정확** 하게 복원된다.

### 8-4. 메타데이터 디컴파일러 — [tools/decompile_metadata.py](../../tools/decompile_metadata.py)

```bash
python tools/decompile_metadata.py
```

출력 일부:
```
┏━ MODULE: <module>  (line 1)
┃  names: ('os', 'sys', 'pwd', 'time', 'math', 'socket', 'logging',
┃          'RotatingFileHandler', 'BootValidator', 'ResourceStressor',
┃          'set_logger', 'validator', 'check_root_user',
┃          'check_env_config', 'check_required_files',
┃          'check_port_availability', 'check_log_permission', ...)
┃  string constants:
┃    '>>> Starting Agent Boot Sequence...'
┃    'Agent Boot Check Failed. Process Terminated.'
┃    'All Boot Checks Passed!'
┃    'Agent READY'

  ┏━ method: BootValidator.check_env_config  (line 73)
  ┃  sig: (self)  locals=14
  ┃  string constants:
  ┃    'AGENT_HOME', 'AGENT_PORT', 'AGENT_UPLOAD_DIR', 'AGENT_KEY_PATH'
  ┃    'Critical Env 'AGENT_HOME' is missing.'
  ┃    'upload_files', 'api_keys', 't_secret.key'
  ┃    'Port mismatch (Expected ', ', Got ', ')'
  ┃    'agent_api_key_test'
  ┃  number constants: [1, 15034]
```

`co_consts` 의 문자열만 봐도 코드가 **무엇을 어떤 형식으로 검증/출력하는지** 가 거의 그대로 드러난다.

### 8-5. 재구성된 소스 — [linux_pbl_v2_reconstructed.py](../../bin/agent-app_extracted/linux_pbl_v2_reconstructed.py)

추출한 메타데이터로 사람이 읽을 수 있는 Python 으로 재구성한 결과. 핵심 구조 요약:

```python
class BootValidator:
    def __init__(self):
        self.steps_name = (
            "Checking User Account",
            "Verifying Environment Variables",
            "Checking Required Files",
            "Checking Port Availability",
            "Verifying Log Permission",
        )

    def check_root_user(self):         # [1/5] uid != 0
    def check_env_config(self):        # [2/5] AGENT_*  5종 + 값 검증
    def check_required_files(self):    # [3/5] 키 파일 내용 == "agent_api_key_test"
    def check_port_availability(self): # [4/5] socket.connect_ex 로 점유 여부
    def check_log_permission(self):    # [5/5] os.access(log_dir, W_OK)

class ResourceStressor:
    LIMIT_MEMORY_MB = 256
    CHUNK_SIZE_MB   = 25
    LIMIT_CPU_SEC   = 5
    LIMIT_CPU_LEVEL = 10

    def __init__(self, logger, port=15034):
        os.nice(10)                    # 우선순위 낮춤 — 다른 프로세스 방해 최소화

    def open_socket(self):             # 0.0.0.0:15034 bind + listen(1)
    def increase_memory(self):         # 'x' * 1MB chunks 누적
    def occupy_cpu(self, level):       # sin/cos 100000*level 회 반복
    def rotate_cycle(self):            # 메모리·CPU 사이클 (UP/DOWN 반복)
```

### 8-6. 큰 발견 — `agent-app` 의 진짜 정체

본격 디컴파일을 통해 드러난 것: **이 앱은 외부 통신이나 명령 실행이 아니라, 의도적으로 시스템 자원을 사이클로 사용하는 "스트레서"**.

```
                  ┌─────────────────────────────────────────┐
                  │  사이클 = UP phase  ↔  DOWN phase       │
                  │                                          │
   메모리:        │   0 ──→ 25 ──→ 50 ──→ ... ──→ 256 MB   │
                  │                                  ↓       │
                  │   256 ←── 231 ←── 206 ←── ... ←── 0 MB │
                  │                                          │
   CPU level:     │   0 ──→ 1 ──→ 2 ──→ ... ──→ 10 (sin/cos)│
                  │                              ↓           │
                  │   10 ←── 9 ←── ... ←── 0                │
                  │                                          │
   매 step:       │   sleep(1)                              │
                  └─────────────────────────────────────────┘
```

즉, **monitor.sh 가 "관제할 데이터를 만드는 워크로드 생성기"** 였던 것. 미션 §6 의 "[WARNING] CPU/MEM threshold exceeded" 가 실제로 trigger 되는 이유.

### 8-7. 발견의 의미 — 미션 설계 의도

| 미션 요구사항 | 왜 그렇게 만들었나 (코드로 검증됨) |
|--------------|--------------------------------|
| CPU 임계값 20% | 사이클 중 level 5~10 에서 자연히 초과 → WARNING 발생 |
| MEM 임계값 10% | LIMIT_MEMORY_MB=256 + 시스템 메모리 비율로 초과 |
| 키 파일 내용 정확 검증 | check_required_files 가 `==` 정확 비교 → 1 byte 만 달라도 부트 실패 |
| AGENT_PORT=15034 강제 | check_env_config 가 다른 값이면 `Port mismatch` |
| 일반 계정 강제 | check_root_user 가 uid==0 시 즉시 sys.exit(1) |

이 발견 자체가 **미션이 측정하려는 것** 을 명확히 보여 준다 — "스트레스가 발생하는 진짜 프로세스를 monitor.sh 로 측정·기록·경고" 하는 능력.

### 이 단계까지 가야 하는가? (수정)

원래 본 문서는 "Layer 6 까지로 충분" 이라 했지만, 위 발견 덕분에 시각이 바뀐다:

- **운영/채점 관점**: Layer 4~5 (어떤 모듈 쓰나) 까지면 충분
- **학습 관점**: Layer 7 까지 가면 미션 설계 의도를 만나는 보너스
- **재배포·수정 목적**: ❌ (라이센스 위반)

---

## 9. 종합 — `agent-app` 의 추정 아키텍처

7 단계 분석을 종합하면 다음 그림이 나온다.

```
┌─────────────────────────────────────────────────────────────────┐
│  agent-app (PyInstaller single-file ELF, Python 3.12)           │
│                                                                  │
│  [기동]                                                          │
│   1. ELF 진입 → PyInstaller C bootloader 실행                    │
│   2. 자기 자신에서 pydata 섹션 읽어 archive 추출                 │
│   3. /tmp/_MEIxxxxxx/ 에 .so 와 base_library.zip 풀기            │
│   4. libpython3.12.so.1.0 을 dlopen                              │
│   5. Python 인터프리터 초기화                                    │
│   6. linux_pbl_v2.pyc 실행                                       │
│                                                                  │
│  [본체 — linux_pbl_v2 추정]                                      │
│   • 환경변수 검증 (AGENT_HOME, AGENT_PORT, AGENT_KEY_PATH ...)   │
│   • 키 파일 검증 (agent_api_key_test)                            │
│   • 0.0.0.0:15034 에 socket 바인드                               │
│   • signal 핸들러 등록 (SIGTERM, SIGINT)                         │
│   • 부트 시퀀스 5단계 [OK] 출력                                  │
│   • "Agent READY" 출력                                           │
│                                                                  │
│  [러닝 루프 — 미확인, 추정]                                      │
│   • HTTP 요청 수신 (port 15034)                                  │
│   • subprocess 로 명령 실행                                      │
│   • SSL/hashlib 로 외부 서버에 결과 보고? (단정 어려움)          │
│   • 로그 파일에 기록 (/var/log/agent-app/...)                    │
│                                                                  │
│  [종료]                                                          │
│   • Ctrl+C → SIGINT → graceful shutdown                          │
│   • /tmp/_MEIxxxxxx/ 자동 정리                                   │
└─────────────────────────────────────────────────────────────────┘
```

### 핵심 결론 3가지

1. **Ubuntu 24.04 가 강제되는 진짜 이유**
   - 번들 `libpython3.12.so.1.0` 는 빌드 시점의 glibc(>=2.38) 와 동적 링크
   - Ubuntu 22.04 는 glibc 2.35 → 로드 자체가 `GLIBC_2.38 not found` 에러
   - 22.04 가 Python 3.10 이라는 사실도 부수적 이슈지만 더 본질은 glibc

2. **이 앱이 "단순 에코 서버" 가 아닌 이유**
   - `_ssl`, `_hashlib`, `libssl`, `libcrypto` 가 번들됨 = TLS·해시 기능 보유
   - `subprocess`, `fork/exec` 가능 = 외부 명령 실행기
   - HTTP 모듈 포함 = HTTP 서버 또는 클라이언트
   - 종합하면 "**원격 명령 수행 + 결과 보고형 agent**" 모델

3. **분석 저항성은 낮은 편**
   - stripped 이지만 PyInstaller 패키징이라 archive 만 풀면 .pyc 까지 즉시 접근
   - 실제로 코드 보호가 중요했다면 **Cython 컴파일** 이나 **PyArmor 난독화** 가 추가됐어야 함
   - 본 미션은 교육용 산출물이라 보호보다는 배포 편의가 우선

---

## 10. 분석 도구 — `tools/analyze_binary.py`

본 문서의 분석 결과를 한 번에 재현할 수 있는 Python 스크립트가 [tools/analyze_binary.py](../../tools/analyze_binary.py) 에 있다.

```bash
pip install pyelftools          # ELF 분석 라이브러리
python tools/analyze_binary.py
```

출력 구조:

```
[ELF Header]              ← 매직, 클래스, 머신 종류
[Dynamic — 의존 라이브러리]
[Section 요약 (상위 12개, 크기순)]
[Imported symbols — 카테고리별]
[흥미로운 문자열 (의도/구현 단서)]
```

직접 다른 바이너리 분석할 때 출발점으로 그대로 활용 가능.

---

## 11. 추가 학습 자원

| 분야 | 자원 |
|------|------|
| ELF 포맷 | `man elf`, [ELF spec PDF](https://refspecs.linuxfoundation.org/elf/elf.pdf) |
| PyInstaller 내부 | [github.com/pyinstaller/pyinstaller/wiki](https://github.com/pyinstaller/pyinstaller/wiki) |
| Python 바이트코드 | Python `dis` 모듈 공식 문서 |
| 동적 분석 (다음 단계) | `strace`, `ltrace`, `gdb` + `pwndbg`, `radare2`, `Ghidra` |
| 안전한 환경 | 분석은 항상 **격리 VM/컨테이너**에서. OrbStack 머신이 적격 |

---

## 12. 한 줄 요약

> ELF → 의심 → 의존 → 문자열 → 심볼 → 아카이브 → 바이트코드. 위층에서 답 나오면 멈춰라.
> 본 `agent-app` 은 Python 3.12 PyInstaller 번들이고, Layer 4 (strings) 만으로도 90% 의 의문이 풀린다.

---

## 출처 & 참고 문헌 (Sources & References)

> 본문 위첨자 각주 번호를 누르면 아래 출처로, ↩ 로 본문 위치로 돌아온다. `⚠` 는 검증 중 발견한 보충/정정. 출처는 1차/표준 자료 우선(man7.org · GNU · PyInstaller · docs.python.org · Wikipedia 등).

[^1]: [file(1) — man7.org](https://man7.org/linux/man-pages/man1/file.1.html)
[^2]: [ld.so(8) — man7.org](https://man7.org/linux/man-pages/man8/ld.so.8.html) · [elf(5) — man7.org](https://man7.org/linux/man-pages/man5/elf.5.html)
[^3]: [PyInstaller PR #4450 (pydata section)](https://github.com/pyinstaller/pyinstaller/pull/4450) · [PyInstaller Advanced Topics](https://pyinstaller.org/en/stable/advanced-topics.html)
[^4]: [strings (GNU Binutils)](https://sourceware.org/binutils/docs/binutils/strings.html) · [strings(1) — man7.org](https://man7.org/linux/man-pages/man1/strings.1.html)
[^5]: [strings (GNU Binutils) — -e 인코딩](https://sourceware.org/binutils/docs/binutils/strings.html)
[^6]: ⚠ 보충: _codecs_kr 은 'EUC-KR 전용'이 아니라 euc_kr·cp949·johab 세 한국어 코덱을 등록하는 CJK 코덱 C모듈이다(한국어 처리 가능 서술 자체는 옳음). — [cpython Modules/cjkcodecs/_codecs_kr.c](https://github.com/python/cpython/blob/main/Modules/cjkcodecs/_codecs_kr.c) · [codecs — Standard Encodings](https://docs.python.org/3/library/codecs.html)
[^7]: [PyInstaller Advanced Topics (부트로더·_MEIPASS)](https://pyinstaller.org/en/stable/advanced-topics.html)
[^8]: [nm(1)](https://man7.org/linux/man-pages/man1/nm.1.html) · [readelf(1) — man7.org](https://man7.org/linux/man-pages/man1/readelf.1.html)
[^9]: ⚠ 보충: decompyle3·uncompyle6 의 디컴파일 상한은 모두 3.8 이다(표의 decompyle3 '3.9'는 부정확). 단 대상 .pyc 가 Python 3.12 라 둘 다 미지원이라는 결론 자체는 유효. — [uncompyle6 · PyPI](https://pypi.org/project/uncompyle6/) · [decompyle3 · PyPI](https://pypi.org/project/decompyle3/)
[^10]: [marshal — docs.python.org](https://docs.python.org/3/library/marshal.html) · [Code Objects (C API)](https://docs.python.org/3/c-api/code.html)
