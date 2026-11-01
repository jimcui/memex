#!/usr/bin/env bash
# =============================================================================
# Memex 自定义文件夹版 —— 一键重编脚本
#
# 用途：官方发新版后，自动拉源码、合入「恢复自定义文件夹」补丁、编译、签名。
#
# 用法：
#   ./rebuild_memex.sh                    # 用最新 GitHub release 或 master
#   ./rebuild_memex.sh android-early-20261021-abc1234   # 指定 tag
#   ./rebuild_memex.sh --check            # 只看官方有无新版，不编译
#
# 首次运行前需确认（脚本会自动检查并提示）：
#   - Flutter SDK          /opt/flutter
#   - Android SDK          /opt/asdk
#   - 签名 keystore        /tmp/resign/xplore.ks
# =============================================================================
set -euo pipefail

# ---------- 可配置参数 ----------
FLUTTER_HOME="${FLUTTER_HOME:-/opt/flutter}"
ANDROID_SDK="${ANDROID_SDK:-/opt/asdk}"
KEYSTORE="${KEYSTORE:-/tmp/resign/xplore.ks}"
KEY_ALIAS="${KEY_ALIAS:-xplore}"
KS_PASS="${KS_PASS:-xplore123}"
WORKDIR="${WORKDIR:-/tmp/memex-src}"
OUTDIR="${OUTDIR:-/workspace}"
REPO="memex-lab/memex"
PROXY="https://gh-proxy.com/"
# flavor 由 tag 类型自动决定（见 pick_flavor）
FLAVOR="cnEarly"
GRADLE_TASK="assembleCnEarlyRelease"
export PATH="$FLUTTER_HOME/bin:$PATH"
export ANDROID_HOME="$ANDROID_SDK"
export ANDROID_SDK_ROOT="$ANDROID_SDK"

# ---------- 输出着色 ----------
info()  { printf '\033[36m[信息]\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m[成功]\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m[注意]\033[0m %s\n' "$*"; }
die()   { printf '\033[31m[失败]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- 1. 环境检查 ----------
check_env() {
  info "检查构建环境..."
  [ -x "$FLUTTER_HOME/bin/flutter" ] || die "未找到 Flutter：$FLUTTER_HOME/bin/flutter"
  [ -d "$ANDROID_SDK/platforms" ]    || die "未找到 Android SDK：$ANDROID_SDK"
  [ -f "$KEYSTORE" ]                 || die "未找到签名密钥：$KEYSTORE"
  command -v java >/dev/null         || die "未找到 java"
  command -v curl >/dev/null         || die "未找到 curl"
  ok "环境就绪：$(flutter --version 2>/dev/null | head -1)"
}

# ---------- 2. 查官方版本 ----------
latest_tag() {
  curl -s -m 30 "${PROXY}https://api.github.com/repos/${REPO}/releases/latest" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('tag_name',''))"
}

latest_daily_tag() {
  curl -s -m 30 "${PROXY}https://api.github.com/repos/${REPO}/releases?per_page=15" \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
for r in d:
    if r.get('tag_name','').startswith('android-early-'):
        print(r['tag_name']); break
"
}

# 根据 tag 推导 flavor：
#   v1.0.x 之类稳定版 -> cn
#   android-early-*   -> cnEarly
pick_flavor() {
  local tag="$1"
  case "$tag" in
    android-early-*|*early*)
      FLAVOR="cnEarly"; GRADLE_TASK="assembleCnEarlyRelease";;
    *)
      FLAVOR="cn";      GRADLE_TASK="assembleCnRelease";;
  esac
  info "目标 flavor：$FLAVOR（对应包名 com.memexlab.memex.${FLAVOR%Early}${FLAVOR:+}）"
}

# ---------- 3. 同步源码 ----------
sync_src() {
  local tag="$1"
  if [ ! -d "$WORKDIR/.git" ]; then
    info "首次克隆源码..."
    git clone "${PROXY}https://github.com/${REPO}.git" "$WORKDIR"
  fi
  cd "$WORKDIR"

  info "拉取最新提交..."
  git fetch --depth 50 origin 2>/dev/null || git fetch origin

  if [ -n "$tag" ]; then
    info "检出 tag：$tag"
    git checkout -f "$tag" 2>/dev/null || {
      # release tag 可能不在默认分支历史里，按 commit 拉
      local sha
      sha=$(curl -s -m 30 "${PROXY}https://api.github.com/repos/${REPO}/git/ref/tags/${tag}" \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('object',{}).get('sha',''))" 2>/dev/null || true)
      [ -n "$sha" ] || die "无法解析 tag：$tag"
      git fetch --depth 1 origin "$sha" && git checkout -f "$sha"
    }
  else
    git checkout -f origin/main 2>/dev/null || git checkout -f main
    tag="main"
  fi
  ok "源码就绪：$(git rev-parse --short HEAD)"
}

# ---------- 4. 打补丁（幂等） ----------
apply_patch() {
  cd "$WORKDIR"
  local page="lib/ui/settings/widgets/data_storage_page.dart"
  local manifest="android/app/src/main/AndroidManifest.xml"

  # --- 补丁 1：Android 分支恢复 customCard ---
  if grep -q "add(customCard);" "$page" && grep -A2 "Android: restore custom folder" "$page" | grep -q "add(customCard)"; then
    ok "补丁1 已存在，跳过"
  else
    info "应用补丁1：恢复 Android 自定义文件夹卡片"
    python3 - "$page" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
# 匹配 Android 分支：任何把 add(appCard) 单独放在 else 里的写法
pat = re.compile(r'(\}\s*else\s*\{\s*\n)(\s*)(//[^\n]*\n\s*)?(add\(appCard\);)')
new, n = pat.subn(
    lambda m: f'{m.group(1)}{m.group(2)}// Android: restore custom folder option\n'
              f'{m.group(2)}add(customCard);\n{m.group(2)}{m.group(4)}',
    s, count=1)
if n == 0:
    if 'add(customCard)' in s and s.count('add(customCard)') >= 2:
        print('already-patched'); sys.exit(0)
    print('NO_MATCH'); sys.exit(2)
open(p, 'w', encoding='utf-8').write(new)
print('patched')
PY
    [ $? -eq 0 ] || die "补丁1 失败：未匹配到 Android 分支结构，上游可能重构了此文件，请人工检查 $page"
    ok "补丁1 完成"
  fi

  # --- 补丁 2：恢复 MANAGE_EXTERNAL_STORAGE 声明 ---
  if grep -q 'android.permission.MANAGE_EXTERNAL_STORAGE' "$manifest"; then
    ok "补丁2 已存在，跳过"
  else
    info "应用补丁2：恢复 MANAGE_EXTERNAL_STORAGE 权限"
    python3 - "$manifest" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
decl = ('    <!-- Android 11+ all files access for custom workspace folder (restored) -->\n'
        '    <uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" '
        'tools:ignore="ScopedStorage" />\n')
# 优先插在 WRITE_EXTERNAL_STORAGE 之后；否则插在 WRITE_EXTERNAL_STORAGE 前或 root 开标签后
anchor = re.search(r'^.*android\.permission\.WRITE_EXTERNAL_STORAGE[^\n]*\n', s, re.M)
if anchor:
    s = s[:anchor.end()] + decl + s[anchor.end():]
else:
    s = re.sub(r'(<manifest[^>]*>\n)', r'\1' + decl.replace('\\', '\\\\'), s, count=1)
open(p, 'w', encoding='utf-8').write(s)
PY
    grep -q 'MANAGE_EXTERNAL_STORAGE' "$manifest" || die "补丁2 失败：权限未写入"
    # 清掉上游遗留的「removed for Google Play policy compliance」注释，避免误导
    sed -i '/<!-- MANAGE_EXTERNAL_STORAGE removed for Google Play policy compliance -->/d' "$manifest"
    ok "补丁2 完成"
  fi

  # --- 补丁 3：选文件夹前申请权限 ---
  if grep -q "_ensureAllFilesAccess" "$page"; then
    ok "补丁3 已存在，跳过"
  else
    info "应用补丁3：选文件夹前申请「所有文件访问」权限"
    python3 - "$page" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()

# 3a. 加 import
if "package:permission_handler/permission_handler.dart" not in s:
    s = s.replace("import 'package:file_picker/file_picker.dart';",
                  "import 'package:file_picker/file_picker.dart';\n"
                  "import 'package:permission_handler/permission_handler.dart';", 1)

# 3b. 插入辅助方法（放在 _verifyPathWritable 注释前）
helper = '''
  /// Ensure Android 11+ "All files access" is granted before picking a folder.
  Future<bool> _ensureAllFilesAccess() async {
    try {
      final status = await Permission.manageExternalStorage.status;
      if (status.isGranted) return true;
      if (status.isPermanentlyDenied) {
        await openAppSettings();
        if (mounted) {
          ToastHelper.showInfo(
              context, UserStorage.l10n.customFolderAccessDenied);
        }
        return false;
      }
      final result = await Permission.manageExternalStorage.request();
      if (result.isGranted) return true;
      if (mounted) {
        ToastHelper.showInfo(
            context, UserStorage.l10n.customFolderAccessDenied);
      }
      return false;
    } catch (_) {
      return true; // 插件不可用时交给写测试判断
    }
  }

'''
marker = '  /// Verify we can read/write the path'
if marker not in s:
    print('NO_MARKER'); sys.exit(2)
s = s.replace(marker, helper + marker, 1)

# 3c. 在 _pickFolder 里、getDirectoryPath 之前插入调用
call = ('    if (!await _ensureAllFilesAccess()) {\n      return;\n    }\n'
        '    final path = await FilePicker.platform.getDirectoryPath();')
if 'final path = await FilePicker.platform.getDirectoryPath();' not in s:
    print('NO_PICKER'); sys.exit(2)
s = s.replace('    final path = await FilePicker.platform.getDirectoryPath();', call, 1)

open(p, 'w', encoding='utf-8').write(s)
print('patched')
PY
    [ $? -eq 0 ] || die "补丁3 失败：未找到 _pickFolder 或辅助方法插入点，请人工检查 $page"
    ok "补丁3 完成"
  fi

  # --- 兼容处理：storagePermissionRequired 可能已被上游删除 ---
  if grep -q "l10n.storagePermissionRequired" "$page"; then
    sed -i 's/UserStorage\.l10n\.storagePermissionRequired/UserStorage.l10n.customFolderAccessDenied/g' "$page"
    warn "已将 storagePermissionRequired 替换为 customFolderAccessDenied"
  fi

  # --- 兜底：清理 settings.gradle 里可能残留的版本升级提示干扰（不改行为） ---
  :
}

# ---------- 5. 编译 ----------
build_apk() {
  cd "$WORKDIR"
  info "拉取 Dart 依赖..."
  flutter pub get > /tmp/memex_pubget.log 2>&1 || die "pub get 失败，见 /tmp/memex_pubget.log"

  info "静态检查修改的文件..."
  flutter analyze lib/ui/settings/widgets/data_storage_page.dart 2>&1 | tail -3

  info "编译 Dart AOT（flutter build，失败则回退 Gradle）..."
  if ! flutter build apk --release --flavor "$FLAVOR" > /tmp/memex_flutter_build.log 2>&1; then
    warn "flutter build 失败（常见于内存不足），改用低内存 Gradle 直编"
  fi

  info "Gradle 打包（跳过 lint，限制内存）..."
  cd android
  local scaled
  scaled="lintVitalAnalyze${FLAVOR^}Release"
  ./gradlew ":app:${GRADLE_TASK}" --no-daemon --console=plain --max-workers=2 \
      -x "lintVitalAnalyze${FLAVOR^}Release" \
      -x "lintVitalReport${FLAVOR^}Release" \
      -x "lintVital${FLAVOR^}Release" \
      -Dorg.gradle.jvmargs="-Xmx3g -XX:MaxMetaspaceSize=768m -XX:+UseSerialGC" \
      > /tmp/memex_gradle_build.log 2>&1
  local rc=$?
  cd ..
  if [ $rc -ne 0 ]; then
    echo "--- Gradle 日志尾部 ---" >&2
    grep -E "What went wrong|FAILURE|error:|daemon disappeared" -A3 /tmp/memex_gradle_build.log | head -20 >&2
    die "Gradle 打包失败（退出码 $rc），完整日志 /tmp/memex_gradle_build.log。常见原因：内存被 OOM 杀掉 → 重跑一次；或上游新增了必须处理的编译错误"
  fi
  ok "打包完成"
}

# ---------- 6. 签名 ----------
sign_apk() {
  local rel_dir="$WORKDIR/build/app/outputs/apk/${FLAVOR}/release"
  local unsigned
  unsigned=$(find "$rel_dir" -maxdepth 1 -name "*.apk" -printf '%T@ %p\n' 2>/dev/null \
             | sort -rn | head -1 | cut -d' ' -f2-)
  [ -n "${unsigned:-}" ] && [ -f "$unsigned" ] || die "未找到打包产物：$rel_dir"

  local aapt2="$ANDROID_SDK/build-tools/36.0.0/aapt2"
  [ -x "$aapt2" ] || aapt2=$(command -v aapt2 || true)

  local ver pkg
  ver=$("$aapt2" dump badging "$unsigned" 2>/dev/null | grep -oE "versionName='[^']+'" | cut -d"'" -f2)
  pkg=$("$aapt2" dump badging "$unsigned" 2>/dev/null | grep -oE "package: name='[^']+'" | cut -d"'" -f2)

  # 核验补丁是否真的进了包
  info "核验权限：$("$aapt2" dump permissions "$unsigned" 2>/dev/null | grep -c MANAGE_EXTERNAL_STORAGE) 处 MANAGE_EXTERNAL_STORAGE"

  local out="${OUTDIR}/Memex_v${ver}_${FLAVOR}_自定义文件夹版.apk"

  info "签名：$out"
  export LD_LIBRARY_PATH="/tmp/bt/lib64:${LD_LIBRARY_PATH:-}"
  java -jar /tmp/bt/apksigner.jar sign \
      --ks "$KEYSTORE" --ks-key-alias "$KEY_ALIAS" --ks-pass "pass:${KS_PASS}" \
      --out "$out" "$unsigned" || die "签名失败"

  java -jar /tmp/bt/apksigner.jar verify --verbose "$out" 2>&1 | head -3
  info "包名：$pkg"
  info "SHA-256：$(sha256sum "$out" | awk '{print $1}')"
  info "版本：$ver  大小：$(du -h "$out" | cut -f1)"
  ok "输出文件：$out"

  # 存档本次补丁 diff
  ( cd "$WORKDIR" && git diff lib/ui/settings/widgets/data_storage_page.dart \
      android/app/src/main/AndroidManifest.xml > "${OUTDIR}/Memex_自定义文件夹补丁.diff" ) || true
}

# ---------- 主流程 ----------
main() {
  local tag=""
  case "${1:-}" in
    --check)
      check_env
      info "官方最新稳定版 tag：$(latest_tag)"
      info "官方最新 daily tag：$(latest_daily_tag)"
      exit 0 ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    "") ;;
    *) tag="$1" ;;
  esac

  check_env
  if [ -z "$tag" ]; then
    tag=$(latest_daily_tag)
    [ -n "$tag" ] || die "无法获取官方 tag"
    info "未指定 tag，使用最新 daily：$tag"
  fi
  pick_flavor "$tag"
  info "官方最新稳定版：$(latest_tag)"
  sync_src "$tag"
  apply_patch
  build_apk
  sign_apk
  echo
  ok "全部完成。手机端操作：应用内备份 → 安装新包 → 指向同一自定义目录"
}

main "$@"
