#!/usr/bin/env node
const { spawnSync } = require('node:child_process');

const args = process.argv.slice(2);
if (args.length === 0) {
  console.error('Usage: turbo-run <...turbo args>');
  process.exit(1);
}

if (args[0] !== 'run') {
  console.error('Fallback supports only "turbo run <task>" invocations.');
  process.exit(1);
}

const task = args[1];
if (!task) {
  console.error('Missing task name for "turbo run".');
  process.exit(1);
}

const prepareFallback = (taskName, extraArgs) => {
  const fallbackArgs = ['--recursive', '--if-present'];
  const passthroughArgs = [];
  const warnings = [];

  for (let i = 0; i < extraArgs.length; i += 1) {
    const current = extraArgs[i];
    if (current === '--') {
      passthroughArgs.push('--', ...extraArgs.slice(i + 1));
      break;
    }
    if (current === '--filter' && i + 1 < extraArgs.length) {
      fallbackArgs.push('--filter', extraArgs[i + 1]);
      i += 1;
      continue;
    }
    if (current.startsWith('--filter=')) {
      fallbackArgs.push(current);
      continue;
    }
    if (current === '--parallel') {
      warnings.push('Ignoring unsupported flag "--parallel" in pnpm fallback.');
      continue;
    }
    if (current.startsWith('--cache')) {
      warnings.push(`Ignoring cache-related flag "${current}" in pnpm fallback.`);
      continue;
    }
    if (current === '--concurrency' && i + 1 < extraArgs.length) {
      warnings.push('Ignoring Turbo concurrency flag in pnpm fallback.');
      i += 1;
      continue;
    }
    if (current.startsWith('--concurrency=')) {
      warnings.push('Ignoring Turbo concurrency flag in pnpm fallback.');
      continue;
    }
    passthroughArgs.push(current);
  }

  return {
    pnpmArgs: [...fallbackArgs, 'run', taskName, ...passthroughArgs],
    warnings,
  };
};

const fallbackPlan = prepareFallback(task, args.slice(2));

const runFallback = (reason) => {
  console.warn('\nTurbo fallback:');
  console.warn(reason);
  fallbackPlan.warnings.forEach((warning) => console.warn(warning));
  const fallback = spawnSync('pnpm', fallbackPlan.pnpmArgs, { stdio: 'inherit' });
  if (fallback.error) {
    console.error(`Failed to run pnpm fallback: ${fallback.error.message}`);
    process.exit(1);
  }
  process.exit(fallback.status === null ? 1 : fallback.status);
};

const hasTurboBinary = () => {
  const platformMap = { linux: 'linux', win32: 'windows', darwin: 'darwin' };
  const archMap = { x64: '64', arm64: 'arm64' };
  const platform = platformMap[process.platform];
  const arch = archMap[process.arch];
  if (!platform || !arch) {
    return false;
  }
  const ext = platform === 'windows' ? '.exe' : '';
  const candidates = [`turbo-${platform}-${arch}/bin/turbo${ext}`];
  if (platform !== 'linux' && arch === 'arm64') {
    candidates.push(`turbo-${platform}-64/bin/turbo${ext}`);
  }
  for (const candidate of candidates) {
    try {
      require.resolve(candidate);
      return true;
    } catch (error) {
      // continue searching other candidates
    }
  }
  return false;
};

if (!hasTurboBinary()) {
  runFallback(
    'Turbo binary for this platform is not available locally; using pnpm --recursive run instead.',
  );
}

const turbo = spawnSync('pnpm', ['exec', 'turbo', ...args], {
  encoding: 'utf8',
  stdio: 'pipe',
});

const printTurboOutput = () => {
  if (turbo.stdout) process.stdout.write(turbo.stdout);
  if (turbo.stderr) process.stderr.write(turbo.stderr);
};

if (turbo.status === 0) {
  printTurboOutput();
  process.exit(0);
}

printTurboOutput();

const combinedOutput = `${turbo.stdout || ''}${turbo.stderr || ''}`;
const turboUnavailable =
  turbo.error ||
  /Turborepo did not find the correct binary for your platform/i.test(combinedOutput) ||
  /Installation has failed/i.test(combinedOutput);

if (!turboUnavailable) {
  const exitCode = turbo.status !== null ? turbo.status : 1;
  process.exit(exitCode);
}

runFallback('Turbo command failed to execute cleanly; falling back to pnpm --recursive run.');
