#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Caddy 管理脚本 (v5.0.0 GitHub发布版)
# ==========================================
SCRIPT_NAME="Caddy 管理脚本"
SCRIPT_VERSION="5.0.0"

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
    echo -e "${RED}错误：请使用 root 权限运行${NC}"
    exit 1
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

# 权限修复（核心稳定性功能）
fix_caddyfile_perms() {
  mkdir -p /etc/caddy
  local owner="root:root"
  # 如果系统里有 caddy 用户，则归属给它
  if id "caddy" &>/dev/null; then owner="caddy:caddy"; fi
  
  # 目录权限
  chown -R "$owner" /etc/caddy 2>/dev/null || true
  chmod 755 /etc/caddy 2>/dev/null || true
  
  # 文件权限 (644 保证 root 能写，caddy 能读)
  if [[ -f "${CADDYFILE}" ]]; then
    chown "$owner" "${CADDYFILE}" 2>/dev/null || true
    chmod 644 "${CADDYFILE}" 2>/dev/null || true
  fi
}

backup_caddyfile() {
  [[ -f "${CADDYFILE}" ]] || return 0
  local dir; dir="$(dirname "${CADDYFILE}")"
  # 只保留一份最新的备份
  find "${dir}" -maxdepth 1 -name "Caddyfile.bak.*" -type f -delete 2>/dev/null
  cp "${CADDYFILE}" "${CADDYFILE}.bak.$(date +%Y%m%d_%H%M%S)"
}

rollback_caddyfile() {
  local dir; dir="$(dirname "${CADDYFILE}")"
  local bak; bak="$(find "${dir}" -maxdepth 1 -name "Caddyfile.bak.*" -type f -print -quit)"
  if [[ -z "${bak}" ]]; then echo -e "${RED}未找到备份文件${NC}"; return 1; fi
  echo -e "${YEL}[回滚]${NC} 正在恢复至 ${bak}"
  cp -f "${bak}" "${CADDYFILE}"
  fix_caddyfile_perms
  apply_config_or_show_logs
}

# 自动格式化
auto_format() { 
  cmd_exists caddy && caddy fmt --overwrite "${CADDYFILE}" >/dev/null 2>&1 || true
  fix_caddyfile_perms 
}

# 初始化 Caddyfile
ensure_caddyfile_init() {
  mkdir -p "$(dirname "${CADDYFILE}")"
  # 如果文件不存在，写入头
  if [[ ! -f "${CADDYFILE}" ]]; then
    echo -e "{\n  email ${EMAIL_DEFAULT}\n}\n# 80端口重定向到443端口:自动完成的，无需配置。\n" > "${CADDYFILE}"
    fix_caddyfile_perms; return
  fi
  # 如果文件存在但没 Email，补全头
  if [[ -s "${CADDYFILE}" ]] && ! grep -q "email" "${CADDYFILE}"; then
    local tmp; tmp="$(mktemp)"
    echo -e "{\n  email ${EMAIL_DEFAULT}\n}\n# 80端口重定向到443端口:自动完成的，无需配置。\n" > "${tmp}"
    cat "${CADDYFILE}" >> "${tmp}"
    mv "${tmp}" "${CADDYFILE}"
  fi
  # 去重提示语
  local tmp2; tmp2="$(mktemp)"
  awk 'BEGIN{seen=0} /80端口重定向到443端口/{if(seen==0){print $0;seen=1}next} {print $0}' "${CADDYFILE}" > "${tmp2}"
  mv "${tmp2}" "${CADDYFILE}"; fix_caddyfile_perms
}

# ==========================================
# 核心逻辑：智能删除与注入
# ==========================================

# 智能删除：删除域名块 + 上方的备注
remove_domain_smart() {
  local domain="$1"; backup_caddyfile; local tmp; tmp="$(mktemp)"
  
  awk -v d="$domain" '
  function trim(s){sub(/^[ \t\r\n]+/,"",s);sub(/[ \t\r\n]+$/,"",s);return s} 
  BEGIN{skip=0;depth=0;c_cnt=0} 
  {
    line=$0; t=trim(line)
    # 跳过模式
    if(skip==1){
      nopen=gsub(/\{/,"{",line); nclose=gsub(/\}/,"}",line)
      depth+=nopen; depth-=nclose
      if(depth<=0){skip=0;depth=0}
      next
    }
    # 命中域名
    if(t==d" {"){
      c_cnt=0; skip=1; depth=1; next # 清空备注缓存，开启跳过，不打印当前行
    }
    # 缓存注释
    if(t~/^#/){ c_buf[c_cnt++]=line; next }
    # 遇到空行或非目标行，先打印缓存的注释
    if(t=="" || t!=d" {"){
      for(i=0;i<c_cnt;i++) print c_buf[i]; c_cnt=0
      print line
    }
  } 
  END{for(i=0;i<c_cnt;i++)print c_buf[i]}' "${CADDYFILE}" > "${tmp}"
  
  mv "${tmp}" "${CADDYFILE}"; fix_caddyfile_perms; auto_format
}

# 注入配置：支持 A+B 备注合并，路径覆盖
inject_proxy_config() {
  local domain="$1" path="$2" target="$3" mode="$4" note="$5"
  ensure_caddyfile_init; backup_caddyfile

  # 1. 新建域名块逻辑
  if ! grep -qE "^[[:space:]]*${domain}[[:space:]]*\{" "${CADDYFILE}"; then
    echo -e "${YEL}[新建]${NC} 域名 ${domain}"
    if [[ "$(tail -n 1 "${CADDYFILE}")" != "" ]]; then echo >> "${CADDYFILE}"; fi
    [[ -n "${note}" ]] && echo "# ${note}" >> "${CADDYFILE}"
    echo "${domain} {" >> "${CADDYFILE}"
    append_proxy_line "${path}" "${target}" "${mode}"
    echo "}" >> "${CADDYFILE}"; fix_caddyfile_perms; auto_format; return
  fi

  # 2. 更新域名块逻辑
  echo -e "${YEL}[更新]${NC} 注入 ${domain}"
  local tmp; tmp="$(mktemp)"

  awk -v d="$domain" -v p="$path" -v t="$target" -v m="$mode" -v n="$note" '
  function trim(s){sub(/^[ \t]+/,"",s);sub(/[ \t]+$/,"",s);return s} 
  BEGIN{in_d=0;depth=0;c_cnt=0} 
  
  function gen(){
    # 生成反代规则
    pre=(p=="")?("reverse_proxy "t):("reverse_proxy "p" "t)
    if(m=="1"){ print "  "pre }
    else if(m=="2"){ print "  "pre" {"; print "    header_up X-Real-IP {remote}"; print "  }" }
    else if(m=="3"){ print "  "pre" {"; print "    header_up Host {upstream_hostport}"; print "  }" }
  }

  {
    raw=$0; clean=trim(raw)
    
    # 检测域名块开始
    if(in_d==0 && clean==d" {"){
      # 输出之前的注释，并尝试合并新备注
      final_note = ""
      for(i=0;i<c_cnt;i++) {
         if (final_note != "") final_note = final_note "\n" c_buf[i]
         else final_note = c_buf[i]
      }
      
      # 智能合并备注 logic: "A" + "B" -> "A + B"
      if (n != "") {
         if (final_note == "") {
             print "# " n
         } else {
             # 如果旧注释里不包含新备注，则追加
             if (index(final_note, n) == 0) {
                 if (c_cnt > 0) {
                    last_idx = c_cnt - 1
                    c_buf[last_idx] = c_buf[last_idx] " + " n
                 } else {
                    print "# " n
                 }
             }
         }
      }
      
      for(i=0;i<c_cnt;i++) print c_buf[i]
      c_cnt=0
      
      in_d=1; depth=1; print raw; next
    }
    
    # 缓存外部注释
    if(in_d==0 && clean~/^#/){ c_buf[c_cnt++]=raw; next }
    # 非注释，先清空缓存
    if(in_d==0 && clean!=""){ for(i=0;i<c_cnt;i++) print c_buf[i]; c_cnt=0 }

    # 块内部处理
    if(in_d==1){
      n_op=gsub(/\{/,"{",raw); n_cl=gsub(/\}/,"}",raw)
      depth+=(n_op-n_cl)
      if(depth<=0){ gen(); in_d=0; print "}"; next } # 块结束，插入新规则
      
      # 覆盖逻辑：检查同路径
      if(clean~/^reverse_proxy/){
        split(clean,pt," ")
        mf=0
        if(p==""){ if(pt[2]!~/^\//) mf=1 } # 根路径
        else { if(pt[2]==p) mf=1 }         # 具体路径
        
        if(mf){
           # 发现旧配置，标记跳过
           if(raw~/\{[ \t]*$/){ sd=1; isk=1 }
           next # 删除旧行
        }
      }
      # 跳过旧块的多行内容
      if(isk==1){
         nso=gsub(/\{/,"{",raw); nsc=gsub(/\}/,"}",raw)
         sd+=(nso-nsc); if(sd<=0) isk=0
         next
      }
    }
    print raw
  }
  END{for(i=0;i<c_cnt;i++)print c_buf[i]} # 打印剩余缓存
  ' "${CADDYFILE}" > "${tmp}"
  
  mv "${tmp}" "${CADDYFILE}"; fix_caddyfile_perms; auto_format
}

append_proxy_line() {
  local p="$1" t="$2" m="$3"
  # 生成规则的辅助函数 (用于新建块)
  local pre
  [[ -z "$p" ]] && pre="  reverse_proxy $t" || pre="  reverse_proxy $p $t"
  
  if [[ "$m" == "1" ]]; then
    echo "$pre" >> "${CADDYFILE}"
  elif [[ "$m" == "2" ]]; then
    echo "$pre {" >> "${CADDYFILE}"
    echo "    header_up X-Real-IP {remote}" >> "${CADDYFILE}"
    echo "  }" >> "${CADDYFILE}"
  elif [[ "$m" == "3" ]]; then
    echo "$pre {" >> "${CADDYFILE}"
    echo "    header_up Host {upstream_hostport}" >> "${CADDYFILE}"
    echo "  }" >> "${CADDYFILE}"
  fi
}

apply_config_or_show_logs() {
  echo -e "${GRN}[校验]${NC} Validating..."
  if ! caddy validate --config "${CADDYFILE}"; then echo -e "${RED}校验失败${NC}"; exit 1; fi
  systemctl restart caddy >/dev/null 2>&1 || true
  if systemctl is-active caddy >/dev/null 2>&1; then echo -e "${GRN}[成功]${NC} Caddy 已重载配置"; else 
    echo -e "${RED}启动失败，最后 20 行日志:${NC}"; journalctl -xeu caddy --no-pager -n 20 || true; exit 1; fi
}

# ==========================================
# 菜单交互逻辑
# ==========================================

option_install() {
  echo -e "${YEL}正在添加源并安装 Caddy，请稍候...${NC}"
  ensure_repo
  apt-get install -y caddy
  systemctl enable --now caddy
  fix_caddyfile_perms
  echo -e "${GRN}安装/升级完成${NC}"
}

option_add_proxy() {
  echo >&2
  echo ">>> 请选择反代模式："
  echo "1. 标准反代 (Web/静态站)"
  echo "2. 反代 VLESS (WebSocket 节点, 需路径)"
  echo "3. 反代他人服务 (伪装/外站)"
  echo "4. 传递真实IP (Emby/GitHub加速 等)"
  
  local mode
  read -r -p "请输入编号 [1]: " mode
  mode="${mode:-1}"
  
  # 域名 (所有模式都需要)
  local domain
  read -r -p "请输入域名 (如 sub.example.com): " domain
  domain="${domain// /}"
  [[ -z "${domain}" ]] && { echo -e "${RED}域名不能为空${NC}"; return 1; }

  local path="" target="" note=""
  
  # 根据模式提问
  if [[ "$mode" == "2" ]]; then
    # VLESS 模式：必须问路径，有默认值
    read -r -p "请输入路径 (默认 /Akaman): " path
    path="${path// /}"
    path="${path:-/Akaman}"
    if [[ ! "$path" =~ ^/ ]]; then path="/$path"; fi
    
    # 端口默认 8001
    read -r -p "请输入目标 (默认 8001): " target
    target="${target// /}"
    target="${target:-127.0.0.1:8001}"
    
    # 修正 target 格式
    if [[ "$target" =~ ^[0-9]+$ ]]; then target="127.0.0.1:$target"; fi
    
    # 映射到内部模式 ID (1=标准, 2=RealIP, 3=Host)
    # VLESS 本质上是标准反代，只是带路径。所以模式传 1
    mode_internal="1"
    
  else
    # 其他模式：路径默认为空
    path=""
    
    read -r -p "请输入目标 (端口 8080 或 https://x.com): " target
    target="${target// /}"
    [[ -z "${target}" ]] && { echo -e "${RED}目标不能为空${NC}"; return 1; }
    
    # 格式修正
    if [[ "$target" =~ ^[0-9]+$ ]]; then target="127.0.0.1:$target"; fi
    if [[ ! "$target" =~ ^http ]] && [[ ! "$target" =~ ^[0-9.]+:[0-9]+$ ]]; then target="https://$target"; fi
    
    # 映射模式
    if [[ "$mode" == "3" ]]; then mode_internal="3"; 
    elif [[ "$mode" == "4" ]]; then mode_internal="2"; 
    else mode_internal="1"; fi
  fi
  
  read -r -p "请输入备注 (可选): " note
  
  inject_proxy_config "${domain}" "${path}" "${target}" "${mode_internal}" "${note}"
  echo -e "${GRN}[完成]${NC} 配置已写入"
  apply_config_or_show_logs
}

option_delete_domain() {
  ensure_caddyfile_init
  # 提取域名列表
  mapfile -t sites < <(awk '/^[^#[:space:]].*\{$/{sub(/\{[ \t]*$/,"",$0);print $1}' "${CADDYFILE}" | sort -u)
  [[ ${#sites[@]} -eq 0 ]] && { echo -e "${YEL}当前无配置域名${NC}"; return 0; }
  
  echo -e "${BLU}当前域名列表:${NC}"
  for i in "${!sites[@]}"; do printf " %s) %s\n" "$((i+1))" "${sites[$i]}"; done
  
  local idx
  read -r -p "请输入编号删除 (0 取消): " idx
  [[ "$idx" == "0" || -z "$idx" ]] && return 0
  
  if (( idx>=1 && idx<=${#sites[@]} )); then
    local d="${sites[$((idx-1))]}"
    echo -e "${YEL}[删除]${NC} $d"
    remove_domain_smart "$d"
    apply_config_or_show_logs
  else
    echo -e "${RED}无效编号${NC}"
  fi
}

# 辅助函数
ensure_repo() { 
  apt-get update -y
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg
  [[ ! -f "${KEYRING}" ]] && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key'|gpg --dearmor -o "${KEYRING}"
  [[ ! -f "${REPO_LIST}" ]] && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt'|tee "${REPO_LIST}">/dev/null
  apt-get update -y
}

show_menu() {
  echo -e "${BLU}=== Caddy 管理脚本 v${SCRIPT_VERSION} ===${NC}"
  echo "1) 安装/升级 Caddy"
  echo "2) 添加/更新反代"
  echo "3) 删除反代"
  echo "4) 查看配置内容"
  echo "5) 回滚上一份配置"
  echo "6) 重置 Caddyfile"
  echo "7) 卸载 Caddy"
  echo "0) 退出"
  echo -n "请选择: "
}

main() {
  need_root
  ensure_caddyfile_init
  while true; do
    show_menu
    read -r c || exit 0
    case "$c" in
      1) option_install ;;
      2) option_add_proxy ;;
      3) option_delete_domain ;;
      4) cat "${CADDYFILE}" ;;
      5) rollback_caddyfile ;;
      6) backup_caddyfile
         echo -e "{\n email ${EMAIL_DEFAULT}\n}\n# 80端口重定向到443端口:自动完成的，无需配置。\n" > "${CADDYFILE}"
         fix_caddyfile_perms; echo -e "${GRN}已重置${NC}"; systemctl restart caddy ;;
      7) echo -e "${YEL}正在卸载...${NC}"; systemctl stop caddy; apt-get purge -y caddy; rm -rf /etc/caddy; echo -e "${GRN}已卸载${NC}" ;;
      0) exit 0 ;;
      *) echo -e "${YEL}无效选项${NC}" ;;
    esac
    echo
  done
}

main "$@"
