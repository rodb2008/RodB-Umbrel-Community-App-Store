# BlackAxe v12.0 - Mining Device Manager for Umbrel Home

Professional mining device management for Bitcoin solo miners.

## What's New in v12.0

### Critical Fixes
- **Avalon API Support**: Fixed TCP socket connection to CGMiner API (port 4028)
- **Device Type Detection**: Now shows actual model name (Bitaxe Ultra, NerdQAxe++, Avalon, etc.)
- **Charts**: Fixed to show continuous smooth line instead of separate spikes
- **Hashrate Calculation**: All miners (Avalon + Bitaxe + NerdQAxe) now included correctly

### Supported Devices
- Bitaxe (Ultra, Supra, Gamma, Hex)
- NerdQAxe++
- Avalon (Nano, Mini, Q, and larger models)
- Antminer
- Whatsminer
- Other CGMiner-compatible devices

## Installation on Umbrel Home

1. Extract this package to your Umbrel apps directory
2. Install dependencies:
   ```bash
   pnpm install
   ```
3. Start the application:
   ```bash
   pnpm start
   ```
4. Access at http://your-umbrel-ip:3000

## Default Credentials
- Username: `blackaxe`
- Password: `blackaxe`

**Important**: Change the password after first login!

## Features
- Real-time monitoring of all mining devices
- Automatic device discovery via network scan
- Temperature and power monitoring
- Share statistics and best difficulty tracking
- Solo block detection
- Alert system for offline miners
- 24-hour history charts

## API Ports
- Bitaxe/NerdQAxe: HTTP port 80 (AxeOS API)
- Avalon/Antminer: TCP port 4028 (CGMiner API)

## Support
For issues and feature requests, please contact the developer.
