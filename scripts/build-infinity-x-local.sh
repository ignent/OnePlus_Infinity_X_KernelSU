#!/usr/bin/env bash
set -euo pipefail

KERNEL_SHA=dc4c44f3ecc041f550d9c1986ab4d4a8f70312d5
MODULES_SHA=694285bd56d8f299816fae50e6aee18d492da37d
AK3_SHA=0b46673ae91aee8d60bd6ee257b4d56d3f6a0114
BUILD_TOOLS_SHA=434f141b6d22a773a163fa9c707b19b4d254d989
AOSP_CLANG_SHA=1cafe071d3b0cd7f98ab7d310b22dc85be5698cf
AOSP_CLANG_DIR=clang-r563880
PATCHES_SHA=24865a0bc50dfb65b04153cc9ad2879a9c26cc7e
BBG_SHA=75668b6cbd039df0d224e9d14b2a3941c602fd1c
INFINITY_X_LOCALVERSION="-4k-g${KERNEL_SHA:0:12}"
KSU_NEXT_DEV_SUSFS_SHA=e7536f02c4e5bb247239264b99c00d21d6923b2f
KSU_NEXT_DEV_SUSFS_PATCH=ksun/e7536f02c4e5-susfs.patch

ROOT_IMPL=''
ROOT_REF=''
JOBS=$(nproc)
CLEAN=false
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK_DIR="$REPO_ROOT/.local-build"
DIST_DIR="$REPO_ROOT/dist"
CACHE_DIR="$REPO_ROOT/.cache/infinity-x"
LOG_DIR="$REPO_ROOT/logs"

usage() {
  cat <<'EOF'
Usage: scripts/build-infinity-x-local.sh [options]

Build an Infinity-X AnyKernel3 ZIP from the fixed remote source archives.

Options:
  --root <resuki|ksu|ksun|sukisu-ultra>
  --root-ref <branch|tag|commit>
  --work-dir <path>
  --jobs <count>
  --clean
  --help
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  if [[ -n "${LOG:-}" ]]; then
    printf 'Build log: %s\n' "$LOG" >&2
  fi
  exit 1
}

report_failure() {
  local status=$?
  trap - ERR
  printf 'Build failed. Build log: %s\n' "$LOG" >&2
  tail -n 80 "$LOG" >&2 || true
  exit "$status"
}

require_commands() {
  local missing=() command
  for command in git curl tar make clang ld.lld bc bison flex openssl pahole zip rsync jq realpath cp mktemp awk sed patch ln strings; do
    command -v "$command" >/dev/null 2>&1 || missing+=("$command")
  done
  ((${#missing[@]} == 0)) || die "missing required commands: ${missing[*]}"
}

ensure_managed_path() {
  local path=$1
  [[ "$path" == "$REPO_ROOT"/* ]] || die "path must be below repository root: $path"
  [[ "$path" != "$REPO_ROOT" ]] || die 'repository root cannot be used as a work directory'
}

reset_directory() {
  local path=$1
  ensure_managed_path "$path"
  rm -rf -- "$path"
  mkdir -p -- "$path"
}

fetch_github_archive() {
  local owner=$1 repo=$2 revision=$3 destination=$4
  local partial=$5
  local url
  mkdir -p "$destination"
  url="https://codeload.github.com/$owner/$repo/tar.gz/$revision"
  if ! download_archive "$url" "$partial"; then
    return 1
  fi
  if ! tar -xzf "$partial" --strip-components=1 -C "$destination"; then
    rm -f -- "$partial"
    return 1
  fi
  rm -f -- "$partial"
}

fetch_gitlab_archive() {
  local project=$1 revision=$2 destination=$3
  local partial=$4
  local url
  mkdir -p "$destination"
  url="https://git.codelinaro.org/$project/-/archive/$revision/archive-$revision.tar.gz"
  if ! download_archive "$url" "$partial"; then
    return 1
  fi
  if ! tar -xzf "$partial" --strip-components=1 -C "$destination"; then
    rm -f -- "$partial"
    return 1
  fi
  rm -f -- "$partial"
}

fetch_susfs_archive() {
  local revision=$1 destination=$2
  local partial=$3
  local url
  mkdir -p "$destination"
  url="https://gitlab.com/simonpunk/susfs4ksu/-/archive/$revision/susfs4ksu-$revision.tar.gz"
  if ! download_archive "$url" "$partial"; then
    return 1
  fi
  if ! tar -xzf "$partial" --strip-components=1 -C "$destination"; then
    rm -f -- "$partial"
    return 1
  fi
  rm -f -- "$partial"
}

fetch_aosp_clang_archive() {
  local revision=$1 destination=$2 partial=$3
  local url
  mkdir -p "$destination"
  url="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/$revision/$AOSP_CLANG_DIR.tar.gz"
  if ! download_archive "$url" "$partial"; then
    return 1
  fi
  if ! tar -xzf "$partial" -C "$destination"; then
    rm -f -- "$partial"
    return 1
  fi
  rm -f -- "$partial"
}

download_archive() {
  local url=$1 partial=$2 attempt status
  for attempt in 1 2 3; do
    if [[ -s "$partial" ]]; then
      printf 'Partial archive exists at %s; resuming\n' "$partial"
    fi
    if curl --fail --location --proto '=https' --http1.1 --connect-timeout 30 \
      --speed-limit 1024 --speed-time 60 --max-time 1800 -LSs \
      --continue-at - --output "$partial" "$url"; then
      return
    else
      status=$?
    fi
    if ((status == 33)); then
      printf 'Remote does not support resuming; restarting archive download\n'
      rm -f -- "$partial"
    fi
    if ((attempt < 3)); then
      sleep 5
    fi
  done
  return 1
}

cache_or_fetch() {
  local cache=$1 required_path=$2 fetcher=$3
  shift 3
  if [[ -f "$cache/.infinity-x-cache" ]] && [[ -e "$cache/$required_path" ]]; then
    printf 'Local cache exists at %s\n' "$cache"
    return
  fi

  rm -rf -- "$cache"
  mkdir -p "$(dirname "$cache")"
  local temporary partial
  temporary=$(mktemp -d "$(dirname "$cache")/.tmp.XXXXXX")
  partial="$cache.archive.tar.gz.partial"
  if ! "$fetcher" "$@" "$temporary" "$partial"; then
    rm -rf -- "$temporary"
    die "source download failed: $cache"
  fi
  [[ -e "$temporary/$required_path" ]] || die "cached source validation failed: $cache"
  : > "$temporary/.infinity-x-cache"
  mv -- "$temporary" "$cache"
}

copy_cache_tree() {
  local cache=$1 destination=$2
  mkdir -p "$destination"
  cp -a "$cache/." "$destination/"
  rm -f "$destination/.infinity-x-cache"
}

cache_github_archive() {
  local owner=$1 repo=$2 revision=$3 destination=$4 required_path=$5
  local cache="$CACHE_DIR/github/$owner/$repo/$revision"
  cache_or_fetch "$cache" "$required_path" fetch_github_archive \
    "$owner" "$repo" "$revision"
  copy_cache_tree "$cache" "$destination"
}

cache_gitlab_archive() {
  local project=$1 revision=$2 destination=$3 required_path=$4
  local cache="$CACHE_DIR/gitlab/$project/$revision"
  cache_or_fetch "$cache" "$required_path" fetch_gitlab_archive \
    "$project" "$revision"
  copy_cache_tree "$cache" "$destination"
}

cache_susfs_archive() {
  local revision=$1 destination=$2
  local cache="$CACHE_DIR/gitlab/simonpunk/susfs4ksu/$revision"
  cache_or_fetch "$cache" kernel_patches/include/linux/susfs.h fetch_susfs_archive "$revision"
  copy_cache_tree "$cache" "$destination"
}

cache_aosp_clang_archive() {
  local destination=$1
  local cache="$CACHE_DIR/aosp/platform/prebuilts/clang/host/linux-x86/$AOSP_CLANG_SHA/$AOSP_CLANG_DIR"
  cache_or_fetch "$cache" bin/clang fetch_aosp_clang_archive "$AOSP_CLANG_SHA"
  copy_cache_tree "$cache" "$destination"
}

cache_root_mirror() {
  ROOT_CACHE="$CACHE_DIR/root/$ROOT_REPO/$ROOT_SHA.git"
  if [[ -f "$ROOT_CACHE/HEAD" ]] && git --git-dir="$ROOT_CACHE" cat-file -e "$ROOT_SHA^{commit}" 2>/dev/null; then
    printf 'Local cache exists at %s\n' "$ROOT_CACHE"
    return
  fi
  rm -rf -- "$ROOT_CACHE"
  mkdir -p "$(dirname "$ROOT_CACHE")"
  git clone --mirror "https://github.com/$ROOT_REPO.git" "$ROOT_CACHE"
  git --git-dir="$ROOT_CACHE" cat-file -e "$ROOT_SHA^{commit}" \
    || die "root revision is absent from cached mirror: $ROOT_SHA"
}

setup_root() {
  cache_root_mirror
  git --git-dir="$ROOT_CACHE" show "$ROOT_SHA:kernel/setup.sh" \
    | (
      cd "$PLATFORM"
      export GIT_CONFIG_COUNT=1
      export GIT_CONFIG_KEY_0="url.file://$ROOT_CACHE.insteadOf"
      export GIT_CONFIG_VALUE_0="https://github.com/$ROOT_REPO.git"
      bash -s "$ROOT_SHA"
    )
}

select_root_interactively() {
  [[ -t 0 ]] || die '--root is required when stdin is not a terminal'
  PS3='Select root implementation: '
  select ROOT_IMPL in resuki ksu ksun sukisu-ultra; do
    [[ -n "$ROOT_IMPL" ]] && return
    printf 'Invalid selection.\n' >&2
  done
}

resolve_root() {
  case "$ROOT_IMPL" in
    resuki)
      ROOT_REPO=ReSukiSU/ReSukiSU
      ROOT_DEFAULT_REF=main
      ROOT_DIR_NAME=KernelSU
      ROOT_ARTIFACT_ID=RESUKI
      ;;
    ksu)
      ROOT_REPO=tiann/KernelSU
      ROOT_DEFAULT_REF=main
      ROOT_DIR_NAME=KernelSU
      ROOT_ARTIFACT_ID=KSU
      ;;
    ksun)
      ROOT_REPO=KernelSU-Next/KernelSU-Next
      ROOT_DEFAULT_REF=dev
      ROOT_DIR_NAME=KernelSU-Next
      ROOT_ARTIFACT_ID=KSUN
      ;;
    sukisu-ultra)
      ROOT_REPO=SukiSU-Ultra/SukiSU-Ultra
      ROOT_DEFAULT_REF=main
      ROOT_DIR_NAME=KernelSU
      ROOT_ARTIFACT_ID=SUKISU-ULTRA
      ;;
    *)
      die "--root must be one of: resuki|ksu|ksun|sukisu-ultra"
      ;;
  esac

  ROOT_REF=${ROOT_REF:-$ROOT_DEFAULT_REF}
  if [[ "$ROOT_REF" =~ ^[0-9a-f]{40}$ ]]; then
    ROOT_SHA=$ROOT_REF
  else
    ROOT_SHA=$(git ls-remote "https://github.com/$ROOT_REPO.git" \
      "refs/heads/$ROOT_REF" "refs/tags/$ROOT_REF" | awk 'NR == 1 { print $1 }')
  fi
  [[ "$ROOT_SHA" =~ ^[0-9a-f]{40}$ ]] || die "cannot resolve $ROOT_REPO ref: $ROOT_REF"
}

append_root_config() {
  local defconfig=$1
  cat >> "$defconfig" <<'EOF'
CONFIG_KSU=y
EOF
  if [[ "$ROOT_IMPL" == sukisu-ultra ]]; then
    echo 'CONFIG_KPM=y' >> "$defconfig"
  fi
}

should_integrate_susfs() {
  [[ "$ROOT_IMPL" != sukisu-ultra ]]
}

append_susfs_config() {
  local defconfig=$1
  cat >> "$defconfig" <<'EOF'
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_OVERLAYFS=n
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_SUS_SU=n
EOF
}

fix_pkcs11_key_pass() {
  local source="$COMMON/certs/extract-cert.c"
  [[ $(grep -c '^#ifdef USE_PKCS11_ENGINE$' "$source") -eq 2 ]] \
    || die 'unexpected extract-cert PKCS#11 declaration layout'
  sed -i '/^#ifdef USE_PKCS11_ENGINE$/,/^#endif$/ { /^#ifdef USE_PKCS11_ENGINE$/d; /^#endif$/d; }' "$source"
}

install_bbg() {
  local kernel=$1 bbg=$2 defconfig=$3
  local makefile="$kernel/security/Makefile" kconfig="$kernel/security/Kconfig"

  [[ -f "$bbg/Kconfig" ]] || die "BBG Kconfig is missing: $bbg/Kconfig"
  [[ -f "$makefile" && -f "$kconfig" ]] || die 'kernel security build files are missing'
  ln -sfn "$bbg" "$kernel/security/baseband-guard"
  grep -Fqx 'obj-$(CONFIG_BBG) += baseband-guard/' "$makefile" \
    || printf '\nobj-$(CONFIG_BBG) += baseband-guard/\n' >> "$makefile"
  if ! grep -Fq 'source "security/baseband-guard/Kconfig"' "$kconfig"; then
    awk '
      { line[NR] = $0 }
      END {
        last = 0
        for (i = 1; i <= NR; i++) if (line[i] ~ /^endmenu[[:space:]]*$/) last = i
        for (i = 1; i <= NR; i++) {
          if (i == last) print "source \"security/baseband-guard/Kconfig\""
          print line[i]
        }
      }
    ' "$kconfig" > "$kconfig.tmp" \
    && mv "$kconfig.tmp" "$kconfig"
  fi
  printf 'CONFIG_BBG=y\n' >> "$defconfig"
  sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' "$kconfig"
}

apply_feature_patch() {
  local kernel=$1 patches=$2 patch_name=$3
  local patch_path="$patches/$patch_name"
  [[ -f "$patch_path" ]] || die "feature patch is missing: $patch_name"
  patch --directory="$kernel" -p1 --forward --batch < "$patch_path"
}

apply_clear_page_alignment_patch() {
  local kernel=$1 patches=$2
  local patch_path="$patches/common/clear_page_16bytes_align.patch"
  [[ -f "$patch_path" ]] || die 'feature patch is missing: common/clear_page_16bytes_align.patch'
  sed 's/SYM_FUNC_START_PI(clear_page)/SYM_FUNC_START_PI(__pi_clear_page)/' "$patch_path" \
    | patch --directory="$kernel" -p1 -F3 --forward --batch
}

validate_root_susfs_compatibility() {
  local kernel=$1

  case "$ROOT_IMPL" in
    resuki|ksu|ksun)
      return
      ;;
    sukisu-ultra)
      if grep -Eq '^config KSU_SUSFS([[:space:]]|$)' "$kernel/Kconfig"; then
        return
      fi
      die "$ROOT_IMPL root $ROOT_SHA does not provide native SUSFS support; use a compatible --root-ref"
      ;;
  esac
}

apply_ksun_dev_susfs_adapter() {
  local kernel=$1 patches=$2
  local patch_path="$patches/$KSU_NEXT_DEV_SUSFS_PATCH"

  [[ "$ROOT_SHA" == "$KSU_NEXT_DEV_SUSFS_SHA" ]] \
    || die "KSU-Next dev SUSFS adapter is not available for $ROOT_SHA; update scripts/patches/ksun"
  [[ -f "$patch_path" ]] || die "KSU-Next dev SUSFS adapter is missing: $patch_path"
  if ! patch --directory="$kernel" -p1 --forward --batch --dry-run < "$patch_path"; then
    die "KSU-Next dev SUSFS adapter is incompatible with $ROOT_SHA; update scripts/patches/ksun"
  fi
  patch --directory="$kernel" -p1 --forward --batch < "$patch_path"
}

apply_ksu_susfs_clang_compatibility() {
  local kernel=$1 source="$kernel/kernel/feature/selinux_hide.c"

  [[ -f "$source" ]] || die "KSU SELinux source is missing: $source"
  grep -Eq '^extern (__weak )?void security_dump_masked_av_fn\(' "$source" \
    || die 'unexpected KSU security_dump_masked_av_fn declaration'
  grep -Eq '^extern (__weak )?void context_struct_compute_av_fn\(' "$source" \
    || die 'unexpected KSU context_struct_compute_av_fn declaration'
  sed -i \
    -e 's/^extern void security_dump_masked_av_fn(/extern __weak void security_dump_masked_av_fn(/' \
    -e 's/^extern void context_struct_compute_av_fn(/extern __weak void context_struct_compute_av_fn(/' \
    "$source"
  grep -Fq 'extern __weak void security_dump_masked_av_fn' "$source" \
    || die 'failed to mark security_dump_masked_av_fn weak'
  grep -Fq 'extern __weak void context_struct_compute_av_fn' "$source" \
    || die 'failed to mark context_struct_compute_av_fn weak'
}

apply_root_susfs_compatibility() {
  local kernel=$1 susfs=$2 patches=$3
  local susfs_patch="$susfs/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"

  case "$ROOT_IMPL" in
    resuki|sukisu-ultra)
      echo "Using $ROOT_IMPL native SUSFS support"
      ;;
    ksun)
      apply_ksun_dev_susfs_adapter "$kernel" "$REPO_ROOT/scripts/patches"
      ;;
    ksu)
      if ! patch --directory="$kernel" -p1 --forward --batch --dry-run < "$susfs_patch"; then
        die "SUSFS conversion is incompatible with ksu root $ROOT_SHA; use a compatible --root-ref"
      fi
      patch --directory="$kernel" -p1 --forward --batch < "$susfs_patch"
      apply_ksu_susfs_clang_compatibility "$kernel"
      ;;
  esac
}

apply_optimisation_patches() {
  local kernel=$1 patches=$2 patch_name
  local patch_names=(
    common/optimized_mem_operations.patch
    common/file_struct_8bytes_align.patch
    common/reduce_cache_pressure.patch
    common/mem_opt_prefetch.patch
    common/optimise_memcmp.patch
    common/minimise_wakeup_time.patch
    common/int_sqrt.patch
    common/force_tcp_nodelay.patch
    common/reduce_gc_thread_sleep_time.patch
    common/add_timeout_wakelocks_globally.patch
    common/f2fs_reduce_congestion.patch
    common/reduce_freeze_timeout.patch
    common/clear_page_16bytes_align.patch
    common/add_limitation_scaling_min_freq.patch
    common/re_write_limitation_scaling_min_freq.patch
    common/adjust_cpu_scan_order.patch
    common/avoid_extra_s2idle_wake_attempts.patch
    common/disable_cache_hot_buddy.patch
    common/f2fs_enlarge_min_fsync_blocks.patch
    common/increase_ext4_default_commit_age.patch
    common/increase_sk_mem_packets.patch
    common/reduce_pci_pme_wakeups.patch
    common/silence_irq_cpu_logspam.patch
    common/silence_system_logspam.patch
    common/use_unlikely_wrap_cpufreq.patch
  )
  for patch_name in "${patch_names[@]}"; do
    if [[ "$patch_name" == common/clear_page_16bytes_align.patch ]]; then
      apply_clear_page_alignment_patch "$kernel" "$patches"
    else
      apply_feature_patch "$kernel" "$patches" "$patch_name"
    fi
  done
}

apply_ntsync_patch() {
  local kernel=$1 patches=$2 defconfig=$3
  apply_feature_patch "$kernel" "$patches" common/ntsync/ntsync_compat_android15-6.6.patch
  apply_feature_patch "$kernel" "$patches" common/ntsync/ntsync_base.patch
  printf 'CONFIG_NTSYNC=y\n' >> "$defconfig"
}

apply_unicode_patch() {
  local kernel=$1 patches=$2
  apply_feature_patch "$kernel" "$patches" common/unicode_bypass_fix_6.1+.patch
}

append_network_configs() {
  local defconfig=$1
  apply_feature_patch "$COMMON" "$PATCHES" common/bbrv3/0001-net-tcp-backport-BBRv3-to-android15-6.6.patch
  cat >> "$defconfig" <<'EOF'
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_TCP_CONG_BBR3=y
CONFIG_NET_SCH_FQ=y
CONFIG_NET_SCH_FQ_CODEL=y
CONFIG_NET_SCH_CAKE=y
CONFIG_NET_SCH_PIE=y
CONFIG_NET_SCH_FQ_PIE=y
CONFIG_IP_NF_TARGET_TTL=y
CONFIG_IP6_NF_TARGET_HL=y
CONFIG_IP6_NF_MATCH_HL=y
CONFIG_BPF_STREAM_PARSER=y
CONFIG_IP_SET=y
CONFIG_IP_SET_MAX=65534
CONFIG_IP_SET_BITMAP_IP=y
CONFIG_IP_SET_BITMAP_IPMAC=y
CONFIG_IP_SET_BITMAP_PORT=y
CONFIG_IP_SET_HASH_IP=y
CONFIG_IP_SET_HASH_IPMARK=y
CONFIG_IP_SET_HASH_IPPORT=y
CONFIG_IP_SET_HASH_IPPORTIP=y
CONFIG_IP_SET_HASH_IPPORTNET=y
CONFIG_IP_SET_HASH_IPMAC=y
CONFIG_IP_SET_HASH_MAC=y
CONFIG_IP_SET_HASH_NETPORTNET=y
CONFIG_IP_SET_HASH_NET=y
CONFIG_IP_SET_HASH_NETNET=y
CONFIG_IP_SET_HASH_NETPORT=y
CONFIG_IP_SET_HASH_NETIFACE=y
CONFIG_IP_SET_LIST_SET=y
CONFIG_NETFILTER_XT_MATCH_ADDRTYPE=y
CONFIG_NETFILTER_XT_SET=y
CONFIG_IP6_NF_NAT=y
CONFIG_IP6_NF_TARGET_MASQUERADE=y
EOF
}

apply_droidspaces_patches() {
  local kernel=$1 patches=$2 defconfig=$3
  apply_feature_patch "$kernel" "$patches" common/droidspaces/fix_sysvipc_kabi_6_7_8.patch
  apply_feature_patch "$kernel" "$patches" common/droidspaces/0001-Return-ghost-task-if-task-is-null-and-is-requested-b.patch
  cat >> "$defconfig" <<'EOF'
CONFIG_SYSVIPC=y
CONFIG_DEVTMPFS=y
CONFIG_PID_NS=y
CONFIG_POSIX_MQUEUE=y
CONFIG_NETFILTER_XT_TARGET_REJECT=y
CONFIG_NETFILTER_XT_TARGET_LOG=y
CONFIG_NETFILTER_XT_MATCH_RECENT=y
CONFIG_USER_NS=y
CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE=y
CONFIG_CC_OPTIMIZE_FOR_PERFORMANCE_O3=n
CONFIG_OPTIMIZE_INLINING=y
CONFIG_FRAME_WARN=0
CONFIG_TRACEPOINTS=y
EOF
}

apply_fake_config_patch() {
  local kernel=$1 patches=$2
  apply_feature_patch "$kernel" "$patches" common/fake_config.patch
}

validate_kernel_version_metadata() {
  local image=$1 version_line
  local timestamp_regex='#[0-9]+( [[:upper:]_]+)* (Mon|Tue|Wed|Thu|Fri|Sat|Sun) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [0-9]{1,2} [0-9]{2}:[0-9]{2}:[0-9]{2} [[:upper:]]{2,5} [0-9]{4}$'
  version_line=$(strings "$image" | grep -m1 '^Linux version ' || true)
  if ! [[ "$version_line" =~ $timestamp_regex ]]; then
    die "Image has an invalid Linux version timestamp: ${version_line:-missing Linux version line}"
  fi
}

while (($#)); do
  case "$1" in
    --root)
      (($# >= 2)) || die '--root requires a value'
      ROOT_IMPL=$2
      shift 2
      ;;
    --root-ref)
      (($# >= 2)) || die '--root-ref requires a value'
      ROOT_REF=$2
      shift 2
      ;;
    --work-dir)
      (($# >= 2)) || die '--work-dir requires a value'
      WORK_DIR=$2
      shift 2
      ;;
    --jobs)
      (($# >= 2)) || die '--jobs requires a value'
      JOBS=$2
      shift 2
      ;;
    --clean)
      CLEAN=true
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ "$JOBS" =~ ^[1-9][0-9]*$ ]] || die '--jobs must be a positive integer'
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/infinity-x-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "$LOG") 2>&1
trap report_failure ERR
WORK_DIR=$(realpath -m "$WORK_DIR")
ensure_managed_path "$WORK_DIR"
[[ -n "$ROOT_IMPL" ]] || select_root_interactively
resolve_root
require_commands

if [[ "$CLEAN" == true ]]; then
  reset_directory "$WORK_DIR"
else
  mkdir -p "$WORK_DIR"
fi

PLATFORM="$WORK_DIR/kernel_platform"
COMMON="$PLATFORM/common"
MODULES="$PLATFORM/sm8750-modules"
SUSFS="$WORK_DIR/susfs4ksu"
AK3="$WORK_DIR/AnyKernel3"
PATCHES="$WORK_DIR/kernel_patches"
BBG="$WORK_DIR/Baseband-guard"
OUT="$COMMON/out"

for path in "$PLATFORM" "$MODULES" "$SUSFS" "$AK3" "$PATCHES" "$BBG"; do
  reset_directory "$path"
done

echo "==> Downloading Infinity-X kernel source"
cache_github_archive Ace6-Development android_kernel_oneplus_sm8750 "$KERNEL_SHA" "$COMMON" Makefile
echo "==> Downloading Infinity-X modules source"
cache_github_archive Ace6-Development android_kernel_oneplus_sm8750-modules "$MODULES_SHA" "$MODULES" Android.bp
echo "==> Downloading pinned feature patches"
cache_github_archive WildKernels kernel_patches "$PATCHES_SHA" "$PATCHES" common/fake_config.patch
echo "==> Downloading pinned BBG"
cache_github_archive vc-teahouse Baseband-guard "$BBG_SHA" "$BBG" Kconfig
echo "==> Downloading pinned build tools"
cache_gitlab_archive 'clo/la/kernel/prebuilts/build-tools' "$BUILD_TOOLS_SHA" "$PLATFORM/prebuilts/kernel-build-tools" linux-x86/bin/pahole
echo "==> Downloading pinned AOSP clang"
cache_aosp_clang_archive "$PLATFORM/prebuilts/clang/host/linux-x86/$AOSP_CLANG_DIR"
echo "==> Downloading pinned AnyKernel3"
cache_github_archive WildKernels AnyKernel3 "$AK3_SHA" "$AK3" anykernel.sh

CLANG_BIN="$PLATFORM/prebuilts/clang/host/linux-x86/$AOSP_CLANG_DIR/bin"
[[ -x "$CLANG_BIN/clang" ]] || die "pinned clang not found: $CLANG_BIN/clang"
export PATH="$CLANG_BIN:$PLATFORM/prebuilts/kernel-build-tools/linux-x86/bin:$PATH"
export LLVM=1 LLVM_IAS=1
export ARCH=arm64 SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export PAHOLE="$PLATFORM/prebuilts/kernel-build-tools/linux-x86/bin/pahole"
export LD=ld.lld HOSTLD=ld.lld AR=llvm-ar NM=llvm-nm
export OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip

echo "==> Injecting $ROOT_IMPL at ${ROOT_SHA:0:12}"
setup_root
ROOT_DIR="$PLATFORM/$ROOT_DIR_NAME"
[[ -d "$ROOT_DIR" ]] || die "root setup did not create $ROOT_DIR"
if should_integrate_susfs; then
  validate_root_susfs_compatibility "$ROOT_DIR/kernel"
  SUSFS_REF=gki-android15-6.6
  SUSFS_SHA=$(git ls-remote https://gitlab.com/simonpunk/susfs4ksu.git "refs/heads/$SUSFS_REF" | awk 'NR == 1 { print $1 }')
  [[ "$SUSFS_SHA" =~ ^[0-9a-f]{40}$ ]] || die "cannot resolve SUSFS ref: $SUSFS_REF"
  echo "==> Downloading SUSFS at ${SUSFS_SHA:0:12}"
  cache_susfs_archive "$SUSFS_SHA" "$SUSFS"
  cp "$SUSFS/kernel_patches/fs/"* "$COMMON/fs/"
  cp "$SUSFS/kernel_patches/include/linux/"* "$COMMON/include/linux/"
  patch --directory="$COMMON" -p1 --forward --batch --fuzz=3 \
    < "$SUSFS/kernel_patches/50_add_susfs_in_gki-android15-6.6.patch"
  apply_root_susfs_compatibility "$ROOT_DIR" "$SUSFS" "$PATCHES"
else
  echo 'Skipping SUSFS integration for SukiSU-Ultra'
fi

DEFCONFIG="$COMMON/arch/arm64/configs/gki_defconfig"
append_root_config "$DEFCONFIG"
if should_integrate_susfs; then
  append_susfs_config "$DEFCONFIG"
fi
install_bbg "$COMMON" "$BBG" "$DEFCONFIG"
apply_optimisation_patches "$COMMON" "$PATCHES"
apply_ntsync_patch "$COMMON" "$PATCHES" "$DEFCONFIG"
apply_unicode_patch "$COMMON" "$PATCHES"
append_network_configs "$DEFCONFIG"
apply_droidspaces_patches "$COMMON" "$PATCHES" "$DEFCONFIG"
apply_fake_config_patch "$COMMON" "$PATCHES"
fix_pkcs11_key_pass

echo 'Skipping module overlay: no KMI-matched Infinity-X module is available'
export CONFIG_FAKE_DISABLE='CONFIG_TCP_CONG_ADVANCED CONFIG_IP6_NF_NAT'
export KBUILD_BUILD_USER=OnePlus
export KBUILD_BUILD_HOST=ubuntu-build
export KBUILD_BUILD_VERSION=1
export KBUILD_BUILD_TIMESTAMP="$(LC_ALL=C date -u)"
echo "==> Building Image"
make -C "$COMMON" O="$OUT" gki_defconfig
"$COMMON/scripts/config" --file "$OUT/.config" --set-str LOCALVERSION "$INFINITY_X_LOCALVERSION"
"$COMMON/scripts/config" --file "$OUT/.config" -d LOCALVERSION_AUTO
sed -i 's/scm_version="$(scm_version --short)"/scm_version=""/' "$COMMON/scripts/setlocalversion"
make -C "$COMMON" -j"$JOBS" O="$OUT" Image
IMAGE="$OUT/arch/arm64/boot/Image"
[[ -s "$IMAGE" ]] || die "Image was not produced: $IMAGE"
validate_kernel_version_metadata "$IMAGE"

grep -Fq 'do.check_boot_version=0' "$AK3/anykernel.sh" || die 'remote AnyKernel3 boot-version policy changed unexpectedly'
"$REPO_ROOT/scripts/prepare-ak3-bbr3-service.sh" "$AK3"
cp "$IMAGE" "$AK3/Image"
mkdir -p "$DIST_DIR"
SUSFS_TAG=_SuSFS
if ! should_integrate_susfs; then
  SUSFS_TAG=''
fi
ZIP_NAME="AK3_OP-ACE-6-INFINITY-X_A16_$(make -s -C "$COMMON" O="$OUT" kernelrelease)_${ROOT_ARTIFACT_ID}_${ROOT_SHA:0:8}${SUSFS_TAG}.zip"
(
  cd "$AK3"
  zip -r9 "$DIST_DIR/$ZIP_NAME" . -x '*.git*' -x 'README.md'
)
sha256sum "$DIST_DIR/$ZIP_NAME" | tee "$DIST_DIR/$ZIP_NAME.sha256"
printf 'Built %s\n' "$DIST_DIR/$ZIP_NAME"
