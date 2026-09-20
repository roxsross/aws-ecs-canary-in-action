/* ---------------------------------------------------------------------------
   Canary lab on ECS Fargate, deployed into a VPC that already exists.

   The VPC and subnets are imported by id, so this stack creates no networking.
   Beyond that it is the same shape as the Terraform and CloudFormation flavours:
   one ALB, two target groups behind a weighted default rule, two Fargate
   services, one DynamoDB table and the alarms that trigger the rollback.
   --------------------------------------------------------------------------- */
import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as cloudwatch from 'aws-cdk-lib/aws-cloudwatch';
import * as cwActions from 'aws-cdk-lib/aws-cloudwatch-actions';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as ecr from 'aws-cdk-lib/aws-ecr';
import * as ecs from 'aws-cdk-lib/aws-ecs';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as sns from 'aws-cdk-lib/aws-sns';

export interface CanaryLabStackProps extends cdk.StackProps {
  readonly projectName: string;

  // existing network
  readonly vpcId: string;
  readonly publicSubnetIds: string[];
  readonly serviceSubnetIds: string[];
  readonly assignPublicIp: boolean;
  readonly allowedIngressCidr: string;

  // image
  readonly imageTag: string;
  readonly containerImage?: string;
  readonly ecrRepositoryName?: string;
  readonly createEcrRepository: boolean;
  readonly containerPort: number;
  readonly cpuArchitecture: string;

  // sizing
  readonly taskCpu: number;
  readonly taskMemory: number;
  readonly stableDesiredCount: number;
  readonly canaryDesiredCount: number;
  readonly stableAppVersion: string;
  readonly canaryAppVersion: string;
  readonly enableExecuteCommand: boolean;

  // traffic split
  readonly stableWeight: number;
  readonly canaryWeight: number;

  // health checks
  readonly healthCheckPath: string;
  readonly healthCheckInterval: number;
  readonly healthyThreshold: number;
  readonly unhealthyThreshold: number;
  readonly deregistrationDelay: number;

  // rollback triggers
  readonly alarmPeriod: number;
  readonly alarmEvaluationPeriods: number;
  readonly alarm5xxThreshold: number;
  readonly alarmLatencyThresholdSeconds: number;
  readonly alarmErrorRateThreshold: number;
  readonly enableEmfAlarm: boolean;
  readonly enableDashboard: boolean;
  readonly alarmSnsTopicArn?: string;

  // app config
  readonly metricsNamespace: string;
  readonly recordMode: string;
  readonly adminToken: string;
  readonly grantListenerRead: boolean;
  readonly logRetentionDays: number;
}

const RETENTION: Record<number, logs.RetentionDays> = {
  1: logs.RetentionDays.ONE_DAY,
  3: logs.RetentionDays.THREE_DAYS,
  5: logs.RetentionDays.FIVE_DAYS,
  7: logs.RetentionDays.ONE_WEEK,
  14: logs.RetentionDays.TWO_WEEKS,
  30: logs.RetentionDays.ONE_MONTH,
  60: logs.RetentionDays.TWO_MONTHS,
  90: logs.RetentionDays.THREE_MONTHS,
  120: logs.RetentionDays.FOUR_MONTHS,
  150: logs.RetentionDays.FIVE_MONTHS,
  180: logs.RetentionDays.SIX_MONTHS,
  365: logs.RetentionDays.ONE_YEAR,
};

export class CanaryLabStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: CanaryLabStackProps) {
    super(scope, id, props);

    const name = props.projectName;
    const repositoryName = props.ecrRepositoryName ?? `${name}-app`;
    const registryUri = `${this.account}.dkr.ecr.${this.region}.amazonaws.com/${repositoryName}`;

    // Composed rather than looked up, so synth never depends on the image
    // already being in the registry.
    const imageUri = props.containerImage ?? `${registryUri}:${props.imageTag}`;

    /* ------------------------------------------------- existing network ---- */
    // Imported by id with token AZs: every subnet is passed explicitly below, so
    // CDK never needs to resolve the VPC's real availability zones.
    const vpc = ec2.Vpc.fromVpcAttributes(this, 'Vpc', {
      vpcId: props.vpcId,
      availabilityZones: cdk.Fn.getAzs(),
    });

    // Expected: CDK cannot resolve AZs for an imported VPC at synth time. Safe here
    // because every construct below receives an explicit subnet list, and it keeps
    // `cdk synth` usable without AWS credentials (no Vpc.fromLookup).
    cdk.Annotations.of(vpc).acknowledgeWarning(
      '@aws-cdk/aws-ec2:vpcAttributeIsListTokenavailabilityZones',
      'Subnets are always passed explicitly, so availability zones are never enumerated.',
    );

    const importSubnet = (scopeId: string, subnetId: string, index: number) => {
      const subnet = ec2.Subnet.fromSubnetId(this, `${scopeId}${index}`, subnetId);
      // Expected: route tables are irrelevant here, nothing reads subnet.routeTable.
      cdk.Annotations.of(subnet).acknowledgeWarning(
        '@aws-cdk/aws-ec2:noSubnetRouteTableId',
        'Route tables belong to the pre-existing VPC and are never referenced.',
      );
      return subnet;
    };

    const albSubnets = props.publicSubnetIds.map((subnetId, index) =>
      importSubnet('AlbSubnet', subnetId, index),
    );
    const serviceSubnets = props.serviceSubnetIds.map((subnetId, index) =>
      importSubnet('ServiceSubnet', subnetId, index),
    );

    /* -------------------------------------------------- security groups ---- */
    const albSg = new ec2.SecurityGroup(this, 'AlbSecurityGroup', {
      vpc,
      securityGroupName: `${name}-alb`,
      description: 'Ingress for the canary lab load balancer',
      allowAllOutbound: false,
    });

    const taskSg = new ec2.SecurityGroup(this, 'TaskSecurityGroup', {
      vpc,
      securityGroupName: `${name}-tasks`,
      description: 'Canary lab Fargate tasks',
      allowAllOutbound: true, // needs ECR, CloudWatch Logs, DynamoDB and the ECS control plane
    });

    // The dashboard is a public demo page with no authentication in front of it.
    // Narrow allowedIngressCidr for anything long lived.
    albSg.addIngressRule(
      ec2.Peer.ipv4(props.allowedIngressCidr),
      ec2.Port.tcp(80),
      `HTTP from ${props.allowedIngressCidr}`,
    );
    albSg.connections.allowTo(taskSg, ec2.Port.tcp(props.containerPort), 'Forward to the app tasks');

    /* ----------------------------------------------------------- registry -- */
    if (props.createEcrRepository) {
      new ecr.Repository(this, 'EcrRepository', {
        repositoryName,
        imageScanOnPush: true,
        imageTagMutability: ecr.TagMutability.MUTABLE,
        emptyOnDelete: true, // lab convenience: allows destroy with images present
        removalPolicy: cdk.RemovalPolicy.DESTROY,
        lifecycleRules: [{ maxImageCount: 20, description: 'Keep the 20 most recent images' }],
      });
    }

    /* ------------------------------------------------------------ storage -- */
    // Single table shared by every task of both tracks, which is what makes the
    // dashboard a global view instead of one container's private counters.
    //   pk=AGG sk=<track>#<version> | pk=TS sk=<minute>#<track>
    //   pk=HIT sk=<epochMs>#<rand>  | pk=CHAOS sk=<track>
    const table = new dynamodb.Table(this, 'TrafficTable', {
      tableName: `${name}-traffic`,
      partitionKey: { name: 'pk', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'sk', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      timeToLiveAttribute: 'expiresAt',
      encryption: dynamodb.TableEncryption.AWS_MANAGED,
      removalPolicy: cdk.RemovalPolicy.DESTROY, // disposable demo data
    });

    /* ----------------------------------------------------- load balancer --- */
    const alb = new elbv2.ApplicationLoadBalancer(this, 'LoadBalancer', {
      loadBalancerName: `${name}-alb`,
      vpc,
      vpcSubnets: { subnets: albSubnets },
      internetFacing: true,
      securityGroup: albSg,
      idleTimeout: cdk.Duration.seconds(60),
      dropInvalidHeaderFields: true,
    });

    const healthCheck: elbv2.HealthCheck = {
      enabled: true,
      path: props.healthCheckPath,
      protocol: elbv2.Protocol.HTTP,
      healthyHttpCodes: '200',
      interval: cdk.Duration.seconds(props.healthCheckInterval),
      timeout: cdk.Duration.seconds(5),
      healthyThresholdCount: props.healthyThreshold,
      unhealthyThresholdCount: props.unhealthyThreshold,
    };

    const stableTg = new elbv2.ApplicationTargetGroup(this, 'StableTargetGroup', {
      targetGroupName: `${name}-stable`,
      vpc,
      port: props.containerPort,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targetType: elbv2.TargetType.IP, // awsvpc networking registers task ENIs by IP
      deregistrationDelay: cdk.Duration.seconds(props.deregistrationDelay),
      healthCheck,
    });

    const canaryTg = new elbv2.ApplicationTargetGroup(this, 'CanaryTargetGroup', {
      targetGroupName: `${name}-canary`,
      vpc,
      port: props.containerPort,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targetType: elbv2.TargetType.IP,
      deregistrationDelay: cdk.Duration.seconds(props.deregistrationDelay),
      healthCheck,
    });

    // The weighted default rule is the canary control knob. Like CloudFormation,
    // CDK has no "ignore changes": a later `cdk deploy` rewrites the live split
    // unless you pass the current values with -c stableWeight/-c canaryWeight.
    const listener = alb.addListener('HttpListener', {
      port: 80,
      protocol: elbv2.ApplicationProtocol.HTTP,
      open: false, // ingress is managed explicitly above
      defaultAction: elbv2.ListenerAction.weightedForward([
        { targetGroup: stableTg, weight: props.stableWeight },
        { targetGroup: canaryTg, weight: props.canaryWeight },
      ]),
    });

    // Forced routing: inspect one version without touching the weights.
    listener.addAction('ForceCanaryByQuery', {
      priority: 10,
      conditions: [elbv2.ListenerCondition.queryStrings([{ key: 'track', value: 'canary' }])],
      action: elbv2.ListenerAction.forward([canaryTg]),
    });
    listener.addAction('ForceStableByQuery', {
      priority: 11,
      conditions: [elbv2.ListenerCondition.queryStrings([{ key: 'track', value: 'stable' }])],
      action: elbv2.ListenerAction.forward([stableTg]),
    });
    listener.addAction('ForceCanaryByHeader', {
      priority: 20,
      conditions: [elbv2.ListenerCondition.httpHeader('X-Canary', ['always'])],
      action: elbv2.ListenerAction.forward([canaryTg]),
    });
    listener.addAction('ForceStableByHeader', {
      priority: 21,
      conditions: [elbv2.ListenerCondition.httpHeader('X-Canary', ['never'])],
      action: elbv2.ListenerAction.forward([stableTg]),
    });

    /* ---------------------------------------------------------------- IAM -- */
    const assumedBy = new iam.ServicePrincipal('ecs-tasks.amazonaws.com', {
      conditions: {
        // Blocks the confused deputy problem: only this account's tasks may assume it.
        StringEquals: { 'aws:SourceAccount': this.account },
      },
    });

    const executionRole = new iam.Role(this, 'ExecutionRole', {
      roleName: `${name}-execution`,
      description: 'Pulls images and ships container logs for the canary lab',
      assumedBy,
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AmazonECSTaskExecutionRolePolicy'),
      ],
    });

    const taskRole = new iam.Role(this, 'TaskRole', {
      roleName: `${name}-task`,
      description: 'Application permissions for the canary lab tasks',
      assumedBy,
    });

    table.grantReadWriteData(taskRole);

    if (props.grantListenerRead) {
      // Lets the dashboard show the weights actually configured on the listener.
      // These Describe* actions have no resource level permissions.
      taskRole.addToPolicy(
        new iam.PolicyStatement({
          sid: 'ReadListenerWeights',
          actions: ['elasticloadbalancing:DescribeRules', 'elasticloadbalancing:DescribeListeners'],
          resources: ['*'],
        }),
      );
    }

    /* ---------------------------------------------------------------- ECS -- */
    const logGroup = new logs.LogGroup(this, 'LogGroup', {
      logGroupName: `/ecs/${name}`,
      retention: RETENTION[props.logRetentionDays] ?? logs.RetentionDays.ONE_WEEK,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    const cluster = new ecs.Cluster(this, 'Cluster', {
      clusterName: name,
      vpc,
      enableFargateCapacityProviders: true,
    });

    const baseEnvironment: Record<string, string> = {
      PROJECT_NAME: name,
      PORT: String(props.containerPort),
      AWS_REGION: this.region,
      TABLE_NAME: table.tableName,
      RECORD_MODE: props.recordMode,
      METRICS_NAMESPACE: props.metricsNamespace,
      LISTENER_ARN: listener.listenerArn,
      STABLE_TARGET_GROUP_ARN: stableTg.targetGroupArn,
      CANARY_TARGET_GROUP_ARN: canaryTg.targetGroupArn,
      ADMIN_TOKEN: props.adminToken,
    };

    const cpuArchitecture =
      props.cpuArchitecture.toUpperCase() === 'ARM64'
        ? ecs.CpuArchitecture.ARM64
        : ecs.CpuArchitecture.X86_64;

    const buildTrack = (track: 'stable' | 'canary') => {
      const isCanary = track === 'canary';
      const pascal = isCanary ? 'Canary' : 'Stable';

      const taskDefinition = new ecs.FargateTaskDefinition(this, `${pascal}TaskDefinition`, {
        family: `${name}-${track}`,
        cpu: props.taskCpu,
        memoryLimitMiB: props.taskMemory,
        executionRole,
        taskRole,
        runtimePlatform: {
          operatingSystemFamily: ecs.OperatingSystemFamily.LINUX,
          // Must match how the image was built. scripts/build-push.sh defaults to
          // linux/amd64 so images built on Apple silicon still run here.
          cpuArchitecture,
        },
      });

      const container = taskDefinition.addContainer('app', {
        containerName: 'app',
        image: ecs.ContainerImage.fromRegistry(imageUri),
        essential: true,
        environment: {
          ...baseEnvironment,
          TRACK: track,
          APP_VERSION: isCanary ? props.canaryAppVersion : props.stableAppVersion,
        },
        portMappings: [
          {
            name: 'http',
            containerPort: props.containerPort,
            protocol: ecs.Protocol.TCP,
            appProtocol: ecs.AppProtocol.http,
          },
        ],
        stopTimeout: cdk.Duration.seconds(20), // room for the app's graceful drain
        logging: ecs.LogDrivers.awsLogs({ streamPrefix: track, logGroup }),
        // Deliberately no container health check: the target group health check is
        // what drives the alarms and the rollback decision.
      });

      // Expected: the image is referenced by URI (the tag moves on every release), so
      // CDK cannot wire repository grants. AmazonECSTaskExecutionRolePolicy on the
      // execution role already carries the ECR pull permissions.
      cdk.Annotations.of(container).acknowledgeWarning(
        '@aws-cdk/aws-ecs:ecrImageRequiresPolicy',
        'Pull permissions come from AmazonECSTaskExecutionRolePolicy on the execution role.',
      );

      const service = new ecs.FargateService(this, `${pascal}Service`, {
        serviceName: `${name}-${track}`,
        cluster,
        taskDefinition,
        desiredCount: isCanary ? props.canaryDesiredCount : props.stableDesiredCount,
        assignPublicIp: props.assignPublicIp,
        vpcSubnets: { subnets: serviceSubnets },
        securityGroups: [taskSg],
        healthCheckGracePeriod: cdk.Duration.seconds(60),
        enableExecuteCommand: props.enableExecuteCommand,
        propagateTags: ecs.PropagatedTagSource.SERVICE,
        minHealthyPercent: 100,
        maxHealthyPercent: 200,
        circuitBreaker: { rollback: true },
      });

      (isCanary ? canaryTg : stableTg).addTarget(service);
      return { service, taskDefinition };
    };

    const stable = buildTrack('stable');
    const canary = buildTrack('canary');

    /* ------------------------------------------------------------- alarms -- */
    const period = cdk.Duration.seconds(props.alarmPeriod);
    const albDimensions = {
      TargetGroup: canaryTg.targetGroupFullName,
      LoadBalancer: alb.loadBalancerFullName,
    };

    const canary5xx = new cloudwatch.Alarm(this, 'Canary5xxAlarm', {
      alarmName: `${name}-canary-5xx`,
      alarmDescription: 'Canary target group is returning 5xx responses',
      metric: new cloudwatch.Metric({
        namespace: 'AWS/ApplicationELB',
        metricName: 'HTTPCode_Target_5XX_Count',
        dimensionsMap: albDimensions,
        statistic: 'Sum',
        period,
      }),
      threshold: props.alarm5xxThreshold,
      evaluationPeriods: props.alarmEvaluationPeriods,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
      // No data means no canary traffic yet, which is not a failure.
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    const canaryLatency = new cloudwatch.Alarm(this, 'CanaryLatencyAlarm', {
      alarmName: `${name}-canary-latency`,
      alarmDescription: 'Canary p95 latency is above the agreed budget',
      metric: new cloudwatch.Metric({
        namespace: 'AWS/ApplicationELB',
        metricName: 'TargetResponseTime',
        dimensionsMap: albDimensions,
        statistic: 'p95',
        period,
      }),
      threshold: props.alarmLatencyThresholdSeconds,
      evaluationPeriods: props.alarmEvaluationPeriods,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    const canaryUnhealthy = new cloudwatch.Alarm(this, 'CanaryUnhealthyAlarm', {
      alarmName: `${name}-canary-unhealthy`,
      alarmDescription: 'Canary target group has unhealthy targets',
      metric: new cloudwatch.Metric({
        namespace: 'AWS/ApplicationELB',
        metricName: 'UnHealthyHostCount',
        dimensionsMap: albDimensions,
        statistic: 'Maximum',
        period,
      }),
      threshold: 1,
      evaluationPeriods: props.alarmEvaluationPeriods,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
    });

    const emfRequests = new cloudwatch.Metric({
      namespace: props.metricsNamespace,
      metricName: 'RequestCount',
      dimensionsMap: { Track: 'canary' },
      statistic: 'Sum',
      period,
    });
    const emfErrors = new cloudwatch.Metric({
      namespace: props.metricsNamespace,
      metricName: 'ErrorCount',
      dimensionsMap: { Track: 'canary' },
      statistic: 'Sum',
      period,
    });

    // Error rate from the app's own embedded metrics: catches application level
    // failures that never reach the ALB as 5xx.
    const canaryErrorRate = props.enableEmfAlarm
      ? new cloudwatch.Alarm(this, 'CanaryErrorRateAlarm', {
          alarmName: `${name}-canary-error-rate`,
          alarmDescription: `Canary application error rate above ${props.alarmErrorRateThreshold}%`,
          metric: new cloudwatch.MathExpression({
            expression: 'IF(requests > 0, 100 * errors / requests, 0)',
            label: 'Canary error rate (%)',
            usingMetrics: { requests: emfRequests, errors: emfErrors },
            period,
          }),
          threshold: props.alarmErrorRateThreshold,
          evaluationPeriods: props.alarmEvaluationPeriods,
          comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
          treatMissingData: cloudwatch.TreatMissingData.NOT_BREACHING,
        })
      : undefined;

    const alarms = [canary5xx, canaryLatency, canaryUnhealthy];
    if (canaryErrorRate) alarms.push(canaryErrorRate);

    if (props.alarmSnsTopicArn) {
      const topic = sns.Topic.fromTopicArn(this, 'AlarmTopic', props.alarmSnsTopicArn);
      const action = new cwActions.SnsAction(topic);
      for (const alarm of alarms) {
        alarm.addAlarmAction(action);
        alarm.addOkAction(action);
      }
    }

    /* ---------------------------------------------------------- dashboard -- */
    if (props.enableDashboard) {
      const trackMetric = (metricName: string, statistic: string) => [
        new cloudwatch.Metric({
          namespace: 'AWS/ApplicationELB',
          metricName,
          dimensionsMap: {
            TargetGroup: stableTg.targetGroupFullName,
            LoadBalancer: alb.loadBalancerFullName,
          },
          statistic,
          period,
          label: `stable ${metricName}`,
        }),
        new cloudwatch.Metric({
          namespace: 'AWS/ApplicationELB',
          metricName,
          dimensionsMap: albDimensions,
          statistic,
          period,
          label: `canary ${metricName}`,
        }),
      ];

      const dashboard = new cloudwatch.Dashboard(this, 'Dashboard', {
        dashboardName: `${name}-canary`,
      });

      dashboard.addWidgets(
        new cloudwatch.GraphWidget({
          title: 'Requests per target group',
          left: trackMetric('RequestCount', 'Sum'),
          width: 12,
        }),
        new cloudwatch.GraphWidget({
          title: '5xx per target group',
          left: trackMetric('HTTPCode_Target_5XX_Count', 'Sum'),
          leftAnnotations: [
            { value: props.alarm5xxThreshold, label: 'alarm threshold', color: '#d62728' },
          ],
          width: 12,
        }),
      );

      dashboard.addWidgets(
        new cloudwatch.GraphWidget({
          title: 'p95 latency per target group',
          left: trackMetric('TargetResponseTime', 'p95'),
          leftAnnotations: [
            {
              value: props.alarmLatencyThresholdSeconds,
              label: 'latency budget',
              color: '#d62728',
            },
          ],
          width: 12,
        }),
        new cloudwatch.GraphWidget({
          title: 'Healthy targets',
          left: [
            ...trackMetric('HealthyHostCount', 'Average'),
            new cloudwatch.Metric({
              namespace: 'AWS/ApplicationELB',
              metricName: 'UnHealthyHostCount',
              dimensionsMap: albDimensions,
              statistic: 'Maximum',
              period,
              label: 'canary unhealthy',
            }),
          ],
          width: 12,
        }),
      );

      dashboard.addWidgets(
        new cloudwatch.GraphWidget({
          title: 'Application metrics (EMF) by track',
          left: [
            new cloudwatch.Metric({
              namespace: props.metricsNamespace,
              metricName: 'RequestCount',
              dimensionsMap: { Track: 'stable' },
              statistic: 'Sum',
              period,
              label: 'stable requests',
            }),
            emfRequests.with({ label: 'canary requests' }),
            emfErrors.with({ label: 'canary errors' }),
          ],
          width: 12,
        }),
        new cloudwatch.AlarmStatusWidget({
          title: 'Canary rollback triggers',
          alarms,
          width: 12,
        }),
      );
    }

    /* ------------------------------------------------------------ outputs -- */
    const out = (key: string, value: string, description?: string, exported = true) => {
      new cdk.CfnOutput(this, key, {
        value,
        description,
        ...(exported ? { exportName: `${this.stackName}-${key}` } : {}),
      });
    };

    out('AppUrl', `http://${alb.loadBalancerDnsName}`, 'Live traffic dashboard', false);
    out(
      'StableOnlyUrl',
      `http://${alb.loadBalancerDnsName}/?track=stable`,
      'Forced routing to the stable version',
      false,
    );
    out(
      'CanaryOnlyUrl',
      `http://${alb.loadBalancerDnsName}/?track=canary`,
      'Forced routing to the canary version',
      false,
    );
    if (props.enableDashboard) {
      out(
        'CloudWatchDashboardUrl',
        `https://${this.region}.console.aws.amazon.com/cloudwatch/home?region=${this.region}#dashboards/dashboard/${name}-canary`,
        'CloudWatch dashboard comparing both tracks',
        false,
      );
    }

    // ---- consumed by scripts/load-env.sh (names match the CloudFormation flavour) ----
    out('CanaryRegion', this.region);
    out('CanaryProject', name);
    out('CanaryCluster', cluster.clusterName);
    out('CanaryAlbDns', alb.loadBalancerDnsName);
    out('CanaryAlbArn', alb.loadBalancerArn);
    out('CanaryListenerArn', listener.listenerArn);
    out('CanaryTgStable', stableTg.targetGroupArn);
    out('CanaryTgCanary', canaryTg.targetGroupArn);
    out('CanarySvcStable', stable.service.serviceName);
    out('CanarySvcCanary', canary.service.serviceName);
    out('CanaryTaskdefStable', `${name}-stable`);
    out('CanaryTaskdefCanary', `${name}-canary`);
    out('CanaryEcrRepo', repositoryName);
    out('CanaryEcrUri', registryUri);
    out('CanaryTable', table.tableName);
    out('CanaryLogGroup', logGroup.logGroupName);
    out('CanaryAlarm5xx', canary5xx.alarmName);
    out('CanaryAlarmLatency', canaryLatency.alarmName);
    out('CanaryAlarmUnhealthy', canaryUnhealthy.alarmName);
    if (canaryErrorRate) out('CanaryAlarmErrorrate', canaryErrorRate.alarmName);
    out('CanaryContainerName', 'app', undefined, false);
    out('CanaryContainerPort', String(props.containerPort), undefined, false);
  }
}
