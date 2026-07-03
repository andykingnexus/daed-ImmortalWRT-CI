#!/bin/bash
set -e

########################################
# skb 回收
########################################
function enable_skb_recycler() {
  if [ -f "$1" ]; then
    cat >> "$1" <<EOF

CONFIG_KERNEL_SKB_RECYCLER=y
CONFIG_KERNEL_SKB_RECYCLER_MULTI_CPU=y
EOF
  fi
}

########################################
# 固定 kernel 6.18 新增 perf 选项
########################################
function pin_arm_perf_kernel_config() {
  local target
  target=$(grep -m 1 -oP '^CONFIG_TARGET_qualcommax_\K[[:alnum:]_]+(?=\=y)' "$GITHUB_WORKSPACE/Config/${WRT_CONFIG}.txt" || true)

  if [ -z "$target" ]; then
    echo "skip kernel perf config: qualcommax target not detected"
    return 0
  fi

  local kernel_config="target/linux/qualcommax/${target}/config-default"
  if [ ! -f "$kernel_config" ]; then
    echo "skip kernel perf config: $kernel_config not found"
    return 0
  fi

  cat >> "$kernel_config" <<'EOF'

# Kernel 6.18 eBPF/BTF perf dependencies
# CONFIG_ARM64_BRBE is not set
# CONFIG_ARM_CCI_PMU is not set
# CONFIG_ARM_CCN is not set
# CONFIG_ARM_CMN is not set
# CONFIG_ARM_NI is not set
# CONFIG_ARM_SMMU_V3_PMU is not set
# CONFIG_ARM_DSU_PMU is not set
# CONFIG_ARM_SPE_PMU is not set
EOF
}

########################################
# 修改内核大小
########################################
function set_kernel_size() {
  for file in target/linux/qualcommax/image/*.mk; do
    [ -f "$file" ] || continue
    sed -i 's/KERNEL_SIZE := [0-9]*k/KERNEL_SIZE := 12288k/g' "$file"
  done
}

########################################
# 生成最终 .config
########################################
function generate_config() {
  local config_file=".config"

  cat "$GITHUB_WORKSPACE/Config/${WRT_CONFIG}.txt" \
      "$GITHUB_WORKSPACE/Config/GENERAL.txt" > "$config_file"

  # 如果上游脚本存在 remove_wifi，则执行；不存在则跳过，避免 command not found。
  if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
    if declare -F remove_wifi >/dev/null 2>&1; then
      local target
      target=$(echo "$WRT_ARCH" | cut -d'_' -f2)
      remove_wifi "$target"
    else
      echo "remove_wifi function not found, skip. Wi-Fi is disabled by config and nowifi dtsi."
    fi
  fi

  enable_skb_recycler "$config_file"
  set_kernel_size
  pin_arm_perf_kernel_config
}

########################################
# 禁用 Wi-Fi 用户态包
########################################
function disable_wifi_userspace() {
  cat >> ./.config <<'EOF'

# No Wi-Fi userspace packages for pure wired AX18 build
CONFIG_PACKAGE_hostapd=n
CONFIG_PACKAGE_hostapd-common=n
CONFIG_PACKAGE_hostapd-utils=n
CONFIG_PACKAGE_hostapd-openssl=n
CONFIG_PACKAGE_hostapd-wolfssl=n
CONFIG_PACKAGE_hostapd-mbedtls=n
CONFIG_PACKAGE_wpad=n
CONFIG_PACKAGE_wpad-basic=n
CONFIG_PACKAGE_wpad-basic-mbedtls=n
CONFIG_PACKAGE_wpad-basic-openssl=n
CONFIG_PACKAGE_wpad-basic-wolfssl=n
CONFIG_PACKAGE_wpad-mbedtls=n
CONFIG_PACKAGE_wpad-openssl=n
CONFIG_PACKAGE_wpad-wolfssl=n
CONFIG_PACKAGE_wpad-full=n
CONFIG_PACKAGE_wpad-full-mbedtls=n
CONFIG_PACKAGE_wpad-full-openssl=n
CONFIG_PACKAGE_wpad-full-wolfssl=n
CONFIG_PACKAGE_wpa-cli=n
CONFIG_PACKAGE_wpa-supplicant=n
CONFIG_PACKAGE_wpa-supplicant-mbedtls=n
CONFIG_PACKAGE_wpa-supplicant-openssl=n
CONFIG_PACKAGE_wpa-supplicant-p2p=n
CONFIG_PACKAGE_wpa-supplicant-wolfssl=n
CONFIG_PACKAGE_iw=n
CONFIG_PACKAGE_wireless-regdb=n
CONFIG_PACKAGE_wifi-scripts=n
EOF
}

########################################
# 执行生成 config
########################################
generate_config

########################################
# LuCI / 系统修改
########################################

# 移除 luci-app-attendedsysupgrade
find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "/attendedsysupgrade/d" {} + 2>/dev/null || true

# 不替换第三方主题，固定使用 bootstrap
# find ./feeds/luci/collections/ -type f -name "Makefile" -exec sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" {} + 2>/dev/null || true

# 修改 immortalwrt.lan 关联 IP
find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js" -exec sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" {} + 2>/dev/null || true

# 添加编译日期标识
find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js" -exec sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" {} + 2>/dev/null || true

# Wi-Fi 名称/密码修改：保留兼容逻辑，但 no-wifi 构建基本不会用到
WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null | head -n 1 || true)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"

if [ -n "$WIFI_SH" ] && [ -f "$WIFI_SH" ]; then
  sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" "$WIFI_SH"
  sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" "$WIFI_SH"
elif [ -f "$WIFI_UC" ]; then
  sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" "$WIFI_UC"
  sed -i "s/key='.*'/key='$WRT_WORD'/g" "$WIFI_UC"
  sed -i "s/country='.*'/country='CN'/g" "$WIFI_UC"
  sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" "$WIFI_UC"
fi

CFG_FILE="./package/base-files/files/bin/config_generate"

# 修改默认 IP 地址和主机名
if [ -f "$CFG_FILE" ]; then
  sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$CFG_FILE"
  sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" "$CFG_FILE"
fi

########################################
# 追加配置
########################################

# LuCI 基础 + bootstrap
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-bootstrap=y" >> ./.config

# 禁用第三方主题和主题配置
echo "CONFIG_PACKAGE_luci-theme-argon=n" >> ./.config
echo "CONFIG_PACKAGE_luci-app-argon-config=n" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-aurora=n" >> ./.config
echo "CONFIG_PACKAGE_luci-app-aurora-config=n" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-kucat=n" >> ./.config
echo "CONFIG_PACKAGE_luci-app-kucat-config=n" >> ./.config

# 不内置 dae / daed
echo "CONFIG_PACKAGE_dae=n" >> ./.config
echo "CONFIG_PACKAGE_daed=n" >> ./.config
echo "CONFIG_PACKAGE_daed-geoip=n" >> ./.config
echo "CONFIG_PACKAGE_daed-geosite=n" >> ./.config
echo "CONFIG_PACKAGE_luci-app-daed=n" >> ./.config
echo "CONFIG_PACKAGE_luci-i18n-daed-zh-cn=n" >> ./.config

# 不内置代理插件
echo "CONFIG_PACKAGE_luci-app-homeproxy=n" >> ./.config
echo "CONFIG_PACKAGE_luci-app-momo=n" >> ./.config
echo "CONFIG_PACKAGE_luci-app-nikki=n" >> ./.config
echo "CONFIG_PACKAGE_luci-app-openclash=n" >> ./.config
echo "CONFIG_PACKAGE_luci-app-passwall=n" >> ./.config
echo "CONFIG_PACKAGE_luci-app-passwall2=n" >> ./.config
echo "CONFIG_PACKAGE_luci-app-mosdns=n" >> ./.config

# 纯有线路由：强制禁用 Wi-Fi 用户态组件，避免编译 hostapd/wpad
disable_wifi_userspace

# 手动调整的插件；默认不填即可
if [ -n "$WRT_PACKAGE" ]; then
  echo -e "$WRT_PACKAGE" >> ./.config
fi

# 手动插件追加后再禁用一次 Wi-Fi 用户态，确保最后生效
disable_wifi_userspace

# 无 Wi-Fi 配置标志
if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
  echo "WRT_WIFI=wifi-no" >> "$GITHUB_ENV"
fi

########################################
# 高通平台调整
########################################
DTS_PATH="./target/linux/qualcommax/dts/"

if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
  # VIKINGYFY/immortalwrt 已内置 NSS，禁用外部 NSS feed，避免重复/冲突
  echo "CONFIG_FEED_nss_packages=n" >> ./.config

  # 不需要 SQM-NSS / QoS
  echo "CONFIG_FEED_sqm_scripts_nss=n" >> ./.config
  echo "CONFIG_PACKAGE_luci-app-sqm=n" >> ./.config
  echo "CONFIG_PACKAGE_sqm-scripts=n" >> ./.config
  echo "CONFIG_PACKAGE_sqm-scripts-nss=n" >> ./.config
  echo "CONFIG_PACKAGE_qos-scripts=n" >> ./.config
  echo "CONFIG_PACKAGE_luci-app-qos=n" >> ./.config

  # NSS 固件版本
  echo "CONFIG_NSS_FIRMWARE_VERSION_12_5=y" >> ./.config

  # 纯有线路由不需要 Qualcomm USB 串口
  echo "CONFIG_PACKAGE_kmod-usb-serial-qualcomm=n" >> ./.config

  # 无 Wi-Fi 配置调整 Q6 大小
  if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
    if [ -d "$DTS_PATH" ]; then
      find "$DTS_PATH" -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
      echo "qualcommax set up nowifi successfully!"
    else
      echo "skip nowifi dtsi replacement: $DTS_PATH not found"
    fi
  fi
fi

# 最终再禁用一次，避免前面依赖或手动包把 wpad 重新拉起
disable_wifi_userspace
