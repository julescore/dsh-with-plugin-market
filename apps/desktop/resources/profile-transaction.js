/** Profile mutation validation and lockfile-backed rollback for the bundled market. */

import { existsSync, readFileSync, unlinkSync, writeFileSync } from 'node:fs';
import { spawn } from 'node:child_process';
import { join } from 'node:path';
import { dshArgv, killChild } from './dsh-cli.js';
import { profileDir } from './profile.js';
const PROFILE_FILES = ['package.json', 'pnpm-lock.yaml', 'pnpm-workspace.yaml'];
/** Capture the dependency manifest, exact resolution lock, and build-script policy. */
export function captureProfile(profile) {
    const dir = profileDir(profile);
    return {
        profile,
        files: Object.fromEntries(PROFILE_FILES.map(name => {
            const path = join(dir, name);
            return [name, existsSync(path) ? readFileSync(path, 'utf8') : null];
        })),
    };
}
function restoreFiles(snapshot) {
    const dir = profileDir(snapshot.profile);
    for (const name of PROFILE_FILES) {
        const path = join(dir, name);
        const content = snapshot.files[name];
        if (content === null) {
            if (existsSync(path))
                unlinkSync(path);
        }
        else {
            writeFileSync(path, content);
        }
    }
}
/** Compose the complete profile with the same CLI executable that launched the market host. */
export function validateProfile(profile) {
    const { file, args, cwd, viaShell } = dshArgv();
    return new Promise((resolvePromise) => {
        const child = spawn(file, [...args, '--profile', profile, '--dump-config'], {
            cwd,
            env: { ...process.env, CI: 'true' },
            stdio: ['ignore', 'pipe', 'pipe'],
            shell: viaShell,
        });
        let stdout = '';
        let stderr = '';
        let timedOut = false;
        const timer = setTimeout(() => {
            timedOut = true;
            killChild(child);
        }, 60 * 1000);
        child.stdout.on('data', (chunk) => { stdout = (stdout + chunk.toString()).slice(-256 * 1024); });
        child.stderr.on('data', (chunk) => { stderr = (stderr + chunk.toString()).slice(-64 * 1024); });
        child.on('error', (error) => {
            clearTimeout(timer);
            resolvePromise({ exitCode: 127, timedOut: false, stdout, stderr: `${stderr}\n${error.message}` });
        });
        child.on('close', (code) => {
            clearTimeout(timer);
            resolvePromise({ exitCode: code, timedOut, stdout, stderr });
        });
    });
}
/** Restore the old dependency files and materialize their exact lockfile resolution offline. */
export async function rollbackProfile(run, snapshot, validate = validateProfile) {
    restoreFiles(snapshot);
    const install = snapshot.files['pnpm-lock.yaml'] === null
        ? { exitCode: 0, timedOut: false, stdout: '', stderr: '' }
        : await run(snapshot.profile, ['install', '--offline', '--frozen-lockfile']);
    const validation = await validate(snapshot.profile);
    return {
        ok: install.exitCode === 0 && !install.timedOut && validation.exitCode === 0 && !validation.timedOut,
        install,
        validation,
    };
}

/** Validate one dependency mutation and restore its snapshot when installation or composition fails. */
export async function validateProfileMutation(run, snapshot, kind, mutationSucceeded, validate = validateProfile) {
    let ok = mutationSucceeded;
    let error = null;
    let validation = null;
    if (ok) {
        validation = await validate(snapshot.profile);
        if (validation.exitCode !== 0 || validation.timedOut) {
            const detail = (validation.stderr || validation.stdout).trim();
            const action = kind === 'install'
                ? '插件与当前 Web profile 冲突，安装已撤销 / plugin conflicts with the current Web profile; installation was rolled back'
                : '插件更新与当前 Web profile 冲突，更新已撤销 / plugin update conflicts with the current Web profile; update was rolled back';
            error = `${action}${detail === '' ? '' : `: ${detail}`}`;
            ok = false;
        }
    }
    let rollback = null;
    if (!ok) {
        rollback = await rollbackProfile(run, snapshot, validate);
        if (!rollback.ok) {
            const failed = kind === 'install'
                ? '插件安装失败 / plugin installation failed'
                : '插件更新失败 / plugin update failed';
            error = `${error ?? failed}\n\n自动恢复未完成，请使用桌面错误页的“备份并重置 Web profile” / automatic recovery did not complete; use "Back up and reset Web profile" on the desktop error screen.`;
        }
    }
    return { ok, error, validation, rollback };
}
