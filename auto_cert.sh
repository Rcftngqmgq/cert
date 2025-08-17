#!/bin/bash
# =========================================================
# 菜单化自动证书管理脚本 (Cloudflare DNS 插件 / HTTP 验证)
# GitHub 一键安装: bash <(curl -fsSL URL)
# =========================================================

set -uo pipefail
LANG=C.UTF-8

# --------------------------
# 基础配置
# --------------------------
readonly INSTALL_PATH="/root/auto_cert.sh"
readonly CERTS_DIR="/home/web/certs"
readonly CF_CREDENTIALS="${CERTS_DIR}/cloudflare.ini"
readonly LOG_FILE="${CERTS_DIR}/cert_renew.log"
readonly DAYS_BEFORE_EXPIRE=15
readonly EMAIL="your@email.com"  # 可自行修改或留空

# --------------------------
# 安装脚本自身（可选）
# --------------------------
if [[ ! -f "$INSTALL_PATH" ]]; then
    echo "[INFO] 安装脚本到 $INSTALL_PATH..."
    mkdir -p "$(dirname "$INSTALL_PATH")"
    curl -fsSL "https://raw.githubusercontent.com/Rcftngqmgq/cert/main/auto_cert.sh" -o "$INSTALL_PATH"
    chmod 700 "$INSTALL_PATH"
    echo "[SUCCESS] 安装完成！"
fi

# --------------------------
# 初始化环境
# --------------------------
init_environment() {
    mkdir -p "${CERTS_DIR}"
    chmod 700 "${CERTS_DIR}"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
    [[ ! -f "${CERTS_DIR}/ticket12.key" ]] && openssl rand -out "${CERTS_DIR}/ticket12.key" 48
    [[ ! -f "${CERTS_DIR}/ticket13.key" ]] && openssl rand -out "${CERTS_DIR}/ticket13.key" 80
}

# --------------------------
# 菜单显示函数
# --------------------------
show_main_menu() {
    clear
    echo "==================== 证书管理菜单 ===================="
    echo "1) 申请新证书"
    echo "2) 续签已有证书"
    echo "3) 强制续签证书"
    echo "4) 查看证书状态"
    echo "0) 退出"
    echo "====================================================="
}

show_auth_menu() {
    clear
    echo "============= 选择验证模式 ============="
    echo "1) Cloudflare API Token (推荐)"
    echo "2) Cloudflare Global API Key"
    echo "3) HTTP 验证 (standalone)"
    echo "0) 返回上级"
    echo "======================================="
}

show_domain_input() {
    clear
    echo "============= 域名输入 ============="
    echo "请输入要操作的域名 (多个用空格分隔)"
    echo "输入 0 返回上级"
    echo "==================================="
}

# --------------------------
# 证书检测与操作
# --------------------------
check_cert_expiry() {
    local domain=$1
    local cert_file="/etc/letsencrypt/live/$domain/cert.pem"

    if [[ ! -f "$cert_file" ]]; then
        echo "[$(date '+%F %T')] [NEW] 新域名证书申请: $domain" | tee -a "$LOG_FILE"
        return 2
    fi

    local expiry_date expiry_ts now_ts days_left
    expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
    expiry_ts=$(date -d "$expiry_date" +%s)
    now_ts=$(date +%s)
    days_left=$(( (expiry_ts - now_ts) / 86400 ))

    if [[ "$days_left" -le "$DAYS_BEFORE_EXPIRE" ]]; then
        echo "[$(date '+%F %T')] [RENEW] 证书即将过期 (剩余 ${days_left} 天): $domain" | tee -a "$LOG_FILE"
        return 1
    else
        echo "[$(date '+%F %T')] [VALID] 证书有效 (剩余 ${days_left} 天): $domain" | tee -a "$LOG_FILE"
        return 0
    fi
}

issue_certificate() {
    local domain=$1
    local auth_mode=$2
    local force_renew=${3:-false}

    if [[ "$force_renew" == "false" ]]; then
        local need_renew
        if check_cert_expiry "$domain"; then
            need_renew=0
        else
            need_renew=$?
        fi
        [[ "$need_renew" -eq 0 ]] && return 0
    fi

    echo "[$(date '+%F %T')] [PROCESS] 正在处理: $domain" | tee -a "$LOG_FILE"

    case "$auth_mode" in
        1|2)
            docker run --rm \
                -v "/etc/letsencrypt:/etc/letsencrypt" \
                -v "$CF_CREDENTIALS:/cloudflare.ini" \
                certbot/dns-cloudflare certonly \
                --dns-cloudflare \
                --dns-cloudflare-credentials /cloudflare.ini \
                -d "$domain" -d "*.$domain" \
                --non-interactive \
                --agree-tos \
                --email "$EMAIL" \
                --key-type ecdsa \
                ${force_renew:+--force-renewal} 2>&1 | tee -a "$LOG_FILE"
            ;;
        3)
            local stopped_nginx=false
            if lsof -i:80 -t >/dev/null 2>&1; then
                echo "[$(date '+%F %T')] 80端口被占用，临时停止 nginx..." | tee -a "$LOG_FILE"
                docker stop nginx 2>/dev/null || true
                stopped_nginx=true
            fi

            docker run --rm \
                -v "/etc/letsencrypt:/etc/letsencrypt" \
                -p 80:80 \
                certbot/certbot certonly \
                --standalone \
                -d "$domain" -d "*.$domain" \
                --non-interactive \
                --agree-tos \
                --email "$EMAIL" \
                --key-type ecdsa \
                ${force_renew:+--force-renewal} 2>&1 | tee -a "$LOG_FILE"

            if [[ "$stopped_nginx" == true ]]; then
                echo "[$(date '+%F %T')] 恢复 nginx..." | tee -a "$LOG_FILE"
                docker start nginx 2>/dev/null || true
            fi
            ;;
    esac

    cp -f "/etc/letsencrypt/live/$domain/fullchain.pem" "${CERTS_DIR}/${domain}_cert.pem"
    cp -f "/etc/letsencrypt/live/$domain/privkey.pem" "${CERTS_DIR}/${domain}_key.pem"
    echo "[$(date '+%F %T')] [SUCCESS] 证书处理完成: $domain" | tee -a "$LOG_FILE"
}

# --------------------------
# Cloudflare 配置
# --------------------------
configure_auth() {
    local auth_mode=$1
    local current_mode=""

    # 检测当前 cloudflare.ini 模式
    if [[ -f "$CF_CREDENTIALS" ]]; then
        if grep -q "dns_cloudflare_api_token" "$CF_CREDENTIALS"; then
            current_mode="token"
        elif grep -q "dns_cloudflare_api_key" "$CF_CREDENTIALS"; then
            current_mode="global"
        fi
    fi

    case "$auth_mode" in
        1) # Token
            if [[ "$current_mode" == "token" ]]; then
                echo "[INFO] 已检测到 Token 模式，使用现有配置"
                return
            elif [[ "$current_mode" == "global" ]]; then
                read -rp "Cloudflare.ini 当前是 Global API Key 模式，是否切换为 Token 模式? (y/n) " yn
                [[ "$yn" != [Yy] ]] && return
            fi
            read -rp "请输入 Cloudflare API Token: " cf_token
            echo "dns_cloudflare_api_token=$cf_token" > "$CF_CREDENTIALS"
            chmod 600 "$CF_CREDENTIALS"
            ;;
        2) # Global API Key
            if [[ "$current_mode" == "global" ]]; then
                echo "[INFO] 已检测到 Global API Key 模式，使用现有配置"
                return
            elif [[ "$current_mode" == "token" ]]; then
                read -rp "Cloudflare.ini 当前是 Token 模式，是否切换为 Global API Key 模式? (y/n) " yn
                [[ "$yn" != [Yy] ]] && return
            fi
            read -rp "请输入 Cloudflare 邮箱: " cf_email
            read -rp "请输入 Global API Key: " cf_key
            echo "dns_cloudflare_email=$cf_email" > "$CF_CREDENTIALS"
            echo "dns_cloudflare_api_key=$cf_key" >> "$CF_CREDENTIALS"
            chmod 600 "$CF_CREDENTIALS"
            ;;
    esac
}

# --------------------------
# 菜单操作流程
# --------------------------
domain_input_flow() {
    local auth_mode=$1
    local action=$2

    while true; do
        show_domain_input
        read -rp "请输入域名: " -a domains
        [[ "${domains[0]}" == "0" ]] && return
        [[ ${#domains[@]} -eq 0 ]] && echo "错误：未输入域名！" && sleep 1 && continue

        for domain in "${domains[@]}"; do
            case "$action" in
                "new") issue_certificate "$domain" "$auth_mode" ;;
                "renew") issue_certificate "$domain" "$auth_mode" ;;
                "force") issue_certificate "$domain" "$auth_mode" "true" ;;
            esac
        done
        read -rp "操作完成，按回车键返回..." && return
    done
}

new_cert_flow() {
    while true; do
        show_auth_menu
        read -rp "请选择验证模式 (0-3): " auth_choice
        case "$auth_choice" in
            1|2|3)
                configure_auth "$auth_choice"
                domain_input_flow "$auth_choice" "new"
                return
                ;;
            0) return ;;
            *) echo "无效输入，请重新选择！"; sleep 1 ;;
        esac
    done
}

renew_cert_flow() {
    domain_input_flow "" "renew"
}

force_renew_flow() {
    while true; do
        show_auth_menu
        read -rp "请选择验证模式 (0-3): " auth_choice
        case "$auth_choice" in
            1|2|3) domain_input_flow "$auth_choice" "force"; return ;;
            0) return ;;
            *) echo "无效输入，请重新选择！"; sleep 1 ;;
        esac
    done
}

check_certs() {
    clear
    echo "============= 证书状态检查 ============="
    echo "域名                剩余天数    状态"
    echo "---------------------------------------"
    for cert in "${CERTS_DIR}"/*_cert.pem; do
        [[ -f "$cert" ]] || continue
        domain=$(basename "$cert" "_cert.pem")
        cert_file="/etc/letsencrypt/live/$domain/cert.pem"

        if [[ -f "$cert_file" ]]; then
            expiry_date=$(openssl x509 -enddate -noout -in "$cert_file" | cut -d= -f2)
            expiry_ts=$(date -d "$expiry_date" +%s)
            now_ts=$(date +%s)
            days_left=$(( (expiry_ts - now_ts) / 86400 ))
            [[ "$days_left" -le "$DAYS_BEFORE_EXPIRE" ]] && status="\e[31m即将过期\e[0m" || status="\e[32m有效\e[0m"
        else
            days_left="N/A"
            status="\e[33m未申请\e[0m"
        fi
        printf "%-20s %-10s %b\n" "$domain" "$days_left" "$status"
    done
    echo "---------------------------------------"
    read -rp "按回车返回主菜单..."
}

# --------------------------
# 主循环
# --------------------------
main() {
    init_environment
    while true; do
        show_main_menu
        read -rp "请输入选择 (0-4): " main_choice
        case "$main_choice" in
            1) new_cert_flow ;;
            2) renew_cert_flow ;;
            3) force_renew_flow ;;
            4) check_certs ;;
            0) echo "退出脚本"; exit 0 ;;
            *) echo "无效输入，请重新选择"; sleep 1 ;;
        esac
    done
}

# --------------------------
# 定时任务
# --------------------------
setup_cron() {
    CRON_JOB="0 3 * * * $INSTALL_PATH >> $LOG_FILE 2>&1"
    if ! crontab -l 2>/dev/null | grep -F "$INSTALL_PATH" >/dev/null; then
        (crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -
        echo "定时任务已添加，每天 03:00 自动检查并续签证书"
    fi
}

# --------------------------
# 启动
# --------------------------
setup_cron

# 直接进入菜单，无论 curl | bash 还是本地执行
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
