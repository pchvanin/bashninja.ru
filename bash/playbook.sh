#!/usr/bin/env bash
# SRE PLAYBOOK by bashninja.ru — диагностика хоста (bash-only)
# Tested: Debian/Ubuntu/Kali/RHEL/Alma/Rocky/openSUSE, bare-metal/VM/container-friendly
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
# Многострочные блоки без подстановок шелла
block(){ while IFS= read -r __line; do note "$__line"; done; }

have(){ command -v "$1" >/dev/null 2>&1; }
first_of(){ for c in "$@"; do have "$c" && { echo "$c"; return; }; done; echo ""; }

PROBLEMS=()

################################################################################
# Система и базовая информация
################################################################################
hdr "Система и базовая информация"
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
la_str="$(awk '{printf "%.2f %.2f %.2f",$1,$2,$3}' /proc/loadavg 2>/dev/null)"
kv "LoadAvg(1/5/15)" "$la_str"

# PSI (Pressure Stall Information) — усреднение
psi_val(){
  local f="$1"
  [ -r "$f" ] || { echo "n/a"; return; }
  awk '
    { for(i=1;i<=NF;i++){split($i,a,"="); m[a[1]]=a[2]} }
    END{ if(m["avg10"]==""||m["avg60"]=="") print "n/a"; else printf "%.2f / %.2f", m["avg10"], m["avg60"] }
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

# Автосигналы по нагрузке
la1="$(awk '{print $1}' /proc/loadavg 2>/dev/null)"
awk -v la="$la1" -v c="$cores" 'BEGIN{ if(c>0 && la/c>1.5) exit 0; else exit 1 }' && warn "Высокая нагрузка: LA1/Core > 1.5 (LA1=$la1, cores=$cores)"
awk -v w="$iowp" 'BEGIN{ if(w>=10.0) exit 0; else exit 1 }' && warn "Высокий iowait (>=10%) — возможны узкие места диска"
awk -v s="$stlp" 'BEGIN{ if(s>=5.0) exit 0; else exit 1 }'  && warn "Высокий steal% (>=5%) — гипервизор/«шумный сосед»"

echo "### Top CPU процессы"
ps -axo pid,ppid,comm,%cpu,%mem --sort=-%cpu 2>/dev/null | awk '
NR==1{printf "     %6s %6s %-18s %5s %5s\n",$1,$2,$3,$4,$5; next}
NR<=11{printf "     %6s %6s %-18s %5s %5s\n",$1,$2,$3,$4,$5}
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
swap_warn=false
if [ -n "$mem_total_kb" ] && [ -n "$mem_avail_kb" ]; then
  mem_avail_pct=$(awk -v a="$mem_avail_kb" -v t="$mem_total_kb" 'BEGIN{printf "%.0f", (t>0? a*100/t : 0)}')
  kv "MemAvailable%" "${mem_avail_pct}%"
  if [ "$mem_avail_pct" -ge 30 ]; then
    ok "Свободная память ок (available=${mem_avail_pct}%)"
  else
    warn "Мало свободной памяти (available=${mem_avail_pct}%)"; swap_warn=true
  fi
fi
if [ -n "$swap_total_kb" ] && [ -n "$swap_free_kb" ]; then
  swap_free_pct=$(awk -v f="$swap_free_kb" -v t="$swap_total_kb" 'BEGIN{printf "%.0f", (t>0? f*100/t : 0)}')
  kv "SwapFree%" "${swap_free_pct}%"
  # Если своп отключен/нулевой и мало памяти — подсказка
  if [ "$swap_total_kb" -eq 0 ] && [ "$swap_warn" = true ]; then warn "Swap отсутствует при низкой памяти"; fi
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
df -hT -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | sed 's/^/     /'
df -iT -x tmpfs -x devtmpfs -x squashfs 2>/dev/null | sed 's/^/     /'

# Автосигналы по дисковому заполнению/инодам
while read -r mp usep; do
  up=${usep%%%}
  if [ "$up" -ge 95 ]; then crit "ФС почти заполнена ($mp: ${usep})"; fi
  if [ "$up" -ge 85 ] && [ "$up" -lt 95 ]; then warn "ФС высоко заполнена ($mp: ${usep})"; fi
done < <(df -P -x tmpfs -x devtmpfs -x squashfs | awk 'NR>1{print $6" "$5}')
while read -r mp iusep; do
  up=${iusep%%%}
  if [ "$up" -ge 95 ]; then warn "Inodes почти исчерпаны ($mp: ${iusep})"; fi
done < <(df -Pi -x tmpfs -x devtmpfs -x squashfs | awk 'NR>1{print $6" "$5}')

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
  base="${rootdev##*/}"
  blk="${base%%[0-9p]*}"
fi
if [ -r "/sys/block/$blk/queue/scheduler" ]; then
  sched="$(cat "/sys/block/$blk/queue/scheduler" 2>/dev/null)"
  cur="$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' <<<"$sched")"
  avail="$(sed 's/\[//;s/\]//' <<<"$sched")"
  kv "scheduler:$blk" "current=${cur:-n/a}; available=${avail:-$sched}"
  rot="$(cat /sys/block/$blk/queue/rotational 2>/dev/null || echo "")"
  if [ "$rot" = "0" ] && [ "$cur" = "cfq" ]; then warn "CFQ на SSD — рассмотрите mq-deadline/none"; fi
fi

################################################################################
# Сеть
################################################################################
hdr "Сеть"
echo "### Интерфейсы"
ip -o link show 2>/dev/null | sed -E 's/^[0-9]+: //; s/:/ /' | awk '{mac="-"; for(i=1;i<=NF;i++) if($i ~ /link\/ether/) mac=$(i+1); printf "     %-16s %-12s %s <%s>\n",$1,$3,(mac=="-"?"":mac),$0}' | sed 's/ <.*$//'

echo "### Адреса"
ip -o -4 addr show 2>/dev/null | awk '{print "     "$2, $9}' | sed 's/$/ /'
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
  [ -d "/sys/class/net/$ifc" ] || continue
  printf "     %-16s\n" "$ifc"
  for dir in rx tx; do
    printf "       %s: %12s %7s %6s %7s %7s %7s\n" \
      "$(tr a-z A-Z <<<"$dir")" \
      "$(cat /sys/class/net/$ifc/statistics/${dir}_packets 2>/dev/null)" \
      "$(cat /sys/class/net/$ifc/statistics/${dir}_dropped 2>/dev/null)" \
      "$(cat /sys/class/net/$ifc/statistics/${dir}_errors  2>/dev/null)" \
      "0" "0" "0"
  done
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
ntp_synced=""; ntp_service=""
if have timedatectl; then
  tdct="$(timedatectl 2>/dev/null)"
  printf "%s\n" "$tdct" | sed -nE 's/^[[:space:]]+//; /Local time|Universal time|RTC time|Time zone|System clock synchronized|NTP service|RTC in local TZ/p' | sed 's/^/     /'
  ntp_synced="$(awk -F': ' '/System clock synchronized/{print $2}' <<<"$tdct")"
  ntp_service="$(awk -F': ' '/NTP service/{print $2}' <<<"$tdct")"
  [ "$ntp_synced" != "yes" ] && warn "Часы не синхронизированы (timedatectl)"
  [[ ! "$ntp_service" =~ active|yes ]] && warn "NTP service не активен"
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
  sel="$(getenforce 2>/dev/null)"; [ -n "$sel" ] && kv "SELinux" "$sel"; 
else
  kv "SELinux" "не установлен"
fi
aa_cmd="$(first_of aa-status apparmor_status)"
if [ -n "$aa_cmd" ]; then
  "$aa_cmd" 2>/dev/null | head -n1 | sed 's/^/ - /'
else
  # Попробуем systemd unit
  if have systemctl && systemctl is-enabled apparmor >/dev/null 2>&1; then
    kv "AppArmor" "enabled"
  else
    kv "AppArmor" "unknown/disabled"
  fi
fi

ulnofile="$(ulimit -n 2>/dev/null || echo n/a)"
kv "ulimit -n (nofile)" "$ulnofile"; 
if [ "$ulnofile" != "n/a" ] && [ "$ulnofile" -lt 8192 ] 2>/dev/null; then
  warn "Низкий nofile ($ulnofile) — может упираться в сокеты/FD"
fi

vmmap="$(sysctl -n vm.max_map_count 2>/dev/null || echo n/a)"
kv "vm.max_map_count" "$vmmap"
if [ "$vmmap" != "n/a" ] && [ "$vmmap" -lt 262144 ] 2>/dev/null; then
  warn "vm.max_map_count < 262144 (для ES/ClickHouse/нагруженных БД)"
fi

# THP статус
thp_enabled="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo "n/a")"
thp_defrag="$(cat /sys/kernel/mm/transparent_hugepage/defrag  2>/dev/null || echo "n/a")"
if [ "$thp_enabled" != "n/a" ]; then
  sel_mode="$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' <<<"$thp_enabled")"
  kv "THP" "$thp_enabled"
  [ "$sel_mode" = "always" ] && warn "THP=always: для PostgreSQL/Elastic лучше madvise/never"
else
  kv "THP" "n/a"
fi

# Entropy
ent="$(cat /proc/sys/kernel/random/entropy_avail 2>/dev/null || echo n/a)"
kv "entropy" "$ent"
if [ "$ent" != "n/a" ] && [ "$ent" -lt 200 ] 2>/dev/null; then
  warn "Низкая энтропия (<200) — медленные TLS/SSH/PGP операции"
fi

# SSH policy
if have sshd; then
  echo "### SSH policy (sshd -T)"
  sshd -T 2>/dev/null | egrep -i '^(maxauthtries|permitrootlogin|pubkeyauthentication|passwordauthentication|ciphers|macs|kexalgorithms)\b' | sed 's/^/     /'
  if sshd -T 2>/dev/null | grep -iq '^passwordauthentication yes'; then warn "SSH: PasswordAuthentication yes"; fi
  if sshd -T 2>/dev/null | grep -iq '^permitrootlogin yes'; then warn "SSH: PermitRootLogin yes"; fi
else
  note "sshd не найден"
fi

# auditd
if have systemctl; then
  if systemctl is-active auditd >/dev/null 2>&1; then note "auditd активен"; else warn "auditd не активен"; fi
fi

# Разные sysctl
ptrace="$(sysctl -n kernel.yama.ptrace_scope 2>/dev/null || cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo 0)"
kv "ptrace_scope" "$ptrace"; [ "$ptrace" -eq 0 ] && warn "ptrace_scope=0 (широкий ptrace)"
aslr="$(sysctl -n kernel.randomize_va_space 2>/dev/null || echo n/a)"
kv "ASLR randomize_va_space" "$aslr"; [ "$aslr" = "0" ] && warn "ASLR выключен (randomize_va_space=0)"
kv "unprivileged_bpf_disabled" "$(sysctl -n kernel.unprivileged_bpf_disabled 2>/dev/null || echo n/a)"
kptr="$(sysctl -n kernel.kptr_restrict 2>/dev/null || echo n/a)"
kv "kptr_restrict" "$kptr"; [ "$kptr" = "0" ] && warn "kptr_restrict=0 — утечка адресов ядра"
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
UP_CNT=0; PKG_MGR=""
if have apt; then
  PKG_MGR="apt"
  echo "### Доступны обновления (итого + топ 15)"
  up_raw="$(apt list --upgradeable 2>/dev/null | tail -n +2 || true)"
  UP_CNT="$(printf "%s\n" "$up_raw" | sed '/^\s*$/d' | wc -l | awk '{print $1}')"
  printf " - Всего апдейтов: %s\n" "${UP_CNT:-0}"
  printf "%s\n" "$up_raw" | head -n 15 | \
    sed -E 's#^([^/]+)/([^ ]+)[^ ]*[ ]+([^ ]+).*upgradable from: ([^]]+)\]#     \1: \4 -> \2#g'
elif have dnf; then
  PKG_MGR="dnf"
  UP_CNT="$(dnf -q check-update 2>/dev/null | awk 'NF==3 && $2 ~ /[0-9]/ {n++} END{print n+0}')"
  kv "Доступно обновлений (dnf)" "$UP_CNT"
elif have yum; then
  PKG_MGR="yum"
  UP_CNT="$(yum -q check-update 2>/dev/null | awk 'NF==3 && $2 ~ /[0-9]/ {n++} END{print n+0}')"
  kv "Доступно обновлений (yum)" "$UP_CNT"
elif have zypper; then
  PKG_MGR="zypper"
  UP_CNT="$(zypper -q lu 2>/dev/null | awk 'BEGIN{n=0}/v | v /{n++}END{print n}')"
  kv "Доступно обновлений (zypper)" "$UP_CNT"
else
  note "менеджер пакетов не распознан"
fi
if [ "$UP_CNT" -gt 0 ] 2>/dev/null; then warn "Есть доступные обновления пакетов ($UP_CNT)"; fi

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
# Сводка проблем + Авто-подсказки/фиксы
################################################################################
hdr "Сводка проблем"
crit_n=$(printf "%s\n" "${PROBLEMS[@]:-}" | grep -c '^CRIT|' 2>/dev/null || echo 0)
warn_n=$(printf "%s\n" "${PROBLEMS[@]:-}" | grep -c '^WARN|' 2>/dev/null || echo 0)
for p in "${PROBLEMS[@]:-}"; do
  lvl="${p%%|*}"; msg="${p#*|}"; printf "%s %s\n" "$lvl" "$msg"; done
printf "\nИтого: CRIT=%s WARN=%s\n" "$crit_n" "$warn_n"

# Какие подсказки показывать
show_thp_help=false
show_ssh_help=false
show_mem_help=false
show_dns_help=false
show_gw_help=false
show_failed_units_help=false
show_ptrace_help=false
show_vmmap_help=false
show_auditd_help=false
show_updates_help=false
show_ntp_help=false
show_entropy_help=false
show_iowait_help=false
show_steal_help=false
show_fs_usage_help=false
show_inodes_help=false
show_ulimit_help=false
show_kptr_help=false

# Триггеры из PROBLEMS
for p in "${PROBLEMS[@]:-}"; do
  case "$p" in
    *"THP=always"*) show_thp_help=true ;;
    *"SSH: PasswordAuthentication yes"*) show_ssh_help=true ;;
    *"SSH: PermitRootLogin yes"*) show_ssh_help=true ;;
    *"Мало свободной памяти ("*) show_mem_help=true ;;
    *"Swap отсутствует"*) show_mem_help=true ;;
    *"DNS resolution не работает"*) show_dns_help=true ;;
    *"Gateway ("*" недоступен"*) show_gw_help=true ;;
    *"Есть неуспешные systemd юниты"*) show_failed_units_help=true ;;
    *"ptrace_scope=0"*) show_ptrace_help=true ;;
    *"vm.max_map_count < 262144"*) show_vmmap_help=true ;;
    *"auditd не активен"*) show_auditd_help=true ;;
    *"Низкая энтропия"*) show_entropy_help=true ;;
    *"Высокий iowait"*) show_iowait_help=true ;;
    *"Высокий steal%"*) show_steal_help=true ;;
    *"ФС почти заполнена"*|*"ФС высоко заполнена"*) show_fs_usage_help=true ;;
    *"Inodes почти исчерпаны"*) show_inodes_help=true ;;
    *"Низкий nofile"*) show_ulimit_help=true ;;
    *"kptr_restrict=0"*) show_kptr_help=true ;;
    *"Часы не синхронизированы"*|*"NTP service не активен"*) show_ntp_help=true ;;
    *"Есть доступные обновления пакетов"*) show_updates_help=true ;;
  esac
done

# Показываем контекстные блоки
if $show_thp_help; then
  hdr "THP → madvise/never (почему и как быстро починить)"
  block <<'THP_HELP'
THP (Transparent Huge Pages) вызывает дефрагментацию памяти и паузы GC — вредно для PostgreSQL/Elastic/Kafka.
Временно (до перезагрузки, madvise):
  echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null && \
  echo madvise | sudo tee /sys/kernel/mm/transparent_hugepage/defrag  >/dev/null

Навсегда (systemd unit):
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

Через GRUB (Debian/Ubuntu):
  sudo sed -i.bak 's/\(GRUB_CMDLINE_LINUX="\)/\1transparent_hugepage=madvise /' /etc/default/grub
  sudo update-grub && echo "Reboot required"

Через GRUB (RHEL/Rocky/Alma):
  sudo sed -i.bak 's/\(GRUB_CMDLINE_LINUX="\)/\1transparent_hugepage=madvise /' /etc/default/grub
  sudo grub2-mkconfig -o /boot/grub2/grub.cfg && echo "Reboot required"

Строго выключить? замените madvise → never во всех командах выше.
Проверка: cat /sys/kernel/mm/transparent_hugepage/enabled — активный режим в [квадратных скобках].
THP_HELP
fi

if $show_ssh_help; then
  hdr "SSH hardening (выключить пароли/RootLogin)"
  block <<'SSH_FIX'
Отключить пароли и root-логин по SSH:
sudo bash -lc 'cfg=/etc/ssh/sshd_config; cp -n "$cfg"{,.bak}; \
  sed -ri "s/^[#[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication no/" "$cfg"; \
  if grep -qi "PermitRootLogin" "$cfg"; then \
     sed -ri "s/^[#[:space:]]*PermitRootLogin[[:space:]].*/PermitRootLogin prohibit-password/" "$cfg"; \
  else echo "PermitRootLogin prohibit-password" >>"$cfg"; fi; \
  sshd -t && systemctl reload sshd'
SSH_FIX
fi

if $show_mem_help; then
  hdr "Память: быстрый triage и своп"
  block <<'MEM_HELP'
Смотри пожирателей RAM:
  ps aux --sort=-%mem | head -n 20
Проверь своп и политику:
  swapon --show ; sysctl vm.swappiness
Быстро добавить временный swap-файл (пример 2ГБ):
  sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
Постоянно — строка в /etc/fstab:
  /swapfile none swap sw 0 0
JVM/Elastic — проверь -Xms/-Xmx и GC; для контейнеров — лимиты cgroup.
Если подозрение на memleak — смотри: smem, pmap -x <pid>, heap dump, perf top/record.
MEM_HELP
fi

if $show_dns_help; then
  hdr "DNS не работает — быстрые фиксы"
  block <<'DNS_HELP'
Проверки:
  resolvectl status || systemd-resolve --status
  getent hosts google.com || dig +short google.com @1.1.1.1
Фиксы (systemd-resolved):
  sudo resolvectl dns <iface> 1.1.1.1 8.8.8.8
  sudo resolvectl domain <iface> '~.'
  sudo systemctl restart systemd-resolved
Если NetworkManager — проверь профиль и /etc/resolv.conf (symlink на /run/systemd/resolve/stub-resolv.conf).
DNS_HELP
fi

if $show_gw_help; then
  hdr "Шлюз недоступен — что проверить"
  block <<'GW_HELP'
Сетевые карты/адреса/маршруты:
  ip addr ; ip route ; arping -c1 <GW>
DHCP переинициализация (пример для eth0):
  sudo dhclient -r -v eth0 && sudo dhclient -v eth0
Статический маршрут (заменить значения на свои):
  sudo ip route replace default via <GW> dev <IFACE>
Проверь, не включена ли политика/файрвол в гипервизоре/облаке (security group, NSG и т.п.).
GW_HELP
fi

if $show_failed_units_help; then
  hdr "Неуспешные systemd юниты — разбор"
  block <<'FAILED_HELP'
Список и статус:
  systemctl --failed
  systemctl status <unit> -l --no-pager
Логи сервиса:
  journalctl -u <unit> --no-pager --since -1h
Перечитать/перезапустить:
  systemctl daemon-reload && systemctl restart <unit>
FAILED_HELP
fi

if $show_ptrace_help; then
  hdr "ptrace_scope — ограничить трейсинг"
  block <<'PTRACE_HELP'
Рекомендованное значение для хостов — 1:
  echo 'kernel.yama.ptrace_scope=1' | sudo tee /etc/sysctl.d/99-hardening.conf
  sudo sysctl --system
Временно:
  sudo sysctl -w kernel.yama.ptrace_scope=1
PTRACE_HELP
fi

if $show_kptr_help; then
  hdr "kptr_restrict — скрыть адреса ядра"
  block <<'KPTR_HELP'
Установить скрытие адресов ядра:
  echo 'kernel.kptr_restrict=1' | sudo tee /etc/sysctl.d/99-hardening.conf
  sudo sysctl --system
Временно:
  sudo sysctl -w kernel.kptr_restrict=1
KPTR_HELP
fi

if $show_vmmap_help; then
  hdr "vm.max_map_count — увеличить для ES/ClickHouse"
  block <<'VMMAP_HELP'
Рекомендуемое значение >= 262144:
  echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/60-elastic.conf
  sudo sysctl --system
Временно:
  sudo sysctl -w vm.max_map_count=262144
VMMAP_HELP
fi

if $show_auditd_help; then
  hdr "auditd — включить аудит"
  block <<'AUDIT_HELP'
Debian/Ubuntu/Kali:
  sudo apt update && sudo apt install -y auditd audispd-plugins
  sudo systemctl enable --now auditd
RHEL/Rocky/Alma:
  sudo dnf install -y audit
  sudo systemctl enable --now auditd
Проверка:
  auditctl -s ; ausearch -m USER_LOGIN -ts recent
AUDIT_HELP
fi

if $show_ntp_help; then
  hdr "NTP/время — включить синхронизацию"
  block <<'NTP_HELP'
Вариант systemd-timesyncd:
  sudo systemctl enable --now systemd-timesyncd
  timedatectl set-ntp true
Проверить источники и статус:
  timedatectl timesync-status || journalctl -u systemd-timesyncd --since -1h
Альтернатива: chrony
  sudo apt/dnf install -y chrony && sudo systemctl enable --now chronyd
NTP_HELP
fi

if $show_entropy_help; then
  hdr "Низкая энтропия — ускоряем генерацию случайных чисел"
  block <<'ENT_HELP'
Установить генератор энтропии:
  Debian/Ubuntu/Kali: sudo apt install -y haveged || sudo apt install -y jitterentropy-rngd
  RHEL/Rocky/Alma:    sudo dnf install -y haveged  || sudo dnf install -y jitterentropy
Включить и запустить:
  sudo systemctl enable --now haveged || sudo systemctl enable --now jitterentropy-rngd
ENT_HELP
fi

if $show_iowait_help; then
  hdr "Высокий iowait — где узкое место"
  block <<'IOWAIT_HELP'
Наблюдение:
  iostat -xz 1
  pidstat -d 1
  iotop -oPa
Проверь writeback:
  sysctl vm.dirty_background_ratio vm.dirty_ratio
SSD/NVMe — проверь планировщик:
  cat /sys/block/<dev>/queue/scheduler ; для SSD — mq-deadline/none лучше CFQ.
Файлы логов/журнала:
  journalctl --disk-usage ; logrotate; tmpwatch
IOWAIT_HELP
fi

if $show_steal_help; then
  hdr "Высокий steal% в виртуалке — действия"
  block <<'STEAL_HELP'
steal% означает, что гипервизор отбирает CPU-квоты.
Проверь загрузку узла-хоста, перенеси ВМ на другой узел, увеличь vCPU, включи CPU reservation/limit (если облако это поддерживает).
STEAL_HELP
fi

if $show_fs_usage_help; then
  hdr "Забит диск — что чистить в первую очередь"
  block <<'FS_HELP'
Что занимает место:
  sudo du -xhd1 / | sort -h | tail -n 20
Удобно ncdu:
  sudo apt/dnf install -y ncdu && sudo ncdu -x /
Журналы systemd:
  journalctl --disk-usage
  sudo journalctl --vacuum-time=7d
Docker:
  docker system df ; docker image prune -a ; docker volume ls ; docker volume rm <vol>
Kubernetes:
  crictl images ; crictl rmi --prune
FS_HELP
fi

if $show_inodes_help; then
  hdr "Мало инодов — много мелких файлов"
  block <<'INODES_HELP'
Найти каталоги с миллионами мелких файлов:
  sudo find / -xdev -type d -printf '%h\n' | sort | uniq -c | sort -nr | head
Очистка кэшей/логов/artefacts; для Docker — prune volumes/containers/images.
INODES_HELP
fi

if $show_ulimit_help; then
  hdr "Увеличить лимит открытых файлов (nofile)"
  block <<'ULIMIT_HELP'
Системно (PAM limits):
  echo '* soft nofile 1048576' | sudo tee -a /etc/security/limits.d/99-nofile.conf
  echo '* hard nofile 1048576' | sudo tee -a /etc/security/limits.d/99-nofile.conf
Для systemd-сервиса:
  sudo sed -i 's/^\(\[Service\]\)/\1\nLimitNOFILE=1048576/' /etc/systemd/system/<unit>.service
  sudo systemctl daemon-reload && sudo systemctl restart <unit>
ULIMIT_HELP
fi

if $show_updates_help; then
  hdr "Есть обновления — безопасное обновление"
  block <<'UPD_HELP'
Рекомендуется:
  Создать снапшот/бэкап; затем:
  Debian/Ubuntu: sudo apt update && sudo apt upgrade -y
  RHEL/Rocky/Alma: sudo dnf upgrade -y
  openSUSE: sudo zypper refresh && sudo zypper update -y
Ядро/миграции могут потребовать перезагрузку.
UPD_HELP
fi
