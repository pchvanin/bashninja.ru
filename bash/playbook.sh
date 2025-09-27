#!/usr/bin/env bash
# SRE PLAYBOOK by bashninja.ru — диагностика хоста (bash-only)
# Tested: Debian/Ubuntu/Kali/RHEL/Alma/Rocky, bare-metal/VM/container-friendly
# Usage: bash playbook.sh

################################################################################
# Общие настройки
################################################################################
LANG=C
LC_ALL=C
PATH=/usr/sbin:/sbin:/usr/bin:/bin:/usr/local/sbin:/usr/local/bin
IFS=$'\n\t'
shopt -s extglob

# Цвета
_rst=$'\033[0m'; _red=$'\033[31m'; _grn=$'\033[32m'; _yel=$'\033[33m'; _blu=$'\033[34m'; _cyn=$'\033[36m'
hdr(){   printf "\n## %s\n" "$*"; }
kv(){    printf " - %s: %s\n" "$1" "$2"; }
ok(){    printf "${_grn}OK${_rst}  %s\n" "$*"; }
warn(){  printf "${_yel}WARN${_rst} %s\n" "$*"; PROBLEMS+=("WARN|$*"); }
crit(){  printf "${_red}CRIT${_rst} %s\n" "$*"; PROBLEMS+=("CRIT|$*"); }
note(){  printf "     %s\n" "$*"; }
# Печать многострочных «вербатим» блоков без подстановок шелла
block(){ while IFS= read -r __line; do note "$__line"; done; }

have(){ command -v "$1" >/dev/null 2>&1; }
first_of(){ for c in "$@"; do have "$c" && { echo "$c"; return; }; done; echo ""; }

PROBLEMS=()

################################################################################
# Система и базовая информация
################################################################################
hdr "Система и базовая информация"
hostnamectl_status="$( (hostnamectl status 2>/dev/null || true) )"
kv "Host"      "$(hostname 2>/dev/null || awk -F. '{print $1}' /etc/hostname 2>/dev/null)"
kv "OS"        "$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"");print $2}' /etc/os-release 2>/dev/null || lsb_release -ds 2>/dev/null || uname -sr)"
kv "Kernel"    "$(uname -srmo 2>/dev/null)"
kv "Uptime"    "$(uptime -p 2>/dev/null | sed 's/up //')"
# Таймзона
tz_line="$(timedatectl 2>/dev/null | awk -F': ' '/Time zone/{print $2}')"
kv "Timezone"  "${tz_line:-$(date +%Z)}"
# Виртуализация
virt="$(systemd-detect-virt 2>/dev/null || true)"
[ -n "$virt" ] && [ "$virt" != "none" ] && kv "Virtualization" "$virt"

################################################################################
# CPU / Load
################################################################################
hdr "CPU / Load"
cores="$( (getconf _NPROCESSORS_ONLN 2>/dev/null) || echo 1 )"
kv "Cores" "$cores"
kv "LoadAvg(1/5/15)" "$(awk '{printf "%.2f %.2f %.2f",$1,$2,$3}' /proc/loadavg 2>/dev/null)"

# PSI (Pressure Stall Information)
psi_val(){
  local f="$1"
  [ -r "$f" ] || { echo "n/a"; return; }
  awk -v k="avg10" -v m="avg60" '
    { for(i=1;i<=NF;i++){split($i,a,"="); if(a[1]=="avg10")v=a[2]; if(a[1]=="avg60")w=a[2]; } }
    END{ if(v==""||w=="") print "n/a"; else printf "%.2f / %.2f", v, w }
  ' "$f"
}
kv "PSI cpu.avg10/60" "$(psi_val /proc/pressure/cpu)"
kv "PSI mem.avg10/60" "$(psi_val /proc/pressure/memory)"
kv "PSI io.avg10/60"  "$(psi_val /proc/pressure/io)"

# iowait% и steal% — снимок по /proc/stat с дельтой
cpu_snapshot(){ awk '/^cpu[[:space:]]/{print $2,$3,$4,$5,$6,$7,$8,$9,$10,$11; exit}' /proc/stat; }
read -r u1 n1 s1 id1 io1 irq1 sirq1 st1 g1 gn1 <<< "$(cpu_snapshot)"
sleep 0.5
read -r u2 n2 s2 id2 io2 irq2 sirq2 st2 g2 gn2 <<< "$(cpu_snapshot)"
total=$(( (u2-u1)+(n2-n1)+(s2-s1)+(id2-id1)+(io2-io1)+(irq2-irq1)+(sirq2-sirq1)+(st2-st1) ))
iowp=$(awk -v d="$((io2-io1))" -v t="$total" 'BEGIN{printf "%.1f", (t>0? d*100/t : 0)}')
stlp=$(awk -v d="$((st2-st1))" -v t="$total" 'BEGIN{printf "%.1f", (t>0? d*100/t : 0)}')
kv "iowait%" "$iowp"
kv "steal%"  "$stlp"

echo "### Top CPU процессы"
ps -axo pid,ppid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | awk '
NR==1{printf "     %6s %6s %-14s %5s %5s\n",$1,$2,$3,$4,$5; next}
NR<=11{printf "     %6s %6s %-14s %5s %5s\n",$1,$2,$3,$4,$5}
'

################################################################################
# Память
################################################################################
hdr "Память"
( free -h || free ) 2>/dev/null
mem_total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
mem_avail_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
swap_total_kb=$(awk '/^SwapTotal:/{print $2}' /proc/meminfo 2>/dev/null)
swap_free_kb=$(awk '/^SwapFree:/{print $2}' /proc/meminfo 2>/dev/null)
if [ -n "$mem_total_kb" ] && [ -n "$mem_avail_kb" ]; then
  mem_avail_pct=$(awk -v a="$mem_avail_kb" -v t="$mem_total_kb" 'BEGIN{printf "%.0f", (t>0? a*100/t : 0)}')
  kv "MemAvailable%" "${mem_avail_pct}%"
  [ "$mem_avail_pct" -ge 30 ] && ok "Свободная память ок (available=${mem_avail_pct}%)" || warn "Мало свободной памяти (available=${mem_avail_pct}%)"
fi
if [ -n "$swap_total_kb" ] && [ -n "$swap_free_kb" ]; then
  swap_free_pct=$(awk -v f="$swap_free_kb" -v t="$swap_total_kb" 'BEGIN{printf "%.0f", (t>0? f*100/t : 0)}')
  kv "SwapFree%" "${swap_free_pct}%"
fi
kv "vm.swappiness" "$(sysctl -n vm.swappiness 2>/dev/null || echo n/a)"

echo "### Top RAM процессы"
ps -axo pid,ppid,comm,rss,%mem --sort=-rss 2>/dev/null | awk '
NR==1{printf "     %6s %6s %-18s %7s %5s\n","PID","PPID","COMMAND","RSS","%MEM"; next}
NR<=11{mb=$4/1024; printf "     %6s %6s %-18s %6.1fMiB %5s\n",$1,$2,$3,mb,$5}
'

################################################################################
# Диски: ёмкость и иноды
################################################################################
hdr "Диски: ёмкость и иноды"
(df -hT -x tmpfs -x devtmpfs -x squashfs 2>/dev/null || df -h) | sed 's/^/     /'
(df -iT -x tmpfs -x devtmpfs -x squashfs 2>/dev/null || df -i) | sed 's/^/     /'

################################################################################
# Диски: IO/подсистемы
################################################################################
hdr "Диски: IO/подсистемы"
if have iostat; then
  echo "### iostat -xz 1 2 (срез)"
  iostat -xz 1 2 2>/dev/null | sed 's/^/     /'
else
  note "iostat не найден (установи пакет: sysstat)"
fi

# Планировщик для корневого устройства
rootdev="$(df / | awk 'NR==2{print $1}')"
blk=""
if have lsblk; then
  blk="$(lsblk -no PKNAME "$rootdev" 2>/dev/null | head -n1)"
fi
if [ -z "$blk" ]; then
  # /dev/sda1 -> sda ; /dev/vda2 -> vda ; /dev/nvme0n1p2 -> nvme0n1
  base="${rootdev##*/}"
  blk="${base%%[0-9p]*}"
fi
if [ -r "/sys/block/$blk/queue/scheduler" ]; then
  sched="$(cat "/sys/block/$blk/queue/scheduler" 2>/dev/null)"
  cur="$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' <<<"$sched")"
  avail="$(sed 's/\[//;s/\]//' <<<"$sched")"
  kv "scheduler:$blk" "current=${cur:-n/a}; available=${avail:-$sched}"
fi

################################################################################
# Сеть
################################################################################
hdr "Сеть"
echo "### Интерфейсы"
ip -o link show 2>/dev/null | sed -E 's/^[0-9]+: //; s/:/ /' | awk '{mac="-"; for(i=1;i<=NF;i++) if($i ~ /link\/ether/) mac=$(i+1); printf "     %-16s %-12s %s <%s>\n",$1,$3,(mac=="-"?"":mac),$0}' | sed 's/ <.*$//'

echo "### Адреса"
# IPv4
ip -o -4 addr show 2>/dev/null | awk '{print "     "$2, $9}' | sed 's/$/ /'
# IPv6
ip -o -6 addr show 2>/dev/null | awk '{print "     "$2, $4}' | sed 's/$/ /'

echo "### Прослушиваемые порты (top 50)"
if have ss; then
  ss_out="$(ss -lntup 2>/dev/null | head -n 51)"
  if [ -n "$ss_out" ] && [ "$(printf "%s\n" "$ss_out" | wc -l)" -gt 1 ]; then
    printf "%s\n" "$ss_out" | sed 's/^/     /'
  else
    note "нет слушающих портов или нет прав на просмотр процессов"
  fi
else
  note "ss не найден"
fi

echo "### Ошибки и дропы на интерфейсах"
while read -r ifc; do
  [ "$ifc" = "lo" ] && {
    printf "     %-16s\n" "$ifc"
    printf "       RX: %12s %7s %6s %7s %7s %7s\n" \
      "$(cat /sys/class/net/lo/statistics/rx_packets 2>/dev/null)" \
      "$(cat /sys/class/net/lo/statistics/rx_dropped 2>/dev/null)" \
      "$(cat /sys/class/net/lo/statistics/rx_errors 2>/dev/null)" \
      "0" "0" "0"
    printf "       TX: %12s %7s %6s %7s %7s %7s\n" \
      "$(cat /sys/class/net/lo/statistics/tx_packets 2>/dev/null)" \
      "$(cat /sys/class/net/lo/statistics/tx_dropped 2>/dev/null)" \
      "$(cat /sys/class/net/lo/statistics/tx_errors 2>/dev/null)" \
      "0" "0" "0"
    continue
  }
  [ -d "/sys/class/net/$ifc" ] || continue
  printf "     %-16s\n" "$ifc"
  printf "       RX: %12s %7s %6s %7s %7s %7s\n" \
    "$(cat /sys/class/net/$ifc/statistics/rx_packets 2>/dev/null)" \
    "$(cat /sys/class/net/$ifc/statistics/rx_dropped 2>/dev/null)" \
    "$(cat /sys/class/net/$ifc/statistics/rx_errors 2>/dev/null)" \
    "0" "0" "0"
  printf "       TX: %12s %7s %6s %7s %7s %7s\n" \
    "$(cat /sys/class/net/$ifc/statistics/tx_packets 2>/dev/null)" \
    "$(cat /sys/class/net/$ifc/statistics/tx_dropped 2>/dev/null)" \
    "$(cat /sys/class/net/$ifc/statistics/tx_errors 2>/dev/null)" \
    "0" "0" "0"
done < <(ls -1 /sys/class/net 2>/dev/null)

# Скорость/дуплекс для активных ethernet-интерфейсов
for dev in $(ls -1 /sys/class/net 2>/dev/null | grep -E '^(e(th|n|n[a-z0-9]+)|enp|ens|eth)[0-9a-z]*$' || true); do
  if have ethtool; then
    spd="$(ethtool "$dev" 2>/dev/null | awk -F': ' '/Speed:/{print $2}')"
    dup="$(ethtool "$dev" 2>/dev/null | awk -F': ' '/Duplex:/{print $2}')"
    [ -n "$spd" ] && note " $dev       Speed: $spd"
    [ -n "$dup" ] && note " $dev       Duplex: $dup"
  fi
done

# Связность
gw="$(ip route 2>/dev/null | awk '/^default/{print $3; exit}')"
if [ -n "$gw" ]; then
  if ping -c1 -W1 "$gw" >/dev/null 2>&1; then ok "Gateway ($gw) доступен"; else warn "Gateway ($gw) недоступен"; fi
fi
if ping -c1 -W1 1.1.1.1 >/dev/null 2>&1; then ok "Интернет ICMP доступен"; else warn "Интернет ICMP недоступен"; fi
if getent hosts google.com >/dev/null 2>&1; then ok "DNS resolution работает"; else warn "DNS resolution не работает"; fi
if ping -6 -c1 -W1 2001:4860:4860::8888 >/dev/null 2>&1; then note "IPv6 ICMP доступен"; else note "IPv6 ICMP недоступен"; fi

echo "### Маршруты (срез)"
ip route 2>/dev/null | sed 's/^/     /'

################################################################################
# Время/синхронизация
################################################################################
hdr "Время/синхронизация"
if have timedatectl; then
  timedatectl 2>/dev/null | sed -nE 's/^[[:space:]]+//; /Local time|Universal time|RTC time|Time zone|System clock synchronized|NTP service|RTC in local TZ/p' | sed 's/^/     /'
else
  date | sed 's/^/     /'
fi

################################################################################
# Сервисы и события ядра
################################################################################
hdr "Сервисы и события ядра"
if have systemctl; then
  failed="$(systemctl --failed --no-legend 2>/dev/null || true)"
  if [ -z "$failed" ]; then
    ok "Неуспешных systemd юнитов нет"
  else
    warn "Есть неуспешные systemd юниты"
    printf "%s\n" "$failed" | sed 's/^/       /'
  fi

  echo "### systemd-analyze critical-chain (срез)"
  if have systemd-analyze; then
    systemd-analyze critical-chain 2>/dev/null | sed 's/^/     /'
  else
    note "systemd-analyze недоступен"
  fi
fi

echo "### Последние ошибки (journalctl -p err -b, tail 100)"
(journalctl -p err -b 2>/dev/null | tail -n 100) | sed 's/^/     /'

echo "### dmesg (err/warn, хвост)"
(dmesg -T --level=err,warn 2>/dev/null | tail -n 30) | sed 's/^/     /'

################################################################################
# Безопасность
################################################################################
hdr "Безопасность"
# SELinux/AppArmor
if have getenforce; then
  sel="$(getenforce 2>/dev/null)"; [ -n "$sel" ] && kv "SELinux" "$sel"; else kv "SELinux" "не установлен"; fi
if have aa-status; then apparmor_status | head -n1 | sed 's/^/ - /'; else kv "AppArmor" "enabled"; fi

kv "ulimit -n (nofile)" "$(ulimit -n 2>/dev/null || echo n/a)"
kv "vm.max_map_count"   "$(sysctl -n vm.max_map_count 2>/dev/null || echo n/a)"

# THP статус
thp_enabled="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "n/a")"
thp_defrag="$(cat /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || echo "n/a")"
if [ "$thp_enabled" != "n/a" ]; then
  sel_mode="$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' <<<"$thp_enabled")"
  kv "THP" "$thp_enabled"
  [ "$sel_mode" = "always" ] && warn "THP=always: для PostgreSQL/Elastic лучше madvise/never"
  kv "entropy" "$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo n/a)"
else
  kv "THP" "n/a"
fi

# SSH policy
if have sshd; then
  echo "### SSH policy (sshd -T)"
  sshd -T 2>/dev/null | egrep -i '^(maxauthtries|permitrootlogin|pubkeyauthentication|passwordauthentication|ciphers|macs|kexalgorithms)\b' | sed 's/^/     /'
  if sshd -T 2>/dev/null | grep -iq '^passwordauthentication yes'; then
    warn "SSH: PasswordAuthentication yes"
  fi
else
  note "sshd не найден"
fi

# auditd
if have systemctl; then
  if systemctl is-active auditd >/dev/null 2>&1; then note "auditd активен"; else note "auditd не активен"; fi
fi

# Разные sysctl
ptrace="$(sysctl -n kernel.yama.ptrace_scope 2>/dev/null || cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo 0)"
kv "ptrace_scope" "$ptrace"; [ "$ptrace" -eq 0 ] && warn "ptrace_scope=0 (широкий ptrace)"
kv "ASLR randomize_va_space" "$(sysctl -n kernel.randomize_va_space 2>/dev/null || echo n/a)"
kv "unprivileged_bpf_disabled" "$(sysctl -n kernel.unprivileged_bpf_disabled 2>/dev/null || echo n/a)"
kv "kptr_restrict" "$(sysctl -n kernel.kptr_restrict 2>/dev/null || echo n/a)"
kv "core ulimit (-c)" "$(ulimit -c 2>/dev/null || echo n/a)"
kv "core_pattern" "$(cat /proc/sys/kernel/core_pattern 2>/dev/null || echo n/a)"

echo "### sysctl срез (важное)"
for k in vm.dirty_ratio vm.dirty_background_ratio vm.overcommit_memory vm.overcommit_ratio net.core.somaxconn net.ipv4.tcp_fin_timeout net.ipv4.ip_local_port_range fs.file-max; do
  v="$(sysctl -n "$k" 2>/dev/null || echo n/a)"
  printf "     %s = %s\n" "$k" "$v"
done

################################################################################
# Фаервол
################################################################################
hdr "Фаервол"
if have nft; then
  echo "### nft ruleset (срез)"
  nft list ruleset 2>/dev/null | sed -n '1,120p' | sed 's/^/     /'
else
  note "nft не найден (или нет правил)"
fi

################################################################################
# Пакеты/обновления
################################################################################
hdr "Пакеты/обновления"
if have apt; then
  echo "### Доступны обновления (итого + топ 15)"
  up_raw="$(apt list --upgradeable 2>/dev/null | tail -n +2 || true)"
  up_cnt="$(printf "%s\n" "$up_raw" | sed '/^\s*$/d' | wc -l | awk '{print $1}')"
  printf " - Всего апдейтов: %s\n" "${up_cnt:-0}"
  printf "%s\n" "$up_raw" | head -n 15 | \
    sed -E 's#^([^/]+)/([^ ]+)[^ ]*[ ]+([^ ]+).*upgradable from: ([^]]+)\]#     \1: \4 -> \2#g'
else
  note "apt недоступен"
fi

################################################################################
# Контейнеры
################################################################################
hdr "Контейнеры"
if have docker; then
  docker ps --format 'table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}' 2>/dev/null | sed 's/^/     /'
elif have podman; then
  podman ps --format 'table {{.ID}}\t{{.Image}}\t{{.Status}}\t{{.Names}}' 2>/dev/null | sed 's/^/     /'
else
  note "контейнеров не обнаружено или docker/podman не установлен"
fi

################################################################################
# Топ по открытым файловым дескрипторам
################################################################################
hdr "Топ по открытым файловым дескрипторам"
if have lsof; then
  lsof -n -P 2>/dev/null | awk 'NR>1{c[$2]++} END{for(pid in c) printf "%8d pid=%s\n", c[pid], pid}' | sort -nr | head -n 10 | \
  while read -r line; do
    n=$(awk '{print $1}' <<<"$line")
    pid=$(awk -F'=' '{print $2}' <<<"$line")
    comm=$(cat "/proc/$pid/comm" 2>/dev/null)
    ppid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)
    printf "     %4s pid=%s %s%s%s\n" "$n" "$pid" "${comm:-?}" "${ppid:+ (ppid=}", "${ppid:+$ppid)}" | sed 's/ (),//'
  done
else
  # Фоллбек без lsof
  for p in /proc/[0-9]*; do
    pid="${p##*/}"
    [ -r "$p/fd" ] || continue
    n=$(ls -1 "$p/fd" 2>/dev/null | wc -l)
    echo "$n $pid"
  done | sort -nr | head -n 10 | while read -r n pid; do
    comm=$(cat "/proc/$pid/comm" 2>/dev/null)
    ppid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null)
    printf "     %4s pid=%s %s%s%s\n" "$n" "$pid" "${comm:-?}" "${ppid:+ (ppid=}", "${ppid:+$ppid)}" | sed 's/ (),//'
  done
fi

################################################################################
# Сводка проблем + Подсказки
################################################################################
hdr "Сводка проблем"
crit_n=$(printf "%s\n" "${PROBLEMS[@]:-}" | grep -c '^CRIT|' 2>/dev/null || echo 0)
warn_n=$(printf "%s\n" "${PROBLEMS[@]:-}" | grep -c '^WARN|' 2>/dev/null || echo 0)
for p in "${PROBLEMS[@]:-}"; do
  lvl="${p%%|*}"; msg="${p#*|}"; printf "%s %s\n" "$lvl" "$msg"; done
printf "\nИтого: CRIT=%s WARN=%s\n" "$crit_n" "$warn_n"

# Контекстные подсказки
show_thp_help=false
show_ssh_help=false
for p in "${PROBLEMS[@]:-}"; do
  case "$p" in
    *"THP=always"*) show_thp_help=true ;;
    *"SSH: PasswordAuthentication yes"*) show_ssh_help=true ;;
  esac
done

if $show_thp_help; then
  hdr "Подсказки по THP"
  block <<'THP_HELP'
THP (Transparent Huge Pages) часто вреден для БД/Elastic из-за дефрагментации памяти.
Временно (до перезагрузки, madvise):
  echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null && \
  echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/defrag  >/dev/null

Навсегда (systemd unit, madvise):
  sudo bash -lc 'cat >/etc/systemd/system/disable-thp.service <<EOF
[Unit]
Description=Set Transparent Huge Pages to madvise
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/bin/bash -c '"'"'for f in /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag; do [ -w "$f" ] && echo madvise > "$f"; done'"'"'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now disable-thp.service'

Навсегда (GRUB, Debian/Ubuntu):
  sudo bash -lc 'f=/etc/default/grub; cp -n "$f"{,.bak}; \
    if grep -q "transparent_hugepage=" "$f"; then
      sed -i "s/transparent_hugepage=[^ \"]\\+/transparent_hugepage=madvise/" "$f";
    else
      sed -i "s/^GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"transparent_hugepage=madvise /" "$f";
    fi; update-grub && echo "Reboot required"'

Навсегда (GRUB, RHEL/Rocky/Alma):
  sudo bash -lc 'f=/etc/default/grub; cp -n "$f"{,.bak}; \
    if grep -q "transparent_hugepage=" "$f"; then
      sed -i "s/transparent_hugepage=[^ \"]\\+/transparent_hugepage=madvise/" "$f";
    else
      sed -i "s/^GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"transparent_hugepage=madvise /" "$f";
    fi; grub2-mkconfig -o /boot/grub2/grub.cfg && echo "Reboot required"'

Хотите «строго» отключить? замените madvise → never во всех командах ↑
Проверка: cat /sys/kernel/mm/transparent_hugepage/enabled — активный режим в [квадратных скобках].
THP_HELP
fi

if $show_ssh_help; then
  hdr "Быстрая правка SSH (отключить пароли)"
  block <<'SSH_FIX'
sudo bash -lc 'cfg=/etc/ssh/sshd_config; cp -n "$cfg"{,.bak}; \
  if grep -qi "PasswordAuthentication" "$cfg"; then
    sed -ri "s/^[#[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication no/" "$cfg";
  else
    printf "\nPasswordAuthentication no\n" >>"$cfg";
  fi; sshd -t && systemctl reload sshd'
SSH_FIX
fi
