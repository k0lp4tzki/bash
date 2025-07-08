#!/bin/bash

#=====================================================
# HugePages System Checker & Configurator for Oracle
# Author: Dennis Kolpatzki (Interactive Refactor)
# Version: July 2025
#=====================================================

set -euo pipefail

# Colors (slimmed down)
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RESET='\033[0m'

banner() {
  echo -e "\n${BLUE}==== $1 ====${RESET}"
}

info() {
  echo -e "${GREEN}$1${RESET}"
}

warn() {
  echo -e "${YELLOW}$1${RESET}"
}

fail() {
  echo -e "${RED}$1${RESET}" >&2
}

meminfo() {
  awk -v key="$1" '$1 == key":" {print $2}' /proc/meminfo
}

# --- Parameter Parsing ---
INTERACTIVE=false
RECOMMEND_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --configure)
      INTERACTIVE=true
      ;;
    --recommend-only)
      RECOMMEND_ONLY=true
      ;;
    *)
      ;; # ignore
  esac
done

# Header
clear
banner "HugePages Check for Oracle Memory Configuration"

# Total Memory
MEM_TOTAL_KB=$(meminfo MemTotal)
MEM_TOTAL_GB=$(echo "scale=2; $MEM_TOTAL_KB / 1024 / 1024" | bc)
info "Memory Total: $MEM_TOTAL_KB kB (~$MEM_TOTAL_GB GB)"

# HugePages Total
HGP_TOTAL=$(meminfo HugePages_Total || echo 0)
if [[ -z "$HGP_TOTAL" || "$HGP_TOTAL" -eq 0 ]]; then
  warn "No HugePages configured."
else
  info "HugePages Configured: $HGP_TOTAL"
fi

# HugePage Size
HGP_SIZE_KB=$(meminfo Hugepagesize)
info "HugePage Size: $HGP_SIZE_KB kB"

# Free HugePages
HGP_FREE=$(meminfo HugePages_Free || echo 0)
info "Free HugePages: $HGP_FREE"

# Calculate free HugePage memory in GB
HGP_FREE_GB=$(echo "scale=2; $HGP_FREE * $HGP_SIZE_KB / 1024 / 1024" | bc)
info "Free HugePage Memory: ~$HGP_FREE_GB GB"

# Total HugePage memory configured
HGP_TOTAL_GB=$(echo "scale=2; $HGP_TOTAL * $HGP_SIZE_KB / 1024 / 1024" | bc)
info "Total HugePage Memory Reserved: ~$HGP_TOTAL_GB GB"

# Percent of RAM used for HugePages
HGP_PERCENT=$(echo "scale=1; $HGP_TOTAL * $HGP_SIZE_KB / $MEM_TOTAL_KB * 100" | bc)
info "~$HGP_PERCENT% of total RAM reserved for HugePages"

# SHMMAX check
SHMMAX_BYTES=$(sysctl -n kernel.shmmax)
SHMMAX_GB=$(echo "scale=2; $SHMMAX_BYTES / 1024 / 1024 / 1024" | bc)
info "kernel.shmmax: ~$SHMMAX_GB GB"

# Oracle Recommendation based on ipcs
banner "Oracle HugePages Recommendation (Doc ID 401749.1)"
KERNEL=$(uname -r | awk -F. '{print $1"."$2}')

HPG_SZ=$(meminfo Hugepagesize)
[[ -z "$HPG_SZ" ]] && fail "HugePages not supported." && exit 1

NUM_PAGES=0
for SEG in $(ipcs -m | awk 'NR>3 {print $5}'); do
  PAGES=$(echo "$SEG / ($HPG_SZ * 1024)" | bc)
  [[ "$PAGES" -gt 0 ]] && NUM_PAGES=$((NUM_PAGES + PAGES + 1))
done

RECOMMENDED="$NUM_PAGES"

KERNEL_SUPPORTED=false
case "$KERNEL" in
  2.*|3.*|4.*|5.*)
    info "Kernel $KERNEL supported."
    KERNEL_SUPPORTED=true
    info "Recommended HugePages (vm.nr_hugepages): $RECOMMENDED"
    ;;
  *)
    warn "Kernel version $KERNEL is not officially supported. Recommendation might not apply."
    ;;
esac

# Recommend only mode
if $RECOMMEND_ONLY; then
  echo -e "\nRecommendation only mode active. No changes applied."
  exit 0
fi

# --- Interactive Mode ---
if $INTERACTIVE; then
  echo
  echo "Interactive configuration enabled."

  CFG_FILE="/etc/sysconfig/oracle"
  BACKUP_FILE="${CFG_FILE}.bak_$(date +%s)"

  if $KERNEL_SUPPORTED; then
    read -rp "Apply recommended setting ($RECOMMENDED) to /etc/sysconfig/oracle and live system? [y/N]: " ANSWER
    if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
      sudo cp "$CFG_FILE" "$BACKUP_FILE"
      if grep -qE '^NR_HUGE_PAGES=' "$CFG_FILE"; then
        sudo sed -i "s/^NR_HUGE_PAGES=.*/NR_HUGE_PAGES=$RECOMMENDED/" "$CFG_FILE"
      else
        echo "NR_HUGE_PAGES=$RECOMMENDED" | sudo tee -a "$CFG_FILE" >/dev/null
      fi
      sudo sysctl -w vm.nr_hugepages=$RECOMMENDED
      echo -e "${GREEN}Updated $CFG_FILE and applied setting live (backup: $BACKUP_FILE)${RESET}"
      LIVE_VAL=$(cat /proc/sys/vm/nr_hugepages)
      if [[ "$LIVE_VAL" -ne "$RECOMMENDED" ]]; then
        warn "Note: Live kernel setting does not match requested value."
        warn "Requested: $RECOMMENDED, Actual: $LIVE_VAL"
        echo "This typically means Oracle SGA is still using memory."
        echo "Restart the database or reboot to fully apply the change."
      fi
    else
      echo "No changes made."
    fi
  else
    MAX_PAGES=$(echo "$MEM_TOTAL_KB / $HGP_SIZE_KB" | bc)
    echo
    echo -e "${YELLOW}Attention! This kernel is not officially supported.${RESET}"
    echo "We cannot recommend a precise setting."
    echo "However, based on your memory and hugepage size,"
    echo "the theoretical maximum is: $MAX_PAGES hugepages"
    read -rp "Enter custom value to set nr_hugepages (or leave blank to skip): " CUSTOM
    if [[ -n "$CUSTOM" && "$CUSTOM" =~ ^[0-9]+$ ]]; then
      sudo cp "$CFG_FILE" "$BACKUP_FILE"
      if grep -qE '^NR_HUGE_PAGES=' "$CFG_FILE"; then
        sudo sed -i "s/^NR_HUGE_PAGES=.*/NR_HUGE_PAGES=$CUSTOM/" "$CFG_FILE"
      else
        echo "NR_HUGE_PAGES=$CUSTOM" | sudo tee -a "$CFG_FILE" >/dev/null
      fi
      sudo sysctl -w vm.nr_hugepages=$CUSTOM
      echo -e "${GREEN}Updated $CFG_FILE and applied custom setting live (backup: $BACKUP_FILE)${RESET}"
      LIVE_VAL=$(cat /proc/sys/vm/nr_hugepages)
      if [[ "$LIVE_VAL" -ne "$CUSTOM" ]]; then
        warn "Note: Live kernel setting does not match requested value."
        warn "Requested: $CUSTOM, Actual: $LIVE_VAL"
        echo "This typically means Oracle SGA is still using memory."
        echo "Restart the database or reboot to fully apply the change."
      fi
    else
      echo "No changes made."
    fi
  fi
fi

exit 0
