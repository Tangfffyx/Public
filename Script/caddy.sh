#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Caddy 管理脚本 (智能清洗版)
# Version: 3.0.0
# ==========================================
SCRIPT_NAME="Caddy 管理脚本"
SCRIPT_VERSION="3.0.0"

CADDYFILE="/etc/caddy/Caddyfile"
REPO_LIST="/etc/apt/sources.list.d/caddy-stable.list"
KEYRING="/usr/share/keyrings/caddy-stable-archive-keyring.gpg"
EMAIL_DEFAULT="tjfytyl541@gmail.com"

# 颜色定义
RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
BLU='\033[0;34m'
NC='\033[0m'

# ==========================================
# 基础工具函数
# ==========================================

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo -e "${RED}需要 root 权限运行${NC}"
    exit 1
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

fix_caddyfile_perms() {
  mkdir -p /etc/caddy
  chown root:root /etc/caddy 2>/dev/null || true
  chmod 755 /etc/caddy 2>/dev/null || true
  if [[ -f "${CADDYFILE}" ]]; then
    chown root:root "${CADDYFILE}" 2>/dev/null || true
    chmod 644 "${CADDYFILE}" 2>/dev/null || true
  fi
}

# 备份函数
backup_caddyfile() {
  [[ -f "${CADDYFILE}" ]] || return 0
  local caddy_dir
  caddy_dir="$(dirname "${CADDYFILE}")"
  find "${caddy_dir}" -maxdepth 1 -name "Caddyfile.bak.*" -type f -delete 2>/dev/null
  local bak_name="${CADDYFILE}.bak.$(date +%Y%m%d_%H%M%S)"
  cp "${CADDYFILE}" "${bak_name}"
  echo -e "${YEL}[备份]${NC} 原配置已备份至: ${bak_name}"
}

# 回滚函数
rollback_caddyfile() {
  local caddy_dir
  caddy_dir="$(dirname "${CADDYFILE}")"
  local bak_file
  bak_file="$(find "${caddy_dir}" -maxdepth 1 -name "Caddyfile.bak.*" -type f -print -quit)"
  if [[ -z "${bak_file}" ]]; then
    echo -e "${RED}[错误]${NC} 未找到任何备份文件，无法回滚。"
    return 1
  fi
  echo -e "${YEL}[回滚]${NC} 正在恢复至: ${bak_file}"
  cp -f "${bak_file}" "${CADDYFILE}"
  apply_config_or_show_logs
}

# 端口检查
check_ports_for_tls() {
  if ! cmd_exists ss; then apt-get update -y >/dev/null && apt-get install -y iproute2 >/dev/null; fi
  echo -e "${GRN}[检查]${NC} 端口 443"
  local u443
  u443="$(ss -lntp 2>/dev/null | awk '$4 ~ /:443$/ {print}')"
  if [[ -n "${u443}" ]]; then
    if echo "${u443}" | grep -qE 'users:\(\("caddy",'; then
      echo -e "${YEL}[提示]${NC} 443 正被 Caddy 使用 (正常)"
    else
      echo -e "${RED}[阻止]${NC} 443 被其他程序占用"
      echo "${u443}"
      return 1
    fi
  else
    echo -e "${GRN}[OK]${NC} 443 可用"
  fi
  return 0
}

# ==========================================
# 核心文本处理 (v3.0 升级版)
# ==========================================

# 1. 自动排版 (治愈强迫症)
auto_format_caddyfile() {
  if cmd_exists caddy; then
    caddy fmt --overwrite "${CADDYFILE}" >/dev/null 2>&1 || true
  fi
}

# 2. 头部去重 (解决 "# 80端口..." 重复出现的问题)
cleanup_duplicate_headers() {
  [[ -f "${CADDYFILE}" ]] || return 0
  local tmp
  tmp="$(mktemp)"
  
  # 使用 awk 去重特定的提示语，只保留第一次出现的
  awk '
    BEGIN { seen_80_msg = 0 }
    {
      # 检测特定字符串
      if ($0 ~ /80端口重定向到443端口/) {
        if (seen_80_msg == 0) {
          print $0
          seen_80_msg = 1
        }
        # 如果已经出现过，跳过不打印（即删除重复行）
        next
      }
      print $0
    }
  ' "${CADDYFILE}" > "${tmp}"
  
  mv "${tmp}" "${CADDYFILE}"
  fix_caddyfile_perms
}

# 3. 智能删除 (解决 "删除域名后残留备注" 的问题)
remove_domain_block_smart() {
  local domain="$1"
  backup_caddyfile
  
  local tmp
  tmp="$(mktemp)"

  # 逻辑：缓存注释行。如果遇到目标域名，清空缓存（即删除注释）并跳过域名块。
  # 如果遇到非目标域名，先打印缓存的注释，再打印当前行。
  awk -v d="$domain" '
  function trim(s) { sub(/^[ \t\r\n]+/, "", s); sub(/[ \t\r\n]+$/, "", s); return s }
  BEGIN { 
    skip = 0; 
    depth = 0; 
    comment_count = 0; 
  }
  
  {
    line = $0
    t = trim(line)
    
    # 如果处于跳过模式（正在删除目标块）
    if (skip == 1) {
      nopen = gsub(/\{/, "{", line)
      nclose = gsub(/\}/, "}", line)
      depth += nopen
      depth -= nclose
      if (depth <= 0) { skip = 0; depth = 0 }
      next # 不打印当前行
    }
    
    # 检测是否是目标域名的开始
    if (t == d " {") {
      # 命中目标！
      # 1. 丢弃之前缓存的注释 (comment_buf) -> 实现了连同备注一起删除
      comment_count = 0 
      
      # 2. 开启跳过模式
      skip = 1
      depth = 1
      next
    }
    
    # 检测是否是注释行
    if (t ~ /^#/) {
      # 缓存注释
      comment_buf[comment_count++] = line
      next
    }
    
    # 检测是否是空行
    if (t == "") {
      # 遇到空行，通常意味着上一段注释结束了。
      # 先把缓存的注释打印出来（因为它们不属于还没出现的“目标域名”）
      for (i=0; i<comment_count; i++) print comment_buf[i]
      comment_count = 0
      print line
      next
    }
    
    # 普通行（非目标域名，非注释，非空行）
    # 比如 "other-domain.com {"
    # 说明之前缓存的注释属于这个 "other-domain"，所以要打印出来
    for (i=0; i<comment_count; i++) print comment_buf[i]
    comment_count = 0
    print line
  }
  
  END {
    # 文件结束，如果还有缓存的注释，打印出来
    for (i=0; i<comment_count; i++) print comment_buf[i]
  }
  ' "${CADDYFILE}" > "${tmp}"

  mv "${tmp}" "${CADDYFILE}"
  fix_caddyfile_perms
}

# 4. 智能注入 (保持之前逻辑，增加格式化)
add_or_update_proxy() {
  local domain="$1"
  local path="$2"
  local target="$3"
  local mode="$4"
  local note="$5"

  if [[ -z "${domain}" || -z "${target}" ]]; then
    echo -e "${RED}[错误]${NC} 域名或目标为空"
    return 1
  fi

  ensure_caddyfile_init
  backup_caddyfile

  # 1. 新建域名逻辑
  if ! grep -qE "^[[:space:]]*${domain}[[:space:]]*\{" "${CADDYFILE}"; then
    if [[ "$(tail -n 1 "${CADDYFILE}")" != "" ]]; then echo >> "${CADDYFILE}"; fi
    echo -e "${YEL}[新建]${NC} 域名块 ${domain}"
    
    # 如果有备注，写在域名块上方（Caddy 风格）
    if [[ -n "${note}" ]]; then echo "# ${note}" >> "${CADDYFILE}"; fi
    
    echo "${domain} {" >> "${CADDYFILE}"
    append_proxy_body "${path}" "${target}" "${mode}"
    echo "}" >> "${CADDYFILE}"
    
    auto_format_caddyfile
    fix_caddyfile_perms
    return
  fi

  # 2. 更新逻辑 (注入到现有块)
  echo -e "${YEL}[更新]${NC} 注入配置到 ${domain}"
  local tmp
  tmp="$(mktemp)"

  awk -v d="$domain" -v p="$path" -v t="$target" -v m="$mode" -v n="$note" '
  function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
  BEGIN { in_domain=0; depth=0; }
  
  function gen_rule() {
    if (n != "") print "  # " n
    if (m == "realip") {
      prefix = (p == "") ? ("reverse_proxy " t) : ("reverse_proxy " p " " t)
      print "  " prefix " {"
      print "    header_up X-Real-IP {remote}"
      print "  }"
    } else {
      prefix = (p == "") ? ("reverse_proxy " t) : ("reverse_proxy " p " " t)
      print "  " prefix
    }
  }

  {
    raw = $0
    clean = trim(raw)
    
    if (in_domain == 0 && clean == d " {") {
      in_domain = 1
      depth = 1
      print raw
      next
    }
    
    if (in_domain == 1) {
      n_open = gsub(/\{/, "{", raw)
      n_close = gsub(/\}/, "}", raw)
      depth += (n_open - n_close)
      
      if (depth <= 0) {
        gen_rule()
        in_domain = 0
        print "}"
        next
      }
      
      # 覆盖旧规则逻辑
      if (clean ~ /^reverse_proxy/) {
        split(clean, parts, " ")
        is_match = 0
        if (p == "") {
          if (parts[2] !~ /^\//) is_match = 1
        } else {
          if (parts[2] == p) is_match = 1
        }
        if (is_match) {
          if (raw ~ /\{[ \t]*$/) { skip_depth = 1; in_skip = 1; }
          next
        }
      }
      
      if (in_skip == 1) {
         n_s_open = gsub(/\{/, "{", raw)
         n_s_close = gsub(/\}/, "}", raw)
         skip_depth += (n_s_open - n_s_close)
         if (skip_depth <= 0) in_skip = 0
         next
      }
    }
    print raw
  }
  ' "${CADDYFILE}" > "${tmp}"

  mv "${tmp}" "${CADDYFILE}"
  auto_format_caddyfile
  fix_caddyfile_perms
}

append_proxy_body() {
  local path="$1"
  local target="$2"
  local mode="$3"
  
  if [[ "${mode}" == "realip" ]]; then
    if [[ -z "${path}" ]]; then echo "  reverse_proxy ${target} {" >> "${CADDYFILE}"; else echo "  reverse_proxy ${path} ${target} {" >> "${CADDYFILE}"; fi
    echo "    header_up X-Real-IP {remote}" >> "${CADDYFILE}"
    echo "  }" >> "${CADDYFILE}"
  else
    if [[ -z "${path}" ]]; then echo "  reverse_proxy ${target}" >> "${CADDYFILE}"; else echo "  reverse_proxy ${path} ${target}" >> "${CADDYFILE}"; fi
  fi
}

# ==========================================
# Caddy 安装与管理
# ==========================================

ensure_repo() {
  echo -e "${GRN}[准备]${NC} 添加官方源"
  apt-get update -y >/dev/null
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg >/dev/null
  if [[ ! -f "${KEYRING}" ]]; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o "${KEYRING}"
  fi
  if [[ ! -f "${REPO_LIST}" ]]; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee "${REPO_LIST}" >/dev/null
  fi
  apt-get update -y >/dev/null
}

write_header() {
  cat > "${CADDYFILE}" <<EOF
{
  email ${EMAIL_DEFAULT}
}

# 80端口重定向到443端口:自动完成的，无需配置。

EOF
  fix_caddyfile_perms
}

ensure_caddyfile_init() {
  mkdir -p "$(dirname "${CADDYFILE}")"
  if [[ ! -f "${CADDYFILE}" ]]; then
    write_header
    return
  fi
  # 如果 email 丢失，补全
  if [[ -s "${CADDYFILE}" ]] && ! grep -q "email" "${CADDYFILE}"; then
    local tmp
    tmp="$(mktemp)"
    cat <<EOF > "${tmp}"
{
  email ${EMAIL_DEFAULT}
}

# 80端口重定向到443端口:自动完成的，无需配置。

EOF
    cat "${CADDYFILE}" >> "${tmp}"
    mv "${tmp}" "${CADDYFILE}"
  fi
  
  # 执行去重清理
  cleanup_duplicate_headers
}

apply_config_or_show_logs() {
  echo -e "${GRN}[校验]${NC} caddy validate"
  if ! caddy validate --config "${CADDYFILE}"; then
    echo -e "${RED}[失败]${NC} 配置校验未通过"
    exit 1
  fi
  systemctl restart caddy >/dev/null 2>&1 || true
  if systemctl is-active caddy >/dev/null 2>&1; then
    echo -e "${GRN}[OK]${NC} 已生效"
  else
    echo -e "${RED}[错误]${NC} 启动失败，日志如下："
    journalctl -xeu caddy --no-pager -n 20 || true
    exit 1
  fi
}

normalize_target() {
  local t="$1"
  t="${t// /}"
  if [[ "${t}" =~ ^[0-9]+$ ]]; then echo "127.0.0.1:${t}"; return; fi
  if [[ "${t}" =~ ^https?:// ]]; then echo "${t}"; return; fi
  echo "${t}"
}

# ==========================================
# 菜单
# ==========================================

option_install() {
  if ! check_ports_for_tls; then return 1; fi
  ensure_repo
  apt-get install -y caddy
  systemctl enable --now caddy
  fix_caddyfile_perms
  echo -e "${GRN}[完成]${NC} 安装成功"
}

option_add_proxy() {
  echo >&2; echo ">>> 添加/更新 反向代理" >&2
  
  local domain
  read -r -p "域名: " domain || return 1
  domain="${domain// /}"
  [[ -z "${domain}" ]] && { echo -e "${RED}域名不能为空${NC}"; return 1; }

  local path_input path
  read -r -p "路径 (回车=/, 输入abcd=/abcd): " path_input || return 1
  path_input="${path_input// /}"
  if [[ -z "${path_input}" || "${path_input}" == "/" ]]; then path=""; elif [[ "${path_input}" =~ ^/ ]]; then path="${path_input}"; else path="/${path_input}"; fi

  local target
  read -r -p "目标 (8080 或 https://x.com): " target || return 1
  target="$(normalize_target "${target}")"
  [[ -z "${target}" ]] && { echo -e "${RED}目标不能为空${NC}"; return 1; }

  local mode_choice mode
  echo "模式: [1] 标准(默认)  [2] 透传真实IP"
  read -r -p "选择: " mode_choice || return 1
  mode=$([[ "${mode_choice}" == "2" ]] && echo "realip" || echo "simple")

  local note
  read -r -p "备注 (可选): " note || return 1

  add_or_update_proxy "${domain}" "${path}" "${target}" "${mode}" "${note}"
  echo -e "${GRN}[完成]${NC} 配置已更新"
  apply_config_or_show_logs
}

option_delete_domain() {
  ensure_caddyfile_init
  mapfile -t sites < <(
    awk '
      function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
      {
        t=trim($0)
        # 提取域名（排除global block { 和 注释）
        if (t ~ /^[^#].*\{$/) {
          sub(/\{[ \t]*$/,"",t)
          t=trim(t)
          # Global options block usually has no name, just {
          if (t != "") print t
        }
      }
    ' "${CADDYFILE}" | sort -u
  )

  if [[ ${#sites[@]} -eq 0 ]]; then
    echo -e "${YEL}无配置域名${NC}"; return 0
  fi

  echo -e "${BLU}域名列表：${NC}"
  for i in "${!sites[@]}"; do printf "  %s) %s\n" "$((i+1))" "${sites[$i]}"; done

  local idx
  read -r -p "删除编号 (0=取消): " idx || return 0
  [[ "${idx}" == "0" || -z "${idx}" ]] && return 0
  
  if (( idx >= 1 && idx <= ${#sites[@]} )); then
    local d="${sites[$((idx-1))]}"
    echo -e "${YEL}[删除]${NC} ${d} (及关联备注)"
    remove_domain_block_smart "${d}"
    auto_format_caddyfile
    apply_config_or_show_logs
  else
    echo -e "${RED}无效编号${NC}"
  fi
}

option_reset() {
  echo -e "${RED}[警告]${NC} 清空所有配置？"
  read -r -p "确认 [y/N]: " ans
  if [[ "${ans}" =~ ^[Yy]$ ]]; then
    backup_caddyfile
    write_header
    echo -e "${GRN}[OK]${NC} 重置完成"
    systemctl restart caddy
  fi
}

option_uninstall() {
  echo -e "${RED}[危险]${NC} 卸载 Caddy？"
  read -r -p "确认 [y/N]: " ans
  if [[ "${ans}" =~ ^[Yy]$ ]]; then
    systemctl stop caddy || true
    systemctl disable caddy || true
    apt-get purge -y caddy || true
    rm -rf /etc/caddy /var/lib/caddy /var/log/caddy "${REPO_LIST}" "${KEYRING}"
    echo -e "${GRN}[OK]${NC} 卸载完成"
  fi
}

show_menu() {
  echo -e "${BLU}================================${NC}"
  echo -e "${BLU} ${SCRIPT_NAME}  v${SCRIPT_VERSION}${NC}"
  echo -e "${BLU}================================${NC}"
  echo "1) 安装/升级 Caddy"
  echo "2) 添加/更新 反代 (支持多路径)"
  echo "3) 删除反代 (智能清理备注)"
  echo "4) 查看配置"
  echo "5) 回滚配置"
  echo "6) 重置 Caddyfile"
  echo "7) 卸载 Caddy"
  echo "0) 退出"
  echo -e "${BLU}--------------------------------${NC}"
  echo -n "请选择："
}

main() {
  need_root
  ensure_caddyfile_init
  while true; do
    show_menu
    read -r choice || exit 0
    case "${choice}" in
      1) option_install ;;
      2) option_add_proxy ;;
      3) option_delete_domain ;;
      4) cat "${CADDYFILE}" ;;
      5) rollback_caddyfile ;;
      6) option_reset ;;
      7) option_uninstall ;;
      0) exit 0 ;;
      *) echo -e "${YEL}无效${NC}" ;;
    esac
    echo
  done
}

main "$@"
