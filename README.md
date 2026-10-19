# codex-protable-single-exe

将指定的官方 ChatGPT x64 MSIX 封装为实验性单文件启动器。

**这是未获官方支持的便携化实验。构建成功只说明封装和解压测试通过，不等于登录、服务、本地执行及所有功能可用。**

## 在 GitHub 上构建

1. Frok 该仓库。
2. 首次 push 会自动运行。也可以打开 **Actions → Build experimental portable EXE → Run workflow**。
3. `expected_sha256` 可留空以下载链接当前版本，也可以填写自己已核验的 64 位 SHA-256，以固定输入包。
4. 构建成功后，在本次运行的 **Artifacts** 中下载 `ChatGPT-Portable-experimental-x64`。
5. GitHub artifact 下载结果是 ZIP；解压后只有 `ChatGPT-Portable.exe` 一个文件。另一个 `build-report` artifact 包含来源、版本、哈希、签名验证和测试记录。

工作流使用 `windows-2022`、只读仓库权限、`actions/checkout@v4` 和 `actions/upload-artifact@v4`。不需要 PAT、API key 或任何自定义 Secrets；产物保留 14 天。不会发布 Release。Actions 主版本标签会随上游更新；如需严格供应链锁定，可审核后改为完整 commit SHA。

## 运行方法

将 EXE 放到本地一个简短、可写的路径（例如 `D:\GPT\`），双击启动。第一次会校验并释放应用；控制台显示进度。不要在应用运行时关闭启动器控制台。

程序将创建以下目录：

```text
ChatGPT-Portable.exe
ChatGPTPortableData/
  runtime/<MSIX-SHA256>/app/...
  profile/
  codex/
  launcher.lock
  launcher.log
```

这是“分发单 EXE”，不是运行期间不落盘。需要 EXE 本身体积加完整应用解压体积及缓存空间；解压体积可在 `build-info.json` 查看，建议预留额外空间。新版本使用新 runtime 目录，旧版本不自动删除。关闭所有相关进程后，可手动删除旧 runtime 以节省空间，保留 profile 和 codex 数据。

启动器为 x64 .NET Framework 4.x 程序，使用 Windows 自带的框架；不安装现代 .NET，不联网下载运行时。原包清单声明的最低系统为 Windows 10 19041。这些条件不替代具体应用兼容性测试。

## 实现流程

1. `scripts/Build.ps1` 从以下固定 HTTPS 地址下载完整 MSIX：
   `https://persistent.oaistatic.com/codex-app-prod/ChatGPT-x64.msix`
2. 计算 SHA-256；如果提供预期值则必须相符。通过 Windows SDK `signtool verify /pa /v` 验证官方包签名，失败即停止。
3. 读取 `AppxManifest.xml`，检查 `OpenAI.Codex`、x64 和已知发布者身份；上游变更时停止，要求人工检查。原包签名验证不等于新启动器获得官方签名。
4. 使用 runner 自带 .NET Framework C# 编译器，将 `src/Launcher.cs` 编译为普通用户权限的控制台启动器。
5. 顺序写入“启动器 PE + 原始 MSIX + 64 字节尾部”。尾部含两个 little-endian int64（偏移和长度）、32 字节 SHA-256、16 字节魔数 `CGPTPORTABLE0001`。流式拼接避免把整个包嵌入编译器内存。
6. 启动器读取自身尾部，校验包哈希，用零起点的受限流读取内嵌 ZIP。首次只提取 `app/`，拒绝越界路径，以临时目录完成后再重命名到版本缓存。
7. 启动 `app\ChatGPT.exe`，将工作目录设置为该程序目录，传入 `--user-data-dir=<旁边的 profile 目录>`，并为子进程设置 `CODEX_HOME=<旁边的 codex 目录>`。
8. 上述路径重定向属于实验性尝试。应用可能覆盖参数或继续使用宿主 AppData、注册表、凭据库；本工程不保证完全数据便携或零残留。不会复制当前电脑账号或自动迁移现有安装数据。
9. 启动器等待主进程退出并保留运行缓存，避免 Electron 辅助进程仍存活时误删文件。独占锁仅覆盖启动器生命周期，不能保证拦截已经独立运行的官方安装版或残留进程。
10. `scripts/Test-Package.ps1` 校验内嵌包、提取到含空格和中文的目录，对每个应用文件与原始 MSIX 逐一比对 SHA-256，再验证损坏 payload 会被拒绝。CI 不登录、不启动真实应用界面。

## 本地构建和诊断

在 Windows 安装 PowerShell 7 和带签名工具的 Windows SDK 后，在工程根目录运行：

```powershell
pwsh -File .\scripts\Build.ps1
pwsh -File .\scripts\Test-Package.ps1
.\dist\ChatGPT-Portable.exe --verify-payload
.\dist\ChatGPT-Portable.exe --extract-only C:\Temp\ChatGPT-New-Test
```

提取目标必须不存在。发生错误时，控制台保留错误信息；提供报错、Windows 版本、是否安装过官方版、具体失败功能，以及构建报告中的版本和 SHA-256。不要公开上传 profile、codex 数据或含令牌的日志。

## 当前验证状态

2026-10-19：Windows Server 2022 Actions 构建及封装测试已通过，运行编号 #4，构建提交 `5e925d5cf4d7b6a6a7bf4c15aa7492ff8bb96847`。

- [成功的构建及 artifact 页面](https://github.com/zeon-gits/codex-protable-single-exe/actions/runs/39194579849)
- [单 EXE artifact](https://github.com/zeon-gits/codex-protable-single-exe/actions/runs/39194579849/artifacts/12160884871)
- [构建报告](https://github.com/zeon-gits/codex-protable-single-exe/actions/runs/39194579849/artifacts/12161357794)

已通过官方 MSIX 签名验证、C# 编译、内嵌包 SHA-256 检查、含中文和空格目录的完整解压及逐文件比对、损坏包拒绝测试。已修复旧版编译器路径解析及深层资源长路径解压问题；解压使用扩展长度路径，不修改电脑全局设置。artifact 保留至 2026-11-02

## 参考
- https://learn.microsoft.com/en-us/windows/apps/get-started/intro-pack-dep-proc
- https://learn.microsoft.com/en-us/dotnet/csharp/language-reference/compiler-options/

本仓库仅提供封装源码与流程，不声明拥有或重新授权内嵌的 OpenAI 应用及其第三方组件；原软件适用其自身条款和许可证。
