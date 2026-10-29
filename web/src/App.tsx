import { useCallback, useEffect, useRef, useState, type ReactNode } from 'react';
import { VoyageSpinner, VoyageStateView, VoyageStatusPill, VoyageToolbar } from '@yiminlab/voyage/react';
import { action, api, downloadDiagnostic, readLaunchState, RequestGate, response, selectJobInURL } from './api';
import { dateTime, duration, eventLabel, followupPresentation, isActive, phaseLabel, phaseTone, routeConfidence, stageLabel, timeline } from './format';
import type { JobDetail, JobEvent, JobList, JobSummary, StatusFilter, SystemInfo } from './types';

const iconPaths: Record<string, ReactNode> = {
  capture: <><path d="M8 3H4a1 1 0 0 0-1 1v4m13-5h4a1 1 0 0 1 1 1v4M3 16v4a1 1 0 0 0 1 1h4m8 0h4a1 1 0 0 0 1-1v-4"/><rect x="7" y="7" width="10" height="10" rx="2"/></>,
  search: <><circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/></>,
  folder: <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v10H3Z"/>,
  clock: <><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></>,
  refresh: <><path d="M20 11a8 8 0 1 0-2 6M20 4v7h-7"/></>,
  download: <><path d="M12 3v12m-4-4 4 4 4-4M4 16v5h16v-5"/></>,
  external: <><path d="M14 3h7v7M10 14 21 3M10 3H4a1 1 0 0 0-1 1v16a1 1 0 0 0 1 1h16a1 1 0 0 0 1-1v-6"/></>,
  stop: <rect x="5" y="5" width="14" height="14" rx="2"/>,
  check: <path d="m5 12 4 4L19 6"/>,
  alert: <><path d="m12 3 10 18H2Z"/><path d="M12 9v5m0 3v.1"/></>,
  activity: <path d="M2 12h4l3-8 6 16 3-8h4"/>,
  history: <><path d="M3 3v6h6M3 9a9 9 0 1 1 0 6M12 7v5l4 2"/></>,
  arrow: <path d="m9 5 7 7-7 7"/>,
};
function Icon({ name, className = '' }: { name: string; className?: string }) {
  return <svg className={`icon ${className}`} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">{iconPaths[name]}</svg>;
}
const initialLaunch = readLaunchState();
const emptyList: JobList = { jobs: [], total: 0, counts: {}, projects: [] };
const filters: Array<{ key: StatusFilter; label: string; icon: string }> = [
  { key: 'all', label: '全部任务', icon: 'history' }, { key: 'active', label: '正在进行', icon: 'activity' },
  { key: 'attention', label: '需要处理', icon: 'alert' }, { key: 'completed', label: '流程已结束', icon: 'check' },
];

function JobBadge({ job }: { job: JobSummary }) {
  const phase = job.derivedPhase || job.phase;
  return <VoyageStatusPill tone={phaseTone(phase)}>{phaseLabel(phase)}</VoyageStatusPill>;
}

export default function App() {
  const [selected, setSelected] = useState(initialLaunch.job);
  const [tokenPresent, setTokenPresent] = useState(initialLaunch.tokenPresent);
  const [search, setSearch] = useState(''); const [query, setQuery] = useState('');
  const [status, setStatus] = useState<StatusFilter>('all'); const [project, setProject] = useState('');
  const [offset, setOffset] = useState(0); const [jobs, setJobs] = useState<JobList>(emptyList);
  const [detail, setDetail] = useState<JobDetail | null>(null); const [system, setSystem] = useState<SystemInfo | null>(null);
  const [loading, setLoading] = useState(true); const [listError, setListError] = useState('');
  const [detailError, setDetailError] = useState(''); const [tab, setTab] = useState<'overview' | 'process' | 'debug'>('overview');
  const [actionError, setActionError] = useState(''); const [notice, setNotice] = useState('');
  const [actionBusy, setActionBusy] = useState(false); const [refreshedAt, setRefreshedAt] = useState('');
  const listGate = useRef(new RequestGate()); const detailGate = useRef(new RequestGate());
  const selectedRef = useRef(selected); selectedRef.current = selected;
  const currentDetail = detail?.jobId === selected ? detail : null;

  useEffect(() => {
    const timer = setTimeout(() => { setQuery(search.trim()); setOffset(0); }, 250);
    return () => clearTimeout(timer);
  }, [search]);

  useEffect(() => {
    const handle = () => {
      const next = readLaunchState(); setTokenPresent(next.tokenPresent);
      if (next.job) { setSelected(next.job); setActionError(''); setNotice(''); }
    };
    addEventListener('hashchange', handle); return () => removeEventListener('hashchange', handle);
  }, []);

  const choose = useCallback((job: string) => {
    detailGate.current.invalidate(); setSelected(job); selectJobInURL(job);
    setActionError(''); setNotice(''); setDetailError('');
  }, []);

  const refreshList = useCallback(async (signal?: AbortSignal) => {
    if (!tokenPresent) { setLoading(false); return; }
    const revision = listGate.current.next();
    try {
      const params = new URLSearchParams({ limit: '50', offset: String(offset), q: query, status, project });
      const result = await api<JobList>(`/api/jobs?${params}`, { signal });
      if (!listGate.current.current(revision)) return;
      setJobs(result); setListError(''); setLoading(false); setRefreshedAt(new Date().toISOString());
      if (!selectedRef.current && result.jobs[0]) choose(result.jobs[0].jobId);
      if (offset && !result.jobs.length && result.total) setOffset(Math.floor((result.total - 1) / 50) * 50);
    } catch (error) {
      if (signal?.aborted || !listGate.current.current(revision)) return;
      setListError(error instanceof Error ? error.message : '任务列表加载失败'); setLoading(false);
    }
  }, [choose, offset, project, query, status, tokenPresent]);

  const refreshDetail = useCallback(async (signal?: AbortSignal) => {
    if (!selected || !tokenPresent) return;
    const revision = detailGate.current.next();
    try {
      const result = await api<JobDetail>(`/api/jobs/${encodeURIComponent(selected)}`, { signal });
      if (!detailGate.current.current(revision) || selectedRef.current !== selected) return;
      setDetail(result); setDetailError('');
    } catch (error) {
      if (signal?.aborted || !detailGate.current.current(revision)) return;
      setDetailError(error instanceof Error ? error.message : '任务详情加载失败');
    }
  }, [selected, tokenPresent]);

  useEffect(() => {
    const controller = new AbortController(); void refreshList(controller.signal);
    return () => { controller.abort(); listGate.current.invalidate(); };
  }, [refreshList]);
  useEffect(() => {
    const controller = new AbortController(); void refreshDetail(controller.signal);
    return () => { controller.abort(); detailGate.current.invalidate(); };
  }, [refreshDetail]);
  useEffect(() => {
    if (!tokenPresent) return;
    const interval = setInterval(() => { if (document.visibilityState === 'visible') { void refreshList(); void refreshDetail(); } }, (jobs.counts.active || (currentDetail && isActive(currentDetail.summary))) ? 1500 : 5000);
    return () => clearInterval(interval);
  }, [refreshList, refreshDetail, jobs.counts.active, currentDetail?.summary.phase, currentDetail?.summary.derivedPhase, tokenPresent]);
  useEffect(() => {
    if (!tokenPresent) return;
    let alive = true;
    const refresh = () => api<SystemInfo>('/api/system').then(value => { if (alive) setSystem(value); }).catch(() => {});
    void refresh(); const timer = setInterval(refresh, 10000);
    return () => { alive = false; clearInterval(timer); };
  }, [tokenPresent]);

  async function runAction(kind: 'cancel' | 'open-chat' | 'export') {
    if (!currentDetail || actionBusy) return;
    if (kind === 'cancel' && !window.confirm('取消这个任务？后台会中断当前对话，不会自动重试。')) return;
    const jobId = selected; setActionBusy(true); setActionError(''); setNotice('');
    try {
      if (kind === 'export') await downloadDiagnostic(jobId); else await action(jobId, kind);
      if (selectedRef.current === jobId) setNotice(kind === 'cancel' ? '取消请求已发送，正在等待后台停止。' : kind === 'open-chat' ? '已请求在 Codex 打开对话。' : '诊断文件已下载到本机。');
      await Promise.all([refreshList(), refreshDetail()]);
    } catch (error) { if (selectedRef.current === jobId) setActionError(error instanceof Error ? error.message : '操作失败'); }
    finally { setActionBusy(false); }
  }

  const helper = system?.helper || system?.hotkey || {};
  const active = currentDetail ? isActive(currentDetail.summary) : false;
  return <div className="vg-app vg-fullscreen capture-app">
    <div className="vg-topline" />
    <header className="vg-header capture-header">
      <span className="vg-logo capture-logo"><Icon name="capture" /></span>
      <strong className="vg-brand">Codex Capture</strong><span className="vg-ws">任务工作台</span>
      <span className="vg-sp" />
      <span className="capture-shortcut"><kbd>⌥ S</kbd><span>截图并开始任务</span></span>
      <button className="vg-iconbtn" title="刷新记录" aria-label="刷新记录" onClick={() => { void refreshList(); void refreshDetail(); }}><Icon name="refresh" /></button>
      <VoyageToolbar locale="zh" />
    </header>
    {!tokenPresent ? <VoyageStateView variant="info" size="page" heading="从菜单栏打开任务工作台" description="选择 Codex Capture 菜单中的「任务工作台…」，或运行 codex-capture gui。当前窗口没有本机连接凭据。" /> : <>
      <main className="capture-workspace">
        <aside className="capture-sidebar" aria-label="任务筛选">
          <div className="sidebar-section"><h2>任务</h2>
            {filters.map(filter => <button key={filter.key} className={`filter-button ${status === filter.key ? 'selected' : ''}`} aria-pressed={status === filter.key} onClick={() => { setStatus(filter.key); setOffset(0); }}>
              <Icon name={filter.icon} /><span>{filter.label}</span><span className="count">{jobs.counts[filter.key] || 0}</span>
            </button>)}
          </div>
          <div className="sidebar-section project-filters"><h2>项目</h2>
            <button className={`filter-button ${!project ? 'selected' : ''}`} aria-pressed={!project} onClick={() => { setProject(''); setOffset(0); }}><Icon name="folder" /><span>所有项目</span></button>
            {jobs.projects.map(value => { const name = typeof value === 'string' ? value : value.name || value.projectName || ''; return <button key={name} className={`filter-button ${project === name ? 'selected' : ''}`} aria-pressed={project === name} title={name} onClick={() => { setProject(name); setOffset(0); }}><span className="project-dot" /><span>{name || '尚未分配'}</span></button>; })}
          </div>
          <details className="helper-status"><summary><span className={`status-dot ${helper.registered ? 'good' : 'attention'}`} />截图助手</summary>
            <dl><dt>快捷键</dt><dd>{helper.registered ? '⌥ S 已注册' : '尚未注册'}</dd><dt>屏幕录制</dt><dd>{helper.screenCaptureAllowed ? '已授权' : '等待授权'}</dd><dt>前景 AX</dt><dd>{!helper.accessibilityEnabled ? '未开启' : helper.accessibilityTrusted ? '已授权' : '等待授权'}</dd></dl>
            <p>权限状态取自菜单栏助手。可在助手菜单刷新。</p>
          </details>
        </aside>
        <section className="history-pane" aria-label="任务历史">
          <div className="history-heading"><h1>任务历史</h1><span>{jobs.total} 条</span></div>
          <label className="search-field"><Icon name="search" /><input aria-label="搜索任务" placeholder="搜索描述、项目或任务 ID" value={search} onChange={event => setSearch(event.target.value)} /></label>
          {listError && <div className="inline-error" role="alert">{listError}</div>}
          <div className="history-list">
            {loading ? <VoyageStateView variant="loading" heading="读取任务记录" /> : !jobs.jobs.length ? <VoyageStateView heading={query || project || status !== 'all' ? '没有匹配的任务' : '还没有截图任务'} description={query || project || status !== 'all' ? '试试其他搜索词或筛选条件。' : '按 Option+S 截图、输入描述，过程会显示在这里。'} /> : jobs.jobs.map(job => <button className={`job-row ${selected === job.jobId ? 'selected' : ''}`} key={job.jobId} onClick={() => choose(job.jobId)} aria-pressed={selected === job.jobId}>
              <div className="job-row-top"><span className={`status-dot ${isActive(job) ? 'running' : phaseTone(job.derivedPhase || job.phase)}`} /><span className="job-project">{job.projectName || '正在判断项目'}</span><time>{dateTime(job.createdAt, true)}</time></div>
              <strong>{job.title?.replace(/^截图任务\s*[·・]\s*/, '') || job.text || '未命名任务'}</strong>
              <p>{job.text || '描述记录不可用'}</p>
              <div className="job-row-bottom"><span>{phaseLabel(job.derivedPhase || job.phase)}</span><span>{job.warningCount ? <><Icon name="alert" />{job.warningCount}</> : <><Icon name="clock" />{duration(job.elapsedSeconds)}</>}</span></div>
            </button>)}
          </div>
          <div className="pagination"><button className="vg-btn" disabled={offset === 0} onClick={() => setOffset(Math.max(0, offset - 50))}>上一页</button><span>{jobs.total ? `${offset + 1}–${Math.min(offset + 50, jobs.total)} / ${jobs.total}` : '0 条'}</span><button className="vg-btn" disabled={offset + 50 >= jobs.total} onClick={() => setOffset(offset + 50)}>下一页</button></div>
        </section>
        <section className="detail-pane" aria-label="任务详情">
          {!selected ? <VoyageStateView size="page" icon={<Icon name="capture" />} heading="选择一个任务" description="查看截图、项目判断、执行过程与诊断记录。" /> : !currentDetail ? <VoyageStateView variant={detailError ? 'error' : 'loading'} size="page" heading={detailError ? '无法读取这个任务' : '正在读取任务'} description={detailError || undefined} /> : <>
            <div className="detail-header"><div className="detail-title-row"><span className="project-label"><Icon name="folder" />{currentDetail.summary.projectName || '尚未分配项目'}</span><JobBadge job={currentDetail.summary} /></div><h2>{currentDetail.route?.title || currentDetail.summary.title?.replace(/^截图任务\s*[·・]\s*/, '') || '截图任务'}</h2>
              <div className="detail-meta"><span><Icon name="clock" />{dateTime(currentDetail.state.createdAt)}</span><span>{duration(currentDetail.summary.elapsedSeconds)}</span></div>
              <div className="detail-actions"><button className="vg-btn primary" disabled={!currentDetail.state.threadId || active || actionBusy} title={active ? '后台结束后可打开完整对话，避免争用执行进程。' : '打开对应的 Codex 对话'} onClick={() => void runAction('open-chat')}><Icon name="external" />打开 Codex chat</button><button className="vg-btn" disabled={actionBusy} onClick={() => void runAction('export')}><Icon name="download" />导出诊断</button>{active && <button className="vg-btn danger" disabled={actionBusy || currentDetail.summary.cancelRequested} onClick={() => void runAction('cancel')}><Icon name="stop" />{currentDetail.summary.cancelRequested ? '正在取消…' : '取消任务'}</button>}</div>
              <p className="muted">诊断导出含原始描述、本机跟进预设、上下文、项目路径和日志，未脱敏；分享前请先检查。</p>
              {(notice || actionError || detailError) && <div className={actionError || detailError ? 'inline-error' : 'inline-notice'} role="status">{actionError || detailError || notice}</div>}
            </div>
            <div className="detail-tabs" role="tablist" aria-label="任务详情视图">{([{ key: 'overview', label: '概览' }, { key: 'process', label: '执行过程' }, { key: 'debug', label: '调试' }] as const).map(item => <button role="tab" aria-selected={tab === item.key} aria-controls={`panel-${item.key}`} id={`tab-${item.key}`} key={item.key} onClick={() => setTab(item.key)} className={tab === item.key ? 'active' : ''}>{item.label}{item.key === 'process' && active ? <span className="status-dot running" /> : null}</button>)}</div>
            <div className="detail-content" role="tabpanel" id={`panel-${tab}`} aria-labelledby={`tab-${tab}`} key={selected + tab}>
              {currentDetail.state.error && <div className="warning-block" role="alert"><Icon name="alert" /><div><strong>这一步需要处理</strong><p>{currentDetail.state.error}</p></div></div>}
              {currentDetail.warnings?.length > 0 && <div className="warning-block"><Icon name="alert" /><div><strong>记录提示</strong>{currentDetail.warnings.map((warning, index) => <p key={index}>{typeof warning === 'string' ? warning : JSON.stringify(warning)}</p>)}</div></div>}
              {tab === 'overview' ? <Overview detail={currentDetail} /> : tab === 'process' ? <ProcessView detail={currentDetail} /> : <DebugView detail={currentDetail} />}
            </div>
          </>}
        </section>
      </main>
      <footer className="capture-footer"><span className={`status-dot ${listError ? 'attention' : 'good'}`} /><span>{listError ? '连接异常，保留上次记录' : jobs.counts.active ? `正在跟踪 ${jobs.counts.active} 个任务` : '本机记录已同步'}</span><span className="footer-right">{refreshedAt ? `最近刷新 ${dateTime(refreshedAt).split(' ').pop()}` : '连接中'}<span>仅本机</span></span></footer>
    </>}
  </div>;
}

function Section({ title, children, extra }: { title: string; children: ReactNode; extra?: ReactNode }) {
  return <section className="detail-section"><div className="section-heading"><h3>{title}</h3>{extra}</div>{children}</section>;
}

function StageTrack({ detail }: { detail: JobDetail }) {
  return <ol className="stage-track">{timeline(detail).map((stage, index) => <li key={stage.key} className={`${stage.finished ? 'finished' : ''} ${stage.failed || stage.interrupted ? 'stage-failed' : ''} ${stage.active ? 'current' : ''} ${stage.disabled || stage.skipped ? 'disabled' : ''}`}><span className="stage-mark">{stage.skipped ? '—' : stage.active ? <VoyageSpinner size="sm" decorative /> : stage.failed || stage.interrupted ? <Icon name="alert" /> : stage.finished ? <Icon name="check" /> : index + 1}</span><div><strong>{stage.label}</strong><span>{stage.skipped ? '已跳过' : stage.active ? '正在进行' : stage.disabled ? '未启用' : stage.failed ? '执行失败' : stage.interrupted ? '已中断' : stage.finished ? duration(stage.seconds) : stage.pendingLabel}</span><small>{stage.note}</small></div></li>)}</ol>;
}

function FollowupDecisionView({ detail }: { detail: JobDetail }) {
  const decision = detail.state.followupDecision;
  if (!decision) return null;
  const presentation = followupPresentation(detail);
  return <div className="followup-decision"><div className="event-heading"><strong>跟进判断</strong><VoyageStatusPill tone={presentation.tone}>{presentation.label}</VoyageStatusPill></div><p>{decision.reason}</p></div>;
}

function Screenshot({ jobId, hasImage }: { jobId: string; hasImage?: boolean }) {
  const [image, setImage] = useState(''); const [error, setError] = useState('');
  useEffect(() => {
    setImage(''); setError(''); if (!hasImage) return;
    let alive = true; let url = ''; const controller = new AbortController();
    response(`/api/jobs/${encodeURIComponent(jobId)}/image`, { signal: controller.signal }).then(res => res.blob()).then(blob => { if (alive) { url = URL.createObjectURL(blob); setImage(url); } }).catch(err => { if (alive) setError(err.message); });
    return () => { alive = false; controller.abort(); if (url) URL.revokeObjectURL(url); };
  }, [jobId, hasImage]);
  if (!hasImage) return <div className="muted empty-image">未找到原始截图</div>;
  if (error) return <div className="inline-error">截图加载失败：{error}</div>;
  return image ? <a className="screenshot-link" href={image} target="_blank" rel="noreferrer" title="在新窗口查看原始截图"><img className="task-screenshot" src={image} alt="本次任务的原始截图" /></a> : <div className="image-loading"><VoyageSpinner label="加载截图" /></div>;
}

function Overview({ detail }: { detail: JobDetail }) {
  const { state, request, route } = detail;
  return <>
    <StageTrack detail={detail} />
    <Section title="你的描述"><p className="user-description">{request.text || detail.summary.text || '描述记录不可用'}</p><Screenshot jobId={detail.jobId} hasImage={detail.summary.hasImage} /></Section>
    <Section title="项目判断" extra={<span className="muted">置信度 {routeConfidence(route?.confidence)}</span>}><p className="route-reason">{route?.reason || (isActive(detail.summary) ? '正在结合截图和上下文识别项目。' : '没有保存项目判断理由。')}</p><div className="facts"><div><span>分类模型</span><strong>{state.classifierModel || '—'}</strong></div><div><span>任务模型</span><strong>{state.actualModel || '—'}</strong></div><div><span>工作目录</span><code>{state.cwd || '—'}</code></div></div></Section>
    {state.initialTurn?.finalText && <Section title="首轮结果"><div className="result-text">{state.initialTurn.finalText}</div></Section>}
    <Section title="预设跟进" extra={<span className="muted">已尝试 {state.followupAttempts || 0} 次</span>}><FollowupDecisionView detail={detail} /><blockquote className="preset-text">{request.followup?.trim() ? request.followup : '此任务未启用自动跟进。'}</blockquote>{state.followupTurn?.finalText && <div className="result-text">{state.followupTurn.finalText}</div>}</Section>
  </>;
}

function ProcessView({ detail }: { detail: JobDetail }) {
  const important = (detail.events || []).filter(event => event.itemType !== 'reasoning' && event.method !== 'thread/status/changed');
  const lifecycle = detail.lifecycle || [];
  const combined: JobEvent[] = [...lifecycle, ...important].sort((a, b) => (a.at || '').localeCompare(b.at || ''));
  return <><StageTrack detail={detail} /><FollowupDecisionView detail={detail} /><Section title="执行记录" extra={<span className="muted">{detail.eventsTotal || 0} 个原始事件</span>}>
    <p className="muted process-note">记录会自动更新。这里只显示阶段变化、工具活动和模型进展；完整事件可在调试页查看。</p>
    {detail.eventsTotal > detail.events.length && <div className="inline-notice">这里只加载最近 {detail.events.length} 个原始事件；导出诊断可查看保留范围说明。</div>}
    {!combined.length ? <VoyageStateView heading="尚无执行事件" description="任务开始后，阶段和工具活动会出现在这里。" /> : <ol className="event-list">{combined.map((event, index) => <li key={`${event.at}-${index}`} className={event.status === 'failed' || event.method === 'error' ? 'event-failed' : ''}><div className="event-time"><time>{dateTime(event.at).split(' ').pop()}</time><span>{stageLabel(event.stage)}</span></div><div className="event-body"><div className="event-heading"><strong>{eventLabel(event)}</strong>{event.status === 'failed' && <VoyageStatusPill tone="warning">失败</VoyageStatusPill>}</div>{event.text && <p>{event.text}</p>}{event.command && <pre>{event.command}</pre>}{event.tool && <code>{[event.server, event.tool].filter(Boolean).join(' / ')}</code>}{event.error != null && <pre>{typeof event.error === 'string' ? event.error : JSON.stringify(event.error, null, 2)}</pre>}</div></li>)}</ol>}
  </Section></>;
}

function DebugView({ detail }: { detail: JobDetail }) {
  return <>
    <Section title="任务标识"><dl className="debug-identifiers"><dt>任务 ID</dt><dd>{detail.jobId}</dd><dt>Codex chat</dt><dd>{detail.state.threadId || '尚未创建'}</dd><dt>后台进程</dt><dd>{detail.state.workerPid || '—'}</dd><dt>App Server</dt><dd>{detail.state.appServerPid || '—'}</dd><dt>最近更新</dt><dd>{dateTime(detail.state.updatedAt)}</dd></dl></Section>
    <Section title="诊断记录"><p className="muted">这些记录只保存在本机。导出文件含原始描述、本机跟进预设、上下文、项目路径和日志，未脱敏；分享前请先检查。</p>
      <Raw title="任务状态" value={detail.state} open />
      <Raw title="原始请求与前景上下文" value={detail.request} />
      <Raw title="Luna 项目判断" value={detail.route} />
      <Raw title={`原始事件（加载 ${detail.events.length} / ${detail.eventsTotal}）`} value={detail.events} />
      <Raw title="阶段日志" value={detail.lifecycle} />
      {Object.entries(detail.logs || {}).map(([name, value]) => <Raw key={name} title={name} value={value || '此日志为空'} />)}
    </Section>
  </>;
}
function Raw({ title, value, open = false }: { title: string; value: unknown; open?: boolean }) {
  return <details className="raw-record" open={open || undefined}><summary>{title}</summary><pre>{typeof value === 'string' ? value : JSON.stringify(value, null, 2) || '无记录'}</pre></details>;
}
