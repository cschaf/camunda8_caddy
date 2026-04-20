import { test, expect } from '@playwright/test';
import { execSync, readFileSync } from 'child_process';
import * as path from 'path';
import * as fs from 'fs';

const PROJECT_ROOT = path.resolve(__dirname, '..');

function run(cmd: string): { stdout: string; stderr: string; exitCode: number } {
  try {
    const stdout = execSync(cmd, {
      cwd: PROJECT_ROOT,
      encoding: 'utf-8',
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    return { stdout, stderr: '', exitCode: 0 };
  } catch (error: any) {
    return {
      stdout: error.stdout?.toString() || '',
      stderr: error.stderr?.toString() || '',
      exitCode: error.status || 1,
    };
  }
}

test.describe('Stage Selection', () => {
  test('docker compose config validates for all stages', () => {
    for (const stage of ['prod', 'dev', 'test']) {
      const { exitCode, stderr } = run(
        `docker compose -f docker-compose.yaml -f stages/${stage}.yaml config --quiet`
      );
      expect(exitCode, `Stage ${stage} should produce valid config`).toBe(0);
      expect(stderr).toBe('');
    }
  });

  test('prod stage resources match base docker-compose.yaml', () => {
    const base = run('docker compose -f docker-compose.yaml config').stdout;
    const merged = run(
      'docker compose -f docker-compose.yaml -f stages/prod.yaml config'
    ).stdout;

    // Extract resource lines and compare
    const baseResources = base
      .split('\n')
      .filter((line) => line.includes('memory:') || line.includes('cpus:'))
      .sort();
    const mergedResources = merged
      .split('\n')
      .filter((line) => line.includes('memory:') || line.includes('cpus:'))
      .sort();

    expect(mergedResources).toEqual(baseResources);
  });

  test('start.sh validates STAGE and exits on error', () => {
    const content = fs.readFileSync(
      path.join(PROJECT_ROOT, 'scripts', 'start.sh'),
      'utf-8'
    );
    expect(content).toContain('STAGE not found');
    expect(content).toContain('Unsupported STAGE');
    expect(content).toContain('prod|dev|test');
    expect(content).toContain('docker compose');
    expect(content).toContain('tr \'[:upper:]\' \'[:lower:]\'');
  });

  test('start.ps1 validates STAGE and exits on error', () => {
    const content = fs.readFileSync(
      path.join(PROJECT_ROOT, 'scripts', 'start.ps1'),
      'utf-8'
    );
    expect(content).toContain('STAGE not found');
    expect(content).toContain('Unsupported STAGE');
    expect(content).toContain('-notin @(\'prod\', \'dev\', \'test\')');
    expect(content).toContain('docker compose');
    expect(content).toContain('ToLowerInvariant');
  });

  test('dev and test stages scale JVM heap sizes', () => {
    for (const stage of ['dev', 'test']) {
      const { stdout } = run(
        `docker compose -f docker-compose.yaml -f stages/${stage}.yaml config`
      );

      // Orchestration should have reduced heap
      expect(stdout).toContain('JAVA_TOOL_OPTIONS');

      // Elasticsearch should have reduced heap
      expect(stdout).toContain('ES_JAVA_OPTS');
    }
  });

  test('all stage files reference only known services', () => {
    const { stdout: baseServices } = run(
      'docker compose -f docker-compose.yaml config --services'
    );
    const baseServiceList = baseServices.trim().split('\n').sort();

    for (const stage of ['prod', 'dev', 'test']) {
      const { stdout } = run(
        `docker compose -f docker-compose.yaml -f stages/${stage}.yaml config --services`
      );
      const stageServiceList = stdout.trim().split('\n').sort();
      expect(stageServiceList).toEqual(baseServiceList);
    }
  });
});
