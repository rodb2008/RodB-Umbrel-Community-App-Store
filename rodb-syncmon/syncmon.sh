#!/bin/bash
VERSION="Blockchain Sync Monitor - Version 3.01 - Feb 28, 2026 (Docker-Hybrid)"
#
# Pre-req software:
#
# sudo apt install bc jq curl tmux -y
# List of required dependencies
DEPS=(bc jq curl tmux)

# Check and prompt for missing tools
for dep in "${DEPS[@]}"; do
    if ! command -v "$dep" &> /dev/null; then
        echo -e "\033[0;31mError: '$dep' is not installed.\033[0m"
        echo "Please run: sudo apt update && sudo apt install bc jq curl tmux -y"
        exit 1
    fi
done

# Verify Docker Permissions
if ! $DOCKER_CMD ps &> /dev/null; then
    echo -e "${R}Error: Cannot connect to Docker. Check permissions or sudo.${NC}"
    exit 1
fi

# Screen/Text Coloring
G='\033[0;32m'; C='\033[0;36m'; Y='\033[1;33m'; W='\033[1;37m'; R='\033[0;31m'; NC='\033[0m'
BG_Y='\033[103;30m'; BG_R='\033[41;37m'

# SMART CONFIG LOADER - Load external COIN Config File
if [ -f "./coin.config" ]; then
    CONF_FILE="./coin.config"
elif [ -f "/usr/local/bin/coin.config" ]; then
    CONF_FILE="/usr/local/bin/coin.config"
else
    echo -e "${R}Error: coin.config not found in . or /usr/local/bin/ ${NC}"
    exit 1
fi
source "$CONF_FILE"

# --- RPC WARMUP TRAP ---
echo -n "[ RPC: CONNECTING... ]"

while :; do
	clear
    echo -e "${C}${COIN} ${VERSION}${NC}"
	echo ""
	echo -e "${G}Initializing...${NC}"
	echo ""
    # Capture the full error output
    RESPONSE=$($CLI_PATH getblockchaininfo 2>&1)

    # If the command succeeds (Exit Code 0), the node is ready
    if [[ $? -eq 0 ]]; then
        echo -e "\r[ RPC: READY         ]                  "
        break
    fi

    # Check for specific "Warmup" messages
    if [[ "$RESPONSE" == *"-28"* ]]; then
        # Use grep to extract the percentage if it exists
        PROGRESS=$(echo "$RESPONSE" | grep -oP '\d+%' || echo "Starting...")
        echo -ne "\r[ RPC: WARMUP ] Indexing: $PROGRESS    "
    else
        echo -ne "\r[ RPC: OFFLINE ] Waiting for Daemon... "
    fi

    sleep 5
done

# --- TMUX SELF-LAUNCHER ---
if [ -z "$TMUX" ]; then
    SESSION_NAME="Sync-Monitor-$(date +%s)"
    tmux new-session -d -s "$SESSION_NAME" "bash $0"
	tmux bind L split-window -v "tail -f ${NODE_PATH}/${BLOCKCHAIN_DIR}/${NODE_LOGFILE} | grep --color=always -P 'height=\d+|'"
    tmux split-window -v -t "$SESSION_NAME" "tail -f ${NODE_PATH}/${BLOCKCHAIN_DIR}/${NODE_LOGFILE} | grep --color=always -P 'height=\d+|'"
    tmux attach-session -t "$SESSION_NAME"
    exit
fi

# Initialize Variables
STALL_ALERT_SENT=false
TARGET_ALERT_SENT=false
BIG_BLOCK_SENT=false
SWAP_ALERT_SENT=false
DIFF_HISTORY=()
PREV_BLOCKS=$($CLI_PATH getblockcount 2>/dev/null || echo 0)
PREV_BYTES=$($CLI_PATH getnettotals | jq .totalbytesrecv 2>/dev/null || echo 0)
PRUNING_CHECK=$($CLI_PATH getblockchaininfo | jq -r '.prune_target_size // 0' | numfmt --to=iec-i --suffix=B | sed 's/^0B$/Disabled/')
START_NET_TOTAL=$PREV_BYTES
MAX_BPM=0.00; MAX_DOWN=0.00
LAST_QUEUE_HEAD=""
QUEUE_TIMER=0
BLOCK_WEIGHT_MB=0
touch "$PEER_HISTORY"
START_BLOCKS=$PREV_BLOCKS
LAST_BLOCK_CHANGE=$SECONDS
START_TS=$(TZ="${YOUR_TZ}" date +"%b %d %H:%M")
SESSION_TOTAL_MB=0
SESSION_TOTAL_BLOCKS=0
LAST_AVG_BATCH="0.00"
PREV_RAM_VAL=0
PREV_SWAP_VAL=0
# Initialize math variables to zero to prevent 'bc' empty-string errors
SESS_AVG="0.01"
GB_LEFT="0.00"
LAST_AVG_BATCH="0.00"
BLOCK_WEIGHT_MB="0.00"
QUEUE_MB="0.00"
SESSION_TOTAL_MB="0.00"
SESSION_TOTAL_BLOCKS=0

REMAINING_LAUNCH=$((TARGET - PREV_BLOCKS))
REMAINING_FMT=$(echo $REMAINING_LAUNCH | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')

send_discord() {
    local msg="$1"
    # Simplified: No 'if' check needed, just send the ping!
    curl -H "Content-Type: application/json" -X POST \
         -d "{\"content\": \"<@$MY_UID> $msg <t:$(date +%s):f>\"}" \
         "$DISCORD_URL" > /dev/null 2>&1
}

generate_bar() {
    local percent=$(echo "$1 * 100 / 1" | bc) # Convert 0.xxxx to 0-100
    local filled=$(( percent / 10 ))
    local empty=$(( 10 - filled ))
    local bar=""
    for i in $(seq 1 $filled); do bar+="█"; done
    for i in $(seq 1 $empty); do bar+="░"; done
    echo "[$bar] $percent%"
}

# Check Discord Status for the UI
if curl --output /dev/null --silent --head --fail "$DISCORD_URL"; then
    DISCORD_STATUS="[ DISCORD: ONLINE ✅ ]"
    send_discord "${COIN} Monitor Link Established! 🚀\nTracking to Block ${TARGET} (Remaining: ${REMAINING_FMT})"
else
    DISCORD_STATUS="[ DISCORD: OFFLINE ❌ ]"
fi

update_display() {
  [ "$(echo "$SESS_AVG < 0" | bc -l)" -eq 1 ] && SESS_AVG="0.01"
  [ "$(echo "$GB_LEFT < 0" | bc -l)" -eq 1 ] && GB_LEFT="0.00"

  # 1. Fetch Data
  DATA=$($CLI_PATH getblockchaininfo 2>/dev/null)
  NET=$($CLI_PATH getnettotals 2>/dev/null)
  PEERS=$($CLI_PATH getpeerinfo 2>/dev/null)
  if [ -z "$DATA" ] || [ "$DATA" == "null" ]; then return; fi

  # 2. Process Block Stats
  CURR_BLOCKS=$(echo "$DATA" | jq -r '.blocks // 0')
  PRUNE_H=$(echo "$DATA" | jq -r '.pruneheight // 0')
  RETAINED=$((CURR_BLOCKS - PRUNE_H))
  
  if [ "$CURR_BLOCKS" -ne "$PREV_BLOCKS" ]; then
      LAST_BLOCK_CHANGE=$SECONDS
      STALL_COL=$G
  fi
  
  STALL_TIME=$(( SECONDS - LAST_BLOCK_CHANGE ))
  [ "$STALL_TIME" -gt 600 ] && STALL_COL=$R || { [ "$STALL_TIME" -gt 300 ] && STALL_COL=$Y || STALL_COL=$G; }

  TOTAL_SESS_BLOCKS=$(echo $((CURR_BLOCKS - START_BLOCKS)) | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')
  BLOCK_TS=$(echo "$DATA" | jq -r '.mediantime // 0')
  BLOCK_DATE=$(date -d "@$BLOCK_TS" +"%Y-%m-%d")
  PROG_DISPLAY=$(printf "%.2f" $(echo "$(echo "$DATA" | jq -r '.verificationprogress // 0') * 100" | bc -l))

  # 3. Network & Heartbeat
  CURR_BYTES=$(echo "$NET" | jq .totalbytesrecv)
  BYTE_DIFF=$((CURR_BYTES - PREV_BYTES))
  [ "$BYTE_DIFF" -lt 0 ] && BYTE_DIFF=0
  MB_PS=$(echo "scale=2; $BYTE_DIFF / 1024 / 1024 / 20" | bc | sed 's/^\./0./')
  [ -z "$MB_PS" ] && MB_PS="0.00"
  
  (( SECONDS % 40 == 0 )) && HEART="${G}●${NC}" || HEART="${G}○${NC}"
  SESSION_GB=$(echo "scale=2; ($CURR_BYTES - $START_NET_TOTAL) / 1024 / 1024 / 1024" | bc | awk '{printf "%.2f", $0}')

  # 4. Swap Watch
  SW_USED=$(free -g | awk '/^Swap:/ {print $3}')
  SW_STATS=$(free -h | awk '/^Swap:/ {print $3 "/" $2}' | sed 's/i//g')
  if [ "$SW_USED" -ge 15 ]; then SW_COL=$R; elif [ "$SW_USED" -ge 10 ]; then SW_COL=$Y; else SW_COL=$G; fi

  # --- SWAP PRESSURE ALERT (15GB+) ---
  if [ "$SW_USED" -ge 15 ]; then
      if [ "$SW_ALERT_SENT" = false ]; then
          send_discord "⚠️ **CRITICAL SWAP PRESSURE** ⚠️\n${COIN}\nSwap usage has reached **$SW_USED GB**! Node is at risk of an OOM crash. \n\n*Action: Consider graceful shutdown!\n\nNode is at risk of an OOM crash!"
          SW_ALERT_SENT=true
      fi
  else
      # Reset once swap pressure subsides (below 10GB)
      [ "$SW_USED" -lt 10 ] && SW_ALERT_SENT=false
  fi

  # 5. BPM, Size-Adjusted ETC & Metrics
  DIFF=$((CURR_BLOCKS - PREV_BLOCKS))
  DIFF_HISTORY+=($DIFF); [ ${#DIFF_HISTORY[@]} -gt 180 ] && DIFF_HISTORY=("${DIFF_HISTORY[@]:1}")
  SUM=0; for i in "${DIFF_HISTORY[@]}"; do SUM=$((SUM + i)); done
  BPM=$(echo "scale=2; $SUM / ${#DIFF_HISTORY[@]}" | bc | sed 's/^\./0./')
  
  SESS_BPM="0.00"
  if [ "$SECONDS" -gt 5 ]; then
    SESS_BPM=$(echo "scale=2; ($CURR_BLOCKS - $START_BLOCKS) * 60 / $SECONDS" | bc | sed 's/^\./0./')
  fi

  BLOCKS_LEFT=$((TARGET - CURR_BLOCKS))
  BLOCKS_LEFT_FMT=$(echo $BLOCKS_LEFT | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')
  
  # --- ENHANCED ETC CALCULATION ---
  # Use Session BPM for the timeline
  CALC_BPM=${SESS_BPM:-$BPM}
  
  if (( $(echo "$CALC_BPM > 0" | bc -l) )); then
    TOTAL_MINS=$(echo "$BLOCKS_LEFT / $CALC_BPM" | bc)
    EST_DUR="$(TZ="${YOUR_TZ}" date -d "+$TOTAL_MINS minutes" +"%b %d %H:%M")"
    T_DAYS=$((TOTAL_MINS/1440)); T_HRS=$(((TOTAL_MINS%1440)/60)); T_MINS=$((TOTAL_MINS%60))
    TIME_LEFT="${T_DAYS}d ${T_HRS}h ${T_MINS}m"
    
    # Calculate Data Left to Sync (Blocks Left * Sess Avg Size)
    # We use a default of 100MB if no blocks have been processed yet
    SAFE_AVG=${SESS_AVG:-100.00}
    # Use a 500MB cap for estimation so it doesn't show impossible TB values
    EST_AVG=$SESS_AVG
    if (( $(echo "$EST_AVG > 500" | bc -l) )); then EST_AVG=100; fi
    GB_LEFT=$(echo "scale=2; ($BLOCKS_LEFT * $SAFE_AVG) / 1024" | bc | sed 's/^\./0./')
  else
    EST_DUR="Establishing..."; TIME_LEFT="--"; GB_LEFT="--"
  fi

  # 6. Peaks
  (( $(echo "$MB_PS > $MAX_DOWN" | bc -l) )) && MAX_DOWN=$MB_PS
  (( $(echo "$BPM > $MAX_BPM" | bc -l) )) && MAX_BPM=$BPM

  # 7. System Stats
  # Check if running in a container with /host/proc mounted, else use default
  if [ -f "/host/proc/stat" ]; then STAT_PATH="/host/proc/stat"; else STAT_PATH="/proc/stat"; fi
  read -r _ u n s id io rest < "$STAT_PATH"
  CPU_VAL=$(echo "scale=1; (($u+$n+$s)*100)/($u+$n+$s+$id+$io)*$(nproc)" | bc)
  IO_WAIT=$(echo "scale=1; ($io*100)/($u+$n+$s+$id+$io)" | bc)
  RAM_STATS=$(free -h | awk '/^Mem:/ {print $3 "/" $2}')
  DISK_TOTAL=$(du -sh $NODE_PATH | awk '{print $1}')
  DISK_UTXO=$(du -sh $CHAIN_PATH 2>/dev/null | awk '{print $1}')
  DISK_BLOCKS=$(du -sh $BLOCK_PATH 2>/dev/null | awk '{print $1}')
  if (( $(echo "${DISK_TOTAL%G} > 280" | bc -l) )); then DISK_COLOR=$R; else DISK_COLOR=$G; fi


  # Calculate RAM Trend
  CURR_RAM_VAL=$(free -m | awk '/^Mem:/ {print $3}')
  if [ "$CURR_RAM_VAL" -gt "$PREV_RAM_VAL" ]; then RAM_TREND="${R}↑${NC}"; 
  elif [ "$CURR_RAM_VAL" -lt "$PREV_RAM_VAL" ]; then RAM_TREND="${G}↓${NC}"; 
  else RAM_TREND="${W}→${NC}"; fi
  PREV_RAM_VAL=$CURR_RAM_VAL

  # Calculate Swap Trend
  if [ "$SW_USED" -gt "$PREV_SWAP_VAL" ]; then SW_TREND="${R}↑${NC}"; 
  elif [ "$SW_USED" -lt "$PREV_SWAP_VAL" ]; then SW_TREND="${G}↓${NC}"; 
  else SW_TREND="${W}→${NC}"; fi
  PREV_SWAP_VAL=$SW_USED

  # --- 1. Stall Alert (Triggers once if stuck > 10 mins) ---
  if [ "$STALL_TIME" -gt 600 ] && [ "$STALL_ALERT_SENT" = false ]; then
      send_discord "🚨 **$COIN NODE STALLED** 🚨\nNo blocks processed for **10+ minutes**.\nCurrent Height: **$CURR_BLOCKS**\nSession Dn: **$SESSION_GB GB**\n\n*Check your 2 high-speed peers!*"
      STALL_ALERT_SENT=true
  elif [ "$STALL_TIME" -lt 20 ]; then
      # Reset and notify once it starts moving again
      if [ "$STALL_ALERT_SENT" = true ]; then
          send_discord "✅ **$COIN NODE MOVING** ✅\nSync has resumed at height **$CURR_BLOCKS** after a stall/heavy validation."
          STALL_ALERT_SENT=false
      fi
      STALL_ALERT_SENT=false 
  fi

  # 2. Target Reach Alert
  if [ "$CURR_BLOCKS" -ge "$TARGET" ] && [ "$TARGET_ALERT_SENT" = false ]; then
      send_discord "🎯 **TARGET REACHED** 🎯\n${COIN} Node has reached block height  $TARGET!"
      TARGET_ALERT_SENT=true
  fi
  
  # --- Milestone Alert (Every 10,000 blocks) ---
  if [ -z "$NEXT_MILESTONE" ] && [ -n "$CURR_BLOCKS" ] && [ "$CURR_BLOCKS" -ne 0 ]; then
      NEXT_MILESTONE=$(( (CURR_BLOCKS / $DISCORD_BLOCK_NOTIFICATION + 1) * $DISCORD_BLOCK_NOTIFICATION ))
  fi

  if [ -n "$NEXT_MILESTONE" ] && [ -n "$CURR_BLOCKS" ]; then
      if [ "$CURR_BLOCKS" -ge "$NEXT_MILESTONE" ]; then
          # Generate the Progress Bar
          P_BAR=$(generate_bar "$(echo "$DATA" | jq -r '.verificationprogress // 0')")
          REMAINING_FMT=$(echo $((TARGET - CURR_BLOCKS)) | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')
          
          send_discord "🏁 **${COIN} Milestone Reached!** 🏁\nPassed Block **$(echo $NEXT_MILESTONE | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')**\nProgress: \`$P_BAR\`\nRemaining: **${REMAINING_FMT}** blocks until **${TARGET}**"
          
          NEXT_MILESTONE=$(( NEXT_MILESTONE + $DISCORD_BLOCK_NOTIFICATION ))
      fi
  fi
  
  # --- BIG BLOCK ALERT (3.5+) ---
  # Trigger alert if the current block weight exceeds 3500 MB
  if [ "$(echo "$BLOCK_WEIGHT_MB > 3500" | bc -l)" -eq 1 ]; then
      if [ "$BIG_BLOCK_SENT" = false ]; then
          send_discord "🐳 **BIG BLOCK DETECTED** 🐳\nBlock **$CURRENT_HEAD** is massive for $COIN! Current Weight: **$BLOCK_WEIGHT_MB MB**"
          BIG_BLOCK_SENT=true
      fi
  else
      # Reset when the queue clears or a smaller block starts
      if [ "$(echo "$BLOCK_WEIGHT_MB < 1000" | bc -l) " -eq 1 ]; then BIG_BLOCK_SENT=false; fi
  fi

  # 8. Peer Processing
  ALL_INFLIGHT=""; QUEUE_MB=0; PEER_OUT=""
  while read -r peer; do
    id=$(echo "$peer" | jq -r ".id"); addr=$(echo "$peer" | jq -r ".addr")
    cb=$(echo "$peer" | jq -r ".bytesrecv"); ping=$(echo "$peer" | jq -r "((.pingtime // 0) * 1000 * 100 | round) / 100")
    inflight=$(echo "$peer" | jq -c ".inflight"); inflight_len=$(echo "$inflight" | jq "length")
    
    pb=$(grep "^$id " "$PEER_HISTORY" | awk '{print $2}'); [ -z "$pb" ] && pb=$cb
    d_mb=$(echo "scale=2; ($cb - $pb) / 1048576" | bc)
    [ "$inflight_len" -gt 0 ] && QUEUE_MB=$(echo "$QUEUE_MB + $d_mb" | bc) && ALL_INFLIGHT="$ALL_INFLIGHT,$(echo "$inflight" | tr -d '[]')"

    PEER_OUT+="$(printf "${W}[%3d] %-22s | %7.2f  GB | + %7.2fMB (%5.2f MB/s)  | %8.2fms | %d${NC}\n" "$id" "$addr" "$(echo "scale=2; $cb / 1073741824" | bc)" "$d_mb" "$(echo "scale=2; $d_mb/20"|bc)" "$ping" "$inflight_len")\n"
  done < <(echo "$PEERS" | jq -c '.[] | select(.bytesrecv > 1048576)')

  # --- 9. Queue Tracking & Estimation Logic ---
  CURRENT_HEAD=$(echo "${ALL_INFLIGHT#,}" | cut -d',' -f1)

  # DO THE MATH FIRST (Before updating LAST_QUEUE_HEAD)
  if [ -n "$LAST_QUEUE_HEAD" ] && [ -n "$CURRENT_HEAD" ]; then
      BLOCKS_PROCESSED=$((CURRENT_HEAD - LAST_QUEUE_HEAD))
      if [ "$BLOCKS_PROCESSED" -gt 0 ]; then
          # Calculate batch average
          LAST_AVG_BATCH=$(echo "scale=2; $BLOCK_WEIGHT_MB / $BLOCKS_PROCESSED" | bc | sed 's/^\./0./')
          # Update session-wide average
          SESSION_TOTAL_MB=$(echo "$SESSION_TOTAL_MB + $BLOCK_WEIGHT_MB" | bc)
          SESSION_TOTAL_BLOCKS=$((SESSION_TOTAL_BLOCKS + BLOCKS_PROCESSED))
          SESS_AVG=$(echo "scale=2; $SESSION_TOTAL_MB / $SESSION_TOTAL_BLOCKS" | bc | sed 's/^\./0./')
      fi
  fi

  # NOW UPDATE THE TRACKER for the next 20s cycle
  if [ -n "$CURRENT_HEAD" ] && [ "$CURRENT_HEAD" == "$LAST_QUEUE_HEAD" ]; then
      (( QUEUE_TIMER += 20 ))
      BLOCK_WEIGHT_MB=$(echo "scale=2; $BLOCK_WEIGHT_MB + $QUEUE_MB" | bc)
  else
      LAST_QUEUE_HEAD=$CURRENT_HEAD
      QUEUE_TIMER=0
      BLOCK_WEIGHT_MB=$QUEUE_MB
  fi

  # Calculate TIMER_FMT from QUEUE_TIMER
  T_MIN=$((QUEUE_TIMER / 60))
  T_SEC=$((QUEUE_TIMER % 60))
  TIMER_FMT=$(printf "%02dm %02ds" $T_MIN $T_SEC)

# Optional: Add color coding for long waits
if [ "$QUEUE_TIMER" -gt 600 ]; then T_COL=$R; elif [ "$QUEUE_TIMER" -gt 300 ]; then T_COL=$Y; else T_COL=$G; fi

  # --- UI RENDER ---
  clear
  echo -e "${C}${COIN} ${VERSION}${NC}"
  echo ""
  echo -e "${W}Tracking to Block: ${Y}$(echo $TARGET | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta') [ $TARGET_DATE ]${NC}               $DISCORD_STATUS"
  echo ""
  echo -e "${W}Status: ${W}Block: ${STALL_COL}$(echo $CURR_BLOCKS | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')${NC} ${C}(+$DIFF)${NC} - ${R}$BLOCK_DATE${W} ${W}- Remaining: ${G}$BLOCKS_LEFT_FMT${NC} | ${W}PruneHt: ${Y}$(echo $PRUNE_H | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta') ${W}(Retained: ${C}$RETAINED${W})${NC}"
  echo -e "${W}Disk Space: ${Y}DB(UTXO): ${G}$DISK_UTXO${NC} | ${W}DB Blocks: ${G}$DISK_BLOCKS${NC} | ${W}Total: ${DISK_COLOR}$DISK_TOTAL${NC} | ${W}Pruning: ${Y}$PRUNING_CHECK${NC}"
  echo -e "${W}Total Blocks since $START_TS: ${G}$TOTAL_SESS_BLOCKS${NC} | ${W}Active: ${Y}$(printf "%02d:%02d:%02d" $((SECONDS/3600)) $(((SECONDS%3600)/60)) $((SECONDS%60)))${NC}"
  echo ""
  echo -e "${W}System: RAM: $RAM_STATS $RAM_TREND | Swap: ${SW_COL}$SW_STATS${NC} $SW_TREND | CPU: ${G}$CPU_VAL%${NC} | IO Wait: ${Y}$IO_WAIT%${NC} | Session Dn: $SESSION_GB GB${NC}"
  echo ""
  echo -e "${W}Sync:   ${Y}$BPM BPM${NC} (Sess: ${Y}$SESS_BPM${NC}) | ${G}$PROG_DISPLAY%${NC} | ${G}$MB_PS MB/s${NC}"
  echo -e "${W}ETC:    ${G}$EST_DUR${NC} (${C}$TIME_LEFT left${NC}) | ${Y}Data Left: ${R}${GB_LEFT} GB${NC} | Peaks: ${Y}$MAX_BPM BPM${NC}"
  echo ""
  echo -e "${W}PEER INFO (Active Transfers >1MB) - Refresh: $(date +%H:%M:%S) $HEART${NC}"
  echo -e "${W}  ID  ADDRESS                | TOTAL RECV  | DELTA (20s)               | PING       | IN-FLIGHT${NC}"
  echo -e "${W}-----------------------------+-------------+---------------------------+------------+-----------${NC}"
  echo -e "$PEER_OUT"
  echo -e "${W}IN-FLIGHT QUEUE ${WEIGHT_COL}(Queue Weight: ${BLOCK_WEIGHT_MB} MB)${NC} | ${G}Avg Block: ${LAST_AVG_BATCH:-0} MB${NC} | ${Y}Sess Avg: ${SESS_AVG:-0} MB${NC}"
  if [ -n "$CURRENT_HEAD" ]; then
      echo -e "${W}Head: ${C}$CURRENT_HEAD ${W}Time in Queue: ${T_COL}$TIMER_FMT${NC}"
      echo -e "${C}[${ALL_INFLIGHT#,}]${NC}"
  else
      echo -e "${G}Queue Empty - Node Idle${NC}"
  fi

  # 10. Update Peer History for next cycle
  PREV_BYTES=$CURR_BYTES
  PREV_BLOCKS=$CURR_BLOCKS
  echo "$PEERS" | jq -r '.[] | "\(.id) \(.bytesrecv)"' > "$PEER_HISTORY"
}

# START LOGIC
update_display
while true; do
  SLEEP_TIME=$(( 20 - $(date +%-S) % 20 ))
  sleep "$SLEEP_TIME"
  update_display
done


