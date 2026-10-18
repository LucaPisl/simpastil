/**
 * Turns a thrown value into a few bounded, non-identifying facts about why it
 * failed, so a log line can say "database error 40001 at dist/x.js:88" instead
 * of an opaque "request failed".
 *
 * This is an allowlist, not a scrubber. Messages, full stacks, SQL, driver
 * detail and request data are never read into the result: every field is
 * rebuilt from a closed set or checked against a strict pattern, and a value
 * that fails its pattern is dropped. Callers still pass the result through
 * the logger's own field validation.
 */

export const CAUSE_KINDS = [
  'postgres', 'network', 'smtp', 'config', 'validation', 'timeout', 'bug', 'unknown',
] as const;
export type CauseKind = (typeof CAUSE_KINDS)[number];

export const CONFIG_PROBLEMS = ['required', 'blank', 'invalid', 'unreadable'] as const;
export type ConfigProblem = (typeof CONFIG_PROBLEMS)[number];

export interface SafeCause {
  causeKind?: CauseKind;
  /** SQLSTATE (23505), SMTP reply (550) or a symbolic system code (ECONNREFUSED). */
  causeCode?: string;
  errorClass?: string;
  /** First in-app stack frame as `dist/…js:line`. */
  where?: string;
  configVariable?: string;
  configProblem?: ConfigProblem;
  /** Field path of the first validation issue, e.g. `items[].amount`. */
  validationPath?: string;
}

export const CAUSE_FIELD_NAMES = [
  'causeKind', 'causeCode', 'errorClass', 'where', 'configVariable', 'configProblem', 'validationPath',
] as const satisfies readonly (keyof SafeCause)[];

const CAUSE_CODE_RE = /^(?:[0-9A-Z]{5}|[A-Z][A-Z0-9_]{1,40}|[2-5][0-9]{2})$/;
const SQLSTATE_RE = /^[0-9A-Z]{5}$/;
const ERROR_CLASS_RE = /^[A-Za-z][A-Za-z0-9_]{0,63}$/;
const WHERE_RE = /^(?:dist|src)\/(?!.*\.\.)[A-Za-z0-9_./-]{1,120}\.(?:js|ts):\d{1,6}$/;
const CONFIG_VARIABLE_RE = /^[A-Z][A-Z0-9_]{1,63}$/;
const SEGMENT = '[A-Za-z_][A-Za-z0-9_]*(?:\\[\\])?';
const VALIDATION_PATH_RE = new RegExp(`^${SEGMENT}(?:\\.${SEGMENT})*$`);
const MAX_VALIDATION_PATH_LENGTH = 100;
const MAX_CHAIN_DEPTH = 4;

/** Checks one cause field against its rule; undefined means it must be dropped. */
export function sanitizeCauseField(name: string, value: unknown): string | undefined {
  if (typeof value !== 'string') return undefined;
  switch (name) {
    case 'causeKind': return (CAUSE_KINDS as readonly string[]).includes(value) ? value : undefined;
    case 'causeCode': return CAUSE_CODE_RE.test(value) ? value : undefined;
    case 'errorClass': return ERROR_CLASS_RE.test(value) ? value : undefined;
    case 'where': return value.length <= 140 && WHERE_RE.test(value) ? value : undefined;
    case 'configVariable': return CONFIG_VARIABLE_RE.test(value) ? value : undefined;
    case 'configProblem': return (CONFIG_PROBLEMS as readonly string[]).includes(value) ? value : undefined;
    case 'validationPath':
      return value.length <= MAX_VALIDATION_PATH_LENGTH && VALIDATION_PATH_RE.test(value) ? value : undefined;
    default: return undefined;
  }
}

/** Drops every unknown or invalid cause field. */
export function sanitizeCause(cause: Record<string, unknown> | undefined): SafeCause {
  const safe: Record<string, string> = {};
  if (!cause || typeof cause !== 'object') return {};
  for (const name of CAUSE_FIELD_NAMES) {
    const value = sanitizeCauseField(name, cause[name]);
    if (value !== undefined) safe[name] = value;
  }
  return safe as SafeCause;
}

const NETWORK_CODES = new Set([
  'ECONNREFUSED', 'ECONNRESET', 'ENOTFOUND', 'EAI_AGAIN', 'EHOSTUNREACH', 'ENETUNREACH', 'EPIPE',
  'CONNECTION_CLOSED', 'CONNECTION_ENDED', 'CONNECTION_DESTROYED',
]);
const TIMEOUT_CODES = new Set([
  'ETIMEDOUT', 'ESOCKETTIMEDOUT', 'CONNECT_TIMEOUT', 'ABORT_ERR', 'UND_ERR_CONNECT_TIMEOUT',
]);
const BUG_CLASSES = new Set(['TypeError', 'ReferenceError', 'RangeError', 'SyntaxError', 'AssertionError']);

type Level = Record<string, unknown>;

function asLevel(value: unknown): Level | undefined {
  return typeof value === 'object' && value !== null ? (value as Level) : undefined;
}

function nameOf(level: Level): string | undefined {
  const name = level['name'];
  if (typeof name === 'string' && ERROR_CLASS_RE.test(name)) return name;
  const constructorName = (level['constructor'] as { name?: unknown } | undefined)?.name;
  return typeof constructorName === 'string' && ERROR_CLASS_RE.test(constructorName)
    ? constructorName
    : undefined;
}

function codeOf(level: Level): string | undefined {
  const code = level['code'];
  return typeof code === 'string' && CAUSE_CODE_RE.test(code) ? code : undefined;
}

function chainOf(error: unknown): Level[] {
  const chain: Level[] = [];
  let current: unknown = error;
  while (chain.length < MAX_CHAIN_DEPTH) {
    const level = asLevel(current);
    if (!level || chain.includes(level)) break;
    chain.push(level);
    current = level['cause'];
  }
  return chain;
}

function describeConfig(level: Level): SafeCause {
  const message = typeof level['message'] === 'string' ? level['message'] : '';
  const variable = /^([A-Z][A-Z0-9_]{1,63})\b/.exec(message)?.[1];
  let problem: ConfigProblem = 'invalid';
  if (/\bis required\b|\bconfigured together\b/.test(message)) problem = 'required';
  else if (/\bmust not be blank\b/.test(message)) problem = 'blank';
  else if (/\bcould not be read\b/.test(message)) problem = 'unreadable';
  return { causeKind: 'config', configProblem: problem, ...(variable ? { configVariable: variable } : {}) };
}

function describeValidation(level: Level): SafeCause {
  const issues = level['issues'];
  const path = Array.isArray(issues) ? asLevel(issues[0])?.['path'] : undefined;
  if (!Array.isArray(path) || path.length === 0) return { causeKind: 'validation' };
  let text = '';
  for (const segment of path) {
    if (typeof segment === 'number') {
      if (text === '') return { causeKind: 'validation' };
      text += '[]';
    } else if (typeof segment === 'string') {
      text += text === '' ? segment : `.${segment}`;
    } else {
      return { causeKind: 'validation' };
    }
  }
  const validationPath = sanitizeCauseField('validationPath', text);
  return { causeKind: 'validation', ...(validationPath ? { validationPath } : {}) };
}

function describeSmtp(level: Level): SafeCause {
  const reply = level['responseCode'];
  const causeCode = typeof reply === 'number' && Number.isInteger(reply) && reply >= 200 && reply <= 599
    ? String(reply)
    : codeOf(level);
  return { causeKind: 'smtp', ...(causeCode ? { causeCode } : {}) };
}

/** The kind this one level names on its own, or undefined when it names none. */
function specificKind(level: Level): SafeCause | undefined {
  const name = nameOf(level);
  const code = codeOf(level);
  if (name === 'ZodError' && Array.isArray(level['issues'])) return describeValidation(level);
  if (name === 'ConfigError' || name === 'WorkerConfigError') return describeConfig(level);
  if (name === 'SmtpDeliveryError' || typeof level['responseCode'] === 'number'
      || (typeof level['command'] === 'string' && typeof level['code'] === 'string')) {
    return describeSmtp(level);
  }
  if (code !== undefined && SQLSTATE_RE.test(code)
      && (name === 'PostgresError' || typeof level['severity'] === 'string')) {
    return { causeKind: 'postgres', causeCode: code };
  }
  if (name === 'TimeoutError' || name === 'AbortError' || (code !== undefined && TIMEOUT_CODES.has(code))) {
    return { causeKind: 'timeout', ...(code ? { causeCode: code } : {}) };
  }
  if (code !== undefined && NETWORK_CODES.has(code)) return { causeKind: 'network', causeCode: code };
  return undefined;
}

/** `dist/x.js:12` from the first frame inside this app, ignoring dependencies. */
function appFrame(level: Level): string | undefined {
  const stack = level['stack'];
  const message = level['message'];
  if (typeof stack !== 'string' || typeof message !== 'string') return undefined;
  // Everything up to the end of the message is attacker-influenced text and may
  // contain forged "    at …" lines. Only the part after it is real frames,
  // so a stack that does not contain its own message gives no location.
  const messageAt = stack.indexOf(message);
  if (messageAt < 0) return undefined;
  for (const line of stack.slice(messageAt + message.length).split('\n')) {
    const frame = /^\s+at (?:.*?\()?(?:file:\/\/)?([^()\s]+?):(\d{1,6}):\d{1,6}\)?$/.exec(line);
    if (!frame) continue;
    const path = frame[1] ?? '';
    if (path.includes('node_modules') || path.startsWith('node:')) continue;
    const start = Math.max(path.lastIndexOf('/dist/'), path.lastIndexOf('/src/'));
    if (start < 0) continue;
    return sanitizeCauseField('where', `${path.slice(start + 1)}:${frame[2]}`);
  }
  return undefined;
}

/**
 * Describes why `error` failed using only closed or pattern-checked values.
 * Looks through `.cause` wrappers (the database layer wraps driver errors) and
 * prefers the most specific kind found anywhere in the chain.
 */
export function describeFailure(error: unknown): SafeCause {
  const chain = chainOf(error);
  const top = chain[0];
  if (!top) return { causeKind: 'unknown' };

  let kind: SafeCause = {};
  let kindLevel: Level = top;
  for (const level of chain) {
    const specific = specificKind(level);
    if (specific) {
      kind = specific;
      kindLevel = level;
      break;
    }
  }
  if (kind.causeKind === undefined) {
    const topName = nameOf(top);
    const topCode = codeOf(top);
    kind = {
      causeKind: topName !== undefined && BUG_CLASSES.has(topName) ? 'bug' : 'unknown',
      ...(topCode ? { causeCode: topCode } : {}),
    };
  }

  const errorClass = nameOf(kindLevel);
  let where: string | undefined;
  for (const level of chain) {
    where = appFrame(level);
    if (where) break;
  }
  return sanitizeCause({ ...kind, ...(errorClass ? { errorClass } : {}), ...(where ? { where } : {}) });
}

const CONFIG_PROBLEM_TEXT: Record<ConfigProblem, string> = {
  required: 'is required but missing',
  blank: 'must not be blank',
  invalid: 'has an invalid value',
  unreadable: 'could not be read',
};

/**
 * A short English clause for a cause, built only from its validated fields,
 * such as `database error 40001 at dist/modules/pills/pills.service.js:88`.
 */
export function describeCauseText(cause: SafeCause): string | undefined {
  const code = cause.causeCode ? ` ${cause.causeCode}` : '';
  let text: string | undefined;
  switch (cause.causeKind) {
    case 'postgres': text = `database error${code}`; break;
    case 'network': text = `network error${code}`; break;
    case 'smtp': text = `mail server error${code}`; break;
    case 'timeout': text = `timed out${cause.causeCode ? ` (${cause.causeCode})` : ''}`; break;
    case 'config':
      text = `configuration problem: ${cause.configVariable ?? 'a setting'} `
        + CONFIG_PROBLEM_TEXT[cause.configProblem ?? 'invalid'];
      break;
    case 'validation':
      text = cause.validationPath ? `invalid field ${cause.validationPath}` : 'invalid request data';
      break;
    case 'bug': text = `unexpected ${cause.errorClass ?? 'error'}${code}`; break;
    case 'unknown':
      // A named code means the failure was recognised by its sender; without one it is a surprise.
      text = cause.causeCode
        ? `${cause.errorClass ?? 'error'}${code}`
        : `unexpected ${cause.errorClass ?? 'error'}`;
      break;
    default: return cause.causeCode ? `error code ${cause.causeCode}` : undefined;
  }
  return cause.where ? `${text} at ${cause.where}` : text;
}
