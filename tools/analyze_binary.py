#!/usr/bin/env python3
"""agent-app 바이너리 정적 분석 도구"""
import sys, re, io
from pathlib import Path
from elftools.elf.elffile import ELFFile
from elftools.elf.dynamic import DynamicSection
from elftools.elf.sections import SymbolTableSection

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:
    pass

BIN = Path(__file__).resolve().parent / "bin" / "agent-app"


def header(elf):
    h = elf.header
    print("=" * 60)
    print("[ELF Header]")
    print("=" * 60)
    print(f"  Class      : {h.e_ident.EI_CLASS}")
    print(f"  Data       : {h.e_ident.EI_DATA}")
    print(f"  OS/ABI     : {h.e_ident.EI_OSABI}")
    print(f"  Type       : {h.e_type}")
    print(f"  Machine    : {h.e_machine}")
    print(f"  Entry      : 0x{h.e_entry:x}")
    print(f"  Sections   : {h.e_shnum}")
    print(f"  Segments   : {h.e_phnum}")


def dynamic_info(elf):
    print()
    print("=" * 60)
    print("[Dynamic — 의존 라이브러리 / interpreter / RPATH]")
    print("=" * 60)
    for sec in elf.iter_sections():
        if isinstance(sec, DynamicSection):
            for tag in sec.iter_tags():
                if tag.entry.d_tag in ("DT_NEEDED", "DT_RPATH", "DT_RUNPATH",
                                       "DT_SONAME"):
                    print(f"  {tag.entry.d_tag:14s} {tag.needed if tag.entry.d_tag=='DT_NEEDED' else tag.runpath if hasattr(tag,'runpath') else ''}")
    for seg in elf.iter_segments():
        if seg.header.p_type == "PT_INTERP":
            interp = seg.get_interp_name()
            print(f"  INTERPRETER    {interp}")


def sections_summary(elf):
    print()
    print("=" * 60)
    print("[Section 요약 — 상위 12개 (크기순)]")
    print("=" * 60)
    sections = sorted(elf.iter_sections(), key=lambda s: s.data_size, reverse=True)
    print(f"  {'Name':<24}{'Type':<14}{'Size':>10}  Flags")
    for s in sections[:12]:
        if s.name == "":
            continue
        flags = []
        f = s.header.sh_flags
        if f & 0x2: flags.append("ALLOC")
        if f & 0x4: flags.append("EXECINSTR")
        if f & 0x1: flags.append("WRITE")
        print(f"  {s.name:<24}{s.header.sh_type:<14}{s.data_size:>10}  {','.join(flags)}")


def strings_scan(elf, min_len=8):
    """ELF 의 .rodata / .data / .text 등에서 ASCII 문자열 추출 + 카테고리화"""
    print()
    print("=" * 60)
    print("[흥미로운 문자열 (의도/구현 단서)]")
    print("=" * 60)

    # 데이터 섹션을 모두 모아 한 번에 스캔
    blob = b""
    for sname in (".rodata", ".data", ".data.rel.ro", ".text"):
        s = elf.get_section_by_name(sname)
        if s:
            blob += s.data()

    # 4-byte 이상 ASCII printable string 추출
    strs = re.findall(rb"[\x20-\x7e]{%d,}" % min_len, blob)
    strs = [x.decode("utf-8", errors="replace") for x in strs]

    # 카테고리별 keyword 매핑
    buckets = {
        "환경변수 (AGENT_*)":     ["AGENT_HOME", "AGENT_PORT", "AGENT_KEY_PATH",
                                  "AGENT_UPLOAD_DIR", "AGENT_LOG_DIR"],
        "Boot Sequence 단계":     ["Boot Sequence", "[1/5]", "[2/5]", "[3/5]",
                                  "[4/5]", "[5/5]", "Agent READY", "READY"],
        "체크 항목 라벨":         ["Checking User", "Verifying Environment",
                                  "Checking Required", "Checking Port",
                                  "Verifying Log", "[OK]", "[FAIL]"],
        "키 검증":                ["agent_api_key_test", "t_secret.key",
                                  "Verified key file"],
        "네트워크/포트":          ["15034", "0.0.0.0", "127.0.0.1", "LISTEN"],
        "에러 메시지":            ["uid=0", "root", "not allowed",
                                  "not available", "writable",
                                  "Missing env"],
        "stdlib/glibc 단서":      ["GLIBC_", "libc.so", "ld-linux"],
        "URL / 도메인":           ["http://", "https://"],
    }
    matched = set()
    for cat, kws in buckets.items():
        print(f"\n  ── {cat} ──")
        for kw in kws:
            for s in strs:
                if kw.lower() in s.lower():
                    if s not in matched and len(s) < 200:
                        print(f"    {s}")
                        matched.add(s)


def imports_overview(elf):
    """동적 심볼 — 어떤 libc 함수를 쓰는지 = 무엇을 하는지 단서"""
    print()
    print("=" * 60)
    print("[Imported symbols — 어떤 libc 호출을 쓰나]")
    print("=" * 60)

    interesting_prefixes = (
        "socket", "bind", "listen", "accept", "send", "recv", "connect",
        "open", "read", "write", "close", "fopen", "fread", "fwrite",
        "getuid", "geteuid", "getpwuid", "getenv",
        "fork", "exec", "wait",
        "signal", "sigaction",
        "printf", "fprintf", "puts", "perror",
        "malloc", "free",
        "strcmp", "strncmp", "strstr",
        "stat", "access",
    )

    found = {}
    for sec in elf.iter_sections():
        if isinstance(sec, SymbolTableSection):
            for sym in sec.iter_symbols():
                if sym.name and sym['st_info']['type'] == 'STT_FUNC':
                    name = sym.name.split("@", 1)[0]
                    if any(name.startswith(p) for p in interesting_prefixes):
                        found.setdefault(name, 0)
                        found[name] += 1

    # 카테고리별로 그룹화 후 출력
    cats = {
        "🌐 네트워크":   ["socket","bind","listen","accept","send","recv","connect","setsockopt"],
        "📂 파일 I/O":   ["open","read","write","close","fopen","fread","fwrite","fclose","stat","access"],
        "👤 계정/권한":  ["getuid","geteuid","getpwuid","getgrgid","getgid","setuid"],
        "🌎 환경변수":   ["getenv","setenv","putenv"],
        "🔔 시그널":     ["signal","sigaction","kill"],
        "📝 출력":       ["printf","fprintf","puts","perror","write"],
        "🧮 문자열":     ["strcmp","strncmp","strstr","strlen","strchr"],
        "💾 메모리":     ["malloc","free","calloc","realloc"],
        "🚀 프로세스":   ["fork","exec","execve","wait","waitpid"],
    }
    for cat, kws in cats.items():
        hits = [k for k in found if any(k.startswith(p) for p in kws)]
        if hits:
            print(f"\n  {cat}")
            for h in sorted(hits):
                print(f"    {h}")


def main():
    if not BIN.exists():
        print(f"[ERROR] {BIN} not found")
        sys.exit(1)
    print(f"분석 대상: {BIN}  ({BIN.stat().st_size:,} bytes)")
    with open(BIN, "rb") as f:
        elf = ELFFile(f)
        header(elf)
        dynamic_info(elf)
        sections_summary(elf)
        imports_overview(elf)
        strings_scan(elf)


if __name__ == "__main__":
    main()
