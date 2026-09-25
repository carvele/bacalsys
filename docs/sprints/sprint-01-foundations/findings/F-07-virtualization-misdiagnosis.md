# F-07: Local virtualization was wrongly reported as disabled

- **Class:** Process / reporting error (corrected)

**What was reported:** "Virtualization is disabled in firmware; Android emulator and Docker are impossible."

**What is true:** `Win32_Processor.VirtualizationFirmwareEnabled` reads `False` whenever the Hyper-V hypervisor is
already running, which hides the flag. `emulator -accel-check` shows **WHPX is installed and usable**. The Android
emulator runs with hardware acceleration and was used for the Sprint 1 dev-client verification.
WSL is still not installed, so Docker Desktop remains unavailable until it is.

**Lesson:** confirm an environment constraint with the tool that depends on it (`emulator -accel-check`,
`wsl --status`), not with an indirect indicator.
