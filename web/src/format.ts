import type { JobDetail, JobEvent, JobSummary } from './types';

const activePhases = new Set(['queued', 'connecting', 'classifying', 'creating_thread', 'starting_initial', 'running_initial', 'initial_finished', 'starting_followup', 'running_followup', 'followup_finished']);
export const isActive = (job: Pick<JobSummary, 'phase' | 'derivedPhase' | 'isActive'>) => job.isActive ?? activePhases.has(job.derivedPhase || job.phase);
export const phaseTone = (phase: string) => phase === 'completed' ? 'success' : ['failed', 'needs_input', 'interrupted', 'unknown'].includes(phase) ? 'warning' : activePhases.has(phase) ? 'accent' : 'neutral';
const phases: Record<string, string> = {
  queued: '等待开始', connecting: '连接 Codex', classifying: 'Luna 判断项目', creating_thread: '创建项目对话',
  starting_initial: '准备首轮', running_initial: '执行首轮', initial_finished: '首轮已结束',
  starting_followup: '执行预设跟进', running_followup: '执行预设跟进', followup_finished: '跟进已结束', completed: '流程已结束',
  failed: '执行失败', cancelled: '已取消', needs_input: '需要处理', interrupted: '后台已中断', unknown: '记录不可用',
};
export const phaseLabel = (phase: string) => phases[phase] || phase;
export function duration(seconds?: number | null) {
  if (seconds == null || !Number.isFinite(seconds)) return '—';
  if (seconds < 60) return `${seconds < 10 ? seconds.toFixed(1) : Math.round(seconds)} 秒`;
  const min = Math.floor(seconds / 60); const sec = Math.floor(seconds % 60);
  return min >= 60 ? `${Math.floor(min / 60)} 小时 ${min % 60} 分` : `${min} 分 ${sec} 秒`;
}
export function dateTime(value?: string, compact = false) {
  if (!value || !Number.isFinite(Date.parse(value))) return '—';
  return new Intl.DateTimeFormat('zh-CN', compact ? { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' } : { month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hour12: false }).format(new Date(value));
}
export function stageLabel(stage?: string) { return ({ classification: '项目判断', initial: '首轮任务', followup: '预设跟进' } as Record<string, string>)[stage || ''] || stage || '调度'; }
export function eventLabel(event: JobEvent) {
  if (event.method === 'turn/started') return '开始对话';
  if (event.method === 'turn/completed') return event.status === 'completed' ? '对话结束' : `对话${event.status === 'failed' ? '失败' : '中断'}`;
  if (event.method === 'error') return '执行错误';
  if (event.method === 'thread/status/changed') return '对话状态更新';
  if (event.phase && !event.itemType) return phaseLabel(event.phase);
  if (event.itemType === 'commandExecution') return event.method === 'item/started' ? '开始执行命令' : event.status === 'failed' ? '命令失败' : '命令结束';
  if (event.itemType === 'mcpToolCall') return event.method === 'item/started' ? '开始调用工具' : event.status === 'failed' ? '工具调用失败' : '工具调用结束';
  return ({ agentMessage: event.phase === 'final_answer' ? '结果' : '进展', commandExecution: '执行命令', mcpToolCall: '调用工具', fileChange: '修改文件', reasoning: '分析', subAgentActivity: '子任务', userMessage: '任务已发送', collabAgentToolCall: '协作工具' } as Record<string, string>)[event.itemType || ''] || event.itemType || event.method || '事件';
}
export function routeConfidence(confidence?: number) { return confidence == null ? '—' : `${Math.round(confidence * 100)}%`; }
export function followupPresentation(detail: JobDetail) {
  const { followupDecision: decision, followupTurn: turn, followupAttempts: attempts = 0 } = detail.state;
  if (decision?.send === false) return { label: '已跳过', tone: 'neutral' as const };
  if (turn?.status === 'completed') return { label: '跟进已完成', tone: 'success' as const };
  if (turn?.status === 'failed') return { label: '跟进失败', tone: 'warning' as const };
  if (turn?.status === 'interrupted') return { label: '跟进已中断', tone: 'warning' as const };
  if (attempts > 0) return { label: isActive(detail.summary) ? '正在跟进' : '已尝试发送', tone: 'accent' as const };
  if (decision?.send) return { label: isActive(detail.summary) ? '等待发送' : '尚未发送', tone: 'neutral' as const };
  return { label: detail.request.followup?.trim() ? '尚未执行' : '未启用', tone: 'neutral' as const };
}
export function timeline(detail: JobDetail) {
  const skipped = detail.state.followupDecision?.send === false;
  const stages = [
    { key: 'classification', label: '判断项目', seconds: detail.state.classificationSeconds, finished: !!detail.route && Object.keys(detail.route).length > 0, failed: false, interrupted: false, note: detail.state.classifierModel || 'Luna' },
    { key: 'initial', label: '首轮任务', seconds: detail.state.initialTurn?.elapsedSeconds, finished: detail.state.initialTurn?.status === 'completed', failed: detail.state.initialTurn?.status === 'failed', interrupted: detail.state.initialTurn?.status === 'interrupted', note: detail.state.actualModel || '默认模型' },
    { key: 'followup', label: '预设跟进', seconds: detail.state.followupTurn?.elapsedSeconds, finished: detail.state.followupTurn?.status === 'completed', failed: detail.state.followupTurn?.status === 'failed', interrupted: detail.state.followupTurn?.status === 'interrupted', note: skipped ? '依据见跟进判断' : detail.request.followup?.trim() ? '最多发送一次' : '未启用' },
  ];
  const phase = detail.summary.derivedPhase || detail.summary.phase;
  const active = isActive(detail.summary);
  return stages.map(stage => ({ ...stage, skipped: stage.key === 'followup' && skipped, active: active && ((stage.key === 'classification' && ['queued', 'connecting', 'classifying'].includes(phase)) || (stage.key === 'initial' && ['creating_thread', 'starting_initial', 'running_initial'].includes(phase)) || (stage.key === 'followup' && !skipped && ['starting_followup', 'running_followup'].includes(phase))), disabled: stage.key === 'followup' && !detail.request.followup?.trim(), pendingLabel: stage.key === 'followup' && phase === 'initial_finished' && !detail.state.followupDecision ? '判断是否跟进' : active ? '等待开始' : '未执行' }));
}
