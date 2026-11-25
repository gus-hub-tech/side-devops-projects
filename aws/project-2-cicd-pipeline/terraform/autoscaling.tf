# autoscaling.tf - Application Auto Scaling for the ECS service
#
# Mirrors the target and policy that were created by hand in the console on
# 2026-11-24, so Terraform adopts them instead of leaving the live scaling
# configuration unmanaged:
#
#   target:  min 1, max 3, dimension ecs:service:DesiredCount
#   policy:  target tracking on ECSServiceAverageCPUUtilization
#            target 70%, scale-out cooldown 60s, scale-in cooldown 60s
#
# Application Auto Scaling creates the CloudWatch alarms itself; they are not
# Terraform resources. As observed in the account:
#   scale-out alarm: CPU > 70% for 3 x 60s
#   scale-in alarm:  CPU < 63% for 15 x 60s  (the ~15 minute scale-in delay)

resource "aws_appautoscaling_target" "webapp" {
  service_namespace  = "ecs"
  resource_id        = "service/${var.cluster_name}/${var.service_name}"
  scalable_dimension = "ecs:service:DesiredCount"

  min_capacity = var.autoscaling_min_capacity
  max_capacity = var.autoscaling_max_capacity
}

resource "aws_appautoscaling_policy" "webapp_cpu" {
  # Exact name of the policy already in the account. Changing it would create a
  # second policy instead of adopting the existing one.
  name        = "Target-tracking-auto scaling-policy"
  policy_type = "TargetTrackingScaling"

  service_namespace  = aws_appautoscaling_target.webapp.service_namespace
  resource_id        = aws_appautoscaling_target.webapp.resource_id
  scalable_dimension = aws_appautoscaling_target.webapp.scalable_dimension

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling_cpu_target
    scale_out_cooldown = var.autoscaling_scale_out_cooldown
    scale_in_cooldown  = var.autoscaling_scale_in_cooldown
    disable_scale_in   = false

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
