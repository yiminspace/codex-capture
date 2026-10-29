import { describe, expect, it } from 'vitest';
import { RequestGate } from './api';
import { duration, eventLabel, followupPresentation, isActive, phaseLabel, timeline } from './format';
import type { JobDetail } from './types';

describe('workflow presentation', () => {
  it('does not equate flow completion with completion of the user requirement', () => {
    expect(phaseLabel('completed')).toBe('流程已结束');
    expect(isActive({ phase: 'running_initial', derivedPhase: 'interrupted' })).toBe(false);
    expect(isActive({ phase: 'starting_followup' })).toBe(true);
    expect(isActive({ phase: 'needs_input' })).toBe(false);
    expect(isActive({ phase: 'unknown' })).toBe(false);
    expect(isActive({ phase: 'running_initial', isActive: false })).toBe(false);
  });
  it('distinguishes failed tools from completed turns', () => {
    expect(eventLabel({ method: 'turn/completed', status: 'failed' })).toBe('对话失败');
    expect(eventLabel({ method: 'item/completed', itemType: 'commandExecution', status: 'failed' })).toBe('命令失败');
  });
  it('never paints a failed or interrupted turn as a successful stage', () => {
    const detail = { summary: { phase: 'failed' }, state: { initialTurn: { status: 'failed' } }, route: { reason: 'match' }, request: { followup: 'review' } } as JobDetail;
    const stages = timeline(detail);
    expect(stages[1].finished).toBe(false); expect(stages[1].failed).toBe(true);
    expect(stages[2].pendingLabel).toBe('未执行');
    detail.state.initialTurn!.status = 'interrupted';
    expect(timeline(detail)[1].interrupted).toBe(true);
  });
  it('keeps duration formatting bounded and handles missing timing', () => {
    expect(duration()).toBe('—'); expect(duration(NaN)).toBe('—');
    expect(duration(9.554)).toBe('9.6 秒'); expect(duration(94)).toBe('1 分 34 秒');
    expect(duration(3661)).toBe('1 小时 1 分');
  });
  it('does not mark an empty classification record as complete', () => {
    const detail = { summary: { phase: 'classifying', isActive: true }, state: {}, route: {}, request: {} } as JobDetail;
    expect(timeline(detail)[0].finished).toBe(false);
    expect(timeline(detail)[0].active).toBe(true);
  });
  it('disables the follow-up stage when no preset was supplied', () => {
    const detail = { summary: { phase: 'completed' }, state: { initialTurn: { status: 'completed' } }, route: { reason: 'matched domain' }, request: { followup: '' } } as JobDetail;
    const stages = timeline(detail);
    expect(stages[0].finished).toBe(true); expect(stages[1].finished).toBe(true);
    expect(stages[2].disabled).toBe(true); expect(stages.some(stage => stage.active)).toBe(false);
  });
  it('shows a no-change decision as skipped, including the transition before completion', () => {
    const detail = { summary: { phase: 'initial_finished', isActive: true }, state: { initialTurn: { status: 'completed' }, followupDecision: { send: false, reason: '未检测到本轮代码改动。' } }, route: {}, request: { followup: '请复查示例便签标签修改。' } } as JobDetail;
    expect(timeline(detail)[2]).toMatchObject({ skipped: true, active: false, finished: false });
    expect(followupPresentation(detail)).toEqual({ label: '已跳过', tone: 'neutral' });
    detail.summary = { ...detail.summary, phase: 'completed', isActive: false };
    expect(timeline(detail)[2].skipped).toBe(true);
  });
  it('distinguishes deciding, sending, completed and ambiguous attempts', () => {
    const detail = { summary: { phase: 'initial_finished', isActive: true }, state: { initialTurn: { status: 'completed' } }, route: {}, request: { followup: '请复查示例便签标签修改。' } } as JobDetail;
    expect(timeline(detail)[2]).toMatchObject({ active: false, pendingLabel: '判断是否跟进' });
    detail.state.followupDecision = { send: true, reason: '检测到本轮修改 src/app.ts。' };
    expect(followupPresentation(detail).label).toBe('等待发送');
    detail.state.followupAttempts = 1;
    detail.summary.phase = 'starting_followup';
    expect(timeline(detail)[2]).toMatchObject({ active: true, skipped: false });
    expect(followupPresentation(detail).label).toBe('正在跟进');
    detail.summary = { ...detail.summary, phase: 'failed', isActive: false };
    expect(followupPresentation(detail).label).toBe('已尝试发送');
    detail.state.followupTurn = { status: 'completed' };
    detail.summary.phase = 'completed';
    expect(followupPresentation(detail).label).toBe('跟进已完成');
    expect(timeline(detail)[2]).toMatchObject({ finished: true, skipped: false });
  });
  it('keeps legacy completed follow-ups without a decision record', () => {
    const detail = { summary: { phase: 'completed' }, state: { followupAttempts: 1, followupTurn: { status: 'completed' } }, route: {}, request: { followup: 'review' } } as JobDetail;
    expect(timeline(detail)[2]).toMatchObject({ finished: true, skipped: false });
    expect(followupPresentation(detail).label).toBe('跟进已完成');
  });
});
describe('latest response protection', () => {
  it('rejects delayed responses after a new request or a selection change', () => {
    const gate = new RequestGate(); const old = gate.next(); const latest = gate.next();
    expect(gate.current(old)).toBe(false); expect(gate.current(latest)).toBe(true);
    gate.invalidate(); expect(gate.current(latest)).toBe(false);
  });
});
