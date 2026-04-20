#!/usr/bin/env python3
import os
import sys
import time
import json
import urllib.request
import urllib.error
import re
import threading
import io
from contextlib import redirect_stdout
from datetime import datetime, timezone

from flask import Flask
from ansi2html import Ansi2HTMLConverter

# --- MULTI-FILE ENV PARSER ---
def load_dotenv(filepath):
    try:
        if not os.path.exists(filepath):
            return
        with open(filepath, 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                if '=' in line:
                    key, val = line.split('=', 1)
                    key = key.strip()
                    if key.startswith('export '):
                        key = key[7:].strip()
                    val = val.split('#')[0].strip()
                    val = val.strip("'").strip('"')
                    os.environ[key] = val
    except Exception as e:
        print(f"Warning: Could not load {filepath}: {e}")

load_dotenv(".env")
load_dotenv("coin.config")

# --- CUSTOMIZABLE IDENTITY & RENTAL ---
DEFAULT_BTCS_PRICE = 0.00893
POOL_FEES = 0.75
DOLPHIN_STATUS = "🐬"
SHARK_STATUS = "🦈"
WHALE_STATUS = "🐋"
YOUR_TZ = "UTC"
RENTAL_END_STR = "2026-04-16 11:02:00"

# Environment Variables
DISCORD_URL = os.environ.get("DISCORD_URL", "")
MY_UID = os.environ.get("MY_UID", "")
if len(sys.argv) > 1 and sys.argv[1] == "loop":
    bg_loop = "true"
else:
    bg_loop = "false"

# State Files
STATE_FILE = "/tmp/btcs_last_block"
LAST_HEIGHT_CACHE = "/tmp/btcs_last_height_seen"
TREND_HASH_REF = "/tmp/btcs_trend_hash"
TREND_DIFF_REF = "/tmp/btcs_trend_diff"
WINNING_DIFF_CACHE = "/tmp/btcs_winning_diff"

# Colors (ANSI)
class C:
    MYCOLOR = '\033[38;2;51;153;255m'
    GREEN = '\033[0;32m'
    RED = '\033[0;31m'
    NC = '\033[0m'
    W = '\033[1;37m'

def get_visual_len(text):
    ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
    return len(ansi_escape.sub('', text))

def visual_ljust(text, width):
    return text + ' ' * (width - get_visual_len(text))

def get_trend(current, last):
    if not last or last == 0 or current == last: return "→"
    if current > last: return f"{C.RED}↑{C.NC}"
    if current < last: return f"{C.GREEN}↓{C.NC}"
    return "→"

def format_hash(h):
    if not h or h == 0: return "0 H/s"
    if h >= 1e15: return f"{(h / 1e15):.2f} PH/s"
    if h >= 1e12: return f"{(h / 1e12):.2f} TH/s"
    return str(h)

def format_time_ago(diff_seconds):
    if diff_seconds >= 3600:
        return f"{int(diff_seconds // 3600)}h {int((diff_seconds % 3600) // 60)}m"
    return f"{int(diff_seconds // 60)}m {int(diff_seconds % 60)}s"

def read_cache(filepath, default=0.0):
    try:
        with open(filepath, 'r') as f:
            return float(f.read().strip())
    except FileNotFoundError:
        return default

def write_cache(filepath, value):
    with open(filepath, 'w') as f:
        f.write(str(value))

def calculate_share_difficulty(block_hash_hex):
    if not block_hash_hex: return "0.00"
    max_target = int("00000000FFFF0000000000000000000000000000000000000000000000000000", 16)
    block_hash = int(block_hash_hex, 16)
    if block_hash == 0: return "0.00"
    actual_diff = max_target / block_hash
    return f"{(actual_diff / 1000000):.2f}"

# --- NATIVE HTTP FETCHERS ---
def fetch_json(url, timeout=5):
    req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read().decode('utf-8'))

def send_discord(msg):
    if not DISCORD_URL:
        print(f"\n{C.RED}ERROR: DISCORD_URL not found.{C.NC}")
        return
    timestamp = int(time.time())
    payload = {"content": f"<@{MY_UID}> {msg} <t:{timestamp}:R>"}
    data = json.dumps(payload).encode('utf-8')
    for attempt in range(5):
        try:
            req = urllib.request.Request(
                DISCORD_URL,
                data=data,
                headers={'Content-Type': 'application/json', 'User-Agent': 'Mozilla/5.0'},
                method='POST'
            )
            with urllib.request.urlopen(req, timeout=10) as response:
                if response.status in [200, 204]:
                    return
        except Exception:
            time.sleep(2)

def fetch_price(arg_price):
    if arg_price and arg_price != ".":
        try: return float(arg_price), "Static Price"
        except ValueError: pass

    try:
        headers = {'User-Agent': 'Mozilla/5.0'}
        req = urllib.request.Request('https://trade.nestex.one/ajax/liq_stats.aspx?cur=BTCS', headers=headers)
        with urllib.request.urlopen(req, timeout=15) as response:
            content = response.read().decode('utf-8')
            lines = content.splitlines()
            for i, line in enumerate(lines):
                if "Effective Price" in line:
                    if i + 1 < len(lines):
                        next_line = lines[i+1].strip()
                        val_match = re.search(r'>([^<]+)<', next_line)
                        if val_match:
                            price = float(val_match.group(1).strip())
                            date_str = datetime.now(timezone.utc).strftime('%b %d %H:%M UTC')
                            return price, date_str
            return DEFAULT_BTCS_PRICE, "Parse Failed"
    except Exception as e:
        return DEFAULT_BTCS_PRICE, f"Request Failed ({type(e).__name__})"

# --- FLASK WEBSERVER SETUP ---
app = Flask(__name__)
conv = Ansi2HTMLConverter(dark_bg=True)
# This holds the latest terminal output, instantly served to the web browser
cached_dashboard_html = "<html><body style='background-color:#000000;color:#ffffff;font-family:monospace;'><h3>Initializing BTCS Dashboard...</h3><p>Fetching node data. Please refresh in 10 seconds.</p></body></html>"

def background_monitor():
    global cached_dashboard_html
    
    arg_price = sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] not in ["loop", "."] else None
    btcs_price, price_date = fetch_price(arg_price)
    starting_block_count = 329
    last_known_effort = "0%"

    while True:
        # Create a string buffer to silently catch all print() statements
        f = io.StringIO()
        with redirect_stdout(f):
            now_ts = int(time.time())

            # Rental & Temp
            try:
                rental_end = datetime.strptime(RENTAL_END_STR, "%Y-%m-%d %H:%M:%S").timestamp()
                diff_ts = int(rental_end - now_ts)
                time_left = f"Time Left: {C.GREEN}{diff_ts // 3600}h {(diff_ts % 3600) // 60}m{C.NC}" if diff_ts > 0 else f"Rental: {C.RED}EXPIRED{C.NC}"
            except: time_left = f"Rental: {C.RED}ERROR{C.NC}"

            try:
                with open('/sys/class/hwmon/hwmon2/temp1_input', 'r') as f_temp:
                    cpu_celsius = float(f_temp.read().strip()) / 1000
            except: cpu_celsius = 0.0

            print(f"\n{C.MYCOLOR}BTCS Dashboard{C.NC} | {time_left} | Temp: {C.GREEN}{cpu_celsius:.2f}°C{C.NC} 🌡️")

            # Data Fetch
            try:
                pools_resp = fetch_json("http://localhost:4000/api/pools")
                btcs_pool = next((p for p in pools_resp.get('pools', []) if p['id'] == 'btcs'), {})
                blocks_resp = fetch_json("http://localhost:4000/api/blocks")
                latest_block = [b for b in blocks_resp if b.get('poolId') == 'btcs'][0] if blocks_resp else {}
            except:
                print(f"{C.RED}Error connecting to MiningCore API.{C.NC}")
                time.sleep(10); continue

            # Stats
            net_stats = btcs_pool.get('networkStats', {})
            pool_stats = btcs_pool.get('poolStats', {})
            raw_net_hash = float(net_stats.get('networkHashrate', 0))
            raw_net_diff = float(net_stats.get('networkDifficulty', 0))
            raw_height = int(net_stats.get('blockHeight', 0))

            # Trends & Padding Fix
            ref_net_hash = read_cache(TREND_HASH_REF, raw_net_hash)
            ref_net_diff = read_cache(TREND_DIFF_REF, raw_net_diff)
            last_height_seen = read_cache(LAST_HEIGHT_CACHE, 0)
            hash_arrow = get_trend(raw_net_hash, ref_net_hash)
            diff_arrow = get_trend(raw_net_diff, ref_net_diff)

            current_total = int(btcs_pool.get('totalBlocks', 0))
            pool_h_fmt = format_hash(pool_stats.get('poolHashrate', 0))
            net_h_fmt = format_hash(raw_net_hash)
            diff_fmt = f"{(raw_net_diff / 1e6):.2f} M"
            spm = round(float(pool_stats.get('sharesPerSecond', 0)) * 60, 2)
            current_effort = f"{(float(btcs_pool.get('poolEffort', 0)) * 100):.2f}%"

            try:
                net_time_str = net_stats.get('lastNetworkBlockTime', '').replace('Z', '+00:00')
                ago_str = format_time_ago(now_ts - datetime.fromisoformat(net_time_str).timestamp())
            except: ago_str = "0m"

            try:
                recent_blocks_resp = fetch_json("http://localhost:4000/api/pools/btcs/blocks?pageSize=100")
                actual_count = sum(1 for b in recent_blocks_resp if b.get('blockHeight', 0) > (raw_height - 100))
            except: actual_count = 0

            predicted = (float(pool_stats.get('poolHashrate', 0)) / (raw_net_hash if raw_net_hash > 0 else 1)) * 100
            luck_var = actual_count - predicted
            var_color = C.GREEN + "+" if luck_var >= 0 else C.RED

            my_height = latest_block.get('blockHeight', 0)
            my_effort = f"{(float(latest_block.get('effort', 0)) * 100):.0f}%"
            try:
                my_ago = format_time_ago(now_ts - datetime.fromisoformat(latest_block.get('created', '').replace('Z', '+00:00')).timestamp())
            except: my_ago = "0m"

            print(f"\nMy Last Block Found: {my_height} (🎯 {my_ago} ago)   Effort: {my_effort}")

            # Display Winning Share Diff from cache
            try:
                with open(WINNING_DIFF_CACHE, 'r') as f_diff:
                    displayed_share_diff = f"{f_diff.read().strip()} M"
            except:
                displayed_share_diff = "0.00 M"

            print(f"   🎯 ** Winning Hash Power: {displayed_share_diff} ** 🎯")

            if current_total >= 500: icon, base_th, status_blk = WHALE_STATUS, 400, 100
            elif current_total >= 400: icon, base_th, status_blk = SHARK_STATUS, 300, 50
            else: icon, base_th, status_blk = DOLPHIN_STATUS, 100, 100
            btcs_status = icon * int(1 + ((current_total - base_th) / status_blk))

            session_gain = current_total - starting_block_count
            total_btcs = (current_total * 50) + POOL_FEES

            print(f"\nTotal Blocks: {current_total} ⛏️ ( {C.GREEN}+{session_gain} {btcs_status}{C.NC} )")
            print(f"Total BTCS: {C.MYCOLOR}{total_btcs:,.2f} 🪙    /   USD: {C.GREEN}$ {(total_btcs * btcs_price):,.2f} 💵{C.NC}")
            print(f"NestEx BTCS Price:{C.GREEN} $ {btcs_price:.8f}{C.NC} @ {price_date}")

            # FIXED ALIGNMENT LOGIC
            col1_width = 30
            row1_left = visual_ljust(f"Network Hash: {net_h_fmt} {hash_arrow}", col1_width)
            row2_left = visual_ljust(f"Pool Hash:    {pool_h_fmt}", col1_width)

            print(f"{row1_left} {C.W}|{C.NC}    Difficulty: {diff_fmt} {diff_arrow}")
            print(f"{row2_left} {C.W}|{C.NC}    Shares/Min: {spm}")
            print(f"Pool Effort:  {current_effort}")
            print(f"Blocks in last 100: {C.MYCOLOR}{actual_count}{C.NC} / {predicted:.1f} ({var_color}{luck_var:.1f}{C.NC}) 🎯")
            print(f"\nCurrent Network Block: {raw_height} ({ago_str} ago)\n")

            if raw_height > last_height_seen:
                write_cache(TREND_HASH_REF, raw_net_hash); write_cache(TREND_DIFF_REF, raw_net_diff); write_cache(LAST_HEIGHT_CACHE, raw_height)

            last_total = int(read_cache(STATE_FILE, 0))
            if current_total > last_total and current_total > 0:
                winning_effort = last_known_effort if last_known_effort != "0%" else current_effort
                share_diff_val = calculate_share_difficulty(latest_block.get('hash', ''))

                with open(WINNING_DIFF_CACHE, 'w') as f_diff_write:
                    f_diff_write.write(share_diff_val)

                t3 = '```'
                msg = (f"{btcs_status} **BTCS BLOCK {my_height} FOUND!**\n**Session:** +{session_gain} this week!\n"
                       f"{t3}diff\n+ Effort: {winning_effort}\n{t3}\n🎯 **Winning Hash Power:** {share_diff_val} M\n\n"
                       f"**Network Hash:** {net_h_fmt} | **Difficulty:** {diff_fmt}\n**Pool Hash:** {pool_h_fmt} | **Shares/Min:** {spm}\n\n🔨 **Miners hit hard!**")
                send_discord(msg); print("\a", end='', flush=True); write_cache(STATE_FILE, current_total)

            last_known_effort = current_effort
            
            # Print last updated timestamp for the web UI
            print(f"Last updated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")

        # Once the loop iteration completes, convert captured text to HTML
        raw_text = f.getvalue()
        cached_dashboard_html = conv.convert(raw_text)

        # Sleep logic (replaces your old terminal countdown)
        time.sleep(60)

@app.route('/')
def serve_dashboard():
    # Adding a simple auto-refresh meta tag to the HTML output
    return cached_dashboard_html.replace(
        '<head>', 
        '<head><meta http-equiv="refresh" content="60">'
    )

if __name__ == "__main__":
    # Start the daemon thread to monitor for blocks 
    t = threading.Thread(target=background_monitor, daemon=True)
    t.start()
    
    # Start the Flask server 
    try:
        app.run(host='0.0.0.0', port=23111)
    except KeyboardInterrupt:
        print(f"\n{C.MYCOLOR}Dashboard stopped by user. Exiting gracefully...{C.NC}")
        sys.exit(0)
