export type StatusFilter = 'all' | 'active' | 'completed' | 'attention';
export interface JobSummary {
  jobId: string; text: string; title: string; phase: string; phaseLabel: string;
  projectName?: string; createdAt?: string; updatedAt?: string; elapsedSeconds?: number;
  threadId?: string; hasImage?: boolean; error?: string; warningCount?: number;
  derivedPhase?: string; workerAlive?: boolean;
  isActive?: boolean; cancelRequested?: boolean;
}
export interface JobList {
  jobs: JobSummary[]; total: number; counts: Record<string, number>;
  projects: Array<string | { name?: string; projectName?: string; count?: number }>;
}
export interface TurnResult { id?: string; status?: string; finalText?: string; elapsedSeconds?: number; completedAt?: string }
export interface FollowupDecision { send: boolean; reason: string; [key: string]: unknown }
export interface JobState {
  phase: string; derivedPhase?: string; error?: string; createdAt?: string; completedAt?: string;
  updatedAt?: string; startedAt?: string; workerPid?: number; appServerPid?: number;
  classifierModel?: string; actualModel?: string; classificationSeconds?: number;
  followupAttempts?: number; threadId?: string; cwd?: string;
  initialTurn?: TurnResult; followupTurn?: TurnResult;
  followupDecision?: FollowupDecision;
  [key: string]: unknown;
}
export interface JobEvent {
  at?: string; stage?: string; method?: string; phase?: string; text?: string;
  itemType?: string; status?: string; command?: string; tool?: string; server?: string;
  error?: unknown; exitCode?: number; [key: string]: unknown;
}
export interface JobDetail {
  jobId: string; summary: JobSummary; state: JobState;
  request: { text?: string; followup?: string; context?: unknown; [key: string]: unknown };
  route: { title?: string; reason?: string; confidence?: number; [key: string]: unknown } | null;
  events: JobEvent[]; lifecycle: JobEvent[]; logs: Record<string, unknown>;
  eventsTotal: number; warnings: Array<string | Record<string, unknown>>;
}
export interface SystemInfo {
  helper?: Record<string, unknown>; hotkey?: Record<string, unknown>;
  installation?: Record<string, unknown>; [key: string]: unknown;
}
