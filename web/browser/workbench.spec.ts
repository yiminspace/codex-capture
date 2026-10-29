import { test, expect, type Page } from '@playwright/test';
import type { JobDetail } from '../src/types';

const primary = { jobId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', text: '请讨论如何编辑示例便签的标签。', title: '示例便签增加标签编辑入口', phase: 'completed', phaseLabel: '流程已结束', projectName: 'sample-notes', createdAt: '2025-01-01T08:05:30Z', updatedAt: '2025-01-01T08:07:04Z', elapsedSeconds: 94, threadId: 'cccccccc-dddd-eeee-ffff-aaaaaaaaaaaa', hasImage: true, warningCount: 0 };
const secondary = { ...primary, jobId: 'bbbbbbbb-bbbb-cccc-dddd-eeeeeeeeeeee', title: '示例看板按名称排序', text: '请将示例看板列表按名称排序', projectName: 'sample-board', phase: 'running_initial', threadId: undefined, elapsedSeconds: 31 };
function detail(job = primary) {
  return { jobId: job.jobId, summary: job, state: { phase: job.phase, createdAt: job.createdAt, updatedAt: job.updatedAt, classifierModel: 'gpt-6-luna', actualModel: 'gpt-6.1-sol', classificationSeconds: 9.554, threadId: job.threadId, cwd: '/workspace/' + job.projectName, followupAttempts: 1, initialTurn: { status: 'completed', finalText: '示例便签可通过标签按钮进行编辑。<script>window.bad = true</script>', elapsedSeconds: 27.7 }, followupTurn: job.phase === 'completed' ? { status: 'completed', finalText: '示例讨论结束，保留现有便签行为。', elapsedSeconds: 50.2 } : undefined }, request: { text: job.text, followup: '请复查刚才的改动，完成必要验证，并总结结果。', context: { app: { name: 'Google Chrome' }, accessibility: { status: 'disabled' } } }, route: { title: job.title, reason: '示例截图中的便签标题与虚构项目一致。', confidence: .99 }, events: [{ at: '2025-01-01T08:05:30Z', stage: 'initial', method: 'turn/started' }, { at: '2025-01-01T08:06:30Z', stage: 'followup', itemType: 'commandExecution', command: 'npm run test', status: 'failed' }, { at: '2025-01-01T08:07:04Z', stage: 'followup', itemType: 'agentMessage', phase: 'final_answer', text: '示例标签检查未完成：测试浏览器拒绝访问。' }], lifecycle: [], logs: { 'worker.log': '', 'app-server.stderr.log': 'browser: permission denied' }, eventsTotal: 3, warnings: [] };
}
async function setup(page: Page, options: { delayPrimary?: boolean; unauthorized?: boolean; primaryDetail?: JobDetail } = {}) {
  const calls: string[] = []; const errors: string[] = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.route('**/api/**', async route => {
    const url = new URL(route.request().url()); calls.push(route.request().method() + ' ' + url.pathname);
    expect(route.request().headers().authorization).toBe('Bearer fixture-token');
    if (options.unauthorized) { await route.fulfill({ status: 401, json: { error: 'Unauthorized' } }); return; }
    if (url.pathname === '/api/system') { await route.fulfill({ json: { helper: { registered: true, screenCaptureAllowed: true, accessibilityEnabled: false } } }); return; }
    if (url.pathname === '/api/jobs') {
      let jobs = [primary, secondary];
      if (url.searchParams.get('q')) jobs = jobs.filter(job => (job.text + job.title).includes(url.searchParams.get('q')!));
      if (url.searchParams.get('project')) jobs = jobs.filter(job => job.projectName === url.searchParams.get('project'));
      if (url.searchParams.get('status') === 'active') jobs = jobs.filter(job => job.phase !== 'completed');
      if (url.searchParams.get('status') === 'completed') jobs = jobs.filter(job => job.phase === 'completed');
      await route.fulfill({ json: { jobs, total: jobs.length, counts: { all: 2, active: 1, completed: 1, attention: 0 }, projects: ['sample-notes', 'sample-board'] } }); return;
    }
    if (url.pathname.endsWith('/image')) { await route.fulfill({ contentType: 'image/png', body: Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a7ioAAAAASUVORK5CYII=', 'base64') }); return; }
    if (url.pathname.endsWith('/cancel') || url.pathname.endsWith('/open-chat')) { await route.fulfill({ json: { ok: true } }); return; }
    if (url.pathname.endsWith('/export')) { await route.fulfill({ json: { task: primary.jobId } }); return; }
    if (options.delayPrimary && url.pathname.endsWith(primary.jobId)) await new Promise(resolve => setTimeout(resolve, 700));
    await route.fulfill({ json: url.pathname.endsWith(secondary.jobId) ? detail(secondary) : options.primaryDetail || detail(primary) });
  });
  return { calls, errors };
}

test('real Voyage theme controls, screenshot and safe task history', async ({ page }) => {
  const { errors, calls } = await setup(page);
  await page.goto(`/#token=fixture-token&job=${primary.jobId}`);
  await expect(page.getByRole('heading', { name: primary.title })).toBeVisible();
  await expect(page.getByAltText('本次任务的原始截图')).toHaveAttribute('src', /^blob:/);
  await expect(page.getByText('示例讨论结束，保留现有便签行为。')).toBeVisible();
  expect(await page.evaluate(() => (window as unknown as { bad?: boolean }).bad)).toBeUndefined();
  expect(page.url()).not.toContain('token=');
  await page.screenshot({ path: test.info().outputPath('workbench-dark.png'), fullPage: true });
  await expect(page.locator('html')).toHaveAttribute('data-theme', 'slate');
  await expect(page.locator('html')).toHaveAttribute('data-mode', 'dark');
  await page.locator('.vg-switcher-mode').click();
  await expect(page.locator('html')).toHaveAttribute('data-mode', 'light');
  await page.screenshot({ path: test.info().outputPath('workbench-light.png'), fullPage: true });
  await page.locator('.vg-switcher-trigger').click();
  await expect(page.locator('.vg-switcher-panel')).toBeVisible();
  expect(calls.filter(call => call.startsWith('POST'))).toEqual([]);
  expect(errors).toEqual([]);
});

test('search and project filters preserve the selected record', async ({ page }) => {
  const { errors } = await setup(page);
  await page.goto(`/#token=fixture-token&job=${primary.jobId}`);
  await expect(page.getByRole('heading', { name: primary.title })).toBeVisible();
  await page.getByRole('textbox', { name: '搜索任务' }).fill('排序');
  await expect(page.locator('.job-row')).toHaveCount(1);
  await expect(page.locator('.job-row')).toContainText('示例看板按名称排序');
  await expect(page.getByRole('heading', { name: primary.title })).toBeVisible();
  await page.getByRole('textbox', { name: '搜索任务' }).fill('');
  await page.getByRole('button', { name: 'sample-notes', exact: true }).click();
  await expect(page.locator('.job-row')).toHaveCount(1);
  await expect(page.locator('.job-row')).toContainText(primary.title);
  expect(errors).toEqual([]);
});

test('a delayed previous selection never overwrites the current detail', async ({ page }) => {
  await setup(page, { delayPrimary: true });
  await page.goto(`/#token=fixture-token&job=${primary.jobId}`);
  await page.locator('.job-row').filter({ hasText: secondary.title }).click();
  await expect(page.getByRole('heading', { name: secondary.title })).toBeVisible();
  await page.waitForTimeout(1100);
  await expect(page.getByRole('heading', { name: secondary.title })).toBeVisible();
  await expect(page.getByRole('button', { name: '打开 Codex chat' })).toBeDisabled();
});

test('explicit cancel, diagnostic download and logs stay bound to selected job', async ({ page }) => {
  const { calls, errors } = await setup(page);
  await page.goto(`/#token=fixture-token&job=${secondary.jobId}`);
  await expect(page.getByRole('heading', { name: secondary.title })).toBeVisible();
  page.once('dialog', dialog => dialog.accept());
  await page.getByRole('button', { name: '取消任务' }).click();
  await expect(page.getByText('取消请求已发送，正在等待后台停止。')).toBeVisible();
  expect(calls).toContain(`POST /api/jobs/${secondary.jobId}/cancel`);
  await page.getByRole('tab', { name: '调试', exact: true }).click();
  await page.getByText('app-server.stderr.log', { exact: true }).click();
  await expect(page.getByText('browser: permission denied')).toBeVisible();
  const downloadPromise = page.waitForEvent('download');
  await page.getByRole('button', { name: '导出诊断' }).click();
  expect((await downloadPromise).suggestedFilename()).toContain(secondary.jobId);
  expect(errors).toEqual([]);
});

test('authentication errors show recovery guidance', async ({ page }) => {
  await setup(page, { unauthorized: true });
  await page.goto('/#token=fixture-token');
  await expect(page.getByText('连接凭据已失效。请从菜单栏重新打开任务工作台。')).toBeVisible();
});

test('narrow screens keep content within the viewport', async ({ page }) => {
  await setup(page); await page.setViewportSize({ width: 390, height: 844 });
  await page.goto(`/#token=fixture-token&job=${primary.jobId}`);
  await expect(page.getByRole('heading', { name: primary.title })).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1)).toBe(true);
});

const followupPreset = '请复查本轮修改，并列出验证结果。';

test('discussion without changes explicitly skips follow-up and retains the original preset', async ({ page }) => {
  const job = detail() as JobDetail;
  job.state.followupAttempts = 0; delete job.state.followupTurn;
  job.state.followupDecision = { send: false, reason: '首轮仅讨论；工作目录没有本轮代码变更，因此未发送跟进语句。' };
  job.request.followup = followupPreset;
  const { calls, errors } = await setup(page, { primaryDetail: job });
  await page.goto(`/#token=fixture-token&job=${primary.jobId}`);
  const followupStage = page.locator('.stage-track li').last();
  await expect(followupStage).toContainText('已跳过');
  await expect(followupStage).not.toHaveClass(/current|finished/);
  await expect(page.locator('.followup-decision')).toContainText(job.state.followupDecision.reason);
  expect(await page.locator('.preset-text').textContent()).toBe(followupPreset);
  await page.getByRole('tab', { name: '执行过程', exact: true }).click();
  await expect(page.locator('.followup-decision')).toContainText('已跳过');
  await expect(page.locator('.followup-decision')).toContainText(job.state.followupDecision.reason);
  expect(calls.filter(call => call.startsWith('POST'))).toEqual([]);
  expect(errors).toEqual([]);
});

test('a verified change shows the conditional follow-up result and decision reason', async ({ page }) => {
  const job = detail() as JobDetail;
  job.state.followupDecision = { send: true, reason: '已检测到本轮修改 src/NoteTags.tsx，发送本机跟进语句。' };
  job.state.followupTurn = { status: 'completed', finalText: '示例便签标签复查完成，测试通过。', elapsedSeconds: 72 };
  job.request.followup = followupPreset;
  const { calls, errors } = await setup(page, { primaryDetail: job });
  await page.goto(`/#token=fixture-token&job=${primary.jobId}`);
  await expect(page.locator('.followup-decision')).toContainText('跟进已完成');
  await expect(page.locator('.followup-decision')).toContainText(job.state.followupDecision.reason);
  await expect(page.locator('.stage-track li').last()).toHaveClass(/finished/);
  await expect(page.getByText(job.state.followupTurn.finalText!)).toBeVisible();
  expect(await page.locator('.preset-text').textContent()).toBe(followupPreset);
  expect(calls.filter(call => call.startsWith('POST'))).toEqual([]);
  expect(errors).toEqual([]);
});
