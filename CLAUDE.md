# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Docker-based network impairment simulator for the AVIXA 2026 conference talk "Hackeando la Señal". Two containers on a custom bridge network (`172.28.0.0/24`): a **sender** (FFmpeg + tc netem at `172.28.0.10`) streams H.264 MPEG-TS over UDP, and a **receiver** (FFplay at `172.28.0.20`) displays the degraded video+audio. An interactive bash menu (`demo-control.sh`) controls impairments in real-time.

## Build & Run

```bash
# First-time setup (builds images, verifies Docker/X11/PulseAudio)
chmod +x setup.sh && ./setup.sh

# Start containers
docker compose up -d

# Interactive demo control
./demo-control.sh

# Direct commands (non-interactive)
./demo-control.sh stream-start|stream-stop|receiver-play|clear|status|ping

# Rebuild after changing sender/ or receiver/ files
docker compose build sender    # or: docker compose build receiver
```

## Architecture

```
demo-control.sh          ← Host: interactive menu, launches docker exec commands
├── sender/
│   ├── stream.sh        ← FFmpeg: generates SMPTE bars or file video + audio over UDP
│   └── apply-netem.sh   ← tc netem: applies/clears network impairments on eth0
└── receiver/
    ├── receive.sh       ← FFplay: displays video with audio via PulseAudio
    └── receive-stats.sh ← FFmpeg stats-only mode (no X11 needed)
```

**Data flow:** FFmpeg (sender) → UDP:5004 → tc netem (impairments) → network → FFplay (receiver)

Impairments are applied on the sender's egress (`eth0`), not on the receiver.

## Critical Technical Context

These are hard-won lessons from debugging; violating them breaks the demo:

1. **Static SMPTE bars encode at ~500kbps** (not 4000k target) because H.264 ABR sees near-zero change between frames. Fix: `noise=alls=20:allf=t+u` adds pixel entropy → forces real 4200kbps.

2. **All I-frames (`-g 1`) are required for SMPTE mode.** P-frames for static content are empty skip-macroblocks; losing them is invisible. With `-g 1`, each frame is ~16 packets, and any lost packet = visible macroblock.

3. **`-re` is mandatory for lavfi sources.** Without it, FFmpeg generates at ~21x real-time → 94 Mbps floods the network and overflows netem queues. File mode also needs `-re`.

4. **FFplay flags for artifact visibility:**
   - `-ec 0`: disables error concealment (shows raw macroblocks)
   - `-fflags nobuffer` (NOT `discardcorrupt`): `discardcorrupt` silently drops corrupted frames
   - Do NOT use `-sync ext`: causes display freeze after clearing impairments (PTS drift = all frames considered "late"). Default audio sync recovers naturally.
   - Do NOT use `-framedrop`: after heavy packet loss, PTS discontinuity makes ALL new frames "late" relative to audio clock → display freezes permanently even though the H.264 decoder recovered (proven with per-second error counting). Without `-framedrop`, FFplay shows every frame → corruption visible during impairment AND immediate recovery when cleared.

5. **Queue limit formula in apply-netem.sh:** `(delay_ms + jitter_ms) * 200 * 3 / 1000 + 2000`. Works for ~400 pkt/s with 3x margin. Too-small limits cause artificial drops unrelated to the configured loss%.

6. **Audio needs PulseAudio socket mounted** in docker-compose.yml (`/run/user/1000/pulse`). Without it, FFplay plays video but audio goes nowhere.

7. **`fifo_size` in receive.sh must be small (~2048).** This is FFplay's UDP circular buffer in packets. At ~374 pkt/s, `fifo_size=65536` = 175 seconds of stale data — after clearing impairments, FFplay keeps showing corrupted video for minutes. With `fifo_size=2048` (~5.5s), recovery happens within seconds.

8. **FFplay must be restarted to recover from heavy corruption.** FFplay has internal packet queues of up to 15MB (~30s at 4Mbps) that cannot be flushed externally. After heavy corruption, these queues fill with corrupted data and FFplay processes them ALL before reaching clean data. The solution: `receive.sh` has a restart loop — when `demo-control.sh` clears impairments, it kills FFplay (`pkill -f ffplay`), and the loop automatically restarts it with clean buffers. This is why `stop_receiver_display()` must also kill `receive.sh` (to stop the loop). The quit handler (`q/Q`) calls `stop_receiver_display()` and also kills sender processes (`stream.sh` + `ffmpeg`) to ensure no orphaned processes remain.

## Key Environment Variables (sender)

| Variable | Default | Purpose |
|----------|---------|---------|
| `AUDIO_MODE` | `tone` | `tone` (1kHz fixed, standard test signal) or `sweep` (chirp 300-1000Hz, very audible degradation) |
| `INPUT_VIDEO` | empty | Path to video file inside container (e.g., `/videos/clip.mp4`) |
| `VIDEO_BITRATE` | `4000k` | Target bitrate (VBV CBR enforced with `-maxrate` + `-bufsize`) |
| `GOP` | `60` | Keyframe interval for file mode only; SMPTE always uses `-g 1` |

## Conventions

- All scripts use Spanish for user-facing text and comments
- ANSI color codes for terminal output throughout
- Docker images based on Ubuntu 22.04
- `exec ffmpeg ...` replaces the shell process (no PID management needed)
- tc netem operations require `cap_add: NET_ADMIN` on the sender container
