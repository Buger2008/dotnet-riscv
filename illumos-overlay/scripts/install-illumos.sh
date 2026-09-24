#!/usr/bin/env bash
# =============================================================================
# install-illumos.sh — 在 OpenIndiana / illumos 上安装 illumos-x64 .NET SDK
#                      并修复交叉构建留下的 PNSE 空壳程序集
# -----------------------------------------------------------------------------
#
# 背景（为什么需要这个脚本）
# --------------------------
# 这套 SDK 由 dotnet VMR 交叉构建。交叉构建时 illumos 不在受支持的平台列表里，
# 于是少数「按平台分实现」的库被编成了 PlatformNotSupportedException 桩（空壳）：
# 类型/方法签名都在，但每个方法体只做一件事 —— 抛 PNSE。
#
# 影响：
#   System.Net.Security          -> NuGet 走 HTTPS 直接失败（NU1301 / NU3018）
#   System.Net.Quic              -> HTTP/3 不可用
#   System.IO.FileSystem.Watcher -> FileSystemWatcher 直接抛异常
#
# 另外 illumos 的 CA 证书库不在 .NET/NuGet 默认查找的 /etc/ssl/certs，
# 且缺少微软代码签名链依赖的老根证书（DigiCert Assured ID Root CA），
# 会导致包签名校验失败（NU3018 signing certificate is not trusted）。
#
# 本脚本做的事（全部在安装时完成，幂等，可重复执行）
# --------------------------------------------------
#   1. 解压并落位 SDK 到安装前缀（默认 /opt/dotnet）
#   2. 安装 CA 证书（合并系统原有证书 + 内置 bundle，写全 .NET 会查的路径）
#   3. 扫描并识别 PNSE 空壳 dll（IL 体量判定，不依赖文件名硬编码）
#   4. 读出空壳 dll 声明的 TFM（如 net11.0），据此从官方源取对应版本的
#      Microsoft.NETCore.App.Runtime.linux-x64，逐个替换成真实现。
#      只替换「illumos 是空壳、而官方不是」的那些 —— Windows 专有 API
#      （如 System.Security.AccessControl）在两边都是桩，属正常，不动。
#   5. 写 /etc/profile.d/illumos-dotnet.sh
#        DOTNET_ROOT / PATH / SSL_CERT_FILE / SSL_CERT_DIR / DOTNET_ReadyToRun=0
#      DOTNET_ReadyToRun=0 是关键：替换进来的官方程序集带 R2R 预编译代码，
#      illumos 加载会 core dump，必须强制 JIT。
#   6. 自检：dotnet --version + 在线 restore 冒烟
#
# 用法
# ----
#   # A) 和 tar 包放在一起（推荐）
#   sudo bash install-illumos.sh dotnet-sdk-*-illumos-x64.tar.gz
#
#   # B) 已经解压好了，进入 SDK 根目录
#   sudo bash install-illumos.sh
#
#   # C) 指定前缀 / 指定 runtime pack 版本 / 自定义下载源
#   sudo bash install-illumos.sh --prefix /opt/dotnet --pack 11.0.0-rc.1.26425.128
#
# 常用选项
# --------
#   --prefix <dir>      安装前缀（默认 /opt/dotnet）
#   --pack <版本>        指定 runtime pack 版本（默认按空壳 dll 的 TFM 自动选择）
#   --pack-base <URL>   自定义下载源（默认 nuget.org → 华为云 → dnceng 依次尝试）
#   --pack-file <nupkg> 使用本地已有的 runtime pack，不联网
#   --dll-list <a,b>    手动指定要替换的 dll（跳过自动扫描）
#   --no-dlls           不替换 dll（只装证书 / 环境变量）
#   --no-certs          不装证书
#   --no-profile        不写 /etc/profile.d
#   --force             覆盖已存在的前缀（默认改名保留为 .old-<时间戳>）
#   --dry-run           只检测与报告，不改动任何东西
#   -y                  不询问
#   -h | --help         帮助
# =============================================================================
set -euo pipefail

PREFIX="/opt/dotnet"
PACK_VER=""
PACK_BASE=""
PACK_FILE=""
DLL_LIST=""
DO_DLLS=1
DO_CERTS=1
DO_PROFILE=1
FORCE=0
DRY=0
TARBALL=""

usage() { sed -n '2,68p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)     PREFIX="${2:?--prefix 需要目录参数}"; shift 2 ;;
    --prefix=*)   PREFIX="${1#*=}"; shift ;;
    --pack)       PACK_VER="${2:?--pack 需要版本号}"; shift 2 ;;
    --pack=*)     PACK_VER="${1#*=}"; shift ;;
    --pack-base)  PACK_BASE="${2:?--pack-base 需要 URL}"; shift 2 ;;
    --pack-base=*) PACK_BASE="${1#*=}"; shift ;;
    --pack-file)  PACK_FILE="${2:?--pack-file 需要文件路径}"; shift 2 ;;
    --pack-file=*) PACK_FILE="${1#*=}"; shift ;;
    --dll-list)   DLL_LIST="${2:?--dll-list 需要逗号分隔的 dll 名}"; shift 2 ;;
    --dll-list=*) DLL_LIST="${1#*=}"; shift ;;
    --no-dlls)    DO_DLLS=0; shift ;;
    --no-certs)   DO_CERTS=0; shift ;;
    --no-profile) DO_PROFILE=0; shift ;;
    --force)      FORCE=1; shift ;;
    --dry-run)    DRY=1; shift ;;
    -y|--yes)     shift ;;
    -h|--help)    usage ;;
    -*)           echo "未知参数: $1（用 --help 看用法）" >&2; exit 2 ;;
    *)            TARBALL="$1"; shift ;;
  esac
done

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

c_info() { printf '\033[36m[install]\033[0m %s\n' "$*"; }
c_ok()   { printf '\033[32m[ok]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
c_die()  { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || c_die "需要 root 权限，请用 sudo 运行"

# ---------------------------------------------------------------------------
# 工具探测
# ---------------------------------------------------------------------------
TAR="tar"
for c in gtar /usr/bin/gtar /usr/sfw/bin/gtar tar; do
  if command -v "$c" >/dev/null 2>&1 && "$c" --version >/dev/null 2>&1; then TAR="$c"; break; fi
done
c_info "tar: $(command -v $TAR)"

PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1; then
    if "$c" -c 'import struct, sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' 2>/dev/null; then PY="$c"; break; fi
  fi
done
[ -n "$PY" ] || c_die "需要 python3 来识别 PNSE 空壳程序集（OpenIndiana: pkg install runtime/python-3）"

command -v curl >/dev/null 2>&1 || c_die "需要 curl"
command -v unzip >/dev/null 2>&1 || c_die "需要 unzip"

# ---------------------------------------------------------------------------
# 内嵌 IL 分析器
#   PNSE 空壳的每个方法体恰好是 11 字节：
#       ldstr <msg>; newobj PlatformNotSupportedException::.ctor(string); throw
#   真实现的平均每方法 IL 远大于此（实测 40~70 字节）。
#   这个判据不依赖文件名，也不依赖会被完整版一并携带的资源字符串
#   （"X is not supported on this platform." 两边都有，不能当特征）。
# ---------------------------------------------------------------------------
ILCHECK="$(mktemp "${TMPDIR:-/tmp}/ilcheck.XXXXXX.py")"
trap 'rm -f "$ILCHECK"' EXIT

cat > "$ILCHECK" <<'PYEOF'
#!/usr/bin/env python3
"""ilcheck.py — 判定 .NET 程序集是否为 PNSE 空壳（平台不支持桩）。"""
import os
import re
import struct
import sys

TFM_RE = re.compile(rb"\.NETCoreApp,\s*Version=v(\d+)\.(\d+)")

SHELL_MIN_METHODS = 20
SHELL_MAX_AVG_IL = 25.0
SHELL_MIN_TINY_RATIO = 0.5


def u16(d, o):
    return struct.unpack_from("<H", d, o)[0]


def u32(d, o):
    return struct.unpack_from("<I", d, o)[0]


class Err(Exception):
    pass


def open_pe(data):
    if data[:2] != b"MZ":
        raise Err("no MZ")
    e = u32(data, 0x3C)
    if data[e:e + 4] != b"PE\0\0":
        raise Err("bad PE sig")
    nsec = u16(data, e + 6)
    opt_size = u16(data, e + 20)
    opt = e + 24
    magic = u16(data, opt)
    if magic == 0x10B:
        dd = opt + 96
    elif magic == 0x20B:
        dd = opt + 112
    else:
        raise Err("bad magic")
    secs = []
    so = opt + opt_size
    for i in range(nsec):
        b = so + i * 40
        vsz = u32(data, b + 8)
        va = u32(data, b + 12)
        sraw = u32(data, b + 16)
        praw = u32(data, b + 20)
        secs.append((va, max(vsz, sraw), praw))

    def r2o(rva):
        for va, sz, praw in secs:
            if va <= rva < va + sz:
                return praw + (rva - va)
        raise Err("rva oob")

    return dd, r2o


def streams(data, dd, r2o):
    cli_rva = u32(data, dd + 14 * 8)
    if cli_rva == 0:
        raise Err("no CLI hdr")
    md = r2o(u32(data, r2o(cli_rva) + 8))
    if u32(data, md) != 0x424A5342:
        raise Err("bad md sig")
    p = (md + 16 + u32(data, md + 12) + 3) & ~3
    n = u16(data, p + 2)
    p += 4
    out = {}
    for _ in range(n):
        off = u32(data, p)
        q = p + 8
        nm = b""
        while data[q] != 0:
            nm += bytes([data[q]])
            q += 1
        out[nm.decode("utf-8", "replace")] = md + off
        p = (q + 1 + 3) & ~3
    return out


def analyze(path):
    """返回 (带方法体的方法数, 平均 IL 字节, 11 字节桩占比)。"""
    data = open(path, "rb").read()
    dd, r2o = open_pe(data)
    st = streams(data, dd, r2o)
    key = "#~" if "#~" in st else ("#-" if "#-" in st else None)
    if not key:
        raise Err("no table stream")
    tabs = st[key]
    heap = data[tabs + 6]
    valid = struct.unpack_from("<Q", data, tabs + 8)[0]
    p = tabs + 24
    rows = {}
    for i in range(64):
        if (valid >> i) & 1:
            rows[i] = u32(data, p)
            p += 4
    strw = 4 if heap & 1 else 2
    guidw = 4 if heap & 2 else 2
    blobw = 4 if heap & 4 else 2

    def simple(t):
        return 4 if rows.get(t, 0) >= 65536 else 2

    def coded(tables, bits):
        m = max([rows.get(t, 0) for t in tables] or [0])
        return 4 if m >= (1 << (16 - bits)) else 2

    rs = {
        0: 2 + strw + guidw + guidw + guidw,
        1: coded([0, 0x1A, 0x23, 1], 2) + strw + strw,
        2: 4 + strw + strw + coded([2, 1, 0x1B], 2) + simple(4) + simple(6),
        3: simple(4),
        4: 2 + strw + blobw,
        5: simple(6),
        6: 4 + 2 + 2 + strw + blobw + simple(8),
    }
    off = p
    for i in range(6):
        if i in rows:
            off += rows[i] * rs[i]

    nmeth = total = tiny = 0
    for i in range(rows.get(6, 0)):
        rva = u32(data, off + i * rs[6])
        if rva == 0:
            continue
        try:
            b = r2o(rva)
        except Err:
            continue
        hdr = data[b]
        if (hdr & 3) == 2:
            cs = hdr >> 2
        elif (hdr & 3) == 3:
            cs = u32(data, b + 4)
        else:
            continue
        nmeth += 1
        total += cs
        if cs == 11:
            tiny += 1
    avg = total / nmeth if nmeth else 0.0
    ratio = tiny / nmeth if nmeth else 0.0
    return nmeth, avg, ratio


def is_shell(nmeth, avg, ratio):
    return (nmeth >= SHELL_MIN_METHODS and avg < SHELL_MAX_AVG_IL
            and ratio > SHELL_MIN_TINY_RATIO)


def read_tfm(path):
    """读出程序集声明的 .NETCoreApp 版本，如 net11.0。"""
    with open(path, "rb") as f:
        m = TFM_RE.search(f.read())
    if not m:
        return ""
    major, minor = m.group(1), m.group(2)
    # 正则匹配的是 bytes，不同 Python 版本 group() 返回 bytes，需显式解码
    if isinstance(major, bytes):
        major, minor = major.decode("ascii"), minor.decode("ascii")
    return "net%s.%s" % (major, minor)


def dlls(d):
    if not os.path.isdir(d):
        return []
    return sorted(f for f in os.listdir(d) if f.endswith(".dll"))


def main():
    mode = sys.argv[1]
    if mode == "tfm":
        print(read_tfm(sys.argv[2]))
    elif mode == "stat":
        for f in dlls(sys.argv[2]):
            try:
                nmeth, avg, ratio = analyze(os.path.join(sys.argv[2], f))
            except Exception:
                continue
            print("%s\t%d\t%.1f\t%.2f\t%s" % (f, nmeth, avg, ratio,
                  "SHELL" if is_shell(nmeth, avg, ratio) else "ok"))
    elif mode == "shell":
        for f in dlls(sys.argv[2]):
            try:
                nmeth, avg, ratio = analyze(os.path.join(sys.argv[2], f))
            except Exception:
                continue
            if is_shell(nmeth, avg, ratio):
                print(f)
    elif mode == "plan":
        src, official = sys.argv[2], sys.argv[3]
        off = {}
        for f in dlls(official):
            try:
                nmeth, avg, ratio = analyze(os.path.join(official, f))
                off[f] = is_shell(nmeth, avg, ratio)
            except Exception:
                off[f] = True          # 解析不了就不冒险替换
        for f in dlls(src):
            if f not in off:
                continue
            try:
                nmeth, avg, ratio = analyze(os.path.join(src, f))
            except Exception:
                continue
            if is_shell(nmeth, avg, ratio) and not off[f]:
                print(f)
    else:
        sys.stderr.write("unknown mode\n")
        sys.exit(2)


if __name__ == "__main__":
    main()
PYEOF

# ---------------------------------------------------------------------------
# 1) 解压 / 落位
# ---------------------------------------------------------------------------
STAGE=""
if [ -n "$TARBALL" ]; then
  [ -f "$TARBALL" ] || c_die "找不到 tar 包: $TARBALL"
  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dotnet-install.XXXXXX")"
  c_info "解压 $(basename "$TARBALL") -> $STAGE （约 2.5GB，请稍等）"
  "$TAR" xzf "$TARBALL" -C "$STAGE"
elif [ -x "$SELF_DIR/dotnet" ] && [ -d "$SELF_DIR/shared" ]; then
  STAGE="$SELF_DIR"
  c_info "就地安装（SDK 根: $STAGE）"
elif [ -x "$PREFIX/dotnet" ] && [ -d "$PREFIX/shared" ]; then
  # 幂等重跑：前缀里已经装了，直接就地修补
  STAGE="$PREFIX"
  c_info "使用已安装的前缀 $PREFIX（就地修补）"
else
  c_die "当前目录不像 SDK 根。请解压后进入该目录，或把 tar 包作为参数传进来"
fi

[ -x "$STAGE/dotnet" ] || c_die "$STAGE 下没有可执行的 dotnet"
[ -d "$STAGE/shared" ] || c_die "$STAGE 下没有 shared/"

if [ "$STAGE" != "$PREFIX" ]; then
  if [ "$DRY" = "1" ]; then
    c_info "[dry-run] 将落位 $STAGE -> $PREFIX"
  else
    mkdir -p "$(dirname "$PREFIX")"
    if [ -e "$PREFIX" ] && [ "$FORCE" = "0" ]; then
      OLD="$PREFIX.old-$(date +%Y%m%d-%H%M%S)"
      c_info "前缀已存在，原目录改名为 $OLD"
      mv "$PREFIX" "$OLD"
    elif [ "$FORCE" = "1" ] && [ -e "$PREFIX" ]; then
      c_info "--force：删除已存在的 $PREFIX"
      rm -rf "$PREFIX"
    fi
    c_info "落位 $STAGE -> $PREFIX"
    mv "$STAGE" "$PREFIX"
  fi
fi
STAGE="$PREFIX"

FX_ROOT="$PREFIX/shared/Microsoft.NETCore.App"
[ -d "$FX_ROOT" ] || c_die "$FX_ROOT 不存在，不像是完整的 SDK"
FX="$(ls -d "$FX_ROOT"/*/ 2>/dev/null | tail -1)"
FX="${FX%/}"
RT_VER="$(basename "$FX")"
c_info "框架目录: $FX"
c_info "运行时版本: $RT_VER"

# ---------------------------------------------------------------------------
# 2) CA 证书
# ---------------------------------------------------------------------------
if [ "$DO_CERTS" = "1" ]; then
  CA_SRC=""
  for c in "$SELF_DIR/illumos-ca-bundle.crt" "$SELF_DIR/certs/illumos-ca-bundle.crt" \
           "$PREFIX/illumos-ca-bundle.crt" /opt/illumos-ca-bundle.crt; do
    [ -s "$c" ] && { CA_SRC="$c"; break; }
  done

  if [ -z "$CA_SRC" ]; then
    c_warn "找不到 illumos-ca-bundle.crt，跳过证书安装（NuGet 会报 NU3018）"
  elif [ "$DRY" = "1" ]; then
    c_ok "[dry-run] 将从 $CA_SRC 安装证书到 /etc/ssl/certs 等路径"
  else
    c_info "安装 CA 证书（bundle: $CA_SRC）"
    mkdir -p /etc/ssl/certs /etc/pki/tls/certs /usr/local/share/ca-certificates
    TMPCA="$(mktemp)"
    cat "$CA_SRC" > "$TMPCA"
    # 并入系统原有证书，而不是覆盖
    for s in /etc/certs/ca-certificates.crt /etc/openssl/certs/ca-certificates.crt; do
      [ -s "$s" ] && { cat "$s" >> "$TMPCA"; c_info "  并入系统证书 $s"; break; }
    done
    cp -f "$TMPCA" /etc/ssl/certs/ca-certificates.crt
    cp -f "$TMPCA" /etc/pki/tls/certs/ca-bundle.crt
    cp -f "$TMPCA" /usr/local/share/ca-certificates/ca-certificates.crt
    [ -d /etc/certs ] && cp -f "$TMPCA" /etc/certs/ca-certificates.crt || true

    # 单证书 + 哈希链接（部分库按目录扫描）
    if command -v openssl >/dev/null 2>&1; then
      ( cd /etc/ssl/certs
        awk 'BEGIN{n=0} /BEGIN CERT/{n++; f=sprintf("illumos-%04d.pem", n)} {if(f) print > f} /END CERT/{close(f); f=""}' "$TMPCA"
        for f in illumos-*.pem; do
          [ -e "$f" ] || continue
          h="$(openssl x509 -hash -noout -in "$f" 2>/dev/null || true)"
          [ -n "$h" ] && ln -sf "$f" "$h.0" 2>/dev/null || true
        done ) || c_warn "  拆分证书出错（不影响主 bundle）"
    fi
    rm -f "$TMPCA"
    TOTAL="$(grep -c 'BEGIN CERTIFICATE' /etc/ssl/certs/ca-certificates.crt || echo 0)"
    c_ok "证书已装到 /etc/ssl/certs/ca-certificates.crt（共 $TOTAL 张）"
    if grep -q 'DigiCert Assured ID Root CA' /etc/ssl/certs/ca-certificates.crt 2>/dev/null; then
      c_ok "  含 DigiCert Assured ID Root CA（NuGet 签名链需要）"
    else
      c_warn "  缺 DigiCert Assured ID Root CA，NuGet 可能仍报 NU3018"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 3) 识别并替换 PNSE 空壳 dll
# ---------------------------------------------------------------------------
MJR=""
if [ "$DO_DLLS" = "1" ]; then
  c_info "扫描 PNSE 空壳程序集 ..."
  SHELLS="$("$PY" "$ILCHECK" shell "$FX" 2>/dev/null || true)"

  if [ -n "$DLL_LIST" ]; then
    SHELLS="$(echo "$DLL_LIST" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' || true)"
    c_info "使用 --dll-list 指定的列表"
  fi

  if [ -z "$SHELLS" ]; then
    c_ok "未发现空壳程序集（或该构建已修好），跳过"
  else
    echo "$SHELLS" | sed 's/^/    /'

    # --- 3a) 从空壳 dll 读出 TFM，决定要取哪个版本的 runtime pack ---
    TFM=""
    for f in $SHELLS; do
      [ -f "$FX/$f" ] || continue
      t="$("$PY" "$ILCHECK" tfm "$FX/$f" 2>/dev/null || true)"
      [ -n "$t" ] && { TFM="$t"; break; }
    done
    if [ -z "$TFM" ]; then
      MAJOR0="$(echo "$RT_VER" | cut -d. -f1)"
      TFM="net${MAJOR0}.0"
      c_warn "无法从空壳 dll 读出 TFM，按运行时主版本推断: $TFM"
    else
      c_info "空壳 dll 声明的 TFM: $TFM"
    fi
    MMR="${TFM#net}"                                   # 11.0
    MJR="${MMR%%.*}"                                   # 11
    BUILDNO="$(echo "$RT_VER" | sed -n 's/.*\.\([0-9][0-9][0-9][0-9][0-9][0-9]*\)\..*/\1/p')"
    # 产品版本前缀，如 12.0.0-alpha.1.26473（去掉末尾的构建修订号）。
    # 用它优先锁定同一产品版本 / 同一构建号的 runtime pack，保证程序集版本一致。
    PRODPREF="$(echo "$RT_VER" | sed 's/\.[0-9][0-9]*$//')"
    c_info "主版本=$MJR  TFM=$MMR  构建号=${BUILDNO:-未知}  产品版本前缀=$PRODPREF"

    # --- 3b) 解析 runtime pack 版本 ---
    # 选择原则：版本一致优先于下载速度，尽量用官方（国外）源；国内镜像仅兜底。
    #   nuget.org        正式发布版（最快，实测 1.5MB/s）
    #   dnceng dotnet12  与 SDK 同产品版本（12.0.0-alpha.* 同构建号）的 nightly
    #   dnceng dotnet11  同 TFM 大版本（net11.0）的 nightly
    #   华为云            国内镜像（兜底）
    PRODMAJOR="$(echo "$RT_VER" | cut -d. -f1)"
    SRC_NUGET="https://api.nuget.org/v3-flatcontainer"
    SRC_DNCENG_PROD="https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet${PRODMAJOR}/nuget/v3/flat2"
    SRC_DNCENG_TFM="https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet${MJR}/nuget/v3/flat2"
    SRC_HUAWEI="https://repo.huaweicloud.com/artifactory/api/nuget/v3/nuget-remote"
    if [ -n "$PACK_BASE" ]; then
      SRC_NUGET="$PACK_BASE"
      c_info "自定义下载源: $PACK_BASE"
    fi
    SOURCES="$SRC_NUGET
$SRC_DNCENG_PROD
$SRC_DNCENG_TFM
$SRC_HUAWEI"

    if [ -z "$PACK_VER" ]; then
      if [ -n "$PACK_FILE" ]; then
        PACK_VER=""
      else
        c_info "查询可用的 runtime pack 版本 ..."
        PACK_VER="$("$PY" - "$SOURCES" "$MMR" "$MJR" "${BUILDNO:-}" "$PRODPREF" <<'PYEOF'
import json
import sys
import urllib.request

PKG = "microsoft.netcore.app.runtime.linux-x64"
srcblob, mmr, mjr, buildno, prodpref = sys.argv[1:6]

# 按给出顺序定优先级（靠前更优先），仅用于同分时的取舍
bases = []
for b in srcblob.splitlines():
    b = b.strip()
    if b and b not in bases:
        bases.append(b)


def versions_of(base):
    url = "%s/%s/index.json" % (base.rstrip("/"), PKG)
    with urllib.request.urlopen(url, timeout=30) as r:
        return json.load(r).get("versions", [])


cands = []
for idx, base in enumerate(bases):
    rank = 100 - idx * 5
    try:
        vers = versions_of(base)
    except Exception:
        continue
    for v in vers:
        if prodpref and v.startswith(prodpref + "."):
            s = 100000                  # 同一产品版本 + 同一构建号：最匹配
        elif buildno and (".%s." % buildno) in v:
            s = 10000                   # 同一构建号
        elif v.startswith(mmr + "."):
            s = 1000                    # 同 TFM 大版本
        elif v.startswith(mjr + "."):
            s = 100                     # 同主版本
        else:
            continue
        if "-" not in v:
            s += 10                     # 正式版优先于预览版
        cands.append((s, v, base))

if cands:
    cands.sort(key=lambda x: (x[0], x[1], x[2]))
    print("%s|%s" % (cands[-1][1], cands[-1][2]))
PYEOF
)"
        [ -n "$PACK_VER" ] || c_die "找不到可用的 runtime pack 版本，请用 --pack <版本> 手动指定"
      fi
    fi

    if [ "$DRY" = "1" ]; then
      c_ok "[dry-run] runtime pack: ${PACK_VER:-<--pack-file 指定>}"
      c_ok "[dry-run] 待替换: $(echo "$SHELLS" | tr '\n' ' ')"
    else
      PVER=""; PBASE=""
      if [ -n "$PACK_VER" ]; then
        PVER="${PACK_VER%%|*}"
        PBASE="${PACK_VER##*|}"
        [ "$PBASE" = "$PVER" ] && PBASE="$SRC_NUGET"
        c_info "runtime pack 版本: $PVER"
      fi

      WORK="$(mktemp -d "${TMPDIR:-/tmp}/dotnet-pack.XXXXXX")"
      NUPKG="$WORK/pack.nupkg"

      # 境外夜间源较慢，超时给足（默认 1 小时，可用 DL_TIMEOUT 覆盖）
      DL_TIMEOUT="${DL_TIMEOUT:-3600}"
      # 下载过的 pack 缓存起来，重跑/多机安装时不必再下
      PACK_CACHE="${PACK_CACHE:-/var/cache/illumos-dotnet}"
      PKGID="microsoft.netcore.app.runtime.linux-x64"
      CACHED="$PACK_CACHE/$PKGID.$PVER.nupkg"

      if [ -n "$PACK_FILE" ]; then
        [ -f "$PACK_FILE" ] || c_die "找不到 --pack-file: $PACK_FILE"
        cp -f "$PACK_FILE" "$NUPKG"
        c_info "使用本地 pack: $PACK_FILE"
      elif [ -n "$PVER" ] && [ -s "$CACHED" ]; then
        c_info "使用缓存 pack: $CACHED（$(stat -c%s "$CACHED") 字节）"
        cp -f "$CACHED" "$NUPKG"
      else
        OKDL=0
        for B in "$PBASE" $SOURCES; do
          [ -n "$B" ] || continue
          U="${B%/}/$PKGID/$PVER/$PKGID.$PVER.nupkg"
          c_info "下载 $U"
          c_info "  超时上限 ${DL_TIMEOUT}s（境外源可能较慢，请耐心等待）"
          if curl -fL --connect-timeout 30 --max-time "$DL_TIMEOUT" \
                  --retry 3 --retry-delay 5 \
                  --progress-bar -o "$NUPKG" "$U"; then
            OKDL=1; break
          fi
          c_warn "  该源失败，换下一个"
        done
        [ "$OKDL" = "1" ] || c_die "所有源都下载失败（可用 --pack-file 指定本地包）"
        if [ -n "$PVER" ] && mkdir -p "$PACK_CACHE" 2>/dev/null; then
          cp -f "$NUPKG" "$CACHED" 2>/dev/null && c_info "已缓存到 $CACHED" || true
        fi
      fi
      c_ok "pack 大小 $(stat -c%s "$NUPKG" 2>/dev/null || echo '?') 字节"

      # 解出官方 linux-x64 的托管 dll。
      # 不硬编码 lib 目录名：先看包里实际有哪些 netX.Y，优先取与空壳 TFM 一致的那个。
      OFFDIR="$WORK/official"
      mkdir -p "$OFFDIR" "$WORK/x"
      AVAIL_LIBS="$(unzip -Z1 "$NUPKG" 2>/dev/null \
        | sed -n 's#^runtimes/linux-x64/lib/\(net[0-9][0-9.]*\)/.*#\1#p' | sort -u)"
      USE_LIB=""
      for L in $AVAIL_LIBS; do
        # 目录名形如 net11.0，$TFM 也是 net11.0；$MMR 是去掉 net 前缀的 11.0
        [ "$L" = "$TFM" ] && USE_LIB="$L"
      done
      if [ -z "$USE_LIB" ]; then
        USE_LIB="$(echo "$AVAIL_LIBS" | tail -1)"
      fi
      [ -n "$USE_LIB" ] || c_die "pack 里没有 runtimes/linux-x64/lib/net* 目录"
      [ "$USE_LIB" = "$TFM" ] || c_warn "包内没有 $TFM，改用 $USE_LIB"
      c_info "使用包内 lib 目录: $USE_LIB"

      unzip -q -o "$NUPKG" "runtimes/linux-x64/lib/$USE_LIB/*" -d "$WORK/x" \
        || c_die "从 pack 里解 $USE_LIB 失败"
      cp -f "$WORK/x/runtimes/linux-x64/lib/$USE_LIB/"*.dll "$OFFDIR/" 2>/dev/null || true
      OFFCNT="$(ls "$OFFDIR"/*.dll 2>/dev/null | wc -l | tr -d ' ')"
      [ "${OFFCNT:-0}" -gt 0 ] || c_die "pack 里没有解出任何 dll"
      c_ok "官方 $USE_LIB 参考 dll: $OFFCNT 个"

      # --- 3c) 只替换「illumos 是空壳 且 官方不是空壳」的 ---
      if [ -n "$DLL_LIST" ]; then
        PLAN="$SHELLS"
      else
        PLAN="$("$PY" "$ILCHECK" plan "$FX" "$OFFDIR" 2>/dev/null || true)"
      fi

      if [ -z "$PLAN" ]; then
        c_ok "无需替换（空壳在官方版里同样是桩，属正常）"
      else
        BK="$PREFIX/.pnse-backup-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$BK"
        n=0
        for f in $PLAN; do
          if [ ! -f "$OFFDIR/$f" ]; then
            c_warn "  官方包中没有 $f，跳过"
            continue
          fi
          cp -p "$FX/$f" "$BK/$f"
          cp -f "$OFFDIR/$f" "$FX/$f"
          c_ok "  已替换 $f（$(stat -c%s "$BK/$f") -> $(stat -c%s "$FX/$f") 字节）"
          n=$((n + 1))
        done
        c_ok "共替换 $n 个程序集，原件备份在 $BK"
      fi
      rm -rf "$WORK"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 4) 环境变量
# ---------------------------------------------------------------------------
if [ "$DO_PROFILE" = "1" ]; then
  if [ "$DRY" = "1" ]; then
    c_ok "[dry-run] 将写 /etc/profile.d/illumos-dotnet.sh"
  else
    PROF=/etc/profile.d/illumos-dotnet.sh
    c_info "写 $PROF"
    cat > "$PROF" <<EOF
# .NET SDK (illumos 适配版) —— 由 install-illumos.sh 生成
export DOTNET_ROOT=$PREFIX
case ":\$PATH:" in
  *":$PREFIX:"*) : ;;
  *) PATH="$PREFIX:\$PATH"; export PATH ;;
esac

# 证书：illumos 上 /etc/ssl/certs 默认不存在，且系统库缺微软签名链的老根
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_DIR=/etc/ssl/certs

# 关键：从官方替换进来的程序集带 R2R 预编译代码，illumos 加载会 core dump
export DOTNET_ReadyToRun=0

# 可选：静音 "MSBuild server unavailable ... Falling back to an in-process build"
# export DOTNET_CLI_DO_NOT_USE_MSBUILD_SERVER=1
EOF
    chmod 0644 "$PROF"
    ln -sf "$PREFIX/dotnet" /usr/bin/dotnet 2>/dev/null \
      && c_ok "/usr/bin/dotnet -> $PREFIX/dotnet" || true
    c_ok "已写入（新登录 shell 自动生效）"
  fi
fi

# ---------------------------------------------------------------------------
# 5) 自检
# ---------------------------------------------------------------------------
echo
c_info "===== 自检 ====="
export DOTNET_ROOT="$PREFIX"
export PATH="$PREFIX:$PATH"
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_DIR=/etc/ssl/certs
export DOTNET_ReadyToRun=0
export DOTNET_NOLOGO=1

if [ "$DRY" = "1" ]; then
  c_info "[dry-run] 结束，未做任何改动"
  exit 0
fi

if "$PREFIX/dotnet" --version >/tmp/dnv.txt 2>&1; then
  c_ok "dotnet --version => $(cat /tmp/dnv.txt)"
else
  c_warn "dotnet --version 失败:"
  sed 's/^/    /' /tmp/dnv.txt >&2 || true
fi
rm -f /tmp/dnv.txt

MAJORV="$("$PREFIX/dotnet" --version 2>/dev/null | cut -d. -f1)"
case "$MAJORV" in ''|*[!0-9]*) MAJORV="${MJR:-11}" ;; esac
SMOKE_TFM="net${MAJORV}.0"
c_info "冒烟测试 TFM: $SMOKE_TFM"

SMOKE="$(mktemp -d "${TMPDIR:-/tmp}/dotnet-smoke.XXXXXX")"
cat > "$SMOKE/smoke.csproj" <<EOF
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>$SMOKE_TFM</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NETCore.Platforms" Version="7.0.0" />
  </ItemGroup>
</Project>
EOF
echo 'class P { static void Main() { System.Console.WriteLine("smoke ok"); } }' > "$SMOKE/Program.cs"

c_info "联网 restore 冒烟测试 ..."
if ( cd "$SMOKE" && timeout 180 "$PREFIX/dotnet" restore \
       -p:NETCoreAppMaximumVersion="${MAJORV}.0" -v minimal >/tmp/smoke.log 2>&1 ); then
  c_ok "在线 restore 成功 —— TLS + 证书 + dll 全部正常"
else
  c_warn "在线 restore 失败，日志末尾:"
  tail -n 15 /tmp/smoke.log 2>/dev/null | sed 's/^/    /' >&2 || true
  c_warn "常见原因：网络不通（需代理时设 https_proxy）、或证书/dll 未生效"
fi
rm -rf "$SMOKE" /tmp/smoke.log

echo
c_info "===== 完成 ====="
c_info "安装前缀 : $PREFIX"
c_info "生效方式 : 重新登录，或 source /etc/profile.d/illumos-dotnet.sh"
echo
echo "    export DOTNET_ROOT=$PREFIX PATH=$PREFIX:\$PATH DOTNET_ReadyToRun=0"
echo "    dotnet --info"
