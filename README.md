# slowdisk (Nerdy Neighbor)

Makes Windows 10/11 run better on slow hardware. It detects whether the PC
boots from **eMMC** or a **mechanical hard drive**, or has an SSD but a
**low-end CPU / 8 GB RAM or less** (low-spec profile), and applies only the
tweaks that help on that hardware. It runs alongside our normal winutil preset
and doesn't duplicate it.

## Run it (elevated Windows PowerShell)

```powershell
# Detect the drive and apply the right profile
irm slowdisk.nerdyneighbor.net | iex

# Preview only: shows what it would change, changes nothing
$env:NN_SLOWDISK = 'report'; irm slowdisk.nerdyneighbor.net | iex

# Undo everything this script changed
$env:NN_SLOWDISK = 'revert'; irm slowdisk.nerdyneighbor.net | iex
```

Options (set before the irm line):

| Variable | Values | Effect |
|---|---|---|
| `NN_SLOWDISK` | `auto` (default), `hdd`, `emmc`, `lowspec`, `report`, `revert` | Profile / mode. Combine a profile with report: `lowspec,report` |
| `NN_SLOWDISK_COMPACT` | `no` | eMMC: skip CompactOS (it can take 10-30 min) |
| `NN_SLOWDISK_VISUAL` | `no` | Skip the "best performance" visual effects |
| `NN_SLOWDISK_SEARCH` | `off`, `keep` | Override the search indexer decision |
| `NN_SLOWDISK_SYSMAIN` | `off` | Disable SysMain anyway (not recommended) |

## Detection

It looks at the disk that holds `C:`:
- Bus `SD`/`MMC` means **eMMC**.
- `NVMe`/`UFS`, or Windows reporting no seek penalty, means **SSD**. If the CPU
  is low-end (4 or fewer threads, or Celeron/Pentium/Atom/Athlon/AMD A-series/
  N-series/older i3) or RAM is 8 GB or less, it uses the **low-spec** profile.
  Otherwise it changes nothing and exits.
- Windows reporting a seek penalty, or a spindle speed, means **HDD**.
- Anything else counts as unknown: the script asks the tech when run
  interactively, or does nothing under RMM.

## What it does

| | HDD | eMMC | Low-spec (SSD) |
|---|---|---|---|
| NTFS last-access timestamps off (no write on every read) | yes | yes | no |
| SysMain + prefetch kept ON (re-enabled if some "optimizer" killed it) | yes | yes | yes |
| Memory compression on (RAM 8 GB or less) | yes | yes | yes |
| Store app pre-launch off | yes | yes | yes |
| Windows Search indexer disabled | yes, unless classic Outlook is installed | kept | kept |
| Fast Startup on with a reduced hiberfile (undoes winutil's "Hibernation - Disable") | yes | yes, unless free space would drop under 10 GB, then hibernation stays off | yes |
| Defender: low-priority scans, 25% CPU cap, scheduled scans only when idle (never disabled) | yes | yes | yes |
| Compatibility Appraiser / CompatTelRunner tasks off | yes | yes | yes |
| Edge Startup Boost + background mode off | yes | yes | yes |
| Page file set back to system managed if it was disabled | yes | yes | yes |
| Weekly drive optimization task on | yes | yes, plus a TRIM now | yes |
| Visual effects: best performance for every profile + new users (keeps smooth fonts/thumbnails, transparency off) | yes | yes | yes |
| CompactOS (compress Windows, frees 2-4 GB, fewer reads) | no | yes | no (warns if already on with a weak CPU) |

It also reports these without changing them: low free space, low RAM,
BitLocker on, Memory Integrity (HVCI) on, and the startup app list.

The script can be re-run safely. Every change records its original value in
`C:\ProgramData\NerdyNeighbor\slowdisk-state.json`, and `revert` puts those values back.
Log: `C:\ProgramData\NerdyNeighbor\slowdisk.log`. Reboot after running.

## Caveats

- Turning the search indexer off on an HDD makes File Explorer search slower
  (it scans instead of using the index). Start menu app search still works.
- The CompactOS state check parses English `compact.exe` output. On
  non-English Windows it skips that step and says so.
- On an HDD machine, swapping in a SATA SSD still beats every tweak here.

## Delivery

Pages project `nerdyneighbor-slowdisk` serves `slowdisk.nerdyneighbor.net`. Its
Pages Function fetches `Optimize-SlowDisk.ps1` from this repo through the GitHub Contents
API, so a push here goes live immediately.
