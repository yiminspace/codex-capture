# 本地开发交付

- 修改 Option+S、截图浮层、菜单栏或其他原生助手行为后，先完成相关测试，再从仓库根目录重新运行安装器，让用户可以直接在当前桌面使用改动。
- 保留当前安装模式。查看 `~/.local/state/codex-capture/installation.json` 的 `installMode`。若为 `editable`，运行 `./install.sh --editable`。若为 `cached`，运行 `./install.sh`。
- 交付前检查 `~/.local/state/codex-capture/hotkey-status.json`，确认新进程的 `state` 为 `ready` 且 `hotkeyRegistered` 为 `true`。如果安装被卡住或尚未验证实际界面，在交付时明确说明。
