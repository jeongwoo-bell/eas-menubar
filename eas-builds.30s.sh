#!/bin/bash
# <xbar.title>EAS Builds</xbar.title>
# <xbar.version>v2.0.0</xbar.version>
# <xbar.desc>Expo EAS 빌드 진행 상황을 메뉴바에서 바로 확인</xbar.desc>
# <xbar.dependencies>node,eas-cli</xbar.dependencies>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>
#
# 설정은 메뉴의 "설정"에서 바꾸거나 ~/.config/eas-builds/config.json 을 직접 편집하세요.
# 파일 이름의 ".30s." 는 SwiftBar 갱신 주기라서 바꾸지 마세요.

# SwiftBar는 로그인 셸 PATH를 물려받지 않아서 흔한 설치 위치를 직접 추가
for d in "$HOME"/.nvm/versions/node/*/bin "$HOME/.local/share/fnm/aliases/default/bin"; do
  [ -d "$d" ] && PATH="$d:$PATH"
done
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.volta/bin:$HOME/.bun/bin:$HOME/.npm-global/bin:$PATH"

export EAS_BUILDS_SCRIPT="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
PLUGIN_NAME="$(basename "$0")"; PLUGIN_NAME="${PLUGIN_NAME%%.*}"

if ! command -v node >/dev/null 2>&1; then
  echo " | sfimage=exclamationmark.triangle"
  echo "---"
  echo "Node.js를 찾을 수 없어요 | color=gray"
  echo "Node.js 설치하기 | href=https://nodejs.org sfimage=arrow.down.circle"
  exit 0
fi

# 터미널 명령 (eas-builds setup 등) → 내부 옵션으로 변환
case "$1" in
  setup|init)    shift; set -- --setup "$@" ;;
  add)           set -- --add-project "${2:-$PWD}" ;;
  list|ls)       set -- --list-projects ;;
  refresh)       set -- --fetch ;;
  login)         set -- --login ;;
  uninstall)     set -- --uninstall ;;
  version|-v|--version) set -- --version ;;
  help|-h|--help)
    cat <<'HELP'
eas-builds — 메뉴바에서 EAS 빌드 상태 보기

  eas-builds setup       로그인 확인 + 볼 앱 고르기 (처음 한 번)
  eas-builds add [폴더]  프로젝트 추가 (기본: 현재 폴더)
  eas-builds list        추적 중인 프로젝트 목록
  eas-builds refresh     지금 새로고침
  eas-builds login       EAS 로그인
  eas-builds uninstall   삭제
HELP
    exit 0 ;;
esac

# eas login은 키보드 입력이 필요해서 node(stdin 사용 중) 밖에서 실행
if [ "$1" = "--login" ]; then
  if command -v eas >/dev/null 2>&1; then eas login; else npx --yes eas-cli login; fi
  open -g "swiftbar://refreshplugin?name=$PLUGIN_NAME" 2>/dev/null
  exit 0
fi

exec node - "$@" <<'JS'
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const tty = require('tty');
const readline = require('readline');
const { spawn, spawnSync, execFile, execFileSync } = require('child_process');

// ───────────────────────── 상수 ─────────────────────────
const VERSION = '2.0.0';
const SCRIPT = process.env.EAS_BUILDS_SCRIPT;
const PLUGIN = path.basename(SCRIPT).split('.')[0];
const HOME = os.homedir();

const CONFIG_DIR = path.join(HOME, '.config', 'eas-builds');
const CONFIG = path.join(CONFIG_DIR, 'config.json');
const CACHE_DIR = process.env.SWIFTBAR_PLUGIN_CACHE_PATH || path.join(HOME, 'Library', 'Caches', 'eas-builds');
const CACHE = path.join(CACHE_DIR, 'builds.json');
const LOCK = path.join(CACHE_DIR, 'fetch.lock');
const CACHE_VERSION = 2;

const DEFAULTS = { projects: [], recent: 3, notify: true };
const POLL_ACTIVE_MS = 15e3;   // 빌드 중일 때 갱신 간격
const POLL_IDLE_MS = 60e3;     // 한가할 때 갱신 간격
const POLL_OPEN_MS = 8e3;      // 메뉴를 열었을 때 이보다 오래된 캐시면 갱신
const LOCK_TTL_MS = 90e3;
const LIST_LIMIT = 15;

const ACTIVE = new Set(['NEW', 'IN_QUEUE', 'IN_PROGRESS', 'PENDING_CANCEL']);
const COLOR = { orange: '#F08C00', green: '#2DA44E', red: '#E5534B', gray: '#8B949E' };
const STATUS = {
  NEW:            { sf: 'clock',              color: COLOR.gray },
  IN_QUEUE:       { sf: 'clock',              color: COLOR.gray },
  IN_PROGRESS:    { sf: 'hammer.fill',        color: COLOR.orange },
  PENDING_CANCEL: { sf: 'stop.circle',        color: COLOR.gray },
  FINISHED:       { sf: 'checkmark.circle.fill', color: COLOR.green },
  ERRORED:        { sf: 'xmark.circle.fill',  color: COLOR.red },
  CANCELED:       { sf: 'stop.circle',        color: COLOR.gray },
};

// ───────────────────────── 유틸 ─────────────────────────
const now = () => Date.now();
const ts = (t) => (t ? new Date(t).getTime() : 0);
const clean = (s) => String(s ?? '').replace(/\|/g, '¦').replace(/\s+/g, ' ').trim();
const firstLine = (s) => String(s ?? '').split('\n')[0];
const cut = (s, n) => (s.length > n ? s.slice(0, n - 1) + '…' : s);
const q = (s) => `"${String(s).replace(/"/g, '\\"')}"`;

function dur(ms) {
  const m = Math.max(0, Math.floor(ms / 60000));
  if (m < 1) return '1분 미만';
  if (m < 60) return `${m}분`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}시간${m % 60 ? ` ${m % 60}분` : ''}`;
  return `${Math.floor(h / 24)}일`;
}
function ago(t) {
  const s = Math.floor((now() - ts(t)) / 1000);
  if (s < 10) return '방금';
  if (s < 60) return `${s}초 전`;
  return `${dur(s * 1000)} 전`;
}
const hhmm = (t) => new Date(t).toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', hour12: false });

function readJSON(file) { try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; } }
function writeJSON(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file + '.tmp', JSON.stringify(data, null, 2) + '\n');
  fs.renameSync(file + '.tmp', file);
}
const loadConfig = () => ({ ...DEFAULTS, ...(readJSON(CONFIG) || {}) });
const saveConfig = (c) => writeJSON(CONFIG, c);
function readCache() {
  const c = readJSON(CACHE);
  return c && c.v === CACHE_VERSION ? c : null;
}

const lockFresh = () => { try { return now() - fs.statSync(LOCK).mtimeMs < LOCK_TTL_MS; } catch { return false; } };
function acquireLock() {
  fs.mkdirSync(CACHE_DIR, { recursive: true });
  try { fs.writeFileSync(LOCK, String(process.pid), { flag: 'wx' }); return true; }
  catch { if (lockFresh()) return false; fs.writeFileSync(LOCK, String(process.pid)); return true; }
}
const releaseLock = () => { try { fs.unlinkSync(LOCK); } catch {} };

const quiet = (cmd, args) => execFile(cmd, args, () => {});
const refreshBar = () => quiet('open', ['-g', `swiftbar://refreshplugin?name=${PLUGIN}`]);
function notify(title, body, href) {
  const p = { name: PLUGIN, title, body, ...(href ? { href } : {}) };
  const qs = Object.entries(p).map(([k, v]) => `${k}=${encodeURIComponent(v)}`).join('&');
  quiet('open', ['-g', `swiftbar://notify?${qs}`]);
}
function osa(lines) { return execFileSync('osascript', lines.flatMap((l) => ['-e', l]), { encoding: 'utf8' }).trim(); }
function alertBox(msg) { try { osa([`display alert "EAS Builds" message ${q(msg)} as warning`]); } catch {} }

function which(cmd) {
  try { return execFileSync('/bin/sh', ['-c', `command -v ${cmd}`], { encoding: 'utf8' }).trim() || null; }
  catch { return null; }
}

// ───────────────────────── 빌드 데이터 ─────────────────────────
const platLabel = (b) => (b.platform === 'IOS' ? 'iOS' : 'Android');
const profLabel = (b) => (b.channel && b.channel !== b.profile ? `${b.profile} → ${b.channel}` : b.profile || '-');
const projName = (p, builds) => builds.find((b) => b._project === p)?.appName || path.basename(p);
const buildPage = (b) => (b.owner && b.slug ? `https://expo.dev/accounts/${b.owner}/projects/${b.slug}/builds/${b.id}` : 'https://expo.dev');
const buildsPage = (b) => (b.owner && b.slug ? `https://expo.dev/accounts/${b.owner}/projects/${b.slug}/builds` : 'https://expo.dev');

// 캐시에는 필요한 필드만 저장
function slim(b, project) {
  return {
    id: b.id, status: b.status, platform: b.platform,
    profile: b.buildProfile, channel: b.updateChannel?.name,
    commit: b.gitCommitHash, commitMsg: b.gitCommitMessage,
    appVersion: b.appVersion, buildNumber: b.appBuildVersion, runtime: b.runtime?.version,
    actor: b.initiatingActor?.displayName,
    createdAt: b.createdAt, completedAt: b.completedAt, updatedAt: b.updatedAt,
    queuePosition: b.queuePosition, waitSec: b.estimatedWaitTimeLeftSeconds,
    error: b.error?.message, artifact: b.artifacts?.buildUrl,
    owner: b.app?.ownerAccount?.name, slug: b.app?.slug, appName: b.app?.name,
    _project: project,
  };
}

function easCommand() {
  const eas = which('eas');
  if (eas) return [eas, []];
  const npx = which('npx');
  if (npx) return [npx, ['--yes', 'eas-cli']];
  return null;
}

function runEas(args, cwd, timeout = 60e3) {
  return new Promise((resolve) => {
    const cmd = easCommand();
    if (!cmd) return resolve({ missing: true });
    execFile(cmd[0], [...cmd[1], ...args], { cwd, timeout, maxBuffer: 50 * 1024 * 1024 },
      (err, stdout, stderr) => resolve({ err, stdout: stdout || '', stderr: stderr || '' }));
  });
}

function classifyError(text) {
  const t = text.toLowerCase();
  const last = clean(text.trim().split('\n').filter(Boolean).pop() || '알 수 없는 오류');
  if (/not logged in|log in|login|unauthori[sz]ed|authentication/.test(t)) return { code: 'AUTH', msg: 'EAS 로그인이 필요해요' };
  if (/enotfound|etimedout|econnreset|econnrefused|network|fetch failed|socket/.test(t)) return { code: 'NET', msg: '네트워크에 연결할 수 없어요' };
  if (/timed out|sigterm/.test(t)) return { code: 'NET', msg: '응답이 너무 늦어요' };
  if (/eas\.json|app\.json|app\.config|projectid|project id|not.*expo project/.test(t)) return { code: 'PROJECT', msg: 'Expo 프로젝트 설정을 읽지 못했어요' };
  return { code: 'OTHER', msg: cut(last, 70) };
}

async function fetchProject(p) {
  if (!fs.existsSync(p)) return { error: { code: 'MISSING', msg: '폴더가 없어요' } };
  const r = await runEas(['build:list', '--limit', String(LIST_LIMIT), '--json', '--non-interactive'], p);
  if (r.missing) return { error: { code: 'NO_EAS', msg: 'eas-cli를 찾을 수 없어요' } };
  if (r.err) return { error: classifyError(`${r.stderr}\n${r.err.message}`) };
  try {
    const i = r.stdout.indexOf('[');
    const list = JSON.parse(r.stdout.slice(i));
    if (!Array.isArray(list)) throw new Error();
    return { builds: list.map((b) => slim(b, p)) };
  } catch {
    return { error: classifyError(r.stderr || 'EAS 응답을 해석하지 못했어요') };
  }
}

async function fetchAll() {
  if (!acquireLock()) return false;
  try {
    const cfg = loadConfig();
    const prev = readCache();
    const results = await Promise.all(cfg.projects.map(fetchProject));
    const next = { v: CACHE_VERSION, checkedAt: now(), okAt: prev?.okAt || 0, builds: [], errors: {} };
    results.forEach((r, i) => {
      const p = cfg.projects[i];
      if (r.error) {
        next.errors[p] = r.error;
        next.builds.push(...(prev?.builds || []).filter((b) => b._project === p)); // 실패하면 이전 값 유지
      } else {
        next.builds.push(...r.builds);
      }
    });
    if (!cfg.projects.length || results.some((r) => !r.error)) next.okAt = now();
    writeJSON(CACHE, next);
    if (cfg.notify && prev) notifyTransitions(prev, next);
    return true;
  } finally {
    releaseLock();
  }
}

function notifyTransitions(prev, next) {
  const before = new Map(prev.builds.map((b) => [b.id, b.status]));
  for (const b of next.builds) {
    const was = before.get(b.id);
    if (!was || !ACTIVE.has(was) || ACTIVE.has(b.status)) continue;
    const title = `${b.appName || path.basename(b._project)} · ${platLabel(b)} ${profLabel(b)}`;
    const took = b.completedAt ? ` (${dur(ts(b.completedAt) - ts(b.createdAt))})` : '';
    const body = b.status === 'FINISHED' ? `빌드 완료${took}`
      : b.status === 'ERRORED' ? `빌드 실패${b.error ? `: ${cut(clean(b.error), 80)}` : ''}`
      : '빌드 취소됨';
    notify(title, body, buildPage(b));
  }
}

function kickFetch() {
  if (lockFresh()) return;
  spawn('/bin/bash', [SCRIPT, '--fetch'], { detached: true, stdio: 'ignore' }).unref();
}

// ───────────────────────── 그리기 ─────────────────────────
function render() {
  const cfg = loadConfig();
  const cache = readCache();
  const out = [];
  const L = (s) => out.push(s);
  const act = (args, extra = '') => `bash=${q(SCRIPT)} ${args.map((a, i) => `param${i + 1}=${q(a)}`).join(' ')} terminal=false${extra ? ' ' + extra : ''}`;

  const builds = (cache?.builds || [])
    .filter((b) => cfg.projects.includes(b._project))
    .sort((a, b) => ts(b.createdAt) - ts(a.createdAt));
  const active = builds.filter((b) => ACTIVE.has(b.status));
  const errors = Object.entries(cache?.errors || {}).filter(([p]) => cfg.projects.includes(p));

  // SWR: 캐시를 바로 그리고, 오래됐으면 뒤에서 갱신
  const opened = /open/i.test(process.env.SWIFTBAR_PLUGIN_REFRESH_REASON || '');
  const staleAfter = opened ? POLL_OPEN_MS : active.length ? POLL_ACTIVE_MS : POLL_IDLE_MS;
  if (cfg.projects.length && (!cache || now() - cache.checkedAt > staleAfter)) kickFetch();

  // ── 메뉴바 ──
  const blocking = errors.find(([, e]) => e.code === 'AUTH' || e.code === 'NO_EAS');
  const lastDone = builds.filter((b) => !ACTIVE.has(b.status) && b.completedAt)
    .sort((a, b) => ts(b.completedAt) - ts(a.completedAt))[0];
  const since = lastDone ? now() - ts(lastDone.completedAt) : Infinity;

  if (!cfg.projects.length || (!cache && !blocking)) L(' | sfimage=hammer');
  else if (active.length === 1) {
    const b = active[0];
    // 메뉴바 폭을 줄이려고 경과 시간만 (플랫폼은 드롭다운에 있음)
    L(`${b.status === 'IN_PROGRESS' ? dur(now() - ts(b.createdAt)) : '대기'} | sfimage=hammer.fill`);
  } else if (active.length > 1) L(`${active.length} | sfimage=hammer.fill`);
  else if (blocking) L(' | sfimage=exclamationmark.triangle');
  else if (lastDone?.status === 'ERRORED' && since < 60 * 60e3) L(` | sfimage=xmark.circle.fill sfcolor=${COLOR.red}`);
  else if (lastDone?.status === 'FINISHED' && since < 10 * 60e3) L(` | sfimage=checkmark.circle.fill sfcolor=${COLOR.green}`);
  else L(' | sfimage=hammer');
  L('---');

  // ── 본문 ──
  if (!cfg.projects.length) {
    L('빌드를 볼 Expo 프로젝트를 추가해 주세요 | color=gray');
    L(`프로젝트 추가… | sfimage=plus.circle ${act(['--add-project'])}`);
  } else if (!cache) {
    L('빌드 정보를 불러오는 중… | sfimage=arrow.triangle.2.circlepath color=gray');
  } else {
    const multi = cfg.projects.length > 1;
    cfg.projects.forEach((p, pi) => {
      const bs = builds.filter((b) => b._project === p);
      const running = bs.filter((b) => ACTIVE.has(b.status));
      const done = bs.filter((b) => !ACTIVE.has(b.status)).slice(0, cfg.recent);
      const err = cache.errors?.[p];
      if (multi) L(`${clean(projName(p, builds))} | size=13 sfimage=folder href=${bs[0] ? buildsPage(bs[0]) : 'https://expo.dev'}`);

      // 모든 줄의 프로필이 같으면 줄마다 반복하지 않고 섹션 제목으로 올림
      const profs = [...new Set([...running, ...done].map(profLabel))];
      const showProf = profs.length > 1;
      const tag = !showProf && profs[0] ? ` · ${profs[0]}` : '';

      if (!running.length && !done.length && !err) L('아직 빌드가 없어요 | color=gray size=12');
      if (running.length) {
        L(`빌드 중${tag} | size=11 color=gray`);
        running.forEach((b) => drawBuild(b, pi, showProf, L, act));
      }
      if (done.length) {
        L(`최근${running.length ? '' : tag} | size=11 color=gray`);
        done.forEach((b) => drawBuild(b, pi, showProf, L, act));
      }
      if (err) drawError(err, L, act);
      if (multi && pi < cfg.projects.length - 1) L('---');
    });
  }

  // ── 하단 ──
  L('---');
  if (cache && cfg.projects.length) {
    const failing = errors.length && cache.okAt < cache.checkedAt;
    if (failing && cache.okAt) L(`갱신 실패 · ${ago(cache.okAt)} 받은 정보를 보여주는 중 | size=11 color=${COLOR.red}`);
    else L(`${ago(cache.okAt)} 갱신 | size=11 color=gray`);
  }
  L(`새로고침 | sfimage=arrow.clockwise ${act(['--fetch'])}`);
  const one = cfg.projects.length === 1 && builds[0];
  L(`${one ? 'expo.dev에서 빌드 목록 보기' : 'expo.dev 열기'} | sfimage=safari href=${one ? buildsPage(builds[0]) : 'https://expo.dev'}`);
  drawSettings(cfg, builds, L, act);

  process.stdout.write(out.join('\n') + '\n');
}

function drawBuild(b, pi, showProf, L, act) {
  const st = STATUS[b.status] || { sf: 'circle', color: COLOR.gray };
  const isActive = ACTIVE.has(b.status);
  const commit = (b.commit || '').slice(0, 7);
  const msg = b.commitMsg ? cut(clean(firstLine(b.commitMsg)), 26) : '';
  const parts = [platLabel(b), showProf && profLabel(b), [commit, msg].filter(Boolean).join(' ')]
    .filter(Boolean);
  if (!isActive) parts.push(ago(b.completedAt || b.updatedAt));
  else if (b.status === 'IN_PROGRESS') parts.push(`${dur(now() - ts(b.createdAt))} 경과`);
  const url = buildPage(b);
  L(`${clean(parts.join('  ·  '))} | sfimage=${st.sf} sfcolor=${st.color} href=${url} symbolize=false`);

  // 대기·취소 중인 빌드는 한 줄 더: 상태
  if (isActive && b.status !== 'IN_PROGRESS') {
    let line;
    if (b.status === 'PENDING_CANCEL') {
      line = '취소하는 중…';
    } else {
      const pos = b.queuePosition ? `대기열 ${b.queuePosition}번째` : '대기 중';
      line = b.waitSec ? `${pos} · 약 ${Math.max(1, Math.round(b.waitSec / 60))}분 후 시작` : pos;
    }
    L(`        ${line} | size=11 color=gray trim=false href=${url}`);
  }

  // 서브메뉴: 상세 정보 + 액션
  if (b.commitMsg) L(`--${cut(clean(firstLine(b.commitMsg)), 70)} | symbolize=false`);
  const ver = [commit, b.appVersion && `v${b.appVersion}${b.buildNumber ? ` (${b.buildNumber})` : ''}`, b.runtime && `runtime ${b.runtime}`]
    .filter(Boolean).join(' · ');
  if (ver) L(`--${clean(ver)} | color=gray size=12`);
  const meta = [b.actor, b.createdAt && `${hhmm(b.createdAt)} 시작`,
    b.completedAt && `${dur(ts(b.completedAt) - ts(b.createdAt))} 걸림`].filter(Boolean).join(' · ');
  if (meta) L(`--${clean(meta)} | color=gray size=12`);
  if (b.status === 'ERRORED' && b.error) L(`--${cut(clean(b.error), 90)} | color=${COLOR.red} sfimage=exclamationmark.triangle.fill sfcolor=${COLOR.red} symbolize=false`);
  L('-----');
  L(`--빌드 페이지 열기 | sfimage=safari href=${url}`);
  if (b.status === 'FINISHED' && b.artifact) L(`--앱 파일 다운로드 | sfimage=arrow.down.circle href=${b.artifact}`);
  if (commit) L(`--커밋 해시 복사 | sfimage=doc.on.doc ${act(['--copy', b.commit])}`);
  if (isActive && b.status !== 'PENDING_CANCEL') L(`--빌드 취소… | sfimage=xmark.circle ${act(['--cancel', b.id, String(pi)])}`);
}

function drawError(err, L, act) {
  L(`${err.msg} | sfimage=exclamationmark.triangle.fill sfcolor=${COLOR.red} size=12`);
  if (err.code === 'AUTH') L(`--터미널에서 eas login 실행 | sfimage=person.crop.circle bash=${q(SCRIPT)} param1=--login terminal=true`);
  if (err.code === 'NO_EAS') L('--eas-cli 설치 안내 | sfimage=arrow.down.circle href=https://docs.expo.dev/build/setup/');
  if (err.code === 'MISSING' || err.code === 'PROJECT') L(`--설정에서 프로젝트 경로를 확인해 주세요 | color=gray`);
  if (err.code !== 'AUTH' && err.code !== 'NO_EAS') L(`--다시 시도 | sfimage=arrow.clockwise ${act(['--fetch'])}`);
}

function drawSettings(cfg, builds, L, act) {
  L('설정 | sfimage=gearshape');
  L('--추적 중인 프로젝트 | size=11 color=gray');
  cfg.projects.forEach((p, i) => {
    L(`--${clean(projName(p, builds))} | sfimage=folder tooltip=${q(p)}`);
    L(`----${clean(p.replace(HOME, '~'))} | color=gray size=11`);
    L(`----Finder에서 보기 | sfimage=folder ${act(['--reveal', String(i)])}`);
    L(`----목록에서 빼기 | sfimage=minus.circle ${act(['--remove-project', String(i)])}`);
  });
  L(`--프로젝트 추가… | sfimage=plus.circle ${act(['--add-project'])}`);
  L('-----');
  L(`--빌드가 끝나면 알림 | ${act(['--toggle-notify'])} checked=${cfg.notify ? 'true' : 'false'}`);
  L('--끝난 빌드 표시 개수');
  for (const n of [1, 3, 5, 10]) L(`----${n}개 | ${act(['--recent', String(n)])} checked=${cfg.recent === n ? 'true' : 'false'}`);
  L('-----');
  L(`--설정 파일 열기 | sfimage=doc.text ${act(['--open-config'])}`);
  L(`--EAS Builds v${VERSION} | color=gray size=11`);
}

// ───────────────────────── 액션 ─────────────────────────
async function addProject(arg) {
  const fromCli = !!arg;
  let p = arg;
  if (!p) {
    try { p = osa(['POSIX path of (choose folder with prompt "EAS 빌드를 볼 Expo 프로젝트 폴더를 선택하세요")']); }
    catch { return; } // 사용자가 취소
  }
  p = path.resolve(p.replace(/^~(?=$|\/)/, HOME));
  if (!fs.existsSync(path.join(p, 'eas.json'))) {
    const msg = `${path.basename(p)} 폴더에 eas.json이 없어요. EAS를 쓰는 Expo 프로젝트 폴더를 골라주세요.`;
    if (fromCli) { console.error(msg); process.exitCode = 1; } else alertBox(msg);
    return;
  }
  const cfg = loadConfig();
  if (!cfg.projects.includes(p)) cfg.projects.push(p);
  saveConfig(cfg);
  if (fromCli) console.log(`추가됨: ${p}`);
  refreshBar();
  await fetchAll();
  refreshBar();
}

function updateConfig(fn) { const c = loadConfig(); fn(c); saveConfig(c); refreshBar(); }

async function cancelBuild(id, pi) {
  const p = loadConfig().projects[Number(pi)];
  if (!p) return;
  try {
    osa([`display dialog "진행 중인 빌드를 취소할까요?" with title "EAS Builds" buttons {"그대로 두기", "빌드 취소"} default button "그대로 두기" cancel button "그대로 두기" with icon caution`]);
  } catch { return; }
  const r = await runEas(['build:cancel', id, '--non-interactive'], p);
  if (r.missing || r.err) alertBox(`빌드를 취소하지 못했어요.\n${r.missing ? 'eas-cli를 찾을 수 없어요' : classifyError(r.stderr || r.err.message).msg}`);
  await fetchAll();
  refreshBar();
}

// ───────────────────────── 터미널 설정 마법사 ─────────────────────────
// node는 스크립트를 stdin으로 받기 때문에, 키보드 입력은 /dev/tty를 직접 열어서 읽음
const ansi = {
  bold: (s) => `\x1b[1m${s}\x1b[22m`, dim: (s) => `\x1b[2m${s}\x1b[22m`,
  green: (s) => `\x1b[32m${s}\x1b[39m`, red: (s) => `\x1b[31m${s}\x1b[39m`,
  yellow: (s) => `\x1b[33m${s}\x1b[39m`, cyan: (s) => `\x1b[36m${s}\x1b[39m`,
};
const say = (s = '') => process.stdout.write(s + '\n');
const ok = (s) => say(`${ansi.green('✔')} ${s}`);
const warn = (s) => say(`${ansi.yellow('!')} ${s}`);
const fail = (s) => say(`${ansi.red('✖')} ${s}`);
const tilde = (p) => p.replace(HOME, '~');

function openTTY() {
  try { const fd = fs.openSync('/dev/tty', 'r+'); return { fd, input: new tty.ReadStream(fd) }; }
  catch { return null; }
}

function ask(t, question) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: t.input, output: process.stdout });
    rl.question(question, (a) => { rl.close(); resolve(a.trim()); });
  });
}
async function confirm(t, question, def = true) {
  const a = (await ask(t, `${question} ${ansi.dim(def ? '[Y/n]' : '[y/N]')} `)).toLowerCase();
  return a ? a.startsWith('y') || a === 'ㅛ' : def;
}

function spinner(text) {
  const frames = '⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏';
  let i = 0;
  const id = setInterval(() => process.stdout.write(`\r${ansi.cyan(frames[i++ % frames.length])} ${text}`), 80);
  return (done) => { clearInterval(id); process.stdout.write('\r\x1b[2K'); if (done) ok(done); };
}

// ↑↓ 이동 · space 선택 · a 전체 · enter 완료
function checklist(t, items, selected) {
  return new Promise((resolve) => {
    const sel = new Set(selected);
    let cur = 0;
    let drawn = 0;
    const nameW = Math.min(28, Math.max(...items.map((x) => x.name.length)));
    const draw = () => {
      if (drawn) process.stdout.write(`\x1b[${drawn}A\x1b[0J`);
      const lines = items.map((x, i) => {
        const box = sel.has(i) ? ansi.green('◉') : ansi.dim('◯');
        const pointer = i === cur ? ansi.cyan('›') : ' ';
        const name = i === cur ? ansi.bold(x.name.padEnd(nameW)) : x.name.padEnd(nameW);
        return ` ${pointer} ${box} ${name}  ${ansi.dim(tilde(x.dir))}`;
      });
      lines.push(ansi.dim(`   ↑↓ 이동 · space 선택 · a 전체 · enter 완료   (${sel.size}개 선택됨)`));
      process.stdout.write(lines.join('\n') + '\n');
      drawn = lines.length;
    };
    const done = (result) => {
      t.input.setRawMode(false);
      t.input.removeListener('data', onKey);
      t.input.pause();
      process.stdout.write('\x1b[?25h');
      resolve(result);
    };
    const onKey = (buf) => {
      const k = buf.toString();
      if (k === '\x03' || k === 'q' || k === '\x1b') return done(null);
      if (k === '\x1b[A' || k === 'k') cur = (cur - 1 + items.length) % items.length;
      else if (k === '\x1b[B' || k === 'j') cur = (cur + 1) % items.length;
      else if (k === ' ') sel.has(cur) ? sel.delete(cur) : sel.add(cur);
      else if (k === 'a') { if (sel.size === items.length) sel.clear(); else items.forEach((_, i) => sel.add(i)); }
      else if (k === '\r' || k === '\n') return done([...sel].sort((a, b) => a - b));
      draw();
    };
    process.stdout.write('\x1b[?25l');
    t.input.setRawMode(true);
    t.input.resume();
    t.input.on('data', onKey);
    draw();
  });
}

function projectInfo(dir) {
  const app = readJSON(path.join(dir, 'app.json'));
  const pkg = readJSON(path.join(dir, 'package.json'));
  const name = app?.expo?.name || app?.name || pkg?.name || path.basename(dir);
  return { dir, name: clean(name) };
}

function discoverProjects() {
  const found = new Set();
  const skip = /\/(node_modules|Library|Pods|\.Trash|\.git|\.expo|ios|android|build|dist)\//;
  const add = (out) => String(out || '').split('\n').forEach((f) => {
    if (f.endsWith('/eas.json') && !skip.test(f)) found.add(path.dirname(f));
  });
  try { add(execFileSync('mdfind', ['-onlyin', HOME, 'kMDItemFSName == "eas.json"'], { encoding: 'utf8', timeout: 8000, stdio: ['ignore', 'pipe', 'ignore'] })); }
  catch (e) { add(e.stdout); }
  try {
    add(execFileSync('find', [HOME, '-maxdepth', '5',
      '(', '-name', 'node_modules', '-o', '-name', 'Library', '-o', '-name', 'Pods', '-o', '-name', '.*', ')', '-prune',
      '-o', '-name', 'eas.json', '-type', 'f', '-print'],
      { encoding: 'utf8', timeout: 15000, stdio: ['ignore', 'pipe', 'ignore'] }));
  } catch (e) { add(e.stdout); }
  return [...found];
}

async function setup() {
  const t = openTTY();
  if (!t) { console.error('터미널에서 실행해 주세요: eas-builds setup'); process.exitCode = 1; return; }

  say();
  say(`  ${ansi.bold('EAS Builds')} ${ansi.dim(`v${VERSION}`)}  메뉴바에서 EAS 빌드 상태 보기`);
  say(ansi.dim('  ────────────────────────────────────────────'));
  say();

  // 1. Node / eas-cli
  ok(`Node.js ${process.version}`);
  let cmd = easCommand();
  if (!cmd || !which('eas')) {
    warn('eas-cli가 설치돼 있지 않아요');
    if (await confirm(t, '  npm으로 설치할까요? (npm install -g eas-cli)')) {
      const r = spawnSync('npm', ['install', '-g', 'eas-cli'], { stdio: [t.fd, 'inherit', 'inherit'] });
      if (r.status !== 0) { fail('설치에 실패했어요. 직접 설치한 뒤 다시 실행해 주세요: npm install -g eas-cli'); return; }
    } else if (!cmd) { fail('eas-cli 없이는 진행할 수 없어요'); return; }
    cmd = easCommand();
  }
  const ver = await runEas(['--version'], HOME, 30e3);
  ok(`eas-cli ${ansi.dim(clean((ver.stdout || '').split('\n')[0]).replace(/^eas-cli\//, '').split(' ')[0])}`);

  // 2. 로그인
  let stop = spinner('EAS 로그인 확인 중…');
  let who = await runEas(['whoami'], HOME, 30e3);
  stop();
  if (who.err) {
    warn('EAS에 로그인돼 있지 않아요. 로그인을 시작할게요.');
    spawnSync(cmd[0], [...cmd[1], 'login'], { stdio: [t.fd, 'inherit', 'inherit'] });
    who = await runEas(['whoami'], HOME, 30e3);
    if (who.err) { fail('로그인을 확인하지 못했어요. eas-builds login 으로 다시 시도해 주세요.'); return; }
  }
  ok(`로그인: ${ansi.bold(clean(who.stdout.split('\n')[0]))}`);

  // 3. SwiftBar
  if (process.platform === 'darwin') {
    const running = spawnSync('pgrep', ['-x', 'SwiftBar']).status === 0;
    if (!running) spawnSync('open', ['-a', 'SwiftBar']);
    ok('SwiftBar 실행 중');
  }

  // 4. 프로젝트 찾기
  say();
  stop = spinner('Mac에서 Expo 프로젝트(eas.json) 찾는 중…');
  const cfg = loadConfig();
  const dirs = [...new Set([...cfg.projects.filter((p) => fs.existsSync(p)), ...discoverProjects()])];
  const items = dirs.map(projectInfo).sort((a, b) => a.name.localeCompare(b.name));
  stop(`프로젝트 ${items.length}개 찾음`);

  let chosen = [];
  if (items.length) {
    say();
    say(ansi.bold('  어떤 앱의 빌드를 메뉴바에 띄울까요?'));
    const pre = items.map((x, i) => (cfg.projects.includes(x.dir) ? i : -1)).filter((i) => i >= 0);
    const picked = await checklist(t, items, pre.length ? pre : items.length === 1 ? [0] : []);
    if (picked === null) { say(); warn('취소했어요. 설정은 바뀌지 않았어요.'); return; }
    chosen = picked.map((i) => items[i].dir);
  } else {
    warn('자동으로 찾은 프로젝트가 없어요');
  }

  // 목록에 없는 폴더 직접 추가
  for (;;) {
    const p = await ask(t, ansi.dim(`  목록에 없는 프로젝트 폴더가 있으면 경로를 입력하세요 (없으면 엔터): `));
    if (!p) break;
    const abs = path.resolve(p.replace(/^['"]|['"]$/g, '').replace(/^~(?=$|\/)/, HOME));
    if (fs.existsSync(path.join(abs, 'eas.json'))) { chosen.push(abs); ok(`${projectInfo(abs).name} 추가`); }
    else fail(`${tilde(abs)} 에 eas.json이 없어요`);
  }

  if (!chosen.length) { warn('선택한 프로젝트가 없어요. 나중에 eas-builds setup 으로 다시 고를 수 있어요.'); return; }
  cfg.projects = [...new Set(chosen)];
  saveConfig(cfg);
  say();
  ok(`${cfg.projects.length}개 앱 저장: ${cfg.projects.map((p) => projectInfo(p).name).join(', ')}`);

  // 5. 첫 데이터 받아오기
  stop = spinner('빌드 정보 가져오는 중…');
  releaseLock();
  await fetchAll();
  stop();
  const cache = readCache();
  for (const p of cfg.projects) {
    const bs = (cache?.builds || []).filter((b) => b._project === p);
    const err = cache?.errors?.[p];
    const running = bs.filter((b) => ACTIVE.has(b.status)).length;
    if (err) fail(`${projectInfo(p).name}: ${err.msg}`);
    else ok(`${projectInfo(p).name}: 최근 빌드 ${bs.length}개${running ? ansi.cyan(` · ${running}개 빌드 중`) : ''}`);
  }
  refreshBar();

  say();
  say(`  ${ansi.green('완료!')} 메뉴바의 망치 아이콘을 눌러보세요.`);
  say(ansi.dim('  앱 목록을 바꾸려면 eas-builds setup · 도움말은 eas-builds help'));
  say();
}

async function uninstall() {
  const t = openTTY();
  if (t && !(await confirm(t, 'EAS Builds 플러그인과 설정을 모두 지울까요?', false))) return;
  const shims = [...new Set([which('eas-builds'), '/opt/homebrew/bin/eas-builds', '/usr/local/bin/eas-builds',
    path.join(HOME, '.local', 'bin', 'eas-builds')].filter(Boolean))];
  for (const s of shims) {
    try { if (fs.readFileSync(s, 'utf8').includes('EAS_BUILDS_SHIM')) { fs.unlinkSync(s); ok(`삭제: ${tilde(s)}`); } } catch {}
  }
  for (const d of [CONFIG_DIR, CACHE_DIR]) { fs.rmSync(d, { recursive: true, force: true }); ok(`삭제: ${tilde(d)}`); }
  try { fs.unlinkSync(SCRIPT); ok(`삭제: ${tilde(SCRIPT)}`); } catch {}
  quiet('open', ['-g', 'swiftbar://refreshallplugins']);
  say(ansi.dim('SwiftBar 앱 자체는 그대로 뒀어요. 필요 없으면: brew uninstall --cask swiftbar'));
}

async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  switch (cmd) {
    case '--fetch': await fetchAll(); refreshBar(); break;
    case '--add-project': await addProject(args[0]); break;
    case '--remove-project': updateConfig((c) => c.projects.splice(Number(args[0]), 1)); break;
    case '--toggle-notify': updateConfig((c) => { c.notify = !c.notify; }); break;
    case '--recent': updateConfig((c) => { c.recent = Math.max(1, Math.min(10, Number(args[0]) || 3)); }); break;
    case '--reveal': { const p = loadConfig().projects[Number(args[0])]; if (p) quiet('open', [p]); break; }
    case '--copy': { const c = spawn('pbcopy'); c.on('error', () => {}); c.stdin.end(args[0] || ''); break; }
    case '--cancel': await cancelBuild(args[0], args[1]); break;
    case '--open-config': if (!fs.existsSync(CONFIG)) saveConfig(loadConfig()); quiet('open', ['-t', CONFIG]); break;
    case '--list-projects': loadConfig().projects.forEach((p) => console.log(`${projectInfo(p).name}\t${tilde(p)}`)); break;
    case '--setup': await setup(); process.exit(process.exitCode || 0);
    case '--uninstall': await uninstall(); process.exit(process.exitCode || 0);
    case '--version': console.log(VERSION); break;
    default: render();
  }
}

main().catch((e) => {
  if (!process.argv[2]) {
    console.log(' | sfimage=exclamationmark.triangle');
    console.log('---');
    console.log(`플러그인 오류: ${clean(e.message)} | color=${COLOR.red}`);
  } else console.error(e);
});
JS
