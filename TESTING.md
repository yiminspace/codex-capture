# 功能验证矩阵

项目使用 stdlib 后端和打包后的 Voyage/React 页面。后端测试用临时数据目录与 Git 仓库，浏览器测试用隔离的 fixture API，不调用真实模型或修改用户任务。真实使用记录与截图不随仓库发布。

测试项目、描述和结果均须使用虚构内容，图片固定为合成图片；不要从真实任务复制示例或把本机截图传入浏览器测试。

| 功能 | 证据 |
| --- | --- |
| 独立分类、新 chat、原图、一次跟进 | tests/test_capture.py 的协议与任务生命周期测试；实际账户验收按文末步骤执行 |
| 正式任务 Full access 与权限不符时停止 | tests/test_capture.py；实际运行核对 state.permissions 与 turn_context |
| 首条消息原文原图、AX 仅用于分类 | tests/test_capture.py；Swift --self-test |
| 首轮文件变化判断、已有脏文件不误判、一次条件跟进 | tests/test_capture.py 的临时 Git 仓库与调度测试 |
| 跟进发送与跳过原因、预设原文展示 | web 阶段单测及浏览器测试 |
| 前景上下文边界与持久化 | tests/test_capture.py；授权后的真实 AX 采集仍由用户触发 |
| 历史列表、搜索、状态和项目筛选、分页 | tests/test_gui.py；web 浏览器测试 |
| 旧记录读取、损坏记录、后台退出显示中断 | tests/test_gui.py；web 阶段状态单测 |
| 原始图片鉴权、详情、日志与诊断导出 | tests/test_gui.py；web 浏览器测试 |
| 阶段日志持久化、工具进展记录 | tests/test_capture.py；web 执行过程页测试 |
| 取消和打开 chat 的边界 | tests/test_gui.py；web 模拟 API 验证，不取消真实任务 |
| 过期网络响应不会覆盖当前选择 | web 单测与浏览器测试 |
| Voyage 组件、theme 明暗与主题偏好 | web 浏览器测试及截图检查 |
| 本机鉴权、Origin/Host、路径和符号链接限制 | tests/test_gui.py |
| GUI 服务独立启动、复用与协议兼容升级 | tests/test_gui.py 的隔离真实 HTTP 服务测试 |
| 菜单栏工作台入口、阶段缓存和中断显示 | Swift 严格编译及 --self-test；真实输入动作需要手动触发 |

运行：

```sh
python3 -W error::ResourceWarning -m unittest discover -s tests -v
cd web
pnpm install --frozen-lockfile
pnpm build
pnpm test
pnpm exec playwright install chromium
pnpm test:browser
```

浏览器测试启动独立的浏览器进程，不使用个人浏览器资料。`CAPTURE_BROWSER_CHANNEL=chrome` 使用本机 Chrome；省略后使用 Playwright 已安装的 Chromium。安装包携带构建产物，最终安装时会校验缓存与源码一致。

对真实任务的只读 GUI 验收应核对同一 job ID 下的描述、原图、项目、两个 turn、预设内容、错误及事件数量；不能把 fixture 截图或深链调用成功当作真实任务已正确显示的证据。

GitHub Actions 运行 Python 测试、前端构建与单测、隔离浏览器测试，以及 macOS Swift 编译与无 UI 自检。CI 不安装登录启动项、不请求屏幕录制权限、不连接真实 Codex 账号。

公开源码检查及安装包生成使用固定入口：

```sh
python3 scripts/package_release.py --check
python3 scripts/package_release.py
```

打包仅使用 Git 跟踪且属于发布清单的工作区文件，输出到 `dist/`。检查会拒绝运行数据、日志、截图、source map、个人 home 路径和常见凭据格式；本机配置存在时也检查完整预设是否混入源码。它无法识别所有真实业务文字，发布前仍需人工检查测试样例和文档。不要使用递归压缩整个工作目录的方式打包。

需要真实端到端验收时，使用自己的截图和明确的测试描述，从 `code-capture submit` 或 Option+S 入口开始；核对 Luna 路由、原文原图、权限、任务结束与条件跟进。使用自动清理的临时文件测试写入权限，完成后归档测试 chat。完整桌面 App 重启后的权限与系统截屏交互仍需手动检查，不能用单元测试代替。
