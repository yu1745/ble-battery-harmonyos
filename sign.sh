#!/usr/bin/env bash
# 手工签名脚本 — 不依赖 DevEco Studio。
#
# 前提: 已按 docs/手动签名指南.md 在 AGC 网页完成:
#   1. 用 sign-tool/blebattery-debug.csr 申请调试证书 → 下载 .cer 放到 signing/
#   2. 注册手机 UDID + 创建调试 Profile → 下载 .p7b 放到 signing/
#
# 用法: ./sign.sh          签名 (产出 dist/blebattery-signed.hap)
#       ./sign.sh install  签名并用 hdc 安装到已连接的真机
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
KEY_ALIAS="blebattery-debug"
KEY_PWD="${SIGN_KEY_PWD:-blebattery2025}"
P12="$ROOT/sign-tool/blebattery-debug.p12"
JAR="$ROOT/sign-tool/hap-sign-tool.jar"
CER="$ROOT/signing/blebattery-debug.cer"
P7B="$ROOT/signing/blebattery-debug.p7b"
UNSIGNED="$ROOT/entry/build/default/outputs/default/entry-default-unsigned.hap"
OUT_DIR="$ROOT/dist"
OUT="$OUT_DIR/blebattery-signed.hap"
HDC="${HDC:-$HOME/harmonyos/command-line-tools/sdk/default/openharmony/toolchains/hdc}"

mkdir -p "$OUT_DIR"

# jar 自动下载
if [[ ! -f "$JAR" ]]; then
  echo ">> 下载 hap-sign-tool.jar ..."
  curl -sL -o "$JAR" "https://raw.githubusercontent.com/openharmony/developtools_hapsigner/master/dist/hap-sign-tool.jar"
fi

if [[ ! -f "$P12" || ! -f "$ROOT/sign-tool/blebattery-debug.csr" ]]; then
  echo ">> 生成密钥库与 CSR ..."
  java -jar "$JAR" generate-keypair -keyAlias "$KEY_ALIAS" -keyAlg ECC -keySize NIST-P-256 \
    -keystoreFile "$P12" -keystorePwd "$KEY_PWD" -keyPwd "$KEY_PWD"
  java -jar "$JAR" generate-csr -keyAlias "$KEY_ALIAS" -keyPwd "$KEY_PWD" \
    -subject "C=CN,O=yu1745,OU=blebattery,CN=BLE Battery Debug" -signAlg SHA256withECDSA \
    -keystoreFile "$P12" -keystorePwd "$KEY_PWD" \
    -outFile "$ROOT/sign-tool/blebattery-debug.csr"
fi

if [[ ! -f "$CER" || ! -f "$P7B" ]]; then
  cat <<EOF
[!] 缺少 AGC 签名文件:
      $CER   (调试证书, AGC 网页上传 CSR 后下载)
      $P7B   (调试 Profile, AGC 网页注册设备后创建下载)
    操作步骤见 docs/手动签名指南.md — 全程只需要浏览器, 不需要 DevEco Studio。
    CSR 已就绪: sign-tool/blebattery-debug.csr
EOF
  exit 1
fi

if [[ ! -f "$UNSIGNED" ]]; then
  echo ">> 未签名 HAP 不存在, 先执行 ./build.sh"
  exit 1
fi

echo ">> 签名中 ..."
java -jar "$JAR" sign-app \
  -mode "localSign" \
  -keyAlias "$KEY_ALIAS" \
  -keyPwd "$KEY_PWD" \
  -signAlg "SHA256withECDSA" \
  -appCertFile "$CER" \
  -profileFile "$P7B" \
  -keystoreFile "$P12" \
  -keystorePwd "$KEY_PWD" \
  -inFile "$UNSIGNED" \
  -outFile "$OUT" \
  -compatibleVersion 18

echo ">> 校验签名 ..."
java -jar "$JAR" verify-app -inFile "$OUT" -outCertChain "$OUT_DIR/_certchain.pem" -outProfile "$OUT_DIR/_profile.p7b" | tail -3

echo ">> 完成: $OUT"

if [[ "${1:-}" == "install" ]]; then
  echo ">> 安装到真机 ..."
  "$HDC" install -r "$OUT"
fi
