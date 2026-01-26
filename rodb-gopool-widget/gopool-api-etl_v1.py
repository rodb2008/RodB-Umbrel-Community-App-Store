import urllib.request
import json
import time
import ssl

# Configuration
API_POOL = "https://192.168.6.6:23443/api/pool"
API_OVERVIEW = "https://192.168.6.6:23443/api/overview"


def get_combined_data():
    try:
        # SSL Bypass context
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE

        # Build an opener that explicitly bypasses all proxies
        proxy_handler = urllib.request.ProxyHandler({})
        https_handler = urllib.request.HTTPSHandler(context=ctx)
        opener = urllib.request.build_opener(proxy_handler, https_handler)

        def fetch_data(url):
            req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
            with opener.open(req, timeout=10) as response:
                return json.loads(response.read().decode('utf-8'))

        # 1. Fetch data from both endpoints
        pool = fetch_data(API_POOL)
        ov = fetch_data(API_OVERVIEW)

        # 2. Extract Best Share from Overview (First entry in list)
        best_shares_list = ov.get("best_shares", [])
        best_share_val = 0
        if best_shares_list and isinstance(best_shares_list, list):
            best_share_val = best_shares_list[0].get("difficulty", 0)

        # 3. Helper Functions for Formatting
        
        def format_units(n):
            """Formats large numbers with metric prefixes (k, M, G, T, P)."""
            if n >= 1e15: return f"{n/1e15:.2f}P"
            if n >= 1e12: return f"{n/1e12:.2f}T"
            if n >= 1e9: return f"{n/1e9:.2f}G"
            if n >= 1e6: return f"{n/1e6:.2f}M"
            if n >= 1e3: return f"{n/1e3:.2f}k"
            return str(n)

        def format_uptime(total_seconds):
            """Converts seconds to 0d 0h 0m 0s format."""
            d, remainder = divmod(int(total_seconds), 86400)
            h, remainder = divmod(remainder, 3600)
            m, s = divmod(remainder, 60)
            return f"{d}d {h}h {m}m {s}s"

        # 4. Process Data
        # Format Uptime
        uptime_seconds = pool.get("uptime", 0) / 1e9
        uptime_str = format_uptime(uptime_seconds)

        # Aggregate 1m rolling hashrate from workers
        workers = ov.get("workers", [])
        total_rolling = sum(w.get("rolling_hashrate", 0) for w in workers)

        hr_rolling_str = format_units(total_rolling)
        hr_pool_str = format_units(pool.get("pool_hashrate", ov.get("pool_hashrate", 0)))
        
        # Format the bestshare value
        best_share_formatted = format_units(best_share_val)

        # Line 1: Basic Status
        line1 = {
            "runtime": uptime_str,  # Now formatted as 0d 0h 0m 0s
            "lastupdate": int(time.time()),
            "Users": ov.get("active_miners", 0),
            "Workers": ov.get("active_miners", 0),
            "Idle": 0, "Disconnected": 0
        }

        # Line 2: Hashrate Breakdown
        line2 = {
            "hashrate1m": hr_rolling_str,
            "hashrate5m": hr_rolling_str,
            "hashrate15m": hr_rolling_str,
            "hashrate1hr": "0", "hashrate6hr": "0", "hashrate1d": "0",
            "hashrate7d": hr_pool_str,
            "Pool Tag": ov.get("pool_tag", "/rodb-goPool/")
        }

        # Line 3: Share Statistics
        spm_ov = ov.get("shares_per_minute", 0)
        sps_val = round(spm_ov / 60.0, 5) if spm_ov else 0.0

        line3 = {
            "diff": pool.get("min_difficulty", 0),
            "accepted": pool.get("accepted", 0),
            "rejected": pool.get("rejected", 0),
            "bestshare": best_share_formatted,
            "SPS1m": sps_val,
            "SPS5m": sps_val,
            "SPS15m": sps_val,
            "SPS1h": sps_val,
            "Shares per min": round(spm_ov, 2)
        }

        return f"{json.dumps(line1)}\n{json.dumps(line2)}\n{json.dumps(line3)}"

    except Exception as e:
        return f"ETL Error: {str(e)}"

if __name__ == "__main__":
    print(get_combined_data())

