#!/usr/bin/env bash
# 排查 PMIC / cpufreq 设备树与驱动绑定
set -uo pipefail
DT=/proc/device-tree

hr() { echo "--------------------------------------------------------------------"; }

echo "=== 1. PMIC 节点 (i2c@ff3c0000/pmic@1b) ==="
for f in compatible status name reg; do
  printf '  %-12s = ' "$f"
  cat "$DT/i2c@ff3c0000/pmic@1b/$f" 2>/dev/null | tr '\0' ' '
  echo
done
echo "  子节点: $(ls "$DT/i2c@ff3c0000/pmic@1b/" 2>/dev/null | tr '\n' ' ')"

echo
echo "=== 2. PMIC 的 regulators 子节点 ==="
for n in "$DT"/i2c@ff3c0000/pmic@1b/regulators/*; do
  [ -e "$n" ] || continue
  nm=$(cat "$n/regulator-name" 2>/dev/null | tr -d '\0')
  ph=$(cat "$n/phandle" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  printf '  %-14s name=%-18s phandle=0x%s\n' "$(basename "$n")" "$nm" "$ph"
done

echo
echo "=== 3. i2c@ff3c0000 上的其他设备 ==="
for n in "$DT"/i2c@ff3c0000/*; do
  [ -e "$n" ] || continue
  nm=$(basename "$n")
  comp=$(cat "$n/compatible" 2>/dev/null | tr '\0' ' ')
  ph=$(cat "$n/phandle" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  rn=$(cat "$n/regulator-name" 2>/dev/null | tr -d '\0')
  printf '  %-14s phandle=0x%-6s name=%-12s compatible=%s\n' "$nm" "$ph" "$rn" "$comp"
done

echo
echo "=== 4. CPU 节点与 cpu-supply 指向 ==="
for c in cpu@0 cpu@100; do
  p=$(cat "$DT/cpus/$c/cpu-supply" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  o=$(cat "$DT/cpus/$c/operating-points-v2" 2>/dev/null | od -An -tx1 | tr -d ' \n')
  echo "  $c: cpu-supply=0x$p  operating-points-v2=0x$o"
done

echo
echo "=== 5. OPP 表节点内容（cluster0 = A53 / cluster1 = A72）==="
for o in "$DT"/opp-table*; do
  [ -e "$o" ] || continue
  echo "  --- $(basename "$o") ---"
  echo "    compatible = $(cat "$o/compatible" 2>/dev/null | tr '\0' ' ')"
  for k in rockchip,bin-sel rockchip,grf rockchip,pvtm-ch rockchip,pvtm-voltage-sel \
           rockchip,pvtm-volt-sel rockchip,pvtm-freq rockchip,pvtm-sample-time \
           rockchip,pvtm-ref-temp rockchip,pvtm-temp-prop rockchip,leakage-voltage-sel \
           rockchip,low-temp rockchip,high-temp rockchip,temp-freq-table; do
    v=$(cat "$o/$k" 2>/dev/null | od -An -tx1 | tr -d ' \n')
    [ -n "$v" ] && printf '    %-34s = %s\n' "$k" "$v"
  done
  n=$(ls "$o" 2>/dev/null | grep -c 'opp@')
  echo "    opp 条目数: $n"
done

echo
echo "=== 6. 平台设备与驱动绑定 ==="
echo "  [rk8xx 平台设备]"; ls /sys/bus/platform/devices/ | grep -iE 'rk8' | sed 's/^/    /'
echo "  [rk8xx 驱动及已绑定设备]"
for d in /sys/bus/platform/drivers/*rk8*; do
  [ -e "$d" ] || continue
  echo "    $(basename "$d"): $(ls "$d" 2>/dev/null | grep -vE '^(bind|unbind|uevent|module)$' | tr '\n' ' ')"
done
echo "  [cpufreq 相关平台设备]"; ls /sys/bus/platform/devices/ | grep -iE 'cpu|opp' | sed 's/^/    /'
echo "  [cpufreq 驱动]"; ls /sys/bus/platform/drivers/ | grep -iE 'cpufreq' | sed 's/^/    /'
echo "  [regulator 平台驱动（前 25 个）]"; ls /sys/bus/platform/drivers/ | grep -iE 'regulator' | head -25 | sed 's/^/    /'
echo "  [cpufreq-dt 绑定了谁]"
for d in /sys/bus/platform/drivers/cpufreq-dt /sys/bus/platform/drivers/rockchip-cpufreq; do
  [ -e "$d" ] && echo "    $(basename "$d"): $(ls "$d" 2>/dev/null | grep -vE '^(bind|unbind|uevent|module)$' | tr '\n' ' ')"
done

echo
echo "=== 7. 设备树里 rk808 节点的 regulator 定义（前 20 个）==="
grep -a -o 'regulator-name[^;]*' "$DT"/i2c@ff3c0000/pmic@1b/regulators/*/regulator-name 2>/dev/null | head -0
for n in "$DT"/i2c@ff3c0000/pmic@1b/regulators/*; do
  [ -e "$n" ] || continue
  echo "    $(basename "$n"): $(cat "$n/regulator-name" 2>/dev/null | tr -d '\0')  min=$(cat "$n/regulator-min-microvolt" 2>/dev/null | od -An -tu4 | tr -d ' ') max=$(cat "$n/regulator-max-microvolt" 2>/dev/null | od -An -tu4 | tr -d ' ')"
done

echo
echo "=== 8. i2c@ff3c0000 控制器状态 ==="
cat "$DT/i2c@ff3c0000/status" 2>/dev/null | tr '\0' ' '; echo

echo
echo "=== 9. 全部 dmesg 中 11.4 ~ 11.7 秒的日志（PMIC/cpufreq 窗口）==="
dmesg | awk '{ if (match($0,/^\[ *([0-9]+\.[0-9]+)\]/,m)) { t=m[1]+0; if (t>=11.40 && t<=11.80) print "  " $0 } }' 2>/dev/null | head -60

echo
echo "=== 10. 内核命令行 ==="
cat /proc/cmdline

echo
echo "=== 11. 完整 dmesg 里 regulator/cpufreq 相关（不过滤关键词，看上下文）==="
dmesg | grep -inE 'regulator|cpufreq|opp|pmic|rk8' | head -40 | sed 's/^/  /'
