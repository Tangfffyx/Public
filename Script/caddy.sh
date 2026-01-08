#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="Caddy 管理脚本"
SCRIPT_VERSION="1.0.0"

CADDYFILE="/etc/caddy/Caddyfile"
REPO_LIST="/etc/apt/sources.list.d/caddy-stable.list"
KEYRING="/usr/share/keyrings/caddy-stable-archive-keyring.gpg"
EMAIL_DEFAULT="tjfytyl541@gmail.com"

RED='\033[0;31m'
YEL='\033[0;33m'
GRN='\033[0;32m'
BLU='\033[0;34m'
NC='\033[0m'

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

port_usage() {
  local port="$1"
  if ! cmd_exists ss; then
    apt-get update -y >/dev/null
    apt-get install -y iproute2 >/dev/null
  fi
  ss -lntp 2>/dev/null | awk -v p=":$port" '$4 ~ p {print}'
}

# 443 被非 caddy 占用 -> 阻止（返回 1）
# 443 被 caddy 占用 -> 允许继续（返回 0，避免 set -e 退出）
check_ports_for_tls() {
  echo -e "${GRN}[检查]${NC} 端口 443/80"

  local u443 u80
  u443="$(port_usage 443 || true)"
  u80="$(port_usage 80 || true)"

  if [[ -n "${u443}" ]]; then
    if echo "${u443}" | grep -qE 'users:\(\("caddy",'; then
      echo -e "${YEL}[提示]${NC} 443 正被 Caddy 使用，继续执行"
    else
      echo -e "${RED}[阻止]${NC} 443 被占用，无法正常自动 HTTPS"
      echo "占用信息："
      echo "${u443}"
      echo -e "${YEL}建议：${NC} 释放 443 或改用 DNS 验证"
      return 1
    fi
  else
    echo -e "${GRN}[OK]${NC} 443 可用"
  fi

  if [[ -n "${u80}" ]]; then
    echo -e "${YEL}[提示]${NC} 80 被占用（可能影响 HTTP-01 验证）"
  else
    echo -e "${GRN}[OK]${NC} 80 可用"
  fi

  return 0
}

ensure_repo() {
  echo -e "${GRN}[准备]${NC} 添加官方源"
  apt-get update -y >/dev/null
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg >/dev/null

  if [[ ! -f "${KEYRING}" ]]; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor -o "${KEYRING}"
  fi

  if [[ ! -f "${REPO_LIST}" ]]; then
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      | tee "${REPO_LIST}" >/dev/null
  fi

  apt-get update -y >/dev/null
}

caddy_installed() { dpkg -s caddy >/dev/null 2>&1; }

get_installed_version() {
  if caddy_installed; then
    dpkg-query -W -f='${Version}\n' caddy 2>/dev/null || true
  else
    echo ""
  fi
}

get_candidate_version() {
  apt-cache policy caddy 2>/dev/null | awk -F': ' '/Candidate:/ {print $2; exit}'
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

has_default_template() {
  [[ -f "${CADDYFILE}" ]] && grep -qE '^[[:space:]]*:80[[:space:]]*\{' "${CADDYFILE}"
}

has_our_header() {
  [[ -f "${CADDYFILE}" ]] && grep -qE '^[[:space:]]*\{[[:space:]]*$' "${CADDYFILE}" && grep -qE 'email[[:space:]]+' "${CADDYFILE}"
}

ensure_caddyfile_header_clean() {
  mkdir -p "$(dirname "${CADDYFILE}")"

  if [[ ! -f "${CADDYFILE}" ]]; then
    echo -e "${GRN}[Caddyfile]${NC} 创建新配置"
    write_header
    return
  fi

  if has_default_template; then
    echo -e "${YEL}[Caddyfile]${NC} 检测到默认模板，已清空并写入头部"
    write_header
    return
  fi

  if ! has_our_header; then
    echo -e "${YEL}[Caddyfile]${NC} 插入头部"
    local tmp
    tmp="$(mktemp)"
    cp -f "${CADDYFILE}" "${tmp}"
    write_header
    sed '1{/^[[:space:]]*$/d;}' "${tmp}" >> "${CADDYFILE}"
    rm -f "${tmp}"
    fix_caddyfile_perms
  fi
}

# 确保块之间有空行（尤其是头部注释与第一个模块）
ensure_block_spacing() {
  [[ -f "${CADDYFILE}" ]] || return 0
  [[ "$(tail -n 1 "${CADDYFILE}" 2>/dev/null || true)" == "" ]] || echo >> "${CADDYFILE}"

  local last_non_empty
  last_non_empty="$(awk 'NF{line=$0} END{print line}' "${CADDYFILE}")"
  if [[ "${last_non_empty}" =~ ^[[:space:]]*# ]]; then
    echo >> "${CADDYFILE}"
  fi
}

remove_site_block() {
  local domain="$1"
  local tmp
  tmp="$(mktemp)"

  awk -v d="$domain" '
  function ltrim(s) { sub(/^[ \t\r\n]+/, "", s); return s }
  function rtrim(s) { sub(/[ \t\r\n]+$/, "", s); return s }
  function trim(s) { return rtrim(ltrim(s)) }

  BEGIN { skip=0; depth=0; prev=""; prevprev=""; }

  {
    line=$0
    t=trim(line)

    if (skip==0) {
      if (t == d " {") {
        # 删除紧贴的注释标注行（# xxx）
        if (prev != "" && match(trim(prev), /^#/) ) {
          if (prevprev != "") print prevprev
          prev=""; prevprev=""
        } else {
          if (prevprev != "") print prevprev
          if (prev != "") print prev
          prev=""; prevprev=""
        }
        skip=1
        depth=1
        next
      }
    }

    if (skip==1) {
      nopen = gsub(/\{/, "{", line)
      nclose = gsub(/\}/, "}", line)
      depth += nopen
      depth -= nclose
      if (depth<=0) { skip=0; depth=0 }
      next
    }

    if (prevprev != "") print prevprev
    prevprev = prev
    prev = line
  }

  END {
    if (prevprev != "") print prevprev
    if (prev != "") print prev
  }' "${CADDYFILE}" > "${tmp}"

  mv "${tmp}" "${CADDYFILE}"
  fix_caddyfile_perms
}

append_site_block() {
  local domain="$1"
  local target="$2"
  local mode="$3"   # simple | realip
  local note="$4"

  ensure_block_spacing

  if [[ -n "${note}" ]]; then
    echo "# ${note}" >> "${CADDYFILE}"
  fi

  if [[ "${mode}" == "simple" ]]; then
    cat >> "${CADDYFILE}" <<EOF
${domain} {
  reverse_proxy ${target}
}

EOF
  else
    cat >> "${CADDYFILE}" <<'EOF'
__DOMAIN__ {
  reverse_proxy {
    to __TARGET__
    header_up X-Real-IP {remote}
    header_up X-Forwarded-For {remote}
    header_up X-Forwarded-Proto {scheme}
  }
}

EOF
    sed -i \
      -e "s|^__DOMAIN__|${domain}|g" \
      -e "s|__TARGET__|${target}|g" \
      "${CADDYFILE}"
  fi

  fix_caddyfile_perms
}

validate_or_die() {
  echo -e "${GRN}[校验]${NC} caddy validate"
  if ! caddy validate --config "${CADDYFILE}"; then
    echo -e "${RED}[失败]${NC} 配置校验未通过，已停止应用"
    exit 1
  fi
  echo -e "${GRN}[OK]${NC} 校验通过"
}

apply_config_or_show_logs() {
  validate_or_die
  systemctl restart caddy >/dev/null 2>&1 || true

  if systemctl is-active caddy >/dev/null 2>&1; then
    echo -e "${GRN}[OK]${NC} 已生效"
  else
    echo -e "${RED}[错误]${NC} 启动失败，日志如下："
    systemctl status caddy --no-pager -l || true
    journalctl -xeu caddy --no-pager -n 120 || true
    exit 1
  fi
}

normalize_target() {
  local t="$1"
  t="${t// /}"

  if [[ "${t}" =~ ^[0-9]+$ ]]; then
    echo "127.0.0.1:${t}"
    return
  fi
  if [[ "${t}" =~ ^https?:// ]]; then
    echo "${t}"
    return
  fi
  echo "${t}"
}

ask_domain_target_note() {
  local domain target note

  echo >&2
  echo "添加/覆盖反代：" >&2

  read -r -p "域名: " domain
  domain="${domain// /}"
  [[ -n "${domain}" ]] || { echo -e "${RED}域名不能为空${NC}" >&2; exit 1; }

  read -r -p "目标(如 5000 / 127.0.0.1:5000 / https://example.com): " target
  target="$(normalize_target "${target}")"
  [[ -n "${target}" ]] || { echo -e "${RED}目标不能为空${NC}" >&2; exit 1; }

  read -r -p "标注(可选): " note

  printf '%s\t%s\t%s' "$domain" "$target" "$note"
}

# 从 Caddyfile 解析站点域名（只取 “第一段地址” 的情况）
list_sites() {
  [[ -f "${CADDYFILE}" ]] || return 0
  awk '
    function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
    {
      line=$0
      t=trim(line)
      if (t=="" || t ~ /^#/) next
      if (t ~ /^\{$/) next                 # global options block begin
      if (t ~ /^\}$/) next                 # global options block end
      if (t ~ /^:80[ \t]*\{/) next         # default site
      # 站点行：形如 example.com { 或 example.com, www.example.com { （这里仅取第一个 token）
      if (t ~ /^[^ \t].*\{[ \t]*$/) {
        # 排除 reverse_proxy { 这类指令块
        if (t ~ /^(reverse_proxy|handle|route|tls|encode|log|redir|respond|php_fastcgi|file_server)[ \t]*\{/) next
        # 取左侧
        sub(/\{[ \t]*$/,"",t)
        t=trim(t)
        # 取逗号前第一个地址
        split(t, parts, ",")
        first=trim(parts[1])
        if (first != "") print first
      }
    }
  ' "${CADDYFILE}" | awk '!seen[$0]++'
}

# 选项1：安装/升级（含版本对比）
option1_install_update() {
  if ! check_ports_for_tls; then
    return 1
  fi

  echo -e "${GRN}[版本检查]${NC} 获取版本信息..."
  ensure_repo

  local installed candidate
  installed="$(get_installed_version)"
  candidate="$(get_candidate_version)"

  if [[ -z "${candidate}" || "${candidate}" == "(none)" ]]; then
    echo -e "${RED}[错误]${NC} 无法从仓库获取最新版本"
    return 1
  fi

  if [[ -z "${installed}" ]]; then
    echo -e "${GRN}[状态]${NC} 未安装 Caddy"
    echo -e "${GRN}[安装]${NC} 最新版本：${candidate}"
    apt-get install -y caddy
    systemctl enable --now caddy
    fix_caddyfile_perms
    echo -e "${GRN}[完成]${NC} 安装并启动成功"
    return 0
  fi

  echo -e "${GRN}[已安装]${NC} ${installed}"
  echo -e "${GRN}[最新版本]${NC} ${candidate}"

  if [[ "${installed}" == "${candidate}" ]]; then
    echo -e "${GRN}[OK]${NC} 已是最新，无需升级"
    systemctl enable caddy >/dev/null 2>&1 || true
    return 0
  fi

  echo -e "${YEL}[发现更新]${NC} ${installed} → ${candidate}"
  local ans
  read -r -p "是否升级？[Y/n] " ans
  ans="${ans:-Y}"
  if [[ "${ans}" =~ ^[Nn]$ ]]; then
    echo -e "${YEL}已取消升级${NC}"
    return 0
  fi

  apt-get install -y caddy
  fix_caddyfile_perms
  systemctl restart caddy || true
  echo -e "${GRN}[完成]${NC} 已升级到 ${candidate}"
  return 0
}

option2_add_simple_proxy() {
  ensure_caddyfile_header_clean
  local domain target note
  IFS=$'\t' read -r domain target note <<< "$(ask_domain_target_note)"

  remove_site_block "${domain}"
  append_site_block "${domain}" "${target}" "simple" "${note}"

  echo -e "${GRN}[写入]${NC} ${domain} -> ${target}"
  apply_config_or_show_logs
}

option3_add_realip_proxy() {
  ensure_caddyfile_header_clean
  local domain target note
  IFS=$'\t' read -r domain target note <<< "$(ask_domain_target_note)"

  remove_site_block "${domain}"
  append_site_block "${domain}" "${target}" "realip" "${note}"

  echo -e "${GRN}[写入]${NC} ${domain} -> ${target}（真实IP）"
  apply_config_or_show_logs
}

# 新增：选项4 删除反代（编号选择）
option4_delete_proxy() {
  ensure_caddyfile_header_clean

  mapfile -t sites < <(list_sites)

  if [[ ${#sites[@]} -eq 0 ]]; then
    echo -e "${YEL}当前没有可删除的反代配置${NC}"
    return 0
  fi

  echo -e "${BLU}--------------------------------${NC}"
  echo -e "${BLU}当前反代列表：${NC}"
  for i in "${!sites[@]}"; do
    printf "  %s) %s\n" "$((i+1))" "${sites[$i]}"
  done
  echo -e "${BLU}--------------------------------${NC}"

  local idx
  read -r -p "输入编号删除（0 取消）: " idx
  idx="${idx// /}"

  if [[ -z "${idx}" || "${idx}" == "0" ]]; then
    echo -e "${YEL}已取消${NC}"
    return 0
  fi
  if ! [[ "${idx}" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}编号无效${NC}"
    return 1
  fi
  if (( idx < 1 || idx > ${#sites[@]} )); then
    echo -e "${RED}编号超出范围${NC}"
    return 1
  fi

  local domain="${sites[$((idx-1))]}"
  echo -e "${YEL}[删除]${NC} ${domain}"
  remove_site_block "${domain}"
  apply_config_or_show_logs
}

# 原选项4：fmt/show -> 变成选项5
option5_fmt_and_show() {
  cmd_exists caddy || { echo -e "${RED}未安装 caddy${NC}"; exit 1; }
  [[ -f "${CADDYFILE}" ]] || { echo -e "${RED}未找到 Caddyfile${NC}"; exit 1; }

  fix_caddyfile_perms
  echo -e "${GRN}[fmt]${NC} 覆盖格式化"
  caddy fmt --overwrite "${CADDYFILE}"

  echo -e "${GRN}[查看]${NC}"
  echo "--------------------------------"
  caddy fmt "${CADDYFILE}" || true
  echo "--------------------------------"
}

# 原选项5：清空/重置 -> 变成选项6
option6_reset_caddyfile() {
  echo -e "${YEL}[重置]${NC} 清空并写入最小可用配置"
  write_header
  echo -e "${GRN}[OK]${NC} 已重置：${CADDYFILE}"
}

# 原选项6：卸载 -> 变成选项7
option7_uninstall_purge() {
  echo -e "${YEL}[卸载]${NC} 停止并彻底清理"
  systemctl stop caddy >/dev/null 2>&1 || true
  systemctl disable caddy >/dev/null 2>&1 || true

  if dpkg -s caddy >/dev/null 2>&1; then
    apt-get purge -y caddy
  fi

  apt-get autoremove -y >/dev/null 2>&1 || true
  rm -rf /etc/caddy /var/lib/caddy /var/log/caddy 2>/dev/null || true
  rm -f "${REPO_LIST}" "${KEYRING}" 2>/dev/null || true
  apt-get update -y >/dev/null 2>&1 || true
  echo -e "${GRN}[OK]${NC} 已卸载"
}

show_menu() {
  echo -e "${BLU}================================${NC}"
  echo -e "${BLU} ${SCRIPT_NAME}  v${SCRIPT_VERSION}${NC}"
  echo -e "${BLU}================================${NC}"
  echo "1) 安装/升级 Caddy"
  echo "2) 添加反代（标准）"
  echo "3) 添加反代（真实IP）"
  echo "4) 删除反代"
  echo "5) 格式化并查看 Caddyfile"
  echo "6) 清空/重置 Caddyfile"
  echo "7) 卸载 Caddy（含配置）"
  echo "0) 退出"
  echo -e "${BLU}--------------------------------${NC}"
  echo -n "请选择："
}

main() {
  need_root
  while true; do
    show_menu
    read -r choice
    case "${choice}" in
      1) option1_install_update ;;
      2) option2_add_simple_proxy ;;
      3) option3_add_realip_proxy ;;
      4) option4_delete_proxy ;;
      5) option5_fmt_and_show ;;
      6) option6_reset_caddyfile ;;
      7) option7_uninstall_purge ;;
      0) exit 0 ;;
      *) echo -e "${YEL}无效选项${NC}" ;;
    esac
    echo
  done
}

main "$@"
