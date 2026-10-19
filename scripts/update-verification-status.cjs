// Only this section is replaced. Contents API SHA prevents overwriting concurrent edits.
module.exports = async function update({github, context, core}) {
  const repo = context.repo;
  const branch = context.payload.repository.default_branch;
  const result = process.env.BUILD_RESULT || 'unknown';
  const steps = JSON.parse(process.env.BUILD_STEPS || '{}');
  const labels = {success: '成功', failure: '失败', cancelled: '已取消', skipped: '已跳过', unknown: '未知'};
  const status = value => labels[value] || value || '未执行';
  const url = `${context.serverUrl}/${repo.owner}/${repo.repo}/actions/runs/${context.runId}`;
  const lines = [
    `更新时间：${new Date().toISOString()}（UTC）。`,
    '',
    `本次 Windows 构建结果：**${status(result)}**；运行 #${context.runNumber}，第 ${process.env.GITHUB_RUN_ATTEMPT || '1'} 次尝试，触发方式：${context.eventName}。`,
    '',
    `- [构建日志与 Artifacts](${url})`,
    `- 构建提交：\`${context.sha}\``,
    `- 官方包下载、签名验证与 EXE 编译：${status(steps.package?.outcome)}`,
    `- 内嵌包校验、完整解压逐文件比对与损坏检测：${status(steps.test?.outcome)}`,
    `- EXE artifact 上传：${status(steps.exe?.outcome)}`,
    `- 构建报告上传：${status(steps.report?.outcome)}`
  ];
  for (const [id, label] of [['exe', '单 EXE artifact'], ['report', '构建报告']]) {
    const artifactUrl = steps[id]?.outputs?.['artifact-url'];
    if (steps[id]?.outcome === 'success' && artifactUrl)
      lines.push(`- [${label}](${artifactUrl})（保留 14 天）`);
  }
  lines.push('', result === 'success'
    ? '本次已通过封装与解压测试；应用启动、登录、服务及具体功能仍待用户实机验证。'
    : '本次未完成全部构建和封装验证；请查看运行日志。不能据此认定已生成可用 EXE。');
  lines.push('', '调度：以 2026-10-19 UTC 为锚点，每 72 小时一个构建日期，每日 00:17 UTC（新加坡时间 08:17）检查；GitHub 可能延迟或漏发调度。手动事件不受日期门控。');
  lines.push('', '新 fork 仓库需在 Actions 页面启用工作流，并可手动 Run workflow 完成首次构建。仅状态更新任务请求 contents: write；构建任务保持只读权限。');
  const body = lines.join('\n');
  for (let attempt = 0; attempt < 3; attempt++) {
    const {data} = await github.rest.repos.getContent({...repo, path: 'README.md', ref: branch});
    const original = Buffer.from(data.content, 'base64').toString('utf8');
    const section = /(^## 当前验证状态[^\S\r\n]*\r?\n)[\s\S]*?(?=^##[ \t]|(?![\s\S]))/m;
    if (!section.test(original)) throw new Error('Current verification section missing; README left untouched.');
    const newline = original.includes('\r\n') ? '\r\n' : '\n';
    const updated = original.replace(section, (_, heading) =>
      heading + newline + body.replace(/\n/g, newline) + newline + newline);
    if (updated === original) return;
    try {
      await github.rest.repos.createOrUpdateFileContents({
        ...repo, path: 'README.md', branch, sha: data.sha,
        message: `docs: update verification status for run #${context.runNumber} [skip ci]`,
        content: Buffer.from(updated, 'utf8').toString('base64')
      });
      core.info('Updated only README current verification status.');
      return;
    } catch (error) {
      if (error.status !== 409 || attempt === 2) throw error;
    }
  }
};
