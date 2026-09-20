#!/usr/bin/env node
/* ---------------------------------------------------------------------------
   CDK entry point.

   Everything is driven by context, so nothing has to be edited in code:

     npx cdk deploy \
       -c vpcId=vpc-0123456789abcdef0 \
       -c publicSubnetIds=subnet-0aaa,subnet-0bbb

   Or fill the same keys in cdk.json once and just run `npx cdk deploy`.
   --------------------------------------------------------------------------- */
import * as cdk from 'aws-cdk-lib';
import { CanaryLabStack } from '../lib/canary-stack';

const app = new cdk.App();

function raw(key: string): string | undefined {
  const value = app.node.tryGetContext(key);
  if (value === undefined || value === null) return undefined;
  const asString = String(value).trim();
  return asString === '' ? undefined : asString;
}

function str(key: string, fallback?: string): string {
  const value = raw(key) ?? fallback;
  if (value === undefined) {
    throw new Error(
      `missing required context "${key}". Pass it with -c ${key}=... or set it in cdk.json.`,
    );
  }
  return value;
}

function list(key: string, fallback: string[] = []): string[] {
  const value = raw(key);
  if (!value) return fallback;
  return value
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

function num(key: string, fallback: number): number {
  const value = raw(key);
  if (!value) return fallback;
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) throw new Error(`context "${key}" must be a number, got "${value}"`);
  return parsed;
}

function bool(key: string, fallback: boolean): boolean {
  const value = raw(key);
  if (!value) return fallback;
  return ['1', 'true', 'yes', 'on'].includes(value.toLowerCase());
}

const projectName = str('projectName', 'canary-lab');
const publicSubnetIds = list('publicSubnetIds');

if (!/^[a-z][a-z0-9-]{2,23}$/.test(projectName)) {
  throw new Error('projectName must be 3-24 chars: lowercase letters, digits and hyphens.');
}
if (publicSubnetIds.length < 2) {
  throw new Error(
    'publicSubnetIds needs at least two subnet ids in different availability zones, ' +
      'comma separated. Try: ../../scripts/discover-vpc.sh --format cdk',
  );
}

new CanaryLabStack(app, projectName, {
  stackName: projectName,
  description:
    'ECS Canary in Action - weighted canary deployments on ECS Fargate in an existing VPC (CDK)',
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
  tags: {
    Project: projectName,
    ManagedBy: 'cdk',
    Component: 'ecs-canary-lab',
    Repo: 'roxsross/aws-ecs-canary-in-action',
  },

  projectName,
  vpcId: str('vpcId'),
  publicSubnetIds,
  serviceSubnetIds: list('serviceSubnetIds', publicSubnetIds),
  assignPublicIp: bool('assignPublicIp', true),
  allowedIngressCidr: str('allowedIngressCidr', '0.0.0.0/0'),

  imageTag: str('imageTag', 'v1'),
  containerImage: raw('containerImage'),
  ecrRepositoryName: raw('ecrRepositoryName'),
  createEcrRepository: bool('createEcrRepository', false),
  containerPort: num('containerPort', 8080),
  cpuArchitecture: str('cpuArchitecture', 'X86_64'),

  taskCpu: num('taskCpu', 256),
  taskMemory: num('taskMemory', 512),
  stableDesiredCount: num('stableDesiredCount', 2),
  canaryDesiredCount: num('canaryDesiredCount', 0),
  stableAppVersion: str('stableAppVersion', '1.0.0'),
  canaryAppVersion: str('canaryAppVersion', '2.0.0'),
  enableExecuteCommand: bool('enableExecuteCommand', true),

  stableWeight: num('stableWeight', 100),
  canaryWeight: num('canaryWeight', 0),

  healthCheckPath: str('healthCheckPath', '/api/health'),
  healthCheckInterval: num('healthCheckInterval', 15),
  healthyThreshold: num('healthyThreshold', 2),
  unhealthyThreshold: num('unhealthyThreshold', 2),
  deregistrationDelay: num('deregistrationDelay', 10),

  alarmPeriod: num('alarmPeriod', 60),
  alarmEvaluationPeriods: num('alarmEvaluationPeriods', 1),
  alarm5xxThreshold: num('alarm5xxThreshold', 3),
  alarmLatencyThresholdSeconds: num('alarmLatencyThresholdSeconds', 1),
  alarmErrorRateThreshold: num('alarmErrorRateThreshold', 5),
  enableEmfAlarm: bool('enableEmfAlarm', true),
  enableDashboard: bool('enableDashboard', true),
  alarmSnsTopicArn: raw('alarmSnsTopicArn'),

  metricsNamespace: str('metricsNamespace', 'CanaryLab'),
  recordMode: str('recordMode', 'full'),
  adminToken: raw('adminToken') ?? '',
  grantListenerRead: bool('grantListenerRead', true),
  logRetentionDays: num('logRetentionDays', 7),
});

app.synth();
